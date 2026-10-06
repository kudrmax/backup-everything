import AppKit
import SwiftUI

struct MenuBarIcon: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let overall = model.overall ?? .ok
        let symbol = StatusStyle.menuBarSymbol(overall, working: model.isWorking || !model.hasReport)
        if let color = MenuBarTint.of(overall).color, let image = Self.tinted(symbol, color) {
            Image(nsImage: image)
        } else {
            Image(systemName: symbol)
        }
    }

    private static func tinted(_ symbol: String, _ color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
}
