import AppKit
import Testing
@testable import myHomeTranslater

// Opt-in because this test opens Chrome and reads the fixture through macOS Accessibility.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MHT_TEST_BROWSER_SELECTION"] == "1"))
func browserSelectionIsIndependentOfDragDirection() async throws {
    try #require(AXIsProcessTrusted(), "Accessibility access is required for the browser integration test")
    let expected = """
    Requirements
    • macOS 26 or later
    • Xcode 26 or later, for the Swift 6.2 toolchain (you never open it)
    • An agent that supports skills: Claude Code, Codex, Cursor, Gemini CLI
    • For clone on native apps: computer use (Claude Pro or Max)
    """
    for partial in [false, true] {
        let forward = try await readFixture(backwards: false, partial: partial)
        let backward = try await readFixture(backwards: true, partial: partial)
        let selected = partial ? String(expected.dropFirst(3).dropLast(5)) : expected
        #expect(String(forward.characters) == selected)
        #expect(String(backward.characters) == selected)
        #expect(backward == forward)
        let heading = try #require(backward.range(of: partial ? "uirements" : "Requirements"))
        #expect(backward[heading].presentationIntent != nil)
        let label = try #require(backward.range(of: "An agent"))
        #expect(backward[label].inlinePresentationIntent == .stronglyEmphasized)
        let emphasis = try #require(backward.range(of: "native apps"))
        #expect(backward[emphasis].inlinePresentationIntent == .emphasized)
    }
}

private func readFixture(backwards: Bool, partial: Bool) async throws -> AttributedString {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent("mht-selection-" + UUID().uuidString)
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: directory) }
    let page = directory.appendingPathComponent("selection.html")
    let html = """
    <!doctype html><meta charset="utf-8"><title>Selection direction test</title>
    <main tabindex="-1"><p>Before the selection.</p><h2>Requirements</h2><ul>
    <li>macOS 26 or later</li><li>Xcode 26 or later, for the Swift 6.2 toolchain (you never open it)</li>
    <li><strong>An agent</strong> that supports skills: Claude Code, Codex, Cursor, Gemini CLI</li>
    <li>For <code>clone</code> on <em>native apps</em>: computer use (Claude Pro or Max)</li></ul>
    <h2>Credits</h2><p>After the selection.</p></main>
    <script>
    window.addEventListener('load', () => {
      document.querySelector('main').focus();
      const first = document.querySelector('h2').firstChild;
      const last = document.querySelector('li:last-child').lastChild;
      const start = [first, \(partial ? 3 : 0)];
      const end = [last, last.length - \(partial ? 5 : 0)];
      const points = \(backwards ? "[...end, ...start]" : "[...start, ...end]");
      getSelection().setBaseAndExtent(...points);
      if (!getSelection().isCollapsed) document.title = 'Selection ready';
    });
    </script>
    """
    try html.write(to: page, atomically: true, encoding: .utf8)
    let browser = Process()
    browser.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
    browser.arguments = ["--user-data-dir=" + directory.appendingPathComponent("profile").path,
                         "--app=" + page.absoluteString, "--no-first-run",
                         "--no-default-browser-check", "--disable-background-networking", "--disable-sync"]
    browser.standardOutput = FileHandle.nullDevice
    browser.standardError = FileHandle.nullDevice
    try browser.run()
    defer {
        if browser.isRunning { browser.terminate() }
        browser.waitUntilExit()
    }
    // Wait for the DOM selection without enabling renderer accessibility or warming up the reader.
    let app = AXUIElementCreateApplication(browser.processIdentifier)
    for _ in 0..<40 {
        try await Task.sleep(for: .milliseconds(200))
        var window: CFTypeRef?
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
           let window, CFGetTypeID(window) == AXUIElementGetTypeID(),
           AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
           (title as? String)?.contains("Selection ready") == true {
            let selection = await SelectionReader().read(pid: browser.processIdentifier)
            return try #require(selection, "First read of the selected web text in a fresh Chrome process").text
        }
    }
    throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The fixture did not select the test text"])
}
