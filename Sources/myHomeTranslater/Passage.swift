import AppKit
import Translation

// Keep semantic formatting independent of the source app's colors, fonts and zoom.
enum Passage {
    static func formatted(_ source: NSAttributedString) -> AttributedString {
        var result = AttributedString()
        let string = source.string as NSString
        var previousHeading = 0
        var previousItem: Int?
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, range, _ in
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            let heading = (attributes[.init("AXHeadingLevel")] as? Int) ?? paragraph?.headerLevel ?? 0
            let text = string.substring(with: range)
            if heading != previousHeading, let last = result.characters.last, !last.isNewline,
               let first = text.first, !first.isNewline {
                result.append(AttributedString("\n"))
            }
            previousHeading = heading
            let item = attributes[.init("AXListItemIndex")] as? Int
            if let item, item != previousItem {
                if previousItem != nil, result.characters.last?.isNewline == false {
                    result.append(AttributedString("\n"))
                }
                let prefix = attributes[.init("AXListItemPrefix")]
                if let marker = (prefix as? NSAttributedString)?.string ?? prefix as? String,
                   !marker.isEmpty, !string.substring(from: range.location).hasPrefix(marker) {
                    result.append(AttributedString(marker.trimmingCharacters(in: .whitespaces) + " "))
                }
            }
            previousItem = item

            let axFont = attributes[.init("AXFont")] as? [String: Any]
            let font = attributes[.font] as? NSFont ?? (axFont?["AXFontName"] as? String).flatMap {
                NSFont(name: $0, size: 12)
            }
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            let inline = attributes[.inlinePresentationIntent] as? NSNumber
            var intent = InlinePresentationIntent(rawValue: inline?.uintValue ?? 0)
            if traits.contains(.bold) || axFont?["AXFontBold"] as? Bool == true || heading > 0 {
                intent.insert(.stronglyEmphasized)
            }
            if traits.contains(.italic) || axFont?["AXFontItalic"] as? Bool == true {
                intent.insert(.emphasized)
            }
            var run = AttributedString(text)
            if !intent.isEmpty { run.inlinePresentationIntent = intent }
            if heading > 0 { run.presentationIntent = PresentationIntent(.header(level: heading), identity: 1) }
            result.append(run)
        }
        return result
    }

    private static func headingLevel(of run: AttributedString.Runs.Run) -> Int? {
        for component in run.presentationIntent?.components ?? [] {
            if case .header(let level) = component.kind { return level }
        }
        return nil
    }

    private static func font(for run: AttributedString.Runs.Run, size: CGFloat) -> NSFont {
        let heading = headingLevel(of: run) != nil
        let intent = run.inlinePresentationIntent ?? []
        let base = NSFont.systemFont(ofSize: heading ? size * 1.2 : size,
                                     weight: heading || intent.contains(.stronglyEmphasized) ? .bold : .regular)
        return intent.contains(.emphasized) ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    }

    @MainActor static func read(from board: NSPasteboard) -> AttributedString? {
        for (type, format) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf), (.html, .html)] {
            guard var data = board.data(forType: type) else { continue }
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: format, .textKit1ListMarkerFormatDocumentOption: true
            ]
            if format == .html {
                // A copied HTML fragment can reference remote images or style sheets.
                let policy = #"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">"#
                data = Data(policy.utf8) + data
                options[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            if let source = try? NSAttributedString(data: data, options: options, documentAttributes: nil),
               !source.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return formatted(source)
            }
        }
        guard let text = board.string(forType: .string) ?? board.string(forType: .init("NSStringPboardType")),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AttributedString(text)
    }

    static func typeset(_ text: AttributedString, size: CGFloat, color: NSColor? = nil) -> NSAttributedString {
        let rich = NSMutableAttributedString()
        for run in text.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: font(for: run, size: size)]
            if let level = headingLevel(of: run) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.headerLevel = level
                attributes[.paragraphStyle] = paragraph
            }
            rich.append(NSAttributedString(string: String(text[run.range].characters), attributes: attributes))
        }
        let string = rich.string as NSString
        var start = 0
        var previousHasText = false
        while start < rich.length {
            var end = 0
            var contentsEnd = 0
            string.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            let range = NSRange(location: start, length: end - start)
            let style = (rich.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            let hasText = contentsEnd > start
            if hasText && previousHasText { style.paragraphSpacingBefore = (size * 0.5).rounded() }
            let line = string.substring(with: NSRange(location: start, length: contentsEnd - start))
            if style.headerLevel == 0, let prefix = line.prefixMatch(of: listPrefix)?.output,
               prefix.contains(where: { !$0.isWhitespace }) {
                // HTML import supplies tabs; accessibility often supplies a bullet and a space.
                // Measure the actual prefix so wrapped lines start at the first word.
                style.tabStops = []
                style.defaultTabInterval = size
                let marker = NSMutableAttributedString(attributedString: rich.attributedSubstring(
                    from: NSRange(location: start, length: prefix.utf16.count)))
                marker.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: marker.length))
                let width = marker.size().width
                style.firstLineHeadIndent = prefix.contains("\t") ? 0 : (size * 0.45).rounded()
                style.headIndent = style.firstLineHeadIndent + width
            }
            rich.addAttribute(.paragraphStyle, value: style, range: range)
            previousHasText = hasText
            start = end
        }
        if let color { rich.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: rich.length)) }
        return rich
    }

    static var listPrefix: Regex<Substring> { /\h*(?:(?:[•◦▪▫‣⁃●○■*+–—-]|[0-9]+[.)]|[a-zA-Z][.)])\h+)?/ }

    @MainActor static func copy(_ text: AttributedString, to board: NSPasteboard) -> Bool {
        let rich = typeset(text, size: 14)
        let item = NSPasteboardItem()
        item.setString(rich.string, forType: .string)
        if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length)) {
            item.setData(rtf, forType: .rtf)
        }
        board.clearContents()
        return board.writeObjects([item])
    }
}

