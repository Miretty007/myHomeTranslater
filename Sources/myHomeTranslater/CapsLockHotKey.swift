import AppKit
import Carbon
import IOKit.hidsystem

struct CapsChord {
    enum Result: Equatable { case pass, suppress, trigger(Shortcut) }
    private(set) var consumedKeys = Set<UInt16>()

    mutating func handle(key: UInt16, isDown: Bool, repeating: Bool, flags: NSEvent.ModifierFlags,
                         held: Bool, shortcuts: Set<Shortcut>, recording: Bool) -> Result {
        if !isDown { return consumedKeys.remove(key) == nil ? .pass : .suppress }
        if consumedKeys.contains(key) { return .suppress }
        guard held, !repeating, let candidate = Shortcut(keyCode: key, flags: flags, capsHeld: true),
              recording || shortcuts.contains(candidate) else { return .pass }
        consumedKeys.insert(key)
        return .trigger(candidate)
    }
}

// F20 down/up comes from the per-keyboard HID remap, even with Caps Lock delay on.
struct CapsPress {
    private(set) var downAt: UInt64?
    private var used = false
    var held: Bool { downAt != nil }
    mutating func begin(at time: UInt64, anotherModifier: Bool) {
        guard !held else { return }
        downAt = time
        used = anotherModifier
    }
    mutating func markChord() { if held { used = true } }
    mutating func end(at time: UInt64) -> TimeInterval? {
        defer { self = Self() }
        guard !used, let downAt, time >= downAt else { return nil }
        return Double(time - downAt) / 1_000_000_000
    }
}

@MainActor
final class CapsLockHotKey {
    var shortcuts = Set<Shortcut>()
    var record: ((Shortcut) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var problem: String?
    private let action: (Shortcut) -> Void
    private let mapping = CapsKeyboardMapping()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var check: Timer?
    private var connection: io_connect_t = 0
    private var press = CapsPress()
    private var chord = CapsChord()
    private var lastNonLatin: TISInputSource?
    private var inputObserver: NSObjectProtocol?
    var isActive: Bool { tap != nil }

    init(action: @escaping (Shortcut) -> Void) {
        self.action = action
        do { try mapping.restore() } catch { problem = error.localizedDescription }
    }

    func start() -> Bool {
        if isActive { return true }
        do {
            guard AXIsProcessTrusted() else { throw CapsModeError.accessibility }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
            guard service != 0 else { throw CapsModeError.noKeyboard }
            defer { IOObjectRelease(service) }
            guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
            else { throw CapsModeError.accessibility }
            let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<CapsLockHotKey>.fromOpaque(context).takeUnretainedValue()
                return MainActor.assumeIsolated { owner.consume(type, event) } ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { throw CapsModeError.accessibility }
            tap = port
            guard let runSource = CFMachPortCreateRunLoopSource(nil, port, 0) else { throw CapsModeError.accessibility }
            source = runSource
            CFRunLoopAddSource(CFRunLoopGetMain(), runSource, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            try mapping.install()
            // Re-enumerate services after reconnect/wake. An external remap takes priority.
            let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            }
            timer.tolerance = 1
            check = timer
            rememberInputSource()
            inputObserver = DistributedNotificationCenter.default().addObserver(forName:
                Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.rememberInputSource() }
                }
            problem = nil
            return true
        } catch {
            let message = error.localizedDescription
            problem = stop() ? message : CapsModeError.restore.localizedDescription
            return false
        }
    }

    private func refreshDevices() {
        do { try mapping.install(requireKeyboard: false) }
        catch {
            let message = error.localizedDescription
            problem = stop() ? message : CapsModeError.restore.localizedDescription
            onError?(problem ?? message)
        }
    }

    private func consume(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            press = CapsPress()
            chord = CapsChord()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type == .keyDown || type == .keyUp else {
            press.markChord()
            return false
        }
        let key = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if key == kVK_F20 {
            if type == .keyDown, !repeating {
                let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
                press.begin(at: event.timestamp, anotherModifier: !event.flags.intersection(modifiers).isEmpty)
            } else if type == .keyUp, let duration = press.end(at: event.timestamp) {
                performSinglePress(duration: duration)
            }
            return true
        }
        if type == .keyDown { press.markChord() }
        let recording = record
        switch chord.handle(key: key, isDown: type == .keyDown, repeating: repeating,
                            flags: .init(rawValue: UInt(event.flags.rawValue)), held: press.held,
                            shortcuts: shortcuts, recording: recording != nil) {
        case .pass: return false
        case .suppress: return true
        case .trigger(let candidate):
            Task { @MainActor in
                if let recording { recording(candidate) } else { action(candidate) }
            }
            return true
        }
    }

    private func isLatin(_ input: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(input, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    private func rememberInputSource() {
        if let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), !isLatin(current) { lastNonLatin = current }
    }

    private func switchInputSource() -> Bool {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return false }
        if !isLatin(current) {
            lastNonLatin = current
            guard let next = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() else { return false }
            return TISSelectInputSource(next) == noErr
        }
        let properties = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                          kTISPropertyInputSourceIsSelectCapable as String: true] as [String: Any]
        let enabled = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        guard let next = enabled.first(where: { source in lastNonLatin.map { CFEqual(source, $0) } == true })
                ?? enabled.first(where: { !isLatin($0) }) else { return false }
        return TISSelectInputSource(next) == noErr
    }

    private func performSinglePress(duration: TimeInterval) {
        var locked = false
        guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS else { return }
        let switchesSource = UserDefaults.standard.bool(forKey: "TISRomanSwitchState")
        if !locked, switchesSource, duration < 0.5, switchInputSource() { return }
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !locked)
    }

    @discardableResult func stop() -> Bool {
        check?.invalidate()
        check = nil
        if let inputObserver { DistributedNotificationCenter.default().removeObserver(inputObserver) }
        inputObserver = nil
        var restored = true
        do { try mapping.restore() } catch { restored = false; problem = error.localizedDescription }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        if connection != 0 { IOServiceClose(connection); connection = 0 }
        source = nil
        tap = nil
        press = CapsPress()
        chord = CapsChord()
        return restored
    }
}
