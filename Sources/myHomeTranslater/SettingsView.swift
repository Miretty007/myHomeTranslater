import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let changeShortcut: (Shortcut?, ShortcutAction) -> Void
    let recordCaps: (((Shortcut) -> Void)?) -> Bool
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
                LabeledContent("Задержка после выделения") {
                    let seconds = Double(preferences.delayMilliseconds) / 1000
                    let value = Measurement(value: seconds, unit: UnitDuration.seconds).formatted(
                        .measurement(width: .narrow, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...2)))
                        .locale(.interfaceLanguage)
                    )
                    Slider(value: Binding(get: { Double(preferences.delayMilliseconds) },
                                          set: { preferences.delayMilliseconds = Int($0.rounded()) }),
                           in: Double(Preferences.delayRange.lowerBound)...Double(Preferences.delayRange.upperBound),
                           step: 20)
                        .frame(width: 140)
                        .accessibilityLabel("Задержка после выделения")
                        .accessibilityValue(value)
                    Text(verbatim: value).monospacedDigit().frame(width: 50, alignment: .trailing)
                }
                .disabled(!preferences.automatic)
                Toggle("Подсвечивать оригинал", isOn: $preferences.highlightOriginal)
                    .help("Щёлкните по слову или выделите фразу в переводе, чтобы увидеть соответствующие слова оригинала")
                Toggle("Включи подсказки из словаря", isOn: $preferences.dictionaryHints)
                    .help("Щёлкните по слову в оригинале, чтобы открыть системный словарь")
            }
            Section("Управление") {
                shortcutRow(String(localized: "Перевод текста"), action: .text)
                shortcutRow(String(localized: "Быстрый перевод изображения"), action: .image)
                Group {
                    if let helpText {
                        Text(helpText)
                    } else if (preferences.shortcut.usesCapsLock || preferences.imageShortcut?.usesCapsLock == true),
                              preferences.shortcutProblems.isEmpty {
                        Label("Самостоятельный режим Caps Lock включён", systemImage: "keyboard")
                    } else {
                        Text("Для каждой команды можно назначить своё сочетание с ⌃, ⌥ или ⌘.")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Универсальный доступ") {
                    if preferences.trusted {
                        Label("Разрешён", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    } else { Button("Разрешить…", action: requestAccess) }
                }
                Text("Доступ нужен для чтения выделения и сочетаний с Caps Lock. Ввести текст вручную можно и без него.")
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
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if preferences.recordingShortcut, (note.object as? NSWindow)?.isVisible == true { stopRecording() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if preferences.recordingShortcut { stopRecording() }
        }
    }

    @ViewBuilder private func shortcutRow(_ title: String, action: ShortcutAction) -> some View {
        let recording = preferences.recordingAction == action
        let key = preferences.shortcut(for: action)
        HStack {
            Text(title)
            Spacer(minLength: 8)
            if recording {
                Text("Нажмите сочетание…").foregroundStyle(.secondary)
                Button("Отмена", action: stopRecording)
                    .accessibilityLabel("Отменить запись: \(title)")
            } else {
                Button(key?.title ?? String(localized: "Назначить…")) { recordShortcut(for: action) }
                    .accessibilityLabel("Горячая клавиша: \(title)")
                Button("С Caps Lock…") { recordShortcut(for: action, withCaps: true) }
                    .disabled(!preferences.trusted)
                    .accessibilityLabel("С Caps Lock: \(title)")
                    .help("Одиночное нажатие ⇪ сохраняет системное действие. Для сочетаний временно используется F20.")
                if action == .image, key != nil {
                    Button {
                        stopRecording()
                        changeShortcut(nil, .image)
                    } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Убрать сочетание для перевода изображения")
                    .help("Убрать сочетание")
                }
            }
        }
        if let message = preferences.shortcutProblems[action] {
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func recordShortcut(for action: ShortcutAction, withCaps: Bool = false) {
        stopRecording()
        preferences.recordingAction = action
        let capsReady = recordCaps { shortcut in
            guard preferences.recordingAction == action else { return }
            // Install the captured shortcut before releasing the temporary listener.
            changeShortcut(shortcut, action)
            stopRecording()
        }
        if withCaps {
            helpText = String(localized: "Нажмите букву или цифру для сочетания с ⇪. Esc — отмена.")
        } else if capsReady {
            helpText = String(localized: "Удерживайте ⇪, ⌃, ⌥ или ⌘ и нажмите клавишу. Esc — отмена.")
        } else {
            helpText = String(localized: "Удерживайте ⌃, ⌥ или ⌘ и нажмите клавишу. Esc — отмена.")
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            guard let shortcut = Shortcut(keyCode: event.keyCode, flags: event.modifierFlags, capsHeld: withCaps) else { return nil }
            stopRecording()
            changeShortcut(shortcut, action)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        preferences.recordingAction = nil
        helpText = nil
        _ = recordCaps(nil)
    }
}
