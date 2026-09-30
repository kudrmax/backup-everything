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
        if let image = model.iconImage(icon) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        } else {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: size)
        }
    }
}
