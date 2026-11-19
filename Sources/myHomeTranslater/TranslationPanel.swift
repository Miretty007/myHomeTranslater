import AppKit
import SwiftUI
import Translation

enum TranslationPhase: Equatable {
    case loading, ready(AttributedString), sameLanguage, needsDownload, chooseSource, failed(String)
}

@MainActor @Observable
final class TranslationRequest {
    let text: AttributedString
    let passive: Bool
    let direction: Direction
    var phase: TranslationPhase = .loading
    var configuration: TranslationSession.Configuration?
    var actualSource: String?
    private(set) var highlightedWords: [NSRange] = []
    struct Lookup: Identifiable {
        let id = UUID()
        let sourceLanguage: String
        let fragments: [WordAlignment.Fragment]
    }
    private(set) var lookup: Lookup?
    private(set) var cancelled = false

    init(_ text: AttributedString, source: String?, target: String, passive: Bool) {
        self.text = text
        self.passive = passive
        self.direction = Direction.choose(text: String(text.characters), sourceOverride: source, fixedTarget: target)
    }

    func prepare() async {
        guard !cancelled, !Task.isCancelled, phase == .loading else { return }
        if direction.isSameLanguage { phase = .sameLanguage; return }
        let target = Locale.Language(identifier: direction.target)
        let source = direction.source.map(Locale.Language.init(identifier:))
        if let source {
            let status = await TranslationLanguages.status(from: source, to: target)
            guard !Task.isCancelled, !cancelled else { return }
            switch status {
            case .unsupported:
                phase = .failed(String(localized: "Apple Translation не поддерживает эту пару языков. Проверьте язык оригинала."))
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

    nonisolated func translate(using session: TranslationSession, alignWords: Bool = false) async {
        do {
            let (translated, language) = try await PassageTranslation.translate(text, using: session, alignWords: alignWords)
            await MainActor.run {
                guard !Task.isCancelled, !cancelled else { return }
                actualSource = language
                phase = .ready(translated)
            }
        } catch {
            await MainActor.run {
                guard !Task.isCancelled, !cancelled else { return }
                phase = .failed(String(localized: "Перевод не завершён. Проверьте загрузку языков или попробуйте ещё раз."))
            }
        }
    }

    func selectTranslation(_ selection: NSRange?) {
        lookup = nil
        highlightedWords = []
        guard !cancelled, let selection, case .ready(let target) = phase else { return }
        let original = String(text.characters) as NSString
        highlightedWords = WordAlignment.originalRanges(for: selection, in: target, original: original)
        guard highlightedWords.isEmpty, let source = actualSource ?? direction.source else { return }
        let fragments = WordAlignment.fragments(for: selection, in: String(target.characters) as NSString, original: original)
        if !fragments.isEmpty { lookup = Lookup(sourceLanguage: source, fragments: fragments) }
    }

    nonisolated func resolve(_ pending: Lookup, using session: TranslationSession) async {
        let from = Locale.Language(identifier: direction.target)
        let to = Locale.Language(identifier: pending.sourceLanguage)
        guard await TranslationLanguages.status(from: from, to: to) == .installed else { return }
        let original = String(text.characters) as NSString
        var ranges: [NSRange] = []
        for fragment in pending.fragments {
            guard await lookup?.id == pending.id, !Task.isCancelled,
                  let response = try? await session.translate(fragment.selectedText) else { return }
            if let range = WordAlignment.uniqueMatch(response.targetText, in: original, paragraph: fragment.originalParagraph) {
                ranges.append(range)
            }
        }
        await MainActor.run {
            guard lookup?.id == pending.id, !Task.isCancelled else { return }
            highlightedWords = ranges
        }
    }

    func cancel() { cancelled = true; configuration = nil; selectTranslation(nil) }
}

enum PanelContent {
    case request(TranslationRequest)
    case manual(ManualTranslation)
    case screenshot(ManualTranslation)

    @MainActor var preferredWidth: CGFloat {
        let compactWidth: CGFloat = 384
        func width(for text: some Collection<Character>) -> CGFloat {
            let threshold = 200
            return text.prefix(threshold).count == threshold ? compactWidth * 2 : compactWidth
        }
        switch self {
        case .request(let request): return width(for: request.text.characters)
        case .screenshot(let editor): return width(for: editor.text)
        case .manual: return compactWidth
        }
    }
}

@MainActor @Observable
final class ManualTranslation {
    private(set) var text = ""
    private(set) var source: String?
    private(set) var request: TranslationRequest?
    @ObservationIgnored private var pending: Task<Void, Never>?

    init(text: String = "") { self.text = text }

    func edit(_ text: String, target: String) {
        cancel()
        self.text = text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let deadline = ContinuousClock.now + .milliseconds(400)
        pending = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            request = TranslationRequest(AttributedString(text), source: source, target: target, passive: false)
        }
    }

    func translate(source: String?, target: String) {
        cancel()
        self.source = source
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        request = TranslationRequest(AttributedString(text), source: source, target: target, passive: false)
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        request?.cancel()
        request = nil
    }
}

@MainActor @Observable
final class PanelState {
    static let minimumReadingSize = CGSize(width: 360, height: 260)
    var manuallyPinned = false
    var translatesSelection = false
    var isPinned: Bool { manuallyPinned || translatesSelection }
    var canClose: Bool { !manuallyPinned || translatesSelection }
    var screenshotProblem: ScreenshotProblem?
    var recognizingScreenshot = false
    var availableSize: CGSize = .zero
    // Store the user's reading area in unzoomed points so zoom stays independent.
    var readingSize: CGSize?

    func minimumFrameSize(scale: CGFloat) -> CGSize {
        CGSize(width: min(Self.minimumReadingSize.width * scale, availableSize.width),
               height: min(Self.minimumReadingSize.height * scale, availableSize.height))
    }

    func constrainedReadingFrame(_ proposed: CGSize, scale: CGFloat) -> CGSize {
        let minimum = minimumFrameSize(scale: scale)
        return CGSize(width: min(max(proposed.width, minimum.width), availableSize.width),
                      height: min(max(proposed.height, minimum.height), availableSize.height))
    }

    func readingFrameSize(scale: CGFloat) -> CGSize? {
        readingSize.map { constrainedReadingFrame(CGSize(width: $0.width * scale, height: $0.height * scale), scale: scale) }
    }
}

// A visual scale alone leaves the hosting window at its original size.
// Measure in logical points, then reserve the scaled bounds in the window.
private struct ZoomedPanelLayout: Layout {
    let scale: CGFloat
    let preferredWidth: CGFloat
    let available: CGSize
    let readingFrame: CGSize?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let readingFrame { return readingFrame }
        let width = min(preferredWidth * scale, available.width)
        let content = subviews[0].sizeThatFits(.init(width: width / scale, height: nil))
        return CGSize(width: width, height: min(ceil(content.height * scale), available.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: .init(width: bounds.width / scale, height: bounds.height / scale))
    }
}

private struct PanelDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

private struct PassageTextView: NSViewRepresentable {
    let text: AttributedString
    let fontSize: CGFloat
    let secondary: Bool
    let dictionaryHints: Bool
    let highlights: [NSRange]
    let select: ((NSRange?) -> Void)?

    func makeNSView(context: Context) -> WordTextView {
        let view = WordTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.heightTracksTextView = false
        view.isVerticallyResizable = false
        return view
    }

    func updateNSView(_ view: WordTextView, context: Context) {
        let rich = Passage.typeset(text, size: fontSize, color: secondary ? .secondaryLabelColor : .labelColor)
        if view.textStorage?.isEqual(to: rich) == false { view.textStorage?.setAttributedString(rich) }
        view.dictionaryHints = dictionaryHints
        view.onTextSelection = select
        view.highlight(highlights)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WordTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite,
              let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).maxY))
    }
}

