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
    private var request: TranslationRequest?
    private var presentation = UUID()
    private var passivePanel = false
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
        NSApp.mainMenu = appMenu

        hotKey = HotKey { [weak self] in self?.handleShortcut() }
        registerShortcut(preferences.shortcut)
        preferences.onAutomaticChange = { [weak self] in
            guard let self else { return }
            pending?.cancel()
            lastSelection = nil
            if !preferences.automatic && passivePanel { dismissPanel() }
            if preferences.automatic && !AXIsProcessTrusted() { pollPermission() }
            refreshMonitors()
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
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
        if panel?.isVisible != true { showSettings() }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let translate = makeItem("Перевести выделение", #selector(handleShortcut))
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
        firstOpen?.cancel()
        UserDefaults.standard.set(true, forKey: "didOpen")
        dismissPanel()
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, changeShortcut: { [weak self] in self?.registerShortcut($0) },
                                    requestAccess: { [weak self] in self?.requestAccess() })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 432),
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
        if settingsWindow?.isVisible != true && (!preferences.automatic || trust) { permissionTimer?.invalidate() }
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

    private func registerShortcut(_ shortcut: Shortcut) {
        if shortcut == preferences.shortcut, hotKeyRegistered { return }
        if hotKey?.set(shortcut) == true {
            preferences.shortcut = shortcut
            preferences.shortcutProblem = nil
            hotKeyRegistered = true
        } else {
            preferences.shortcutProblem = "Не удалось зарегистрировать сочетание. Выберите другую горячую клавишу."
        }
    }
    private var hotKeyRegistered = false

    // AppKit invokes this exact three-argument selector for NSServices.
    @objc(translateSelection:userData:error:)
    func translateSelection(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let raw = board.string(forType: .string) ?? board.string(forType: .init("NSStringPboardType")),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "Выделите слово или фразу." as NSString
            return
        }
        pending?.cancel()
        lastSelection = nil
        present(text: raw, source: nil, anchor: PanelPosition.anchor(for: nil), passive: false)
    }

    @objc private func handleShortcut() {
        guard !preferences.recordingShortcut else { return }
        preferences.trusted = AXIsProcessTrusted()
        guard preferences.trusted else {
            notice("Нужен универсальный доступ",
                   "Разрешите myHomeTranslater читать выделенный текст или вызовите перевод через меню «Службы».", permission: true)
            return
        }
        readSelection(automatic: false)
    }

    private func refreshMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        let panelVisible = panel?.isVisible == true
        guard preferences.automatic || panelVisible else { return }
        var mask: NSEvent.EventTypeMask = [.leftMouseDown]
        if AXIsProcessTrusted() {
            mask.insert(.keyDown)
            if preferences.automatic { mask.formUnion([.leftMouseUp, .keyUp]) }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.externalEvent(event)
        }) { monitors.append(monitor) }
    }

    private func externalEvent(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 53 {
            pending?.cancel()
            dismissPanel()
            return
        }
        if event.type == .leftMouseDown {
            pending?.cancel()
            if panel?.isVisible == true && panel?.attachedSheet == nil { dismissPanel() }
            lastSelection = nil
            return
        }
        guard preferences.automatic, AXIsProcessTrusted(), !preferences.recordingShortcut else { return }
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
            if !automatic { notice("Выделите текст", "Выделите слово или фразу в другом приложении и вызовите перевод ещё раз.") }
            return
        }
        pending = Task {
            if automatic { try? await Task.sleep(for: .milliseconds(420)) }
            guard !Task.isCancelled else { return }
            let selection = await reader.read(pid: pid)
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard let selection else {
                lastSelection = nil
                if !automatic { notice("Выделение недоступно", "Попробуйте вызвать «Перевести в myHomeTranslater» через меню «Службы» выделенного текста.") }
                else if passivePanel { dismissPanel() }
                return
            }
            if automatic && (lastSelection == selection || !preferences.automatic || panel?.attachedSheet != nil) { return }
            lastSelection = selection
            present(text: selection.text, source: nil, anchor: PanelPosition.anchor(for: selection), passive: automatic)
        }
    }

    private func notice(_ title: String, _ message: String, permission: Bool = false) {
        display(.notice(title, message, permission), at: PanelPosition.anchor(for: nil), passive: false)
    }

    private func present(text: String, source: String?, anchor: CGRect, passive: Bool) {
        let job = TranslationRequest(text, source: source, target: preferences.target, passive: passive)
        display(.request(job), at: anchor, passive: passive)
    }

    private func display(_ content: PanelContent, at position: CGRect, passive: Bool) {
        firstOpen?.cancel()
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet, returnCode: .cancel) }
        request?.cancel()
        if case .request(let newRequest) = content { request = newRequest } else { request = nil }
        let id = UUID()
        presentation = id
        anchor = position
        passivePanel = passive
        let window = panel ?? makePanel()
        panel = window
        let view = PanelView(content: content, preferences: preferences, close: { [weak self] in self?.dismissPanel() },
                             settings: { [weak self] in self?.showSettings() },
                             repeatRequest: { [weak self] source in
            guard let self, let text = request?.text else { return }
            present(text: text, source: source, anchor: anchor, passive: false)
        })
        .frame(width: 384)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { [weak self] height in
            Task { @MainActor in
                guard let self, self.presentation == id else { return }
                self.resizePanel(height: height)
            }
        }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        resizePanel(height: max(100, host.fittingSize.height))
        if passive { window.orderFrontRegardless() } else { window.makeKeyAndOrderFront(nil) }
        refreshMonitors()
    }

    private func makePanel() -> TranslationPanel {
        let window = TranslationPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
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
        window.onEscape = { [weak self] in self?.dismissPanel() }
        return window
    }

    private func resizePanel(height: CGFloat) {
        let point = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = PanelPosition.frame(size: CGSize(width: 384, height: ceil(height)), anchor: anchor, visible: visible)
        panel?.setFrame(frame, display: true)
        panel?.contentView?.wantsLayer = true
        panel?.contentView?.layer?.cornerRadius = 14
        panel?.contentView?.layer?.masksToBounds = true
        panel?.invalidateShadow()
    }

    private func dismissPanel() {
        presentation = UUID()
        request?.cancel()
        request = nil
        passivePanel = false
        if let sheet = panel?.attachedSheet { panel?.endSheet(sheet, returnCode: .cancel) }
        panel?.orderOut(nil)
        panel?.contentView = nil
        refreshMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.stop()
        pending?.cancel()
        permissionTimer?.invalidate()
        monitors.forEach(NSEvent.removeMonitor)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

#if DEBUG
import Translation

extension AppController {
    // Run only in a separate debug bundle, with an isolated preferences domain.
    func verifyApp(in directory: URL) async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var report = ["Hotkey registered: \(hotKeyRegistered)", "Accessibility granted: \(AXIsProcessTrusted())"]
            for (source, target, sample) in [("en", "ru", "Good morning!"), ("ru", "en", "Доброе утро!")] {
                let status = await TranslationLanguages.status(from: .init(identifier: source), to: .init(identifier: target))
                report.append("\(source) → \(target): \(status)")
                if status == .installed {
                    let pb = NSPasteboard.withUniqueName()
                    pb.setString(sample, forType: .string)
                    var error: NSString?
                    translateSelection(pb, userData: nil, error: &error)
                    pb.releaseGlobally()
                    for _ in 0..<100 {
                        if case .ready = request?.phase { break }
                        if case .failed = request?.phase { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard case .ready(let translated) = request?.phase,
                          !translated.isEmpty, translated != sample else { throw CocoaError(.validationMissingMandatoryProperty) }
                    report.append("Service translation: \(translated)")
                }
            }
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                NSApp.appearance = NSAppearance(named: appearance)
                showSettings()
                try await Task.sleep(for: .milliseconds(440))
                try capture(settingsWindow, at: directory.appendingPathComponent("settings-\(mode).png"))
                settingsWindow?.orderOut(nil)
                let job = TranslationRequest("See you tomorrow.", source: "en", target: "ru", passive: true)
                job.cancel()
                job.phase = .ready("До завтра.")
                display(.request(job), at: CGRect(x: 460, y: 560, width: 8, height: 8), passive: true)
                try await Task.sleep(for: .milliseconds(360))
                try capture(panel, at: directory.appendingPathComponent("panel-\(mode).png"))
                report.append("Panel \(mode): \(Int(panel?.frame.height ?? 0)) pt; key: \(panel?.isKeyWindow ?? false)")
                dismissPanel()
            }
            let long = TranslationRequest(String(repeating: "A longer passage. ", count: 65),
                                          source: "en", target: "ru", passive: true)
            long.cancel()
            long.phase = .ready(String(repeating: "Перевод длинного текста. ", count: 65))
            display(.request(long), at: CGRect(x: 460, y: 560, width: 8, height: 8), passive: true)
            try await Task.sleep(for: .milliseconds(300))
            try capture(panel, at: directory.appendingPathComponent("panel-long.png"))
            guard let panel, (275...500).contains(panel.frame.height) else { throw CocoaError(.formatting) }
            report.append("Long selection: \(Int(panel.frame.height)) pt")
            dismissPanel()
            try report.joined(separator: "\n").write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        } catch {
            FileHandle.standardError.write(Data("Verification failed: \(error)\n".utf8))
            exit(1)
        }
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
