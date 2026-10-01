import AppKit
import UniformTypeIdentifiers

@MainActor
enum IconImporter {
    private static let side = 128

    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .icns, .tiff]
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pngData(from file: URL) -> Data? {
        guard let image = NSImage(contentsOf: file), image.size.width > 0, image.size.height > 0,
              let canvas = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        let scale = CGFloat(side) / max(image.size.width, image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = NSPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }
}
