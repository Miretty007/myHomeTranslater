import AppKit
import Testing
@testable import myHomeTranslater

@MainActor @Test(arguments: [["Good morning", "Open the window"], ["Доброе утро", "Откройте окно"], []])
func recognizesScreenshotLines(_ lines: [String]) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 160,
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 640, height: 160)).fill()
    for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: CGPoint(x: 18, y: 95 - 60 * index),
                                withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: url)
    if lines.isEmpty {
        await #expect(throws: ScreenshotProblem.noText) { try await AreaScreenshot.recognize(at: url) }
    } else {
        let text = try await AreaScreenshot.recognize(at: url)
        #expect(text == lines.joined(separator: "\n"))
    }
}
