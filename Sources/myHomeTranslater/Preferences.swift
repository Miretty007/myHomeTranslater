import AppKit
import Carbon
import NaturalLanguage
import Observation
import Translation

enum ThemeChoice: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self { case .system: "Системная"; case .light: "Светлая"; case .dark: "Тёмная" }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var key: String
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey), key: "T")

    var title: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }
}

struct LanguageOption: Identifiable, Equatable {
    let id: String
    var name: String { Self.name(for: id) }

    static func name(for id: String) -> String {
        let russian = Locale(identifier: "ru")
        return (russian.localizedString(forIdentifier: id) ?? id).capitalized(with: russian)
    }
}

struct Direction: Equatable {
    var source: String?
    var target: String

    static func choose(text: String, sourceOverride: String?, fixedTarget: String) -> Self {
        let guess = sourceOverride ?? NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
        let source = guess == NLLanguage.undetermined.rawValue ? nil : guess
        let target = fixedTarget == "auto" ? (base(source) == "ru" ? "en" : "ru") : fixedTarget
        return Self(source: source, target: target)
    }

    static func base(_ id: String?) -> String? {
        id.flatMap { Locale.Language(identifier: $0).languageCode?.identifier }
    }

    var isSameLanguage: Bool {
        guard let source else { return false }
        return Locale.Language(identifier: source).isEquivalent(to: Locale.Language(identifier: target))
            || source == target
    }
}

enum TranslationLanguages {
    static func supported() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    static func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }
}

@MainActor @Observable
final class Preferences {
    private let defaults: UserDefaults
    var target: String { didSet { defaults.set(target, forKey: "target") } }
    var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme"); NSApp.appearance = theme.appearance } }
    var automatic: Bool { didSet { defaults.set(automatic, forKey: "automatic"); onAutomaticChange?() } }
    var shortcut: Shortcut { didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") } }
    var languages = [LanguageOption(id: "en"), LanguageOption(id: "ru")]
    var trusted = AXIsProcessTrusted()
    var shortcutProblem: String?
    var recordingShortcut = false
    @ObservationIgnored var onAutomaticChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        target = defaults.string(forKey: "target") ?? "auto"
        theme = ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        automatic = defaults.bool(forKey: "automatic")
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
        if target != "auto", !languages.contains(where: { $0.id == target }) { languages.append(.init(id: target)) }
    }

    func loadLanguages() async {
        let supported = await TranslationLanguages.supported()
        guard !supported.isEmpty else { return }
        let ids = Set(supported.map { $0.minimalIdentifier })
        languages = ids.map(LanguageOption.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
