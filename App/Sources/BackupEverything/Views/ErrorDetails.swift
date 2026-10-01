import AppKit
import SwiftUI

struct CopyButton: View {
    let text: String
    @State private var isCopied = false

    var body: some View {
        Button(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            isCopied = true
        }
    }
}

struct ErrorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Error: \(title)").font(.title3.weight(.semibold))
            ScrollView {
                Text(message)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .defaultScrollAnchor(.bottom)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                CopyButton(text: message)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620, height: 440)
    }
}