/// A nonactivating panel must explicitly give its field first responder status
/// after AppKit attaches the hosting view. Otherwise the first keystroke is lost.
private struct ManualTextEditor: NSViewRepresentable {
    let text: String
    let dictionaryHints: Bool
    let highlights: [NSRange]
    let clearHighlight: (() -> Void)?
    let edit: (String) -> Void

    final class Editor: WordTextView, NSTextViewDelegate {
        var edit: ((String) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.isVisible else { return }
                window.makeFirstResponder(self)
            }
        }
        func textDidChange(_ notification: Notification) { edit?(string) }
        override func cancelOperation(_ sender: Any?) {
            if hasMarkedText() { super.cancelOperation(sender) }
            else { (window as? TranslationPanel)?.onEscape?() }
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = Editor()
        editor.isRichText = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.autoresizingMask = [.width]
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize.height = CGFloat.greatestFiniteMagnitude
        editor.setAccessibilityLabel(String(localized: "Текст для перевода"))
        editor.delegate = editor
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        editor.edit = edit
        editor.dictionaryHints = dictionaryHints
        editor.onTextSelection = clearHighlight.map { clear in { _ in clear() } }
        if !editor.hasMarkedText(), editor.string != text { editor.string = text }
        editor.highlight(highlights)
    }
}

