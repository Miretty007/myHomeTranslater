import AppKit
import Carbon
import NaturalLanguage
import Observation
import Translation

extension Locale {
    static let interfaceLanguage = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "ru")
}

enum PanelZoom: Int, CaseIterable {
    case small = 75, standard = 100, large = 125, larger = 150, extraLarge = 175, double = 200

    var factor: CGFloat { CGFloat(rawValue) / 100 }
    var label: String { (Double(rawValue) / 100).formatted(.percent.locale(.interfaceLanguage)) }
}

enum ThemeChoice: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: String(localized: "Системная")
        case .light: String(localized: "Светлая")
        case .dark: String(localized: "Тёмная")
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum ShortcutAction: CaseIterable {
    case text, image
}

struct Shortcut: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(controlKey | optionKey))
    var usesCapsLock: Bool { modifiers & UInt32(alphaLock) != 0 }

    var title: String {
        let symbols = [(alphaLock, "⇪"), (controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
            + (Self.keyLabels[Int(keyCode)] ?? String(localized: "Клавиша \(Int(keyCode))"))
    }
}

struct LanguageOption: Identifiable, Equatable {
    let id: String
    var name: String { Self.name(for: id) }

    static func name(for id: String) -> String {
        let locale = Locale.interfaceLanguage
        return (locale.localizedString(forIdentifier: id) ?? id).capitalized(with: locale)
    }
}

struct Direction: Equatable {
    var source: String?
    var target: String

    static func choose(text: String, sourceOverride: String?, fixedTarget: String) -> Self {
        let guess = sourceOverride ?? detectedLanguage(in: text, preferRussian: fixedTarget == "auto")?.rawValue
        let source = guess == NLLanguage.undetermined.rawValue ? nil : guess
        let target = fixedTarget == "auto" ? (base(source) == "ru" ? "en" : "ru") : fixedTarget
        return Self(source: source, target: target)
    }

    private static func detectedLanguage(in text: String, preferRussian: Bool) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        guard preferRussian, language != .russian, text.utf8.count <= 256,
              Locale.Language(identifier: language.rawValue).script?.identifier == "Cyrl" else { return language }

        let words = text.split(whereSeparator: { !$0.isLetter })
        guard words.count <= 8 else { return language }
        let scores = recognizer.languageHypotheses(withMaximum: 2)
        if let russian = scores[.russian], let winner = scores[language], russian >= 0.8 * winner {
            return .russian
        }

        // The whole heading can score strongly for Bulgarian even when every word
        // scores highest for Russian. Short words like Ukrainian “це” still count.
        guard words.count >= 2, words.allSatisfy({
            NLLanguageRecognizer.dominantLanguage(for: String($0)) == .russian
        }) else { return language }
        return .russian
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
    static let delayRange = 0...3000
    var delayMilliseconds: Int { didSet { defaults.set(delayMilliseconds, forKey: "delayMilliseconds") } }
    var panelZoom: PanelZoom { didSet { defaults.set(panelZoom.rawValue, forKey: "panelZoom") } }
    var target: String { didSet { defaults.set(target, forKey: "target") } }
    var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme"); NSApp.appearance = theme.appearance } }
    var automatic: Bool { didSet { defaults.set(automatic, forKey: "automatic"); onAutomaticChange?() } }
    var highlightOriginal: Bool { didSet { defaults.set(highlightOriginal, forKey: "highlightOriginal") } }
    var dictionaryHints: Bool { didSet { defaults.set(dictionaryHints, forKey: "dictionaryHints") } }
    var shortcut: Shortcut { didSet { defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut") } }
    var imageShortcut: Shortcut? {
        didSet {
            if let imageShortcut { defaults.set(try? JSONEncoder().encode(imageShortcut), forKey: "imageShortcut") }
            else { defaults.removeObject(forKey: "imageShortcut") }
        }
    }
    var languages = [LanguageOption(id: "en"), LanguageOption(id: "ru")]
    var trusted = AXIsProcessTrusted()
    var shortcutProblems: [ShortcutAction: String] = [:]
    var recordingAction: ShortcutAction?
    var recordingShortcut: Bool { recordingAction != nil }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        action == .text ? shortcut : imageShortcut
    }
    @ObservationIgnored var onAutomaticChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let delay = defaults.object(forKey: "delayMilliseconds") as? Int ?? 420
        delayMilliseconds = min(max(delay, Self.delayRange.lowerBound), Self.delayRange.upperBound)
        panelZoom = PanelZoom(rawValue: defaults.integer(forKey: "panelZoom")) ?? .standard
        target = defaults.string(forKey: "target") ?? "auto"
        theme = ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        automatic = defaults.bool(forKey: "automatic")
        highlightOriginal = defaults.bool(forKey: "highlightOriginal")
        dictionaryHints = defaults.bool(forKey: "dictionaryHints")
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .standard
        imageShortcut = defaults.data(forKey: "imageShortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        if target != "auto", !languages.contains(where: { $0.id == target }) { languages.append(.init(id: target)) }
    }

    func loadLanguages() async {
        let supported = await TranslationLanguages.supported()
        guard !supported.isEmpty else { return }
        let ids = Set(supported.map { $0.minimalIdentifier })
        languages = ids.map(LanguageOption.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
