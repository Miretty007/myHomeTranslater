import AppKit
import Testing
@testable import myHomeTranslater

@Test func defaultDirections() {
    #expect(Direction.choose(text: "Как пройти к вокзалу?", sourceOverride: nil, fixedTarget: "auto").target == "en")
    #expect(Direction.choose(text: "Where can I buy a train ticket?", sourceOverride: nil, fixedTarget: "auto").target == "ru")
    #expect(Direction.choose(text: "bonjour", sourceOverride: "fr", fixedTarget: "ja") == Direction(source: "fr", target: "ja"))
    #expect(Direction.choose(text: "Привет", sourceOverride: "ru", fixedTarget: "ru").isSameLanguage)
}

@Test func automaticDirectionForShortCyrillicSelections() {
    func automatic(_ text: String, source: String? = nil) -> Direction {
        Direction.choose(text: text, sourceOverride: source, fixedTarget: "auto")
    }

    #expect(automatic("Задачи и напоминания") == Direction(source: "ru", target: "en"))
    #expect(automatic("Задачи и заметки") == Direction(source: "ru", target: "en"))
    #expect(automatic("Список") == Direction(source: "ru", target: "en"))
    #expect(automatic("Задачи и напомняния") == Direction(source: "bg", target: "ru"))
    #expect(automatic("Завдання та нагадування") == Direction(source: "uk", target: "ru"))
    #expect(automatic("Це наша мама") == Direction(source: "uk", target: "ru"))
    #expect(automatic("Задачи и напоминания", source: "bg") == Direction(source: "bg", target: "ru"))
}

@MainActor @Test func persistsPreferences() throws {
    let name = "myHomeTranslater.tests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let prefs = Preferences(defaults: defaults)
    #expect(!prefs.automatic)
    #expect(!prefs.highlightOriginal && !prefs.dictionaryHints)
    prefs.dictionaryHints = true
    #expect(Preferences(defaults: defaults).dictionaryHints && !Preferences(defaults: defaults).highlightOriginal)
    prefs.highlightOriginal = true
    prefs.dictionaryHints = false
    #expect(prefs.delayMilliseconds == 420)
    #expect(prefs.panelZoom == .standard)
    #expect(prefs.shortcut.title == "⌃⌥T")
    prefs.automatic = true
    prefs.delayMilliseconds = 0
    prefs.panelZoom = .extraLarge
    prefs.target = "de"
    prefs.shortcut = Shortcut(keyCode: 11, modifiers: 4096)
    let restored = Preferences(defaults: defaults)
    #expect(restored.highlightOriginal && !restored.dictionaryHints)
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

@MainActor @Test func selectionAndScreenshotPanelsDoubleWidthAt200Characters() {
    let short = String(repeating: "👩‍💻", count: 199)
    func width(_ text: String) -> CGFloat {
        let request = TranslationRequest(AttributedString(text), source: "en", target: "ru", passive: true)
        return PanelContent.request(request).preferredWidth
    }
    #expect(width(short) == 384)
    #expect(width(short + "a") == 768)
    #expect(PanelContent.screenshot(ManualTranslation(text: short)).preferredWidth == 384)
    #expect(PanelContent.screenshot(ManualTranslation(text: short + "a")).preferredWidth == 768)
    #expect(PanelContent.manual(ManualTranslation(text: short + "a")).preferredWidth == 384)
}

@MainActor @Test func readingPanelLimitsBothAxesAtEveryZoom() {
    let state = PanelState()
    state.availableSize = CGSize(width: 1600, height: 1000)
    state.readingSize = CGSize(width: 1, height: 1)
    for zoom in PanelZoom.allCases {
        let scale = zoom.factor
        let floor = CGSize(width: 360 * scale, height: 260 * scale)
        #expect(state.readingFrameSize(scale: scale) == floor)
        #expect(state.constrainedReadingFrame(CGSize(width: 1, height: 660), scale: scale)
                == CGSize(width: floor.width, height: 660))
        #expect(state.constrainedReadingFrame(CGSize(width: 840, height: 1), scale: scale)
                == CGSize(width: 840, height: floor.height))
    }
    state.availableSize = CGSize(width: 640, height: 480)
    #expect(state.readingFrameSize(scale: 2) == state.availableSize)
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

