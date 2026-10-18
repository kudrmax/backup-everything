import BackupCore
import SwiftUI

/// What the storage setup still lacks and the command that sets it up.
struct SetupSection: View {
    @Environment(AppModel.self) private var model
    @State private var contentHeight: CGFloat = 0

    private static let maxHeight: CGFloat = 320

    private var commands: [String] {
        SetupTexts.commands(for: model.setupProblems, config: model.config, script: model.setupScript)
    }

    var body: some View {
        if !model.isStorageReady {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Setup", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(SetupTexts.intro)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.setupProblems.enumerated()), id: \.offset) { _, problem in
                            Text("• " + SetupTexts.line(problem, config: model.config))
                        }
                    }
                    .foregroundStyle(.secondary)
                    if commands.isEmpty {
                        Text(SetupTexts.noDestination).foregroundStyle(.secondary)
                    }
                    ForEach(commands, id: \.self) { command in
                        CommandBox(command: command)
                    }
                }
                .font(.callout)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(contentHeight, Self.maxHeight))
            .background(.orange.opacity(0.08))
        }
    }
}

struct CommandBox: View {
    let command: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            CopyButton(text: command, title: "Copy command")
                .pointing()
        }
    }
}
