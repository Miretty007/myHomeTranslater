import AppKit
import SwiftUI
import Translation

enum TranslationPhase: Equatable {
    case loading, ready(String), sameLanguage, needsDownload, chooseSource, failed(String)
}

@MainActor @Observable
final class TranslationRequest {
    let text: String
    let passive: Bool
    let direction: Direction
    var phase: TranslationPhase = .loading
    var configuration: TranslationSession.Configuration?
    var actualSource: String?
    private(set) var cancelled = false

    init(_ text: String, source: String?, target: String, passive: Bool) {
        self.text = text
        self.passive = passive
        self.direction = Direction.choose(text: text, sourceOverride: source, fixedTarget: target)
    }

    func prepare() async {
        if direction.isSameLanguage { phase = .sameLanguage; return }
        let target = Locale.Language(identifier: direction.target)
        let source = direction.source.map(Locale.Language.init(identifier:))
        if let source {
            let status = await TranslationLanguages.status(from: source, to: target)
            guard !Task.isCancelled, !cancelled else { return }
            switch status {
            case .unsupported:
                phase = .failed("Apple Translation не поддерживает эту пару языков. Проверьте язык оригинала.")
                return
            case .supported where passive:
                phase = .needsDownload
                return
            default: break
            }
        } else if passive {
            phase = .chooseSource
            return
        }
        configuration = .init(source: source, target: target)
    }

    nonisolated func translate(using session: TranslationSession) async {
        do {
            let result = try await session.translate(text)
            let language = result.sourceLanguage.minimalIdentifier
            let translated = result.targetText
            await MainActor.run {
                guard !Task.isCancelled, !cancelled else { return }
                actualSource = language
                phase = .ready(translated)
            }
        } catch {
            await MainActor.run {
                guard !Task.isCancelled, !cancelled else { return }
                phase = .failed("Перевод не завершён. Проверьте загрузку языков или попробуйте ещё раз.")
            }
        }
    }

    func cancel() { cancelled = true; configuration = nil }
}

enum PanelContent {
    case request(TranslationRequest)
    case notice(String, String, Bool)
}

struct PanelView: View {
    let content: PanelContent
    let preferences: Preferences
    let close: () -> Void
    let settings: () -> Void
    let repeatRequest: (String?) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "translate").foregroundStyle(.tint)
                Text("myHomeTranslater").font(.system(size: 12, weight: .semibold))
                Spacer()
                iconButton("gearshape", "Открыть настройки", settings)
                iconButton("xmark", "Закрыть (Esc)", close)
            }
            .padding(.horizontal, 16).frame(height: 40)
            Divider()
            switch content {
            case .request(let request):
                requestBody(request)
            case .notice(let title, let message, let permission):
                VStack(alignment: .leading, spacing: 12) {
                    Text(title).font(.headline)
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if permission { Button("Открыть настройки", action: settings) }
                }.padding(16)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 20, height: 24)
        }.buttonStyle(.plain).foregroundStyle(.secondary).help(label).accessibilityLabel(label)
    }

    private func requestBody(_ request: TranslationRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Оригинал").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button("Определять автоматически") { repeatRequest(nil) }
                        Divider()
                        ForEach(preferences.languages) { item in
                            Button(item.name) { repeatRequest(item.id) }
                        }
                    } label: {
                        Text((request.actualSource ?? request.direction.source).map(LanguageOption.name) ?? "Уточнить язык")
                            .font(.caption)
                    }.fixedSize().menuStyle(.borderlessButton)
                    .help("Изменить язык оригинала")
                }
                passage(request.text, size: 14, limit: 84, secondary: true)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Перевод").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(LanguageOption.name(for: request.direction.target)).font(.caption).foregroundStyle(.secondary)
                }
                switch request.phase {
                case .loading:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Переводим…").foregroundStyle(.secondary) }
                case .ready(let result):
                    passage(result, size: 18, limit: 184, secondary: false)
                    Button { copy(result) } label: {
                        Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }.controlSize(.small).padding(.top, 4)
                case .sameLanguage:
                    Text("Оригинал уже на выбранном языке.").foregroundStyle(.secondary)
                case .needsDownload:
                    Text("Для этой пары нужно скачать языки.").foregroundStyle(.secondary)
                    Button("Загрузить и перевести") { repeatRequest(request.direction.source) }
                case .chooseSource:
                    Text("Выберите язык оригинала в меню выше.").foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Повторить") { repeatRequest(request.direction.source) }
                }
            }.padding(16)
        }
        .task { await request.prepare() }
        .translationTask(request.configuration, action: request.translate(using:))
    }

    private func passage(_ text: String, size: CGFloat, limit: CGFloat, secondary: Bool) -> some View {
        let label = Text(verbatim: text).font(.system(size: size)).textSelection(.enabled)
            .foregroundStyle(secondary ? Color.secondary : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        return ViewThatFits(in: .vertical) {
            label
            ScrollView { label.padding(.trailing, 4) }
        }.frame(maxHeight: limit, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(text, forType: .string)
    }
}

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
