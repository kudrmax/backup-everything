import Foundation
import Testing
@testable import BackupEverything

@MainActor
struct AppModelEditTests {
    @Test func savingSettingsAsksForAnImmediateCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(dataDirectory: root.appendingPathComponent("data"), workDirectory: root.appendingPathComponent("work"))
        var checks = 0
        model.onConfigEdited = { checks += 1 }
        await model.orderSources([])
        #expect(checks == 1)
        try? FileManager.default.trashItem(at: root, resultingItemURL: nil)
    }
}
