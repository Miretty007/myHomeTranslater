import AppKit

/// Leave AppKit in charge of editing, dragging, selection and Force Click.
class WordTextView: NSTextView {
    var dictionaryHints = false
    var onTextSelection: ((NSRange?) -> Void)?
    private var pendingClick: NSEvent?
    private var highlights: [NSRange] = []

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        dictionaryHints || onTextSelection != nil || super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if (dictionaryHints || onTextSelection != nil), !event.modifierFlags.contains(.control) {
            pendingClick = event
        }
        super.mouseDown(with: event)
        // NSTextView can consume mouse-up inside its own selection tracking loop.
        if NSApp.currentEvent?.type == .leftMouseUp || NSEvent.pressedMouseButtons & 1 == 0 {
            finishClick()
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        finishClick()
    }

    private func finishClick() {
        guard let event = pendingClick else { return }
        pendingClick = nil
        let selection = selectedRange()
        if selection.length > 0 {
            onTextSelection?(selection)
        } else {
            let word = wordRange(at: convert(event.locationInWindow, from: nil))
            onTextSelection?(word)
            if dictionaryHints, event.clickCount == 1, let word {
                showDefinition(for: nil, range: word, options: nil, baselineOriginProvider: nil)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        let previous = selectedRange()
        super.keyDown(with: event)
        let selection = selectedRange()
        if selection != previous { onTextSelection?(selection.length > 0 ? selection : nil) }
    }

    func wordRange(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage else { return nil }
        let origin = textContainerOrigin
        let position = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: position, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(position)
        else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        let raw = storage.string as NSString
        guard index < raw.length,
              raw.substring(with: raw.rangeOfComposedCharacterSequence(at: index)).contains(where: { $0.isLetter || $0.isNumber })
        else { return nil }
        return storage.doubleClick(at: index)
    }

    func highlight(_ ranges: [NSRange]) {
        guard ranges != highlights, let layout = layoutManager, let storage = textStorage else { return }
        highlights = ranges
        let entireText = NSRange(location: 0, length: storage.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: entireText)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: entireText)
        for range in ranges where NSMaxRange(range) <= storage.length {
            layout.addTemporaryAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.32),
                                           .foregroundColor: NSColor.labelColor], forCharacterRange: range)
        }
        if let first = ranges.first, NSMaxRange(first) <= storage.length { scrollRangeToVisible(first) }
    }
}
