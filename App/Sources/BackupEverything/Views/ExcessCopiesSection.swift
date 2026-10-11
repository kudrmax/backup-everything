import BackupCore
import SwiftUI

/// Copies the retention rules no longer keep, with the command that removes them; the app itself never deletes a copy.
struct ExcessCopiesSection: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0

    private static let maxHeight: CGFloat = 240

    var body: some View {
        if let summary = ExcessCopiesText.summary(model.excessCopies, config: model.config) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary).font(.headline)
                    Text(ExcessCopiesText.intro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(model.excessCopies.enumerated()), id: \.offset) { _, excess in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ExcessCopiesText.title(excess, config: model.config))
                            if excess.asOf == nil {
                                CommandBox(command: model.excessCommand(for: excess))
                            } else {
                                Text(ExcessCopiesText.disconnected).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, Self.maxHeight))
        }
    }
}
