import Foundation

enum WordAlignment {
    static func words(in text: NSString) -> [NSRange] {
        var words: [NSRange] = []
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byWords, .substringNotRequired]) { _, word, _, _ in
            words.append(word)
        }
        return words
    }

    // Translation preserves Foundation replacement indices on corresponding target runs.
    // Use offsets in the whole original so repeated words and reordered phrases stay distinct.
    static func mark(_ original: AttributedString) -> AttributedString {
        let text = String(original.characters) as NSString
        var marked = original
        for word in words(in: text) {
            if let range = Range(word, in: marked) { marked[range].replacementIndex = word.location }
        }
        return marked
    }

    static func originalRanges(for selection: NSRange, in translation: AttributedString,
                               original: NSString) -> [NSRange] {
        guard let range = Range(selection, in: translation) else { return [] }
        let offsets = Set(translation[range].runs.compactMap { run -> Int? in
            guard let offset = run.replacementIndex,
                  translation[run.range].characters.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return offset
        })
        guard !offsets.isEmpty else { return [] }
        return words(in: original).filter { offsets.contains($0.location) }
    }

    struct Fragment {
        let selectedText: String
        let originalParagraph: NSRange
    }

    // The passage translator preserves paragraph separators even on systems that return plain text.
    static func fragments(for selection: NSRange, in target: NSString, original: NSString) -> [Fragment] {
        func paragraphs(_ text: NSString) -> [NSRange] {
            var spans: [NSRange] = []
            text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                     options: [.byLines, .substringNotRequired]) { _, line, _, _ in spans.append(line) }
            return spans
        }
        let sourceLines = paragraphs(original)
        let targetLines = paragraphs(target)
        guard sourceLines.count == targetLines.count else { return [] }
        return zip(sourceLines, targetLines).compactMap { sourceLine, targetLine in
            let overlap = NSIntersectionRange(selection, targetLine)
            guard overlap.length > 0 else { return nil }
            let line = target.substring(with: targetLine) as NSString
            let selected = NSRange(location: overlap.location - targetLine.location, length: overlap.length)
            let tokens = words(in: line).filter { NSIntersectionRange(selected, $0).length > 0 }
            guard let first = tokens.first, let last = tokens.last else { return nil }
            return Fragment(selectedText: line.substring(with: NSUnionRange(first, last)), originalParagraph: sourceLine)
        }
    }

    static func uniqueMatch(_ backTranslation: String, in original: NSString, paragraph: NSRange) -> NSRange? {
        let translated = backTranslation as NSString
        let needle = words(in: translated).map { translated.substring(with: $0).lowercased() }
        let line = original.substring(with: paragraph) as NSString
        let tokens = words(in: line)
        guard !needle.isEmpty, needle.count <= tokens.count else { return nil }
        let haystack = tokens.map { line.substring(with: $0).lowercased() }
        var match: NSRange?
        for start in 0...(tokens.count - needle.count) {
            let end = start + needle.count
            guard haystack[start..<end].elementsEqual(needle) else { continue }
            guard match == nil else { return nil }
            let span = NSUnionRange(tokens[start], tokens[end - 1])
            match = NSRange(location: paragraph.location + span.location, length: span.length)
        }
        return match
    }
}