@Test func structuredTranslationKeepsLayoutAndStyledWords() throws {
    var label = AttributedString("Benefits:")
    label.inlinePresentationIntent = .stronglyEmphasized
    let source = AttributedString("Options\r\n\r\n  • ") + label + AttributedString(" Works offline.\n2. Second option\n")
    let layout = PassageTranslation(source, translateStyledRunsSeparately: false)
    #expect(layout.inputs.map { String($0.characters) } == ["Options", "Benefits: Works offline.", "Second option"])
    var targetLabel = AttributedString("Плюсы:")
    targetLabel.inlinePresentationIntent = .stronglyEmphasized
    let expected = AttributedString("Варианты\r\n\r\n  • ") + targetLabel
        + AttributedString(" Работает офлайн.\n2. Второй вариант\n")
    #expect(try layout.assemble(["Варианты", targetLabel + AttributedString(" Работает офлайн."), "Второй вариант"]) == expected)

    let legacy = PassageTranslation(source, translateStyledRunsSeparately: true)
    #expect(legacy.inputs.map { String($0.characters) } == ["Options", "Benefits:", "Works offline.", "Second option"])
    #expect(try legacy.assemble(["Варианты", "Плюсы:", "Работает офлайн.", "Второй вариант"]) == expected)
}

@Test func accessibilityFormattingSeparatesFlattenedBlocks() {
    let rich = NSMutableAttributedString(string: "ОбзорПлюсы: быстроМинусы: цена")
    let raw = rich.string as NSString
    rich.addAttribute(.init("AXHeadingLevel"), value: 2, range: raw.range(of: "Обзор"))
    for (index, text) in ["Плюсы: быстро", "Минусы: цена"].enumerated() {
        rich.addAttributes([.init("AXListItemIndex"): index, .init("AXListItemPrefix"): "•"], range: raw.range(of: text))
    }
    rich.addAttribute(.init("AXFont"), value: ["AXFontBold": true], range: raw.range(of: "Плюсы:"))
    rich.addAttribute(.init("AXFont"), value: ["AXFontItalic": true], range: raw.range(of: "цена"))
    let value = Passage.formatted(rich)
    #expect(String(value.characters) == "Обзор\n• Плюсы: быстро\n• Минусы: цена")
    #expect(value[value.range(of: "Обзор")!].presentationIntent != nil)
    #expect(value[value.range(of: "Плюсы:")!].inlinePresentationIntent == .stronglyEmphasized)
    #expect(value[value.range(of: "цена")!].inlinePresentationIntent == .emphasized)
}

@MainActor @Test func serviceAndClipboardPreserveFormattedText() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let html = "<h2>Options</h2><ul><li><b>Pros:</b> Works <i>offline</i>.</li><li>Free</li></ul>"
    board.setString(html, forType: .html)
    let value = try #require(Passage.read(from: board))
    let text = String(value.characters)
    #expect(text.contains("•") && text.components(separatedBy: .newlines).count >= 3)
    #expect(value[value.range(of: "Options")!].presentationIntent != nil)
    #expect(value[value.range(of: "Pros:")!].inlinePresentationIntent == .stronglyEmphasized)
    #expect(value[value.range(of: "offline")!].inlinePresentationIntent == .emphasized)
    #expect(Passage.copy(value, to: board))
    #expect(board.string(forType: .string) == text)
    let rtf = try #require(board.data(forType: .rtf))
    let exported = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    let index = (exported.string as NSString).range(of: "Pros:").location
    let paragraph = try #require(exported.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
    #expect(paragraph.headIndent > paragraph.firstLineHeadIndent && paragraph.paragraphSpacingBefore > 0)
    let pasted = try #require(Passage.read(from: board))
    #expect(String(pasted.characters) == text)
    #expect(pasted[pasted.range(of: "offline")!].inlinePresentationIntent == .emphasized)
}

@MainActor @Test func listContinuationsAlignWithTheirText() throws {
    let headingStyle = NSMutableParagraphStyle()
    headingStyle.headerLevel = 2
    let document = NSMutableAttributedString(string: "3. План\n", attributes: [.paragraphStyle: headingStyle])
    document.append(NSAttributedString(string: "Введение.\n• Первый длинный пункт занимает несколько строк в панели.\n\t•\tВторой длинный пункт также переносится."))
    let rich = Passage.typeset(Passage.formatted(document), size: 16)
    let text = rich.string as NSString
    let storage = NSTextStorage(attributedString: rich)
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 190, height: 2000))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    storage.addLayoutManager(layout)
    layout.ensureLayout(for: container)
    #expect((rich.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.headIndent == 0)
    for word in ["Первый", "Второй"] {
        let index = text.range(of: word).location
        let style = try #require(rich.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.paragraphSpacingBefore > 0)
        var line = NSRange()
        let glyph = layout.glyphIndexForCharacter(at: index)
        let first = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        let bodyX = first.minX + layout.location(forGlyphAt: glyph).x
        let nextGlyph = NSMaxRange(line)
        let wrapped = layout.lineFragmentRect(forGlyphAt: nextGlyph, effectiveRange: nil)
        let wrappedX = wrapped.minX + layout.location(forGlyphAt: nextGlyph).x
        #expect(abs(wrappedX - bodyX) <= 1)
    }
}
