import AppKit
import Carbon

@MainActor
final class HotKey {
    private var handler: EventHandlerRef?
    private var registrations: [ShortcutAction: (id: UInt32, ref: EventHotKeyRef)] = [:]
    private var bindings: [ShortcutAction: Shortcut] = [:]
    private var sequence: UInt32 = 0
    private let perform: (ShortcutAction) -> Void
    private(set) lazy var caps = CapsLockHotKey { [weak self] shortcut in
        guard let self, let action = bindings.first(where: { $0.value == shortcut })?.key else { return }
        perform(action)
    }
    private static let signature: OSType = 0x4D485452

    init(perform: @escaping (ShortcutAction) -> Void) {
        self.perform = perform
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let owner = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard id.signature == HotKey.signature,
                      let action = owner.registrations.first(where: { $0.value.id == id.id })?.key
                else { return OSStatus(eventNotHandledErr) }
                if let record = owner.caps.record, let shortcut = owner.bindings[action] { record(shortcut) }
                else { owner.perform(action) }
                return noErr
            }
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func isRegistered(_ action: ShortcutAction) -> Bool {
        guard let key = bindings[action] else { return false }
        return key.usesCapsLock ? caps.isActive : registrations[action] != nil
    }

    /// Keep the previous binding until its replacement has been acquired.
    func set(_ shortcut: Shortcut?, for action: ShortcutAction) -> String? {
        if let shortcut, bindings.contains(where: { $0.key != action && $0.value == shortcut }) {
            return "Это сочетание уже назначено другой команде переводчика."
        }
        if bindings[action] == shortcut, shortcut == nil || isRegistered(action) { return nil }
        var updated = bindings
        updated[action] = shortcut
        let capsShortcuts = Set(updated.values.filter(\.usesCapsLock))
        var newRef: EventHotKeyRef?
        if let shortcut {
            if shortcut.usesCapsLock {
                guard caps.start() else { return caps.problem ?? CapsModeError.accessibility.localizedDescription }
            } else {
                sequence &+= 1
                guard handler != nil, RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                      EventHotKeyID(signature: Self.signature, id: sequence), GetApplicationEventTarget(), 0, &newRef) == noErr
                else { return "Не удалось зарегистрировать сочетание. Выберите другое." }
            }
        }
        if capsShortcuts.isEmpty, !caps.stop() {
            if let newRef { UnregisterEventHotKey(newRef) }
            return CapsModeError.restore.localizedDescription
        }
        if let old = registrations.removeValue(forKey: action) { UnregisterEventHotKey(old.ref) }
        if let newRef { registrations[action] = (sequence, newRef) }
        bindings = updated
        caps.shortcuts = capsShortcuts
        return nil
    }

    func recordCaps(_ record: ((Shortcut) -> Void)?) -> Bool {
        caps.record = record
        return caps.isActive
    }

    func stop() {
        caps.stop()
        for registration in registrations.values { UnregisterEventHotKey(registration.ref) }
        if let handler { RemoveEventHandler(handler) }
        registrations.removeAll()
        bindings.removeAll()
        handler = nil
    }
}

extension Shortcut {
    // Carbon ANSI codes name positions on a US keyboard, independently of the active input source.
    static let keyLabels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Quote: "'", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ISO_Section: "§",
        kVK_ANSI_Keypad0: "0", kVK_ANSI_Keypad1: "1", kVK_ANSI_Keypad2: "2", kVK_ANSI_Keypad3: "3",
        kVK_ANSI_Keypad4: "4", kVK_ANSI_Keypad5: "5", kVK_ANSI_Keypad6: "6", kVK_ANSI_Keypad7: "7",
        kVK_ANSI_Keypad8: "8", kVK_ANSI_Keypad9: "9", kVK_ANSI_KeypadDecimal: ".", kVK_ANSI_KeypadPlus: "+",
        kVK_ANSI_KeypadMinus: "-", kVK_ANSI_KeypadMultiply: "*", kVK_ANSI_KeypadDivide: "/", kVK_ANSI_KeypadEquals: "=",
        kVK_JIS_KeypadComma: ",", kVK_JIS_Yen: "¥", kVK_JIS_Underscore: "_"
    ]

    init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, capsHeld: Bool = false) {
        guard Self.keyLabels[Int(keyCode)] != nil,
              capsHeld || !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var mask: UInt32 = capsHeld ? UInt32(alphaLock) : 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        where flags.contains(flag) { mask |= UInt32(carbon) }
        self.init(keyCode: UInt32(keyCode), modifiers: mask)
    }
}
