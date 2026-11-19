import AppKit
import Vision
import VisionKit

enum ScreenshotProblem: Error {
    case permission, capture, recognition, noText

    var message: String {
        switch self {
        case .permission: String(localized: "Разрешите переводчику запись экрана, чтобы сделать снимок области.")
        case .capture: String(localized: "Не удалось сделать снимок. Попробуйте выделить область ещё раз.")
        case .recognition: String(localized: "Не удалось распознать изображение. Попробуйте сделать снимок ещё раз.")
        case .noText: String(localized: "В этой области не найден текст. Выделите область с надписью.")
        }
    }
}

@MainActor
final class AreaScreenshot {
    private var picker: Process?

    func cancelSelection() {
        if let picker, picker.isRunning { picker.terminate() }
    }

    /// A nil result means the user cancelled the system's rectangle selection.
    func readText(onImageCaptured: () -> Void) async throws -> String? {
        try Task.checkCancellation()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw ScreenshotProblem.permission }
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: folder) }
        let screenshot = folder.appendingPathComponent("selection.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-s", "-x", "-t", "png", screenshot.path]
        let errors = Pipe()
        process.standardError = errors
        picker = process
        defer { if picker === process { picker = nil } }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        try Task.checkCancellation()
        if !files.fileExists(atPath: screenshot.path) {
            let details = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if status == 0 || details.localizedCaseInsensitiveContains("cancel") || (status == 1 && details.isEmpty) {
                return nil
            }
            throw ScreenshotProblem.capture
        }
        guard status == 0 else { throw ScreenshotProblem.capture }
        onImageCaptured()
        return try await Self.recognize(at: screenshot)
    }

    nonisolated static func recognize(at url: URL) async throws -> String {
        if ImageAnalyzer.isSupported {
            do {
                let analysis = try await ImageAnalyzer().analyze(imageAt: url, orientation: .up, configuration: .init([.text]))
                try Task.checkCancellation()
                let text = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ScreenshotProblem.noText }
                return text
            } catch let problem as ScreenshotProblem { throw problem }
            catch {
                try Task.checkCancellation()
                // Live Text may be temporarily unavailable even on supported hardware.
            }
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let observations: [RecognizedTextObservation]
        do { observations = try await request.perform(on: url) }
        catch { throw ScreenshotProblem.recognition }
        try Task.checkCancellation()
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScreenshotProblem.noText }
        return text
    }
}
