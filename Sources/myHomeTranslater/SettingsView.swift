import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let changeShortcut: (Shortcut) -> Void
    let requestAccess: () -> Void
    @State private var monitor: Any?
    @State private var helpText: String?

    var body: some View {
        Form {
            Section("Перевод") {
                Picker("Язык перевода", selection: $preferences.target) {
                    Text("На русский, с русского — на английский").tag("auto")
                    Divider()
                    ForEach(preferences.languages) { Text($0.name).tag($0.id) }
                }
                Toggle("Переводить сразу после выделения", isOn: $preferences.automatic)
                    .help("Показывать перевод после короткой паузы, сохраняя фокус в исходном приложении")
            }
            Section("Управление") {
                LabeledContent("Горячая клавиша") {
                    Button(preferences.recordingShortcut ? "Нажмите сочетание…" : preferences.shortcut.title) {
                        if preferences.recordingShortcut { stopRecording() } else { recordShortcut() }
                    }
                    .accessibilityLabel("Изменить горячую клавишу")
                }
                if let message = helpText ?? preferences.shortcutProblem {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                LabeledContent("Универсальный доступ") {
                    if preferences.trusted {
                        Label("Разрешён", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else { Button("Разрешить…", action: requestAccess) }
                }
                Text("Доступ нужен для горячей клавиши и автоперевода. По правому клику выберите «Службы → Перевести в myHomeTranslater».")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Оформление") {
                Picker("Тема", selection: $preferences.theme) {
                    ForEach(ThemeChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if preferences.recordingShortcut { stopRecording() }
        }
    }

    private func recordShortcut() {
        stopRecording()
        preferences.recordingShortcut = true
        helpText = "Нажмите букву или цифру с ⌃, ⌥ или ⌘. Esc отменяет запись."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            guard let shortcut = Shortcut(event: event) else { return nil }
            stopRecording()
            changeShortcut(shortcut)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        preferences.recordingShortcut = false
        helpText = nil
    }
}
