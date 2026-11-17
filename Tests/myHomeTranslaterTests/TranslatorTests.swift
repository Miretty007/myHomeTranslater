import AppKit
import Testing
@testable import myHomeTranslater

@Test func defaultDirections() {
    #expect(Direction.choose(text: "Как пройти к вокзалу?", sourceOverride: nil, fixedTarget: "auto").target == "en")
    #expect(Direction.choose(text: "Where can I buy a train ticket?", sourceOverride: nil, fixedTarget: "auto").target == "ru")
    #expect(Direction.choose(text: "bonjour", sourceOverride: "fr", fixedTarget: "ja") == Direction(source: "fr", target: "ja"))
    #expect(Direction.choose(text: "Привет", sourceOverride: "ru", fixedTarget: "ru").isSameLanguage)
}

@MainActor @Test func persistsPreferences() throws {
    let name = "myHomeTranslater.tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let prefs = Preferences(defaults: defaults)
    #expect(!prefs.automatic)
    #expect(prefs.shortcut.title == "⌃⌥T")
    prefs.automatic = true
    prefs.target = "de"
    prefs.shortcut = Shortcut(keyCode: 11, modifiers: 4096, key: "B")
    let restored = Preferences(defaults: defaults)
    #expect(restored.automatic && restored.target == "de")
    #expect(restored.shortcut == prefs.shortcut)
}

@MainActor @Test func staysInsideScreen() {
    let screen = CGRect(x: -1280, y: 0, width: 1280, height: 800)
    let size = CGSize(width: 384, height: 240)
    for corner in [CGPoint(x: -4, y: 4), CGPoint(x: -1200, y: 784), CGPoint(x: -800, y: 400)] {
        #expect(screen.contains(PanelPosition.frame(size: size, anchor: CGRect(origin: corner, size: .zero), visible: screen)))
    }
}

@MainActor @Test func sameLanguageSkipsTranslation() async {
    let request = TranslationRequest("Hello", source: "en", target: "en", passive: false)
    await request.prepare()
    #expect(request.phase == .sameLanguage)
    #expect(request.configuration == nil)
}
