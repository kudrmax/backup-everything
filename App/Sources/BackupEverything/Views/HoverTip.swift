import AppKit
import SwiftUI

/// A hover tooltip. It lives in a separate panel that lets the mouse pass through:
/// the cursor, hover and clicks on the element below work as usual.
@MainActor
final class TooltipController {
    static let shared = TooltipController()

    private static let delay: Duration = .milliseconds(450)
    /// While tooltips were just shown, the next one appears immediately, as in system apps.
    private static let warmPeriod: TimeInterval = 0.8
    private static let gap: CGFloat = 6

    private var panel: NSPanel?
    private var pending: Task<Void, Never>?
    private var owner: UUID?
    private var lastShownAt = Date.distantPast
    private var monitor: Any?
    private var anchor: (() -> NSRect?)?

    func request(_ text: String, anchor: @escaping () -> NSRect?, owner: UUID) {
        pending?.cancel()
        self.owner = owner
        self.anchor = anchor
        let isWarm = panel?.isVisible == true || Date().timeIntervalSince(lastShownAt) < Self.warmPeriod
        pending = Task { [weak self] in
            if !isWarm { try? await Task.sleep(for: Self.delay) }
            guard !Task.isCancelled, let self, self.owner == owner, let rect = anchor() else { return }
            self.show(text, below: rect)
        }
        installMonitor()
    }

    /// The text changed while the tooltip is open (e.g. a running timer): redraw it in place.
    func update(_ text: String, owner: UUID) {
        guard self.owner == owner, panel?.isVisible == true, let rect = anchor?() else { return }
        show(text, below: rect)
    }

    func dismiss(owner: UUID) {
        guard self.owner == owner else { return }
        hide()
    }

    private func hide() {
        pending?.cancel()
        pending = nil
        owner = nil
        anchor = nil
        if panel?.isVisible == true { lastShownAt = Date() }
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            self?.hide()
            return event
        }
    }

    private func show(_ text: String, below anchor: NSRect) {
        let panel = panel ?? makePanel()
        self.panel = panel
        let bubble = TooltipBubble(text: text)
        let size = NSHostingController(rootView: bubble).sizeThatFits(in: NSSize(width: TooltipBubble.maxWidth, height: 10_000))
        let hosting = NSHostingView(rootView: bubble)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let origin = TooltipPlacement.origin(size: size, below: anchor, on: screen, gap: Self.gap)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        lastShownAt = Date()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        return panel
    }
}

struct TooltipBubble: View {
    /// The width beyond which text wraps to a new line (including padding).
    static let maxWidth: CGFloat = 358

    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.6)))
    }
}

/// An empty NSView behind the element: the tooltip uses it to find where the element is on screen.
private final class AnchorView: NSView {
    var screenRect: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct Anchor: NSViewRepresentable {
    let holder: AnchorHolder

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        holder.view = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        holder.view = view
    }
}

@MainActor
private final class AnchorHolder {
    weak var view: AnchorView?
}

private struct HoverTip: ViewModifier {
    let text: String
    @State private var id = UUID()
    @State private var holder = AnchorHolder()

    func body(content: Content) -> some View {
        content
            .background(Anchor(holder: holder))
            .onHover { isInside in
                if isInside, !text.isEmpty {
                    TooltipController.shared.request(text, anchor: { [holder] in holder.view?.screenRect }, owner: id)
                } else {
                    TooltipController.shared.dismiss(owner: id)
                }
            }
            .onChange(of: text) { _, newText in TooltipController.shared.update(newText, owner: id) }
            .onDisappear { TooltipController.shared.dismiss(owner: id) }
    }
}

extension View {
    func hoverTip(_ text: String) -> some View {
        modifier(HoverTip(text: text))
    }
}
