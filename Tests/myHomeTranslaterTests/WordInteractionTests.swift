import AppKit
import Testing
@testable import myHomeTranslater

@Test func alignedSelectionTracksOccurrencesAfterWordReordering() throws {
    let source: NSString = "🐾 A cat and a black cat."
    let marked = WordAlignment.mark(AttributedString(source as String))
    let cat = source.range(of: "cat", options: .backwards)
    let black = source.range(of: "black")
    let secondCat = try #require(Range(cat, in: marked))
    #expect(marked[secondCat].replacementIndex == cat.location)
    var target = AttributedString("un chat noir")
    let noun = try #require(target.range(of: "chat "))
    target[noun].replacementIndex = cat.location
    let adjective = try #require(target.range(of: "noir"))
    target[adjective].replacementIndex = black.location
    let text = String(target.characters) as NSString
    func matches(_ selected: String) -> [NSRange] {
        WordAlignment.originalRanges(for: text.range(of: selected), in: target, original: source)
    }
    #expect(matches("chat") == [cat])
    #expect(matches("hat no") == [black, cat])
    #expect(matches("un") == [])
    #expect(matches(" ") == [])
}

@Test func plainTranslationRequiresUniqueWordsWithinTheMatchingParagraph() {
    let source: NSString = "Blue cat\r\n\r\nThe catfish and the cat.\nCat, cat!"
    let target: NSString = "Синий кот\r\n\r\nСом и кот.\nКот, кот!"
    let selection = target.range(of: "от.\nКо")
    let fragments = WordAlignment.fragments(for: selection, in: target, original: source)
    #expect(fragments.map(\.selectedText) == ["кот", "Кот"])
    let matches = fragments.compactMap { WordAlignment.uniqueMatch("Cat.", in: source, paragraph: $0.originalParagraph) }
    #expect(matches == [NSRange(location: source.range(of: "cat.").location, length: 3)])
    let phrase = WordAlignment.uniqueMatch("The cat!", in: source, paragraph: source.range(of: "The catfish and the cat."))
    #expect(phrase == source.range(of: "the cat", options: .backwards))
}

@Test func dictionaryClickUsesTheWordUnderThePointerAndKeepsTheCaret() async {
    // AppKit tracks mouse drags in a nested event loop. Isolate it from the other UI tests.
    await #expect(processExitsWith: .success) { try await exerciseWordClicks() }
}

@MainActor private func exerciseWordClicks() throws {
    final class DictionaryProbe: WordTextView {
        var definitions: [NSRange] = []
        override func showDefinition(for attrString: NSAttributedString?, range targetRange: NSRange,
                                     options: [NSView.DefinitionOptionKey: Any]? = nil,
                                     baselineOriginProvider originProvider: ((NSRange) -> NSPoint)? = nil) {
            definitions.append(targetRange)
        }
    }
    let app = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
                          styleMask: .borderless, backing: .buffered, defer: false)
    let view = DictionaryProbe(frame: window.contentView!.bounds)
    view.string = "Hello world."
    window.contentView = view
    let layout = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    layout.ensureLayout(for: container)
    func point(at offset: Int) -> NSPoint {
        let glyph = layout.glyphIndexForCharacter(at: offset)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return NSPoint(x: view.textContainerOrigin.x + rect.midX, y: view.textContainerOrigin.y + rect.midY)
    }
    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        else { throw CocoaError(.featureUnsupported) }
        return event
    }
    func click(at point: NSPoint) throws {
        let down = try event(.leftMouseDown, at: point)
        let up = try event(.leftMouseUp, at: point)
        app.postEvent(up, atStart: true)
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }
    let word = NSRange(location: 6, length: 5)
    let inside = point(at: 8)
    #expect(view.wordRange(at: inside) == word)
    #expect(view.wordRange(at: point(at: 5)) == nil)
    #expect(view.wordRange(at: point(at: 11)) == nil)
    #expect(view.wordRange(at: NSPoint(x: 280, y: inside.y)) == nil)
    try click(at: inside)
    #expect(view.definitions.isEmpty)
    view.dictionaryHints = true
    view.mouseMoved(with: try event(.mouseMoved, at: inside))
    #expect(view.definitions.isEmpty)
    try click(at: inside)
    #expect(view.definitions == [word])
    let caret = view.selectedRange()
    #expect(caret.length == 0)
    view.highlight([word])
    #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 8, effectiveRange: nil) != nil)
    #expect(view.selectedRange() == caret && view.string == "Hello world.")
    view.highlight([])
    #expect(layout.temporaryAttribute(.backgroundColor, atCharacterIndex: 8, effectiveRange: nil) == nil)

    view.isEditable = false
    view.dictionaryHints = false
    var chosen: NSRange?
    view.onTextSelection = { chosen = $0 }
    try click(at: inside)
    #expect(chosen == word)
    let start = point(at: 1), end = point(at: 9)
    let up = try event(.leftMouseUp, at: end)
    app.postEvent(up, atStart: true)
    app.postEvent(try event(.leftMouseDragged, at: end), atStart: true)
    view.mouseDown(with: try event(.leftMouseDown, at: start))
    view.mouseUp(with: up)
    #expect(chosen == view.selectedRange())
    #expect((chosen?.length ?? 0) > word.length)
}
