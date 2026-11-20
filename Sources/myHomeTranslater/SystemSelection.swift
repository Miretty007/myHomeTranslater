import AppKit
import ApplicationServices

struct Selection: Sendable, Equatable {
    let text: AttributedString
    let pid: pid_t
    let range: CFRange?
    let quartzBounds: CGRect?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pid == rhs.pid && lhs.text == rhs.text && lhs.range?.location == rhs.range?.location
            && lhs.range?.length == rhs.range?.length && lhs.quartzBounds == rhs.quartzBounds
    }
}

// AX requests can wait on another app. Keep them off the window's main thread.
actor SelectionReader {
    private var activationDeadlines: [pid_t: ContinuousClock.Instant] = [:]

    func read(pid: pid_t) async -> Selection? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard var element = await focusedElement(in: app, pid: pid) else { return nil }
        for _ in 0..<5 {
            if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
            if let selection = selection(in: element, pid: pid) { return selection }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return nil
    }

    private func focusedElement(in app: AXUIElement, pid: pid_t) async -> AXUIElement? {
        let key = kAXFocusedUIElementAttribute as CFString
        var focus: CFTypeRef?
        var status = AXUIElementCopyAttributeValue(app, key, &focus)
        if status == .noValue,
           let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           id == "com.google.Chrome" || id.hasPrefix("com.google.Chrome.") || id == "com.openai.codex" {
            // Chromium debounces this request for two seconds. Reissuing it on
            // each selection would postpone activation while the user is dragging.
            let now = ContinuousClock.now
            activationDeadlines = activationDeadlines.filter { $0.value > now }
            let deadline: ContinuousClock.Instant
            if let pending = activationDeadlines[pid] {
                deadline = pending
            } else {
                let result = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                // Chrome can schedule activation and still return notImplemented.
                guard result == .success || result == .notImplemented else { return nil }
                deadline = now + .seconds(3)
                activationDeadlines[pid] = deadline
            }
            while status == .noValue, ContinuousClock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
                status = AXUIElementCopyAttributeValue(app, key, &focus)
            }
        }
        guard !Task.isCancelled, status == .success, let focus,
              CFGetTypeID(focus) == AXUIElementGetTypeID() else { return nil }
        return (focus as! AXUIElement)
    }

    private func selection(in element: AXUIElement, pid: pid_t) -> Selection? {
        var selectedRange: CFRange?
        let raw = attribute(element, kAXSelectedTextRangeAttribute)
        if let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range) { selectedRange = range }
        }
        // Web views (including HTML mail) often expose richer text through markers.
        if let selectedMarkers = attribute(element, "AXSelectedTextMarkerRange") {
            let ordered = orderedMarkerRange(selectedMarkers, in: element)
            let markers: CFTypeRef = ordered ?? selectedMarkers
            let rich = parameter(element, "AXAttributedStringForTextMarkerRange", markers) as? NSAttributedString
            let source = rich ?? (parameter(element, "AXStringForTextMarkerRange", markers) as? String)
                .map(NSAttributedString.init(string:))
            if let source, !source.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let structured = ordered.map { structuredText(source, in: element, selection: $0) } ?? source
                let bounds = boundsForRange(in: element, key: "AXBoundsForTextMarkerRange", range: markers)
                return Selection(text: Passage.formatted(structured), pid: pid, range: selectedRange, quartzBounds: bounds)
            }
        }

        if let raw, let selectedRange, selectedRange.length > 0,
           let rich = parameter(element, kAXAttributedStringForRangeParameterizedAttribute, raw) as? NSAttributedString,
           !rich.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let bounds = boundsForRange(in: element, key: kAXBoundsForRangeParameterizedAttribute, range: raw)
            return Selection(text: Passage.formatted(rich), pid: pid, range: selectedRange, quartzBounds: bounds)
        }

        var text = attribute(element, kAXSelectedTextAttribute) as? String
        if let raw, let selectedRange, selectedRange.length > 0, text?.isEmpty != false {
            text = parameter(element, kAXStringForRangeParameterizedAttribute, raw) as? String
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let bounds = raw.flatMap { boundsForRange(in: element, key: kAXBoundsForRangeParameterizedAttribute, range: $0) }
        return Selection(text: AttributedString(text), pid: pid, range: selectedRange, quartzBounds: bounds)
    }

    // The selection can carry the drag's anchor and focus in either order.
    // Only walk forwards from endpoints whose document order is known.
    private func orderedMarkerRange(_ markers: CFTypeRef, in element: AXUIElement) -> AXTextMarkerRange? {
        guard CFGetTypeID(markers) == AXTextMarkerRangeGetTypeID() else { return nil }
        let selection = markers as! AXTextMarkerRange
        let anchor = AXTextMarkerRangeCopyStartMarker(selection)
        let focus = AXTextMarkerRangeCopyEndMarker(selection)
        if let ordered = parameter(element, "AXTextMarkerRangeForUnorderedTextMarkers", [anchor, focus] as CFArray),
           CFGetTypeID(ordered) == AXTextMarkerRangeGetTypeID() {
            return (ordered as! AXTextMarkerRange)
        }
        let indexKey = "AXIndexForTextMarker"
        guard let anchorIndex = parameter(element, indexKey, anchor) as? Int, anchorIndex >= 0,
              let focusIndex = parameter(element, indexKey, focus) as? Int, focusIndex >= 0,
              anchorIndex != focusIndex else { return nil }
        return anchorIndex < focusIndex ? selection : AXTextMarkerRangeCreate(nil, focus, anchor)
    }

    // Some browsers concatenate accessibility nodes, even in an attributed selection.
    // Ask for paragraph boundaries in that same selection, independently of line wrap.
    private func structuredText(_ source: NSAttributedString, in element: AXUIElement,
                                selection: AXTextMarkerRange) -> NSAttributedString {
        let lengthKey = "AXLengthForTextMarkerRange"
        guard parameter(element, lengthKey, selection) as? Int == source.length else { return source }
        let finish = AXTextMarkerRangeCopyEndMarker(selection)
        var start = AXTextMarkerRangeCopyStartMarker(selection)
        // Select All can start at a child index inside a container. Use its
        // equivalent text position only if it covers the same selected range.
        var node = parameter(element, "AXUIElementForTextMarker", start)
        while let current = node, CFGetTypeID(current) == AXUIElementGetTypeID(),
              let span = parameter(element, "AXTextMarkerRangeForUIElement", current),
              CFGetTypeID(span) == AXTextMarkerRangeGetTypeID() {
            let candidate = AXTextMarkerRangeCopyStartMarker(span as! AXTextMarkerRange)
            guard parameter(element, lengthKey, AXTextMarkerRangeCreate(nil, candidate, finish)) as? Int == source.length else { break }
            start = candidate
            var children: CFArray?
            let item = current as! AXUIElement
            guard AXUIElementCopyAttributeValues(item, kAXChildrenAttribute as CFString, 0, 1, &children) == .success else { break }
            node = (children as? [AXUIElement])?.first
        }
        let result = NSMutableAttributedString(attributedString: source)
        applyInlineStyles(to: result, from: start, in: element)
        let string = source.string as NSString
        let newline = CharacterSet.newlines as NSCharacterSet
        var breaks: [Int] = []
        var cursor = start
        var previousEnd = start
        var offset = 0
        while !Task.isCancelled,
              let next = parameter(element, "AXNextParagraphEndTextMarkerForTextMarker", cursor),
              CFGetTypeID(next) == AXTextMarkerGetTypeID() {
            let end = next as! AXTextMarker
            let range = AXTextMarkerRangeCreate(nil, previousEnd, end)
            guard let length = parameter(element, lengthKey, range) as? Int, length > 0 else { break }
            let boundary = offset + length
            let limit = min(boundary, source.length)
            if let heading = headingLevel(at: boundary > source.length ? finish : end, in: element) {
                result.addAttribute(.init("AXHeadingLevel"), value: heading,
                                    range: NSRange(location: offset, length: limit - offset))
            }
            guard boundary < source.length else { break }
            if !newline.characterIsMember(string.character(at: boundary - 1)),
               !newline.characterIsMember(string.character(at: boundary)) {
                breaks.append(boundary)
            }
            guard let after = parameter(element, "AXNextTextMarkerForTextMarker", end),
                  CFGetTypeID(after) == AXTextMarkerGetTypeID() else { break }
            cursor = after as! AXTextMarker
            previousEnd = end
            offset = boundary
        }
        for index in breaks.reversed() { result.insert(NSAttributedString(string: "\n"), at: index) }
        return result
    }

    // Chromium can expose <strong>/<em> as ancestor roles while reporting a
    // medium-weight font without AXFontBold. Walk only the selected text leaves.
    private func applyInlineStyles(to result: NSMutableAttributedString, from start: AXTextMarker, in element: AXUIElement) {
        var cursor = start
        var previousEnd = start
        var offset = 0
        while offset < result.length, !Task.isCancelled,
              let node = parameter(element, "AXUIElementForTextMarker", cursor),
              CFGetTypeID(node) == AXUIElementGetTypeID(),
              let span = parameter(element, "AXTextMarkerRangeForUIElement", node),
              CFGetTypeID(span) == AXTextMarkerRangeGetTypeID() {
            let end = AXTextMarkerRangeCopyEndMarker(span as! AXTextMarkerRange)
            let range = AXTextMarkerRangeCreate(nil, previousEnd, end)
            guard let length = parameter(element, "AXLengthForTextMarkerRange", range) as? Int, length >= 0 else { break }
            // A selection can begin at the trailing edge of the preceding leaf.
            // Cross that edge once, but stop if the provider stops advancing.
            if length == 0 && !CFEqual(cursor, start) { break }
            let count = min(length, result.length - offset)
            var intent: InlinePresentationIntent = []
            var ancestor: CFTypeRef? = node
            var visited = Set<AXUIElement>()
            while let object = ancestor, CFGetTypeID(object) == AXUIElementGetTypeID() {
                let item = object as! AXUIElement
                guard visited.insert(item).inserted else { break }
                let role = attribute(item, kAXRoleAttribute) as? String
                guard role == "AXStaticText" || role == "AXGroup" || role == "AXLink" else { break }
                switch attribute(item, kAXSubroleAttribute) as? String {
                case "AXStrongStyleGroup": intent.insert(.stronglyEmphasized)
                case "AXEmphasisStyleGroup": intent.insert(.emphasized)
                default: break
                }
                ancestor = attribute(item, kAXParentAttribute)
            }
            if count > 0 && !intent.isEmpty {
                result.addAttribute(.inlinePresentationIntent, value: NSNumber(value: intent.rawValue),
                                    range: NSRange(location: offset, length: count))
            }
            offset += count
            guard offset < result.length, let next = parameter(element, "AXNextTextMarkerForTextMarker", end),
                  CFGetTypeID(next) == AXTextMarkerGetTypeID() else { break }
            guard !CFEqual(cursor, next) else { break }
            cursor = next as! AXTextMarker
            previousEnd = end
        }
    }

    private func headingLevel(at marker: AXTextMarker, in element: AXUIElement) -> Int? {
        var node = parameter(element, "AXUIElementForTextMarker", marker)
        while let current = node, CFGetTypeID(current) == AXUIElementGetTypeID() {
            let item = current as! AXUIElement
            switch attribute(item, kAXRoleAttribute) as? String {
            case "AXHeading": return attribute(item, "AXHeadingLevel") as? Int ?? attribute(item, kAXValueAttribute) as? Int ?? 1
            case "AXStaticText", "AXLink", "AXGroup", "AXGenericElement":
                node = attribute(item, kAXParentAttribute)
            default: return nil
            }
        }
        return nil
    }

    private func boundsForRange(in element: AXUIElement, key: String, range: CFTypeRef) -> CGRect? {
        guard let value = parameter(element, key, range), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), !rect.isEmpty else { return nil }
        return rect
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }

    private func parameter(_ element: AXUIElement, _ key: String, _ value: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, key as CFString, value, &result) == .success ? result : nil
    }
}

@MainActor
enum PanelPosition {
    static func anchor(for selection: Selection?) -> CGRect {
        if let rect = selection?.quartzBounds, let main = NSScreen.screens.first {
            return CGRect(x: rect.minX, y: main.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        return CGRect(origin: NSEvent.mouseLocation, size: .zero)
    }

    static func frame(size: CGSize, anchor: CGRect, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        let below = anchor.minY - 8 - height
        let y = below >= visible.minY ? below : anchor.maxY + 8
        return CGRect(x: min(max(anchor.minX, visible.minX), visible.maxX - width),
                      y: min(max(y, visible.minY), visible.maxY - height), width: width, height: height)
    }

    static func pinnedFrame(size: CGSize, topLeft: CGPoint, visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return CGRect(x: min(max(topLeft.x, visible.minX), visible.maxX - width),
                      y: min(max(topLeft.y - height, visible.minY), visible.maxY - height),
                      width: width, height: height)
    }
}
