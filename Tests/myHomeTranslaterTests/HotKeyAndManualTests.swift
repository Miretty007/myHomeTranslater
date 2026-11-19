import AppKit
import Carbon
import IOKit.hidsystem
import Testing
@testable import myHomeTranslater

@Test func physicalKeyLabelsIgnoreLayoutAndLegacySavedCharacters() throws {
    let saved = Data(#"{"keyCode":17,"modifiers":4096,"key":"Е"}"#.utf8)
    let old = try JSONDecoder().decode(Shortcut.self, from: saved)
    #expect(old.title == "⌃T")
    #expect(Shortcut(keyCode: UInt16(kVK_ANSI_T), flags: [.control, .capsLock]) == old)
    #expect(Shortcut(keyCode: UInt16(kVK_ANSI_T), flags: [.capsLock]) == nil)
    #expect(Shortcut(keyCode: UInt16(kVK_ANSI_LeftBracket), flags: [.command])?.title == "⌘[")
    #expect(Shortcut(keyCode: UInt16(kVK_Escape), flags: [], capsHeld: true) == nil)
}

@Test func singleCapsPressFiresOnlyOnceAndChordsDoNotToggle() {
    var press = CapsPress()
    press.begin(at: 100, anotherModifier: false)
    press.begin(at: 200, anotherModifier: false)
    #expect(press.end(at: 100_000_100) == 0.1)
    #expect(press.end(at: 200_000_100) == nil)
    press.begin(at: 10, anotherModifier: false)
    press.markChord()
    #expect(press.end(at: 20) == nil)
    press.begin(at: 10, anotherModifier: true)
    #expect(press.end(at: 20) == nil)
}

@MainActor @Test func capsMappingMergesAndRemovesOnlyItsOwnPair() throws {
    typealias Map = CapsKeyboardMapping
    let other = [Map.source: NSNumber(value: 4), Map.destination: NSNumber(value: 5)]
    let changed = [Map.source: Map.caps, Map.destination: NSNumber(value: 6)]
    let table = try Map.adding(to: [other], modifiers: [])
    #expect(table == [other, Map.pair])
    #expect(Map.removing(from: table + [changed]) == [other, changed])
    #expect(throws: CapsModeError.self) { try Map.adding(to: [Map.pair], modifiers: []) }
    #expect(throws: CapsModeError.self) { try Map.adding(to: [], modifiers: [changed]) }
}

@Test func capsRequiresPhysicalHoldConsumesOnePressAndReleasesInEitherOrder() throws {
    let key = UInt16(kVK_ANSI_T)
    let shortcut = try #require(Shortcut(keyCode: key, flags: [], capsHeld: true))
    let imageKey = UInt16(kVK_ANSI_I)
    let imageShortcut = try #require(Shortcut(keyCode: imageKey, flags: [], capsHeld: true))
    #expect(shortcut.title == "⇪T")
    var chord = CapsChord()
    func handle(_ keyCode: UInt16, held: Bool, down: Bool = true, repeating: Bool = false,
                flags: NSEvent.ModifierFlags = [.capsLock], recording: Bool = false) -> CapsChord.Result {
        chord.handle(key: keyCode, isDown: down, repeating: repeating, flags: flags,
                     held: held, shortcuts: [shortcut, imageShortcut], recording: recording)
    }
    #expect(handle(key, held: false) == .pass)
    #expect(handle(UInt16(kVK_ANSI_A), held: true) == .pass)
    #expect(handle(key, held: true, flags: [.command]) == .pass)
    #expect(handle(key, held: true) == .trigger(shortcut))
    #expect(handle(key, held: true, repeating: true) == .suppress)
    #expect(handle(key, held: false, down: false) == .suppress)
    #expect(handle(key, held: false) == .pass)
    #expect(handle(key, held: true, flags: [], recording: true) == .trigger(shortcut))
    #expect(handle(key, held: true, down: false) == .suppress)
    #expect(handle(imageKey, held: true) == .trigger(imageShortcut))
    #expect(handle(imageKey, held: false, down: false) == .suppress)
    #expect(chord.consumedKeys.isEmpty)
}

@MainActor @Test func imageShortcutIsOptionalAndIndependentOfTextShortcut() throws {
    let suite = "myHomeTranslater.shortcuts." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = Preferences(defaults: defaults)
    let text = try #require(Shortcut(keyCode: UInt16(kVK_ANSI_T), flags: [], capsHeld: true))
    let image = try #require(Shortcut(keyCode: UInt16(kVK_ANSI_I), flags: [], capsHeld: true))
    preferences.shortcut = text
    #expect(Preferences(defaults: defaults).imageShortcut == nil)
    preferences.imageShortcut = image
    let restored = Preferences(defaults: defaults)
    #expect(restored.imageShortcut == image && restored.shortcut == text)
    restored.imageShortcut = nil
    let cleared = Preferences(defaults: defaults)
    #expect(cleared.imageShortcut == nil && cleared.shortcut == text)
}

@MainActor @Test func manualTypingCancelsOldRequestsAndClearsEmptyInput() async throws {
    let editor = ManualTranslation()
    editor.edit("one", target: "ru")
    editor.edit("two\nlines", target: "ru")
    #expect(editor.request == nil)
    let deadline = ContinuousClock.now + .seconds(3)
    while editor.request == nil, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(30))
    }
    let request = try #require(editor.request)
    #expect(request.text == "two\nlines")
    editor.edit("three", target: "ru")
    #expect(request.cancelled && editor.request == nil)
    editor.translate(source: "en", target: "de")
    #expect(editor.request?.direction == Direction(source: "en", target: "de"))
    editor.edit(" \n", target: "de")
    try await Task.sleep(for: .milliseconds(500))
    #expect(editor.request == nil)
}
