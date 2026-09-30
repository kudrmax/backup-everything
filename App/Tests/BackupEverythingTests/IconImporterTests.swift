import AppKit
import Foundation
import Testing
@testable import BackupEverything

@MainActor
struct IconImporterTests {
    @Test func anyPictureBecomesASquarePNG() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let wide = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        try #require(wide.representation(using: .png, properties: [:])).write(to: file)

        let png = try #require(IconImporter.pngData(from: file))
        let result = try #require(NSBitmapImageRep(data: png))

        #expect(result.pixelsWide == 128)
        #expect(result.pixelsHigh == 128)
    }

    @Test func fileThatIsNotAPictureIsRejected() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not an image".utf8).write(to: file)
        #expect(IconImporter.pngData(from: file) == nil)
    }
}
