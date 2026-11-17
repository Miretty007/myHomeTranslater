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
    #expect(prefs.delayMilliseconds == 420)
    #expect(prefs.panelZoom == .standard)
    #expect(prefs.shortcut.title == "⌃⌥T")
    prefs.automatic = true
    prefs.delayMilliseconds = 0
    prefs.panelZoom = .extraLarge
    prefs.target = "de"
    prefs.shortcut = Shortcut(keyCode: 11, modifiers: 4096, key: "B")
    let restored = Preferences(defaults: defaults)
    #expect(restored.automatic && restored.target == "de")
    #expect(restored.shortcut == prefs.shortcut)
    #expect(restored.delayMilliseconds == 0)
    #expect(restored.panelZoom == .extraLarge)
    defaults.set(5700, forKey: "delayMilliseconds")
    #expect(Preferences(defaults: defaults).delayMilliseconds == 3000)
}

@MainActor @Test func pinnedWindowKeepsTopLeftAndFitsDisplay() {
    let screen = CGRect(x: -1280, y: 0, width: 1280, height: 800)
    let top = CGPoint(x: -1100, y: 700)
    let frame = PanelPosition.pinnedFrame(size: CGSize(width: 480, height: 250), topLeft: top, visible: screen)
    #expect(frame.minX == top.x && frame.maxY == top.y)
    #expect(PanelPosition.pinnedFrame(size: CGSize(width: 1300, height: 970), topLeft: top, visible: screen) == screen)
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