struct PanelView: View {
    let content: PanelContent
    let preferences: Preferences
    let state: PanelState
    let togglePin: () -> Void
    let setTranslatesSelection: @MainActor (Bool) -> Void
    let close: () -> Void
    let settings: () -> Void
    let takeScreenshot: () -> Void
    let repeatRequest: (String?) -> Void
    @State private var copied = false

    private var currentRequest: TranslationRequest? {
        switch content {
        case .request(let request): request
        case .manual(let manual), .screenshot(let manual): manual.request
        }
    }

    var body: some View {
        let scale = preferences.panelZoom.factor
        ZoomedPanelLayout(scale: scale, preferredWidth: content.preferredWidth,
                          available: state.availableSize, readingFrame: state.readingFrameSize(scale: scale)) {
            panelBody.scaleEffect(scale, anchor: .topLeading)
        }
        .fixedSize()
        .background {
            if preferences.highlightOriginal, let request = currentRequest, let lookup = request.lookup {
                Color.clear
                    .translationTask(.init(source: .init(identifier: request.direction.target),
                                           target: .init(identifier: lookup.sourceLanguage))) { @Sendable session in
                        await request.resolve(lookup, using: session)
                    }
                    .id(lookup.id)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: preferences.highlightOriginal) { _, enabled in
            if !enabled { currentRequest?.selectTranslation(nil) }
        }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "translate").foregroundStyle(.tint)
                    Text("myHomeTranslater").font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .overlay {
                    PanelDragArea().help("Перетащить окно перевода")
                }
                Menu {
                    Picker("Масштаб окна", selection: Bindable(preferences).panelZoom) {
                        ForEach(PanelZoom.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                    }.pickerStyle(.inline)
                } label: {
                    Text(verbatim: preferences.panelZoom.label).font(.caption.monospacedDigit())
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Изменить масштаб окна").accessibilityLabel("Масштаб окна")
                .accessibilityValue(preferences.panelZoom.label)
                iconButton("camera", "Перевести текст с области экрана", takeScreenshot)
                    .disabled(state.recognizingScreenshot)
                iconButton(state.isPinned ? "pin.fill" : "pin",
                           state.isPinned ? "Открепить окно" : "Закрепить поверх окон", togglePin)
                    .foregroundStyle(state.isPinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                iconButton("gearshape", "Открыть настройки", settings)
                iconButton("xmark", "Закрыть (Esc)", close)
                    .disabled(!state.canClose)
                    .help(state.canClose ? "Закрыть (Esc)" : "Чтобы закрыть окно, снимите закрепление")
            }
            .padding(.horizontal, 16).frame(height: 40)
            Divider()
            if let problem = state.screenshotProblem {
                VStack(alignment: .leading, spacing: 6) {
                    Text(problem.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if case .permission = problem,
                       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        Link("Открыть настройки записи экрана", destination: url)
                    }
                }.padding(12)
                Divider()
            }
            ZStack(alignment: .topLeading) {
                translationContent
                    .opacity(state.recognizingScreenshot ? 0 : 1)
                    .disabled(state.recognizingScreenshot)
                    .accessibilityHidden(state.recognizingScreenshot)
                if state.recognizingScreenshot {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Распознаём текст…").foregroundStyle(.secondary)
                    }.padding(16)
                }
            }
            .frame(maxHeight: state.readingSize == nil ? nil : .infinity, alignment: .topLeading)
            HStack {
                if case .ready(let result) = currentRequest?.phase {
                    Button { copy(result) } label: {
                        Label(copied ? "Скопировано" : "Скопировать", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }
                Spacer(minLength: 8)
                Toggle("Переводить выделенное", isOn: Binding(get: { state.translatesSelection }, set: setTranslatesSelection))
                    .toggleStyle(.switch)
                    .fixedSize()
                    .help("Закрепить окно и сразу переводить новые выделения в нём")
            }
            .controlSize(.small)
            .disabled(state.recognizingScreenshot)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: state.readingSize == nil ? nil : .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottomTrailing) {
            Path { path in
                path.move(to: CGPoint(x: 2, y: 10))
                path.addLine(to: CGPoint(x: 10, y: 2))
                path.move(to: CGPoint(x: 7, y: 10))
                path.addLine(to: CGPoint(x: 10, y: 7))
            }
            .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            .frame(width: 12, height: 12).padding(3)
            .allowsHitTesting(false).accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var translationContent: some View {
        switch content {
        case .request(let request):
            VStack(spacing: 0) {
                if state.readingSize == nil {
                    fittingContent { requestBody(request) }
                } else {
                    requestBody(request)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
                .task { await request.prepare() }
                .translationTask(request.configuration) { @Sendable [alignWords = preferences.highlightOriginal] session in
                    await request.translate(using: session, alignWords: alignWords)
                }
        case .manual(let manual), .screenshot(let manual):
            manualBody(manual)
        }
    }

    private func fittingContent<Content: View>(@ViewBuilder _ body: () -> Content) -> some View {
        ViewThatFits(in: .vertical) {
            body().fixedSize(horizontal: false, vertical: true)
            ScrollView { body() }
        }
    }

    private func iconButton(_ symbol: String, _ label: LocalizedStringKey, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 20, height: 24)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }

    private func requestBody(_ request: TranslationRequest) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Оригинал").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    sourceMenu(request.actualSource ?? request.direction.source, select: repeatRequest)
                }
                passage(request.text, size: 14, limit: sourceHeightLimit, secondary: true, request: request)
            }.padding(16)
            Divider()
            resultBody(request, retry: repeatRequest)
        }
    }

    private func sourceMenu(_ language: String?, select: @escaping (String?) -> Void) -> some View {
        Menu {
            Button("Определять автоматически") { select(nil) }
            Divider()
            ForEach(preferences.languages) { item in Button(item.name) { select(item.id) } }
        } label: {
            Text(language.map(LanguageOption.name) ?? String(localized: "Уточнить язык")).font(.caption)
        }.fixedSize().menuStyle(.borderlessButton).help("Изменить язык оригинала")
    }

    private func manualBody(_ manual: ManualTranslation) -> some View {
        let translate = { (source: String?) in manual.translate(source: source, target: preferences.target) }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Оригинал").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    sourceMenu(manual.source ?? manual.request?.actualSource ?? manual.request?.direction.source, select: translate)
                }
                ManualTextEditor(text: manual.text, dictionaryHints: preferences.dictionaryHints,
                                 highlights: preferences.highlightOriginal ? manual.request?.highlightedWords ?? [] : [],
                                 clearHighlight: preferences.highlightOriginal ? { manual.request?.selectTranslation(nil) } : nil) {
                    copied = false
                    manual.edit($0, target: preferences.target)
                }
                    .overlay(alignment: .topLeading) {
                        if manual.text.isEmpty {
                            Text("Введите или вставьте текст").font(.system(size: 14)).foregroundStyle(.secondary)
                                .padding(.leading, 5).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .frame(height: sourceHeightLimit)
            }.padding(16)
            Divider()
            if let request = manual.request {
                resultBody(request, retry: translate)
                    .id(ObjectIdentifier(request))
                    .task { await request.prepare() }
                    .translationTask(request.configuration) { @Sendable [alignWords = preferences.highlightOriginal] session in
                        await request.translate(using: session, alignWords: alignWords)
                    }
            } else {
                Text("Перевод").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(16)
            }
        }
        .onChange(of: preferences.target) { _, target in manual.translate(source: manual.source, target: target) }
    }

