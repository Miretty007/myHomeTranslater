import AppKit
import Carbon

@MainActor
final class HotKey {
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var sequence: UInt32 = 0
    private let action: () -> Void
    private static let signature: OSType = 0x4D485452

    init(action: @escaping () -> Void) {
        self.action = action
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
                guard id.signature == HotKey.signature, id.id == owner.sequence else { return OSStatus(eventNotHandledErr) }
                owner.action()
                return noErr
            }
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func set(_ shortcut: Shortcut) -> Bool {
        guard handler != nil else { return false }
        let next = sequence &+ 1
        var newRef: EventHotKeyRef?
        guard RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                  EventHotKeyID(signature: Self.signature, id: next),
                                  GetApplicationEventTarget(), 0, &newRef) == noErr else { return false }
        if let registration { UnregisterEventHotKey(registration) }
        registration = newRef
        sequence = next
        return true
    }

    func stop() {
        if let registration { UnregisterEventHotKey(registration) }
        if let handler { RemoveEventHandler(handler) }
        registration = nil
        handler = nil
    }
}

extension Shortcut {
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        guard let chars = event.characters(byApplyingModifiers: [])?.uppercased(), chars.count == 1,
              chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.punctuationCharacters).contains($0) })
        else { return nil }
        var mask: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        where flags.contains(flag) { mask |= UInt32(carbon) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mask, key: chars)
    }
}
