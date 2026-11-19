import Foundation
import IOKit.hid
import IOKit.hidsystem

enum CapsModeError: LocalizedError {
    case accessibility, conflict, noKeyboard, write, restore

    var errorDescription: String? {
        switch self {
        case .accessibility: "Включите «Универсальный доступ» для myHomeTranslater."
        case .conflict: "Caps Lock или F20 уже переназначена. Освободите клавишу в Raycast или настройках клавиатуры."
        case .noKeyboard: "macOS не предоставила клавиатуру для режима Caps Lock."
        case .write: "macOS не применила назначение Caps Lock. Проверьте универсальный доступ."
        case .restore: "Не удалось вернуть назначение Caps Lock. Переводчик повторит попытку."
        }
    }
}

// Apple TN2450. Each service owns a separate table. Merge only our entry
// into the current table and remove only that exact pair on release.
@MainActor
final class CapsKeyboardMapping {
    typealias Table = [[String: NSNumber]]
    static let source = kIOHIDKeyboardModifierMappingSrcKey
    static let destination = kIOHIDKeyboardModifierMappingDstKey
    static let caps = NSNumber(value: 0x700000039 as UInt64)
    static let f20 = NSNumber(value: 0x70000006f as UInt64)
    static let pair = [source: caps, destination: f20]

    let client = IOHIDEventSystemClientCreateSimpleClient(nil)
    private let defaults = UserDefaults.standard
    private let journal = "capsModeOwnedKeyboardIDs"
    private var owned: Set<String> {
        didSet {
            if owned.isEmpty { defaults.removeObject(forKey: journal) }
            else { defaults.set(Array(owned), forKey: journal) }
            defaults.synchronize()
        }
    }

    init() {
        owned = Set(defaults.stringArray(forKey: journal) ?? [])
    }

    private var keyboards: [IOHIDServiceClient] {
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return services.filter { IOHIDServiceClientConformsTo($0, 1, 6) != 0 }
    }

    static func adding(to current: Table, modifiers: Table) throws -> Table {
        // A system identity mapping simply means that Caps Lock has its default action.
        for entry in current + modifiers where entry[source] != entry[destination] {
            if [caps, f20].contains(where: { $0 == entry[source] || $0 == entry[destination] }) {
                throw CapsModeError.conflict
            }
        }
        // An existing owner (even one using exactly our destination) stays in charge.
        guard !current.contains(where: { $0[source] == caps }) else { throw CapsModeError.conflict }
        return current + [pair]
    }

    static func removing(from current: Table) -> Table { current.filter { $0 != pair } }

    private func read(_ key: String, _ keyboard: IOHIDServiceClient) throws -> Table {
        guard let value = IOHIDServiceClientCopyProperty(keyboard, key as CFString) else { return [] }
        guard let entries = value as? Table else { throw CapsModeError.conflict }
        return entries
    }

    private func write(_ table: Table, to keyboard: IOHIDServiceClient) throws {
        guard IOHIDServiceClientSetProperty(keyboard, kIOHIDUserKeyUsageMapKey as CFString, table as CFArray),
              try read(kIOHIDUserKeyUsageMapKey, keyboard) == table else { throw CapsModeError.write }
    }

    func install(requireKeyboard: Bool = true) throws {
        let devices = keyboards
        if requireKeyboard && devices.isEmpty { throw CapsModeError.noKeyboard }
        for keyboard in devices {
            let id = (IOHIDServiceClientGetRegistryID(keyboard) as! NSNumber).stringValue
            let table = try read(kIOHIDUserKeyUsageMapKey, keyboard)
            let modifiers = try read(kIOHIDKeyboardModifierMappingPairsKey, keyboard)
            if owned.contains(id), table.contains(Self.pair) {
                // Also detect another owner changing the modifier table while we are active.
                _ = try Self.adding(to: Self.removing(from: table), modifiers: modifiers)
                continue
            }
            let updated = try Self.adding(to: table, modifiers: modifiers)
            owned.insert(id)
            try write(updated, to: keyboard)
        }
    }

    func restore() throws {
        guard !owned.isEmpty else { return }
        var failed = false
        for keyboard in keyboards {
            let id = (IOHIDServiceClientGetRegistryID(keyboard) as! NSNumber).stringValue
            guard owned.contains(id) else { continue }
            do {
                let current = try read(kIOHIDUserKeyUsageMapKey, keyboard)
                if current.contains(Self.pair) { try write(Self.removing(from: current), to: keyboard) }
                owned.remove(id)
            } catch { failed = true }
        }
        // A removed service loses its HID mapping when it disconnects.
        if failed { throw CapsModeError.restore }
        if !owned.isEmpty { owned.removeAll() }
    }
}
