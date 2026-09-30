import BackupCore
import SwiftUI

struct SourceIcon: View {
    @Environment(AppModel.self) private var model
    let icon: String?
    let symbol: String
    var size: CGFloat = 18

    init(_ source: Source, size: CGFloat = 18) {
        icon = source.icon
        symbol = source.enabled ? StatusStyle.symbol(for: source.kind) : "pause.circle"
        self.size = size
    }

    init(icon: String?, symbol: String, size: CGFloat = 18) {
        self.icon = icon
        self.symbol = symbol
        self.size = size
    }

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .padding(Self.inset)
            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: (size + Self.inset * 2) * 0.27))
    }

    private static let inset: CGFloat = 4

    @ViewBuilder
    private var glyph: some View {
        if let image = model.iconImage(icon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.78))
                .foregroundStyle(.secondary)
        }
    }
}
