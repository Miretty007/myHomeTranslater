import AppKit
import SwiftUI

@main
enum MyHomeTranslater {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppController()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let preferences = Preferences()
    private let reader = SelectionReader()
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private var monitors: [Any] = []
    private var permissionTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var lastSelection: Selection?
    private var pending: Task<Void, Never>?
    private var firstOpen: Task<Void, Never>?
    private var panel: TranslationPanel?
    private let panelState = PanelState()
    private var request: TranslationRequest?
    private var manual: ManualTranslation?
    private let screenshot = AreaScreenshot()
    private lazy var readScreenshot: (@MainActor () -> Void) async throws -> String? = screenshot.readText
    private var screenshotTask: Task<Void, Never>?
    private var presentation = UUID()
    private var passivePanel = false
    private var watchesSelection: Bool { preferences.automatic || panelState.translatesSelection }
    private var anchor = CGRect.zero
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = preferences.theme.appearance
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "translate", accessibilityDescription: "myHomeTranslater")
        item.button?.toolTip = "myHomeTranslater"
        item.menu = NSMenu()
        item.menu?.delegate = self
        statusItem = item
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appMenu.addItem(appItem)
        let commands = NSMenu(title: "myHomeTranslater")
        commands.addItem(makeItem("Настройки…", #selector(showSettings), key: ","))
        commands.addItem(makeItem("Завершить myHomeTranslater", #selector(quit), key: "q"))
        appItem.submenu = commands
        let editItem = NSMenuItem()
        appMenu.addItem(editItem)
        let edit = NSMenu(title: "Правка")
        for (label, selector, key) in [("Отменить", Selector(("undo:")), "z"),
                                        ("Вырезать", #selector(NSText.cut(_:)), "x"),
                                        ("Скопировать", #selector(NSText.copy(_:)), "c"),
                                        ("Вставить", #selector(NSText.paste(_:)), "v"),
                                        ("Выделить всё", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: label, action: selector, keyEquivalent: key)
        }
        editItem.submenu = edit
        NSApp.mainMenu = appMenu

        hotKey = HotKey { [weak self] action in
            switch action {
            case .text: self?.handleShortcut()
            case .image: self?.takeScreenshot()
            }
        }
        hotKey?.caps.onError = { [weak self] message in
            guard let self else { return }
            for action in ShortcutAction.allCases where preferences.shortcut(for: action)?.usesCapsLock == true {
                preferences.shortcutProblems[action] = message
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["MHT_VERIFY"] != nil,
           Bundle.main.bundleIdentifier == "com.myhome.translater.verification" {
            // The verification copy can run alongside the installed app and survives failed runs.
            preferences.shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | optionKey | controlKey))
            preferences.imageShortcut = nil
            preferences.automatic = false
        }
        #endif
        registerShortcut(preferences.shortcut)
        if let imageShortcut = preferences.imageShortcut { registerShortcut(imageShortcut, for: .image) }
        preferences.onAutomaticChange = { [weak self] in
            guard let self else { return }
            pending?.cancel()
            lastSelection = nil
            if !watchesSelection && passivePanel { dismissPanel() }
            if preferences.automatic && !AXIsProcessTrusted() { pollPermission() }
            refreshMonitors()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.screenshotTask == nil else { return }
                self?.pending?.cancel()
                self?.lastSelection = nil
                if self?.passivePanel == true { self?.dismissPanel() }
            }
        }
        refreshMonitors()
        Task { await preferences.loadLanguages() }
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["MHT_VERIFY"] {
            Task { await verifyApp(in: URL(fileURLWithPath: output)) }
            return
        }
        #endif
        if !UserDefaults.standard.bool(forKey: "didOpen") {
            firstOpen = Task {
                try? await Task.sleep(for: .milliseconds(650))
                if !Task.isCancelled && panel == nil { showSettings() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel?.isVisible != true, screenshotTask == nil { showSettings() }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let translate = makeItem("Перевести текст…", #selector(handleShortcut))
        translate.toolTip = preferences.shortcut.title
        menu.addItem(translate)
        let automatic = makeItem("Переводить сразу после выделения", #selector(toggleAutomatic))
        automatic.state = preferences.automatic ? .on : .off
        menu.addItem(automatic)
        menu.addItem(.separator())
        menu.addItem(makeItem("Настройки…", #selector(showSettings), key: ","))
        menu.addItem(makeItem("Завершить myHomeTranslater", #selector(quit), key: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func toggleAutomatic() {
        preferences.automatic.toggle()
        if preferences.automatic && !AXIsProcessTrusted() { showSettings() }
    }

    @objc func showSettings() {
        if screenshotTask != nil {
            cancelScreenshot()
            if panelState.isPinned { panel?.orderFrontRegardless() }
        }
        firstOpen?.cancel()
        UserDefaults.standard.set(true, forKey: "didOpen")
        dismissPanel()
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, changeShortcut: { [weak self] in self?.registerShortcut($0, for: $1) },
                                    recordCaps: { [weak self] in self?.hotKey?.recordCaps($0) ?? false },
                                    requestAccess: { [weak self] in self?.requestAccess() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 606),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Настройки myHomeTranslater"
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        preferences.trusted = AXIsProcessTrusted()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        pollPermission()
    }

    private func pollPermission() {
        permissionTimer?.invalidate()
        let timer = Timer.scheduledTimer(timeInterval: 1.5, target: self, selector: #selector(checkPermission),
                                        userInfo: nil, repeats: true)
        timer.tolerance = 0.35
        permissionTimer = timer
    }

    @objc private func checkPermission() {
        let trust = AXIsProcessTrusted()
        if preferences.trusted != trust { preferences.trusted = trust; refreshMonitors() }
        if trust {
            for action in ShortcutAction.allCases {
                if let key = preferences.shortcut(for: action), key.usesCapsLock,
                   preferences.shortcutProblems[action] == CapsModeError.accessibility.localizedDescription {
                    registerShortcut(key, for: action)
                }
            }
        }
        if settingsWindow?.isVisible != true && (!watchesSelection || trust) { permissionTimer?.invalidate() }
    }

    private func requestAccess() {
        // Register this app in the privacy pane, then let the user change its switch.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        pollPermission()
    }

    private func registerShortcut(_ shortcut: Shortcut?, for action: ShortcutAction = .text) {
        guard let hotKey else { return }
        let other: ShortcutAction = action == .text ? .image : .text
        if let shortcut, shortcut == preferences.shortcut(for: other) {
            preferences.shortcutProblems[action] = "Это сочетание уже назначено другой команде переводчика."
            return
        }
        let problem = hotKey.set(shortcut, for: action)
        preferences.shortcutProblems[action] = problem
        guard problem == nil else { return }
        switch action {
        case .text: if let shortcut { preferences.shortcut = shortcut }
        case .image: preferences.imageShortcut = shortcut
        }
    }

    // AppKit invokes this exact three-argument selector for NSServices.
    @objc(translateSelection:userData:error:)
    func translateSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let raw = Passage.read(from: board) else {
            error.pointee = "Выделите слово или фразу." as NSString
            return
        }
        pending?.cancel()
        lastSelection = nil
        present(text: raw, source: nil, anchor: PanelPosition.anchor(for: nil), passive: false)
    }

    @objc private func handleShortcut() {
        guard !preferences.recordingShortcut, screenshotTask == nil else { return }
        pending?.cancel()
        if manual != nil, panel?.isKeyWindow == true { return }
        preferences.trusted = AXIsProcessTrusted()
        guard preferences.trusted else {
            showManual()
            return
        }
        readSelection(automatic: false)
    }

    private func refreshMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        guard screenshotTask == nil else { return }
        let panelVisible = panel?.isVisible == true
        guard preferences.automatic || panelVisible else { return }
        var mask: NSEvent.EventTypeMask = [.leftMouseDown]
        if AXIsProcessTrusted() {
            mask.insert(.keyDown)
            if watchesSelection { mask.formUnion([.leftMouseUp, .keyUp]) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.externalEvent(event)
        }) { monitors.append(monitor) }
    }

    private func externalEvent(_ event: NSEvent) {
        guard screenshotTask == nil else { return }
        if event.type == .keyDown && event.keyCode == 53 {
            pending?.cancel()
            dismissPanel()
            return
        }
        if event.type == .leftMouseDown {
            pending?.cancel()
            if panel?.isVisible == true && panel?.attachedSheet == nil { dismissPanel() }
            if !panelState.translatesSelection { lastSelection = nil }
            return
        }
        guard watchesSelection, AXIsProcessTrusted(), !preferences.recordingShortcut else { return }
        let selectionKey = event.modifierFlags.contains(.shift)
            || (event.modifierFlags.contains(.command) && event.keyCode == 0)
        if event.type == .leftMouseUp || (event.type == .keyUp && selectionKey) { readSelection(automatic: true) }
        if event.type == .keyDown {
            pending?.cancel()
            if passivePanel && !selectionKey { dismissPanel() }
            if !selectionKey { lastSelection = nil }
        }
    }

    private func readSelection(automatic: Bool) {
        pending?.cancel()
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else {
            if !automatic { showManual() }
            return
        }
        pending = Task {
            if automatic && !panelState.translatesSelection {
                try? await Task.sleep(for: .milliseconds(preferences.delayMilliseconds))
            }
            guard !Task.isCancelled else { return }
            var selection = await reader.read(pid: pid)
            // The release event can arrive before a browser publishes its new AX selection.
            // Use fresh text immediately and retry an empty or still-displayed value once.
            if automatic && panelState.translatesSelection && (selection == nil || selection?.text == request?.text) {
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                selection = await reader.read(pid: pid)
            }
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let selection else {
                lastSelection = nil
                if !automatic { showManual() }
                else if passivePanel { dismissPanel() }
                return
            }
            if automatic && (lastSelection == selection || !watchesSelection || panel?.attachedSheet != nil) { return }
            lastSelection = selection
            present(text: selection.text, source: nil, anchor: PanelPosition.anchor(for: selection), passive: automatic)
        }
    }

    private func showManual() {
        lastSelection = nil
        if manual != nil, let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        display(.manual(ManualTranslation()), at: PanelPosition.anchor(for: nil), passive: false)
    }

    private func takeScreenshot() {
        guard !preferences.recordingShortcut else { return }
        translateScreenshot(readText: readScreenshot)
    }

    private func translateScreenshot(readText: @escaping (@MainActor () -> Void) async throws -> String?) {
        guard screenshotTask == nil, panel?.attachedSheet == nil else { return }
        let previousPanel = panel.flatMap { $0.isVisible ? $0 : nil }
        let resultAnchor = previousPanel == nil ? PanelPosition.anchor(for: nil) : anchor
        firstOpen?.cancel()
        pending?.cancel()
        panelState.screenshotProblem = nil
        let previousResponder = previousPanel?.firstResponder
        previousPanel?.orderOut(nil)
        screenshotTask = Task {
            var text: String?
            var problem: ScreenshotProblem?
            do {
                text = try await readText {
                    guard let panel = previousPanel else { return }
                    panelState.recognizingScreenshot = true
                    panel.makeFirstResponder(nil)
                    panel.orderFrontRegardless()
                }
            }
            catch { problem = error as? ScreenshotProblem ?? .capture }
            guard !Task.isCancelled else { return }
            screenshotTask = nil
            panelState.recognizingScreenshot = false
            if let text {
                let editor = ManualTranslation(text: text)
                editor.translate(source: nil, target: preferences.target)
                lastSelection = nil
                previousPanel?.keepsPosition = true
                display(.screenshot(editor), at: resultAnchor, passive: false, retry: previousPanel != nil)
            } else if let panel = previousPanel {
                panelState.screenshotProblem = problem
                if passivePanel {
                    panel.orderFrontRegardless()
                } else {
                    panel.makeKeyAndOrderFront(nil)
                    if let previousResponder { panel.makeFirstResponder(previousResponder) }
                }
            } else if let problem {
                display(.manual(ManualTranslation()), at: resultAnchor, passive: false)
                panelState.screenshotProblem = problem
            }
            refreshMonitors()
        }
        refreshMonitors()
    }

    private func cancelScreenshot() {
        screenshotTask?.cancel()
        screenshot.cancelSelection()
        screenshotTask = nil
        panelState.recognizingScreenshot = false
    }

    private func present(text: AttributedString, source: String?, anchor: CGRect, passive: Bool, retry: Bool = false) {
        let job = TranslationRequest(text, source: source, target: preferences.target, passive: passive)
        display(.request(job), at: anchor, passive: passive, retry: retry)
    }

    private func display(_ content: PanelContent, at position: CGRect, passive: Bool, retry: Bool = false) {
        cancelScreenshot()
        panelState.screenshotProblem = nil
        firstOpen?.cancel()
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet, returnCode: .cancel) }
        request?.cancel()
        manual?.cancel()
        switch content {
        case .manual(let editor), .screenshot(let editor):
            manual = editor
            request = nil
        case .request(let newRequest):
            request = newRequest
            manual = nil
        }
        let id = UUID()
        presentation = id
        if !panelState.isPinned { anchor = position }
        passivePanel = passive
        let window = panel ?? makePanel()
        panel = window
        if !retry { window.keepsPosition = false }
        updateAvailableSize()
        let view = PanelView(content: content, preferences: preferences, state: panelState,
                             togglePin: { [weak self] in self?.togglePin() },
                             setTranslatesSelection: { [weak self] in self?.setTranslatesSelection($0) },
                             close: { [weak self] in self?.dismissPanel(explicit: true) },
                             settings: { [weak self] in self?.showSettings() },
                             takeScreenshot: { [weak self] in self?.takeScreenshot() },
                             repeatRequest: { [weak self] source in
            guard let self, let text = request?.text else { return }
            present(text: text, source: source, anchor: anchor, passive: false, retry: true)
        })
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
            Task { @MainActor in
                guard let self, self.presentation == id else { return }
                self.resizePanel(to: size)
            }
        }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        // A newly attached, unconstrained NSHostingView can initially measure zero.
        // Give the first frame a real size so AppKit can assign the window a screen.
        let measured = host.fittingSize
        let scale = preferences.panelZoom.factor
        let initial = CGSize(width: content.preferredWidth * scale, height: PanelState.minimumReadingSize.height * scale)
        resizePanel(to: measured.width > 0 && measured.height > 0 ? measured : initial, newSelection: true)
        if passive { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }
        refreshMonitors()
    }

    private func makePanel() -> TranslationPanel {
        let window = TranslationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                      backing: .buffered, defer: false)
        window.title = "Перевод"
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.delegate = self
        window.onEscape = { [weak self] in self?.dismissPanel(explicit: true) }
        return window
    }

    private var panelScreen: NSScreen? {
        if let panel, panelState.isPinned || panel.keepsPosition, let screen = panel.screen { return screen }
        let point = CGPoint(x: anchor.midX, y: anchor.midY)
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func updateAvailableSize() {
        if let size = panelScreen?.visibleFrame.size, panelState.availableSize != size {
            panelState.availableSize = size
        }
    }

    private func togglePin() {
        panelState.manuallyPinned = !panelState.isPinned
        panelState.translatesSelection = false
        updatePanelMode()
    }

    private func setTranslatesSelection(_ enabled: Bool) {
        guard panel?.isVisible == true, panelState.translatesSelection != enabled else { return }
        panelState.translatesSelection = enabled
        updatePanelMode()
        if enabled && !AXIsProcessTrusted() { requestAccess() }
    }

    private func updatePanelMode() {
        pending?.cancel()
        lastSelection = nil
        guard let panel else { return }
        panel.level = panelState.isPinned ? .statusBar : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, panelState.isPinned ? .stationary : .transient]
        if !panelState.isPinned {
            // Keep the current position until the next selection.
            panel.keepsPosition = true
        }
        refreshMonitors()
    }

    private func resizePanel(to measuredSize: CGSize, newSelection: Bool = false) {
        guard let panel, !panel.inLiveResize, let visible = panelScreen?.visibleFrame else { return }
        let scale = preferences.panelZoom.factor
        let size = panelState.readingFrameSize(scale: scale) ?? measuredSize
        guard size.width > 0, size.height > 0 else { return }
        panel.contentMinSize = panelState.minimumFrameSize(scale: scale)
        let frame: CGRect
        if panelState.isPinned || panel.keepsPosition || (panelState.readingSize != nil && !newSelection) {
            frame = PanelPosition.pinnedFrame(size: size, topLeft: CGPoint(x: panel.frame.minX, y: panel.frame.maxY),
                                              visible: visible)
        } else {
            frame = PanelPosition.frame(size: size, anchor: anchor, visible: visible)
        }
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if manual != nil { panel.keepsPosition = true }
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = 14 * preferences.panelZoom.factor
        panel.contentView?.layer?.masksToBounds = true
        panel.invalidateShadow()
    }

    private func dismissPanel(explicit: Bool = false) {
        guard !panelState.isPinned || (explicit && panelState.canClose) else { return }
        if panelState.translatesSelection {
            panelState.translatesSelection = false
            panelState.manuallyPinned = false
            updatePanelMode()
        }
        cancelScreenshot()
        presentation = UUID()
        request?.cancel()
        request = nil
        manual?.cancel()
        manual = nil
        passivePanel = false
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet, returnCode: .cancel) }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panelState.readingSize = nil
        refreshMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelScreenshot()
        hotKey?.stop()
        pending?.cancel()
        permissionTimer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

extension AppController: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel, panelState.availableSize != .zero else { return frameSize }
        return panelState.constrainedReadingFrame(frameSize, scale: preferences.panelZoom.factor)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.inLiveResize else { return }
        recordReadingSize(of: panel)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        recordReadingSize(of: panel)
    }

    private func recordReadingSize(of panel: NSPanel) {
        let scale = preferences.panelZoom.factor
        let size = panelState.constrainedReadingFrame(panel.frame.size, scale: scale)
        panelState.readingSize = CGSize(width: size.width / scale, height: size.height / scale)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateAvailableSize()
    }
}

#if DEBUG
import Carbon
import Translation

extension AppController {
    // Run only in a separate debug bundle, with an isolated preferences domain.
    func verifyApp(in directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            preferences.panelZoom = .standard
            var report = ["Hotkey registered: \(hotKey?.isRegistered(.text) == true)", "Accessibility granted: \(AXIsProcessTrusted())"]
            if let fixture = ProcessInfo.processInfo.environment["MHT_VERIFY_COLD_FIXTURE"] {
                report.append(try await verifyFirstHotkey(with: URL(fileURLWithPath: fixture)))
            }
            if ProcessInfo.processInfo.environment["MHT_VERIFY_SCREENSHOT"] == "1" {
                report.append(try await verifyScreenshot(in: directory))
            }
            if ProcessInfo.processInfo.environment["MHT_VERIFY_SELECTION"] == "1" {
                report.append(try await verifyBrowserSelectionMode())
            }
            if AXIsProcessTrusted(), ProcessInfo.processInfo.environment["MHT_VERIFY_CAPS"] == "1" {
                let original = preferences.shortcut
                let capsT = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(alphaLock))
                registerShortcut(capsT)
                guard preferences.shortcut == capsT, preferences.shortcutProblems[.text] == nil else {
                    throw NSError(domain: "CapsVerification", code: 1, userInfo: [NSLocalizedDescriptionKey: preferences.shortcutProblems[.text] ?? "Registration failed"])
                }
                showSettings()
                for _ in 0..<50 {
                    if settingsWindow?.isKeyWindow == true { break }
                    try await Task.sleep(for: .milliseconds(30))
                }
                guard settingsWindow?.isKeyWindow == true else { throw CocoaError(.featureUnsupported) }
                for (key, down) in [(kVK_F20, true), (kVK_ANSI_T, true), (kVK_ANSI_T, false), (kVK_F20, false)] {
                    let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
                    event?.flags = []
                    event?.post(tap: .cgSessionEventTap)
                }
                let deadline = ContinuousClock.now + .seconds(2)
                while manual == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                guard manual?.text.isEmpty == true, panel?.isVisible == true else { throw CocoaError(.formatting) }
                dismissPanel()
                settingsWindow?.orderOut(nil)
                registerShortcut(original)
                guard preferences.shortcut == original, preferences.shortcutProblems[.text] == nil else {
                    throw CocoaError(.featureUnsupported)
                }
                report.append("Caps Lock HID remap, F20 chord delivery, teardown and switching back to Carbon: passed")
            } else {
                report.append("Caps Lock system remap verification skipped")
            }
            var formattedExample: (source: AttributedString, target: AttributedString)?
            var wordExample: (source: AttributedString, target: AttributedString)?
            preferences.dictionaryHints = false
            for (source, target, sample) in [("en", "ru", "The black cat drinks milk."), ("ru", "en", "Доброе утро!")] {
                preferences.highlightOriginal = source == "en"
                let status = await TranslationLanguages.status(from: .init(identifier: source), to: .init(identifier: target))
                report.append("\(source) → \(target): \(status)")
                if status == .installed {
                    let pb = NSPasteboard.withUniqueName()
                    if source == "ru" {
                        let html = """
                        <h2>3. Локальные LLM через Ollama или MLX</h2>
                        <p>Если у вас Mac на процессоре Apple Silicon, вы можете подключить локальную нейросеть.</p>
                        <ul><li><strong>Как это работает:</strong> Вы запускаете модель в фоне, а ваше приложение общается с ней по локальному API.</li>
                        <li><strong>Плюсы:</strong> Модель понимает контекст технического текста и может работать <em>офлайн</em>.</li>
                        <li><strong>Минусы:</strong> Модели требуется оперативная память, и она расходует заряд батареи.</li></ul>
                        """
                        pb.setString(html, forType: .html)
                    } else {
                        pb.setString(sample, forType: .string)
                    }
                    var error: NSString?
                    translateSelection(pb, userData: nil, error: &error)
                    pb.releaseGlobally()
                    for _ in 0..<100 {
                        if case .ready = request?.phase { break }
                        if case .failed = request?.phase { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard case .ready(let translated) = request?.phase,
                          !translated.characters.isEmpty, String(translated.characters) != sample else { throw CocoaError(.validationMissingMandatoryProperty) }
                    if source == "en", let request {
                        wordExample = (request.text, translated)
                    } else if source == "ru", let original = request?.text {
                        let lines = String(translated.characters).split(whereSeparator: \.isNewline)
                        guard lines.count == 5, lines.suffix(3).allSatisfy({ $0.contains("•") }),
                              translated.runs.contains(where: { $0.inlinePresentationIntent?.contains(.emphasized) == true }),
                              translated.runs.contains(where: { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && $0.presentationIntent == nil }) else {
                            print("Source formatting", original, "Translated formatting", translated)
                            throw CocoaError(.formatting)
                        }
                        formattedExample = (original, translated)
                    }
                    report.append("Service translation: \(String(translated.characters))")
                }
            }
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                showSettings()
                try await Task.sleep(for: .milliseconds(440))
                try capture(settingsWindow, at: directory.appendingPathComponent("settings-\(mode).png"))
                settingsWindow?.orderOut(nil)
                if let wordExample {
                    preferences.highlightOriginal = true
                    let example = TranslationRequest(wordExample.source, source: "en", target: "ru", passive: true)
                    // Exercise both an aligned result and the plain-text compatibility path.
                    let result = mode == "light" ? wordExample.target : AttributedString(String(wordExample.target.characters))
                    example.phase = .ready(result)
                    display(.request(example), at: CGRect(x: 460, y: 560, width: 8, height: 8), passive: true)
                    let selection = (String(result.characters) as NSString).range(of: "молоко", options: .caseInsensitive)
                    guard selection.location != NSNotFound else { throw CocoaError(.formatting) }
                    try await Task.sleep(for: .milliseconds(120))
                    try clickWord(at: selection.location, in: String(result.characters))
                    for _ in 0..<60 where example.highlightedWords.isEmpty { try await Task.sleep(for: .milliseconds(50)) }
                    let milk = (String(example.text.characters) as NSString).range(of: "milk")
                    guard example.highlightedWords == [milk] else { throw CocoaError(.formatting) }
                    try await Task.sleep(for: .milliseconds(150))
                    try capture(panel, at: directory.appendingPathComponent("word-selection-\(mode).png"))
                    report.append("Source highlight \(mode): молоко → milk")
                    if mode == "light" {
                        preferences.dictionaryHints = true
                        try await Task.sleep(for: .milliseconds(120))
                        let visible = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
                        try clickWord(at: milk.location, in: String(example.text.characters))
                        let deadline = ContinuousClock.now + .seconds(4)
                        while !NSApp.windows.contains(where: { $0.isVisible && !visible.contains(ObjectIdentifier($0)) }),
                              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
                        guard panel?.isVisible == true,
                              NSApp.windows.contains(where: { $0.isVisible && !visible.contains(ObjectIdentifier($0)) })
                        else { throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Dictionary window did not open"]) }
                        report.append("Click on original: system dictionary window opened")
                        preferences.dictionaryHints = false
                    }
                    dismissPanel()
                    preferences.highlightOriginal = false
                }
                if formattedExample != nil { panelState.readingSize = CGSize(width: 740, height: 700) }
                let job = TranslationRequest(formattedExample?.source ?? "До завтра.", source: "ru", target: "en", passive: true)
                job.cancel()
                job.phase = .ready(formattedExample?.target ?? "See you tomorrow.")
                display(.request(job), at: CGRect(x: 460, y: 560, width: 8, height: 8), passive: true)
                try await Task.sleep(for: .milliseconds(360))
                try capture(panel, at: directory.appendingPathComponent("panel-\(mode).png"))
                report.append("Panel \(mode): \(Int(panel?.frame.height ?? 0)) pt; key: \(panel?.isKeyWindow ?? false)")
                dismissPanel()
                showSettings()
                try await Task.sleep(for: .milliseconds(150))
                handleShortcut()
                try await Task.sleep(for: .milliseconds(300))
                guard let editor = panel?.firstResponder as? NSTextView, editor.isEditable, let manual
                else { throw CocoaError(.validationMissingMandatoryProperty) }
                try capture(panel, at: directory.appendingPathComponent("manual-empty-\(mode).png"))
                editor.insertText("Good morning!", replacementRange: editor.selectedRange())
                guard manual.text == "Good morning!" else { throw CocoaError(.formatting) }
                let installed = await TranslationLanguages.status(from: .init(identifier: "en"), to: .init(identifier: "ru")) == .installed
                if installed {
                    for _ in 0..<100 {
                        if case .ready = manual.request?.phase { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard case .ready(let translated) = manual.request?.phase, !translated.characters.isEmpty,
                          panel?.firstResponder === editor else { throw CocoaError(.formatting) }
                    try capture(panel, at: directory.appendingPathComponent("manual-translated-\(mode).png"))
                    report.append("Manual \(mode): \(String(translated.characters)), keyboard focus retained")
                }
                editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                guard manual.text.isEmpty, manual.request == nil else { throw CocoaError(.formatting) }
                let clipboard = NSPasteboard.withUniqueName()
                clipboard.setString("First line\nSecond line", forType: .string)
                let pasted = editor.readSelection(from: clipboard, type: .string)
                clipboard.releaseGlobally()
                guard pasted, manual.text == "First line\nSecond line" else { throw CocoaError(.formatting) }
                report.append("Hotkey without selection, immediate typing, clearing and multiline paste: passed")
                dismissPanel()
                settingsWindow?.orderOut(nil)
            }
            let long = TranslationRequest(AttributedString(String(repeating: "A longer passage. ", count: 65)),
                                          source: "en", target: "ru", passive: true)
            long.cancel()
            long.phase = .ready(AttributedString(String(repeating: "Перевод длинного текста. ", count: 65)))
            display(.request(long), at: CGRect(x: 460, y: 560, width: 8, height: 8), passive: true)
            try await Task.sleep(for: .milliseconds(300))
            try capture(panel, at: directory.appendingPathComponent("panel-long.png"))
            guard let panel, let screen = panel.screen?.visibleFrame,
                  panel.frame.width == min(768, screen.width),
                  (275...500).contains(panel.frame.height) else { throw CocoaError(.formatting) }
            report.append("Long selection: \(Int(panel.frame.width)) × \(Int(panel.frame.height)) pt")
            let topLeft = CGPoint(x: screen.minX + 20, y: screen.maxY - 12)
            // Route a mouse-down through the actual header of the unpinned panel.
            let titlePoint = NSPoint(x: 56, y: panel.frame.height - 20)
            guard let host = panel.contentView, let container = host.superview,
                  let title = host.hitTest(container.convert(titlePoint, from: nil)),
                  let down = NSEvent.mouseEvent(with: .leftMouseDown, location: titlePoint,
                                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1) else { throw CocoaError(.formatting) }
            title.mouseDown(with: down)
            guard panel.keepsPosition else { throw CocoaError(.formatting) }
            panel.setFrameTopLeftPoint(topLeft)
            preferences.panelZoom = .small
            try await Task.sleep(for: .milliseconds(240))
            guard panel.frame.minX == topLeft.x, panel.frame.maxY == topLeft.y else { throw CocoaError(.formatting) }
            let nextAnchor = CGRect(x: screen.midX, y: screen.midY, width: 10, height: 10)
            display(.request(long), at: nextAnchor, passive: true)
            try await Task.sleep(for: .milliseconds(160))
            guard !panel.keepsPosition, panel.frame == PanelPosition.frame(size: panel.frame.size, anchor: nextAnchor,
                                                                           visible: screen) else { throw CocoaError(.formatting) }
            report.append("Unpinned title drag, resize in place and next selection: passed")
            if AXIsProcessTrusted() {
                guard !watchesSelection, !panelState.isPinned else { throw CocoaError(.formatting) }
                setTranslatesSelection(true)
                dismissPanel()
                guard panel.isVisible, panel.level == .statusBar, watchesSelection, !preferences.automatic
                else { throw CocoaError(.formatting) }
                try await Task.sleep(for: .milliseconds(120))
                try capture(panel, at: directory.appendingPathComponent("follow-selection.png"))
                setTranslatesSelection(false)
                guard !watchesSelection, panel.level == .floating else { throw CocoaError(.formatting) }
                togglePin()
                setTranslatesSelection(true)
                setTranslatesSelection(false)
                guard panelState.isPinned, !watchesSelection else { throw CocoaError(.formatting) }
                setTranslatesSelection(true)
                togglePin()
                guard !panelState.isPinned, !watchesSelection else { throw CocoaError(.formatting) }
                setTranslatesSelection(true)
                panel.cancelOperation(nil)
                guard !panel.isVisible, !watchesSelection, !panelState.isPinned else { throw CocoaError(.formatting) }
                display(.request(long), at: nextAnchor, passive: true)
                guard panel.isVisible, !panelState.translatesSelection else { throw CocoaError(.formatting) }
                report.append("Per-window selection mode: previous pin restored, manual unpin stops tracking, closing resets mode")
            }
            togglePin()
            panel.setFrameTopLeftPoint(topLeft)
            for scale in [PanelZoom.small, .double] {
                preferences.panelZoom = scale
                try await Task.sleep(for: .milliseconds(240))
                guard panel.frame.width == min(768 * scale.factor, screen.width),
                      screen.contains(panel.frame), panel.frame.minX == min(topLeft.x, screen.maxX - panel.frame.width),
                      request === long else { throw CocoaError(.formatting) }
                try capture(panel, at: directory.appendingPathComponent("pinned-\(scale.rawValue).png"))
            }
            preferences.panelZoom = .standard
            try await Task.sleep(for: .milliseconds(160))
            let smallest = windowWillResize(panel, to: CGSize(width: 1, height: 1))
            let minimumFrame = PanelPosition.pinnedFrame(size: smallest, topLeft: topLeft, visible: screen)
            panel.setFrame(minimumFrame, display: true)
            windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
            try await Task.sleep(for: .milliseconds(160))
            guard panel.frame.size == panelState.minimumFrameSize(scale: 1) else { throw CocoaError(.formatting) }
            try capture(panel, at: directory.appendingPathComponent("panel-minimum.png"))
            // Exercise the same final-frame notification AppKit sends after a corner drag.
            let enlarged = PanelPosition.pinnedFrame(size: CGSize(width: 620, height: 578),
                                                     topLeft: topLeft, visible: screen)
            panel.setFrame(enlarged, display: true)
            windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: panel))
            try await Task.sleep(for: .milliseconds(160))
            guard panel.frame.size == enlarged.size, preferences.panelZoom == .standard,
                  request === long else { throw CocoaError(.formatting) }
            try capture(panel, at: directory.appendingPathComponent("panel-resized.png"))
            let pinnedCorner = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
            panel.cancelOperation(nil)
            showSettings()
            settingsWindow?.orderOut(nil)
            guard panel.isVisible, panel.level == .statusBar, request === long else { throw CocoaError(.formatting) }
            present(text: "Testing again", source: "en", anchor: .zero, passive: true)
            try await Task.sleep(for: .milliseconds(320))
            guard panel === self.panel, request?.text == "Testing again", panel.isVisible,
                  panel.frame.size == enlarged.size,
                  abs(panel.frame.minX - pinnedCorner.x) <= 1,
                  abs(panel.frame.maxY - pinnedCorner.y) <= 1 else { throw CocoaError(.formatting) }
            togglePin()
            panel.cancelOperation(nil)
            guard !panel.isVisible, panelState.readingSize == nil else { throw CocoaError(.formatting) }
            report.append("User-sized panel retained its dimensions for the next translation")
            report.append("Pin, zoom 75–200%, update in place and unpin: passed")
            dismissPanel()
            try report.joined(separator: "\n").write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        } catch {
            hotKey?.stop()
            FileHandle.standardError.write(Data("Verification failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // Only run against a disposable local page in a separate Chrome profile.
    private func verifyBrowserSelectionMode() async throws -> String {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: folder) }
        let page = folder.appendingPathComponent("selection.html")
        try """
        <!doctype html><meta charset="utf-8"><title>Selection mode fixture</title>
        <style>body { margin: 24vh 18vw }</style>
        <input autofocus value="Morning"><input value="See you tomorrow">
        <script>window.onload = () => document.querySelector('input').select();</script>
        """.write(to: page, atomically: true, encoding: .utf8)
        showManual()
        guard let panel, !panelState.translatesSelection, !preferences.automatic else { throw CocoaError(.formatting) }
        let oldDelay = preferences.delayMilliseconds
        defer { preferences.delayMilliseconds = oldDelay; dismissPanel(explicit: true) }
        preferences.delayMilliseconds = 3000
        setTranslatesSelection(true)
        let browser = Process()
        browser.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        browser.arguments = ["--app=" + page.absoluteString, "--user-data-dir=" + folder.appendingPathComponent("profile").path,
                             "--force-renderer-accessibility", "--no-first-run", "--no-default-browser-check",
                             "--disable-background-networking", "--disable-sync"]
        browser.standardOutput = FileHandle.nullDevice
        browser.standardError = FileHandle.nullDevice
        try browser.run()
        defer { if browser.isRunning { browser.terminate(); browser.waitUntilExit() } }
        let pid = browser.processIdentifier
        func browserIsActive() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        var bounds: CGRect?
        let launchDeadline = ContinuousClock.now + .seconds(12)
        while bounds == nil, ContinuousClock.now < launchDeadline {
            if browserIsActive(), let selection = await reader.read(pid: pid), selection.text == "Morning" {
                bounds = selection.quartzBounds
            }
            if bounds == nil { try await Task.sleep(for: .milliseconds(60)) }
        }
        guard let bounds, browserIsActive(), CGPreflightPostEventAccess() else { throw CocoaError(.fileReadUnknown) }
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        if let screen = panel.screen {
            panel.setFrameTopLeftPoint(CGPoint(x: screen.visibleFrame.maxX - panel.frame.width, y: screen.visibleFrame.midY))
        }
        var hit: AXUIElement?
        var hitPID: pid_t = 0
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit, AXUIElementGetPid(hit, &hitPID) == .success, hitPID == pid else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Fixture is not under the test click"])
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: 2)
            event?.post(tap: .cghidEventTap)
        }
        func expectSelection(_ text: AttributedString) async throws {
            let deadline = ContinuousClock.now + .seconds(2)
            while request?.text != text, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
            guard request?.text == text, self.panel === panel, panel.isVisible, panelState.translatesSelection, browserIsActive()
            else {
                let selected = await reader.read(pid: pid)?.text
                throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey:
                    "Expected \(String(text.characters)), fixture selection \(String(selected?.characters ?? AttributedString().characters)), panel received expected text \(request?.text == text), browser active \(browserIsActive())"])
            }
        }
        try await expectSelection("Morning")
        for key in [kVK_Tab, kVK_ANSI_A] {
            for down in [true, false] {
                guard browserIsActive() else { throw CocoaError(.userCancelled) }
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
                event?.flags = key == kVK_ANSI_A ? .maskCommand : []
                event?.post(tap: .cghidEventTap)
            }
        }
        try await expectSelection("See you tomorrow")
        if await TranslationLanguages.status(from: .init(identifier: "en"), to: .init(identifier: "ru")) == .installed {
            for _ in 0..<100 {
                if case .ready = request?.phase { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard case .ready(let translated) = request?.phase, !translated.characters.isEmpty else { throw CocoaError(.formatting) }
        }
        return "Chrome mouse and keyboard selections updated the same pinned window with browser focus retained"
    }

    // Dispatch locally to the text view in this verification window.
    private func clickWord(at offset: Int, in text: String) throws {
        func findText(in view: NSView) -> WordTextView? {
            if let view = view as? WordTextView, view.string == text, !view.isHiddenOrHasHiddenAncestor { return view }
            return view.subviews.lazy.compactMap { findText(in: $0) }.first
        }
        guard let panel, let content = panel.contentView, let view = findText(in: content),
              let layout = view.layoutManager, let container = view.textContainer else { throw CocoaError(.formatting) }
        let glyph = layout.glyphIndexForCharacter(at: offset)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = view.convert(NSPoint(x: rect.midX + view.textContainerOrigin.x,
                                         y: rect.midY + view.textContainerOrigin.y), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { throw CocoaError(.featureUnsupported) }
        NSApp.postEvent(up, atStart: true)
        panel.sendEvent(down)
    }

    // Exercise Carbon delivery before this process has created any translator window.
    private func verifyFirstHotkey(with executable: URL) async throws -> String {
        let fixture = Process()
        fixture.executableURL = executable
        try fixture.run()
        defer {
            if fixture.isRunning { fixture.terminate() }
            dismissPanel()
        }
        for _ in 0..<75 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(40))
        }
        guard panel == nil, NSWorkspace.shared.frontmostApplication?.processIdentifier == fixture.processIdentifier,
              fixture.suspend() else { throw CocoaError(.featureUnsupported) }
        defer { _ = fixture.resume() }
        let original = preferences.shortcut
        let key = CGKeyCode(kVK_ANSI_9)
        let binding = Shortcut(keyCode: UInt32(key), modifiers: UInt32(cmdKey | optionKey | controlKey))
        registerShortcut(binding)
        defer { registerShortcut(original) }
        guard preferences.shortcut == binding else { throw CocoaError(.featureUnsupported) }
        let start = ContinuousClock.now
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            event?.flags = [.maskCommand, .maskAlternate, .maskControl]
            event?.post(tap: .cghidEventTap)
        }
        let deadline = start + .seconds(2)
        while panel?.firstResponder as? NSTextView == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let elapsed = start.duration(to: .now)
        guard let panel, let screen = panel.screen, panel.isVisible, panel.isKeyWindow, manual != nil,
              screen.visibleFrame.intersects(panel.frame), panel.frame.width >= 300,
              let editor = panel.firstResponder as? NSTextView, editor.isEditable else {
            throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey: "First shortcut did not show a usable manual panel. Frame \(String(describing: panel?.frame)), responder \(String(describing: panel?.firstResponder))"])
        }
        editor.insertText("First press", replacementRange: editor.selectedRange())
        guard manual?.text == "First press" else { throw CocoaError(.formatting) }
        return "First global hotkey with unresponsive source: \(elapsed) to editable panel"
    }

    private func verifyImageShortcut(_ key: Shortcut, image: URL) async throws {
        let originalTextKey = preferences.shortcut
        let originalReader = readScreenshot
        defer {
            readScreenshot = originalReader
            registerShortcut(nil, for: .image)
            registerShortcut(originalTextKey)
            dismissPanel()
        }
        if key.usesCapsLock { registerShortcut(.init(keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(alphaLock))) }
        registerShortcut(key, for: .image)
        registerShortcut(preferences.shortcut, for: .image)
        guard hotKey?.isRegistered(.text) == true, hotKey?.isRegistered(.image) == true,
              preferences.imageShortcut == key, preferences.shortcutProblems[.image] != nil,
              panel?.isVisible != true else { throw CocoaError(.validationMissingMandatoryProperty) }
        var calls = 0
        readScreenshot = { captured in
            calls += 1
            if calls == 1 { return nil }
            captured()
            return try await AreaScreenshot.recognize(at: image)
        }
        for expected in 1...2 {
            let code = Int(key.keyCode)
            let events = key.usesCapsLock ? [(kVK_F20, true), (code, true), (code, false), (kVK_F20, false)]
                                         : [(code, true), (code, false)]
            for (keyCode, down) in events {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: down)
                event?.flags = key.usesCapsLock ? [] : [.maskControl, .maskAlternate, .maskCommand]
                event?.post(tap: .cgSessionEventTap)
            }
            let deadline = ContinuousClock.now + .seconds(8)
            while (calls < expected || screenshotTask != nil), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(30))
            }
            guard calls == expected, screenshotTask == nil, (panel?.isVisible == true) == (expected == 2)
            else { throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey: "Image shortcut failed: \(key.title)"]) }
        }
        guard manual?.text == "Good morning!", manual?.request != nil else { throw CocoaError(.formatting) }
        registerShortcut(nil, for: .image)
        guard hotKey?.isRegistered(.image) == false, hotKey?.isRegistered(.text) == true else { throw CocoaError(.formatting) }
    }

    // The optional interactive test drags only inside this app's opaque fixture.
    private func verifyScreenshot(in directory: URL) async throws -> String {
        let live = CGPreflightScreenCaptureAccess() && CGPreflightPostEventAccess()
        guard let screen = NSScreen.screens.first else { throw CocoaError(.featureUnsupported) }
        let bounds = CGRect(x: screen.visibleFrame.midX - 210, y: screen.visibleFrame.midY - 70, width: 420, height: 140)
        let fixture = NSPanel(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        fixture.backgroundColor = .white
        fixture.contentView?.wantsLayer = true
        fixture.contentView?.layer?.backgroundColor = NSColor.white.cgColor
        fixture.level = .statusBar
        let label = NSTextField(labelWithString: "Good morning!")
        label.font = .systemFont(ofSize: 32)
        label.textColor = .black
        label.frame = CGRect(x: 32, y: 34, width: 350, height: 52)
        fixture.contentView?.addSubview(label)
        fixture.orderFrontRegardless()
        let image = directory.appendingPathComponent("ocr-fixture.png")
        try capture(fixture, at: image)
        defer { fixture.orderOut(nil); cancelScreenshot() }
        var testedKeys: [String] = []
        if CGPreflightPostEventAccess() {
            var keys = [Shortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: UInt32(cmdKey | optionKey | controlKey))]
            if ProcessInfo.processInfo.environment["MHT_VERIFY_CAPS"] == "1" {
                keys.append(.init(keyCode: UInt32(kVK_ANSI_I), modifiers: UInt32(alphaLock)))
            }
            for key in keys {
                try await verifyImageShortcut(key, image: image)
                testedKeys.append(key.title)
            }
        }
        let draft = ManualTranslation(text: "Черновик до снимка")
        display(.manual(draft), at: bounds, passive: false)
        togglePin()
        defer { if panelState.isPinned { togglePin() }; dismissPanel() }
        func waitForResult() async throws {
            let deadline = ContinuousClock.now + .seconds(90)
            while screenshotTask != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            guard screenshotTask == nil else { throw CocoaError(.userCancelled, userInfo: [NSLocalizedDescriptionKey: "Screenshot picker timed out"]) }
        }
        if live {
            takeScreenshot()
            try await Task.sleep(for: .seconds(1))
            guard screenshotTask != nil, panel?.isVisible == false else { throw CocoaError(.featureUnsupported) }
            for down in [true, false] {
                CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)?.post(tap: .cghidEventTap)
            }
        } else {
            translateScreenshot { _ in nil }
            guard panel?.isVisible == false else { throw CocoaError(.formatting) }
        }
        try await waitForResult()
        guard panel?.isVisible == true, manual === draft, panelState.screenshotProblem == nil,
              panelState.isPinned else { throw CocoaError(.formatting) }

        if live {
            takeScreenshot()
            try await Task.sleep(for: .seconds(1))
            guard screenshotTask != nil, panel?.isVisible == false else { throw CocoaError(.featureUnsupported) }
            let start = CGPoint(x: bounds.minX + 12, y: screen.frame.maxY - bounds.maxY + 12)
            let end = CGPoint(x: bounds.maxX - 12, y: screen.frame.maxY - bounds.minY - 12)
            for (type, point) in [(CGEventType.mouseMoved, start), (.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(100))
            }
        } else {
            translateScreenshot { captured in
                captured()
                return try await AreaScreenshot.recognize(at: image)
            }
        }
        try await waitForResult()
        guard let manual, manual.text == label.stringValue, panel?.isVisible == true, manual.request != nil,
              panelState.isPinned else { throw CocoaError(.formatting) }
        let installed = await TranslationLanguages.status(from: .init(identifier: "en"), to: .init(identifier: "ru")) == .installed
        func waitForTranslation(_ editor: ManualTranslation) async throws {
            guard installed else { return }
            for _ in 0..<100 {
                if case .ready = editor.request?.phase { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CocoaError(.formatting)
        }
        try await waitForTranslation(manual)
        try capture(panel, at: directory.appendingPathComponent("screenshot-translation.png"))
        guard let editor = panel?.firstResponder as? NSTextView, editor.isEditable else { throw CocoaError(.formatting) }
        editor.insertText("Hi", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        guard manual.text == "Hi", let window = panel, let visible = window.screen?.visibleFrame,
              window.frame.width == min(384, visible.width) else { throw CocoaError(.formatting) }
        let sampleImage = ProcessInfo.processInfo.environment["MHT_VERIFY_LONG_SCREENSHOT"]
        translateScreenshot { captured in
            captured()
            if let sampleImage { return try await AreaScreenshot.recognize(at: URL(fileURLWithPath: sampleImage)) }
            return Array(repeating: "A longer paragraph from the screenshot.", count: 8).joined(separator: "\n")
        }
        try await waitForResult()
        guard let article = self.manual, article.text.count >= 200, window.isVisible,
              window.frame.width == min(768, visible.width) else {
            throw CocoaError(.formatting, userInfo: [NSLocalizedDescriptionKey:
                "Long screenshot: \(self.manual?.text.count ?? 0) characters, panel width \(window.frame.width) pt"])
        }
        try await waitForTranslation(article)
        let appearance = NSApp.appearance
        defer { NSApp.appearance = appearance }
        for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: name)
            try await Task.sleep(for: .milliseconds(300))
            guard window.frame.width == min(768, visible.width) else { throw CocoaError(.formatting) }
            try capture(window, at: directory.appendingPathComponent("screenshot-long-\(mode).png"))
        }
        return (live ? "System rectangle picker" : "Own-window image (interactive picker lacks permission)")
            + ": cancellation restored pinned draft; OCR, translation and editing passed. Cold image shortcuts: \(testedKeys)"
            + "\nLong screenshot: \(article.text.count) characters, panel width \(Int(window.frame.width)) pt"
    }

    private func capture(_ window: NSWindow?, at url: URL) throws {
        guard let view = window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
#endif