    private func resultBody(_ request: TranslationRequest, retry: @escaping (String?) -> Void) -> some View {
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
                passage(result, size: 18, limit: state.readingSize == nil ? 184 : nil, secondary: false, request: request)
            case .sameLanguage:
                Text("Оригинал уже на выбранном языке.").foregroundStyle(.secondary)
            case .needsDownload:
                Text("Для этой пары нужно скачать языки.").foregroundStyle(.secondary)
                Button("Загрузить и перевести") { retry(request.direction.source) }
            case .chooseSource:
                Text("Выберите язык оригинала в меню выше.").foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Повторить") { retry(request.direction.source) }
            }
        }.padding(16)
    }

    private var sourceHeightLimit: CGFloat {
        guard let size = state.readingFrameSize(scale: preferences.panelZoom.factor) else { return 84 }
        return max(32, (size.height / preferences.panelZoom.factor - 120) * 0.30)
    }

    @ViewBuilder private func passage(_ text: AttributedString, size: CGFloat, limit: CGFloat?, secondary: Bool,
                                      request: TranslationRequest) -> some View {
        let label = PassageTextView(text: text, fontSize: size, secondary: secondary,
                                    dictionaryHints: secondary && preferences.dictionaryHints,
                                    highlights: secondary && preferences.highlightOriginal ? request.highlightedWords : [],
                                    select: preferences.highlightOriginal ? { request.selectTranslation(secondary ? nil : $0) } : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let limit {
            ViewThatFits(in: .vertical) {
                label
                ScrollView { label.padding(.trailing, 4) }
            }.frame(maxHeight: limit, alignment: .topLeading).fixedSize(horizontal: false, vertical: true)
        } else {
            ScrollView { label.padding(.trailing, 4) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func copy(_ text: AttributedString) {
        copied = Passage.copy(text, to: .general)
    }
}

final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var keepsPosition = false
    override func performDrag(with event: NSEvent) {
        keepsPosition = true
        super.performDrag(with: event)
    }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}
