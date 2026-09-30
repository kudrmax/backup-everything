import SwiftUI

private struct HoverTip: ViewModifier {
    private static let delay: Duration = .milliseconds(350)

    let text: String
    @State private var isShown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                pending?.cancel()
                guard isInside else {
                    isShown = false
                    return
                }
                pending = Task {
                    try? await Task.sleep(for: Self.delay)
                    if !Task.isCancelled { isShown = true }
                }
            }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                Text(text)
                    .font(.callout)
                    .fixedSize()
                    .padding(10)
            }
    }
}

extension View {
    func hoverTip(_ text: String) -> some View {
        modifier(HoverTip(text: text))
    }
}