// Only submit the words to Translation. Keep paragraph separators, list markers
// and surrounding whitespace locally so the model cannot merge or renumber them.
struct PassageTranslation {
    private enum Piece {
        case literal(AttributedString)
        case request(Int)
    }
    private var pieces: [Piece] = []
    private(set) var inputs: [AttributedString] = []

    init(_ source: AttributedString, translateStyledRunsSeparately: Bool) {
        let chars = source.characters
        var cursor = chars.startIndex
        while cursor < chars.endIndex {
            let end = chars[cursor...].firstIndex(where: \.isNewline) ?? chars.endIndex
            let line = source[cursor..<end]
            let prefix = String(line.characters).prefixMatch(of: Passage.listPrefix)?.output ?? ""
            let body = chars.index(cursor, offsetBy: prefix.count)
            literal(source[cursor..<body])
            let content = source[body..<end]
            if translateStyledRunsSeparately {
                for run in content.runs { add(source[run.range]) }
            } else {
                add(content)
            }
            cursor = end
            if end < chars.endIndex {
                cursor = chars.index(after: end)
                literal(source[end..<cursor])
            }
        }
    }


    private mutating func literal(_ value: AttributedSubstring) {
        if !value.characters.isEmpty { pieces.append(.literal(AttributedString(value))) }
    }

    private mutating func add(_ value: AttributedSubstring) {
        let chars = value.characters
        guard let start = chars.firstIndex(where: { !$0.isWhitespace }),
              let last = chars.lastIndex(where: { !$0.isWhitespace }) else { literal(value); return }
        guard chars.contains(where: { $0.isLetter || $0.isNumber }) else { literal(value); return }
        let end = chars.index(after: last)
        literal(value[..<start])
        pieces.append(.request(inputs.count))
        inputs.append(AttributedString(value[start..<end]))
        literal(value[end...])
    }

    func assemble(_ translations: [AttributedString]) throws -> AttributedString {
        guard translations.count == inputs.count else { throw CocoaError(.formatting) }
        var result = AttributedString()
        for piece in pieces {
            switch piece {
            case .literal(let text): result.append(text)
            case .request(let index):
                var translated = translations[index]
                // A plain response (macOS 15) corresponds to one uniform source run.
                if let intent = inputs[index].inlinePresentationIntent { translated.inlinePresentationIntent = intent }
                if let heading = inputs[index].presentationIntent { translated.presentationIntent = heading }
                result.append(translated)
            }
        }
        return result
    }
}

extension PassageTranslation {
    static func translate(_ text: AttributedString, using session: TranslationSession, alignWords: Bool = false) async throws -> (AttributedString, String?) {
        #if compiler(>=6.3)
        if #available(macOS 26.4, *) {
            let layout = Self(alignWords ? WordAlignment.mark(text) : text, translateStyledRunsSeparately: false)
            var values: [AttributedString] = []
            var language: String?
            for input in layout.inputs {
                try Task.checkCancellation()
                // The batch API can return plain text for a styled request even
                // when the single-paragraph API can align the same words.
                let response = try await session.translate(input)
                language = response.sourceLanguage.minimalIdentifier
                let target = response.attributedTargetText ?? AttributedString(response.targetText)
                let expected = Set(input.runs.compactMap(\.inlinePresentationIntent))
                let returned = Set(target.runs.compactMap(\.inlinePresentationIntent))
                if input.runs.count > 1 && !expected.isSubset(of: returned) {
                    var styledInput = input
                    styledInput.replacementIndex = nil
                    let (styled, _) = try await translateRuns(styledInput, using: session)
                    values.append(styled)
                } else {
                    values.append(target)
                }
            }
            return (try layout.assemble(values), language)
        }
        #endif
        return try await translateRuns(text, using: session)
    }

    private static func translateRuns(_ text: AttributedString, using session: TranslationSession) async throws
        -> (AttributedString, String?) {
        let layout = Self(text, translateStyledRunsSeparately: true)
        guard !layout.inputs.isEmpty else { return (text, nil) }
        let batch = layout.inputs.map { TranslationSession.Request(sourceText: String($0.characters)) }
        let responses = try await session.translations(from: batch)
        let values = responses.map { AttributedString($0.targetText) }
        return (try layout.assemble(values), responses.first?.sourceLanguage.minimalIdentifier)
    }
}
