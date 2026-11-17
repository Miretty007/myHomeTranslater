import AppKit
import ApplicationServices

struct Selection: Sendable, Equatable {
    let text: String
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
    func read(pid: pid_t) -> Selection? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let object = attribute(app, kAXFocusedUIElementAttribute),
              CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        var element = object as! AXUIElement
        for _ in 0..<5 {
            if attribute(element, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole { return nil }
            if let selection = selection(in: element, pid: pid) { return selection }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        return nil
    }

    private func selection(in element: AXUIElement, pid: pid_t) -> Selection? {
        var selectedRange: CFRange?
        var rect: CGRect?
        let raw = attribute(element, kAXSelectedTextRangeAttribute)
        if let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range) { selectedRange = range }
        }
        var text = attribute(element, kAXSelectedTextAttribute) as? String
        if let raw, let selectedRange, selectedRange.length > 0 {
            if text?.isEmpty != false {
                text = parameter(element, kAXStringForRangeParameterizedAttribute, raw) as? String
            }
            if let bounds = parameter(element, kAXBoundsForRangeParameterizedAttribute, raw),
               CFGetTypeID(bounds) == AXValueGetTypeID() {
                var result = CGRect.zero
                if AXValueGetValue(bounds as! AXValue, .cgRect, &result), !result.isEmpty { rect = result }
            }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Selection(text: text, pid: pid, range: selectedRange, quartzBounds: rect)
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
}
