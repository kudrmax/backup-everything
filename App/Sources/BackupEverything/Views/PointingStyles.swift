import SwiftUI

/// System bordered buttons: same look, with a pointing-hand cursor.
struct PointingButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let base: Base

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration)
            .buttonStyle(base)
            .pointerStyle(.link)
    }
}

extension PrimitiveButtonStyle where Self == PointingButtonStyle<DefaultButtonStyle> {
    static var automaticPointing: Self { PointingButtonStyle(base: DefaultButtonStyle()) }
}

extension PrimitiveButtonStyle where Self == PointingButtonStyle<BorderedProminentButtonStyle> {
    static var borderedProminentPointing: Self { PointingButtonStyle(base: BorderedProminentButtonStyle()) }
}

/// A borderless button whose label defines its look: the whole area is clickable and darkens when pressed.
struct PlainPointingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration) { label, isPressed, _ in
            label
                .contentShape(Rectangle())
                .opacity(isPressed ? 0.55 : 1)
        }
    }
}

/// An icon or short borderless label: highlighted with a backdrop under the cursor, like toolbar buttons.
struct BorderlessPointingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration) { label, isPressed, isHovered in
            label
                .padding(.horizontal, 4)
                .frame(minWidth: 24, minHeight: 24)
                .foregroundStyle(isHovered || isPressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(Highlight(isHovered: isHovered, isPressed: isPressed, cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// A full-width menu row: highlighted as a whole and clickable anywhere.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration) { label, isPressed, isHovered in
            label
                .labelStyle(MenuRowLabelStyle())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Highlight(isHovered: isHovered, isPressed: isPressed, cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

struct MenuRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .foregroundStyle(.secondary)
                .frame(width: 16)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == PlainPointingButtonStyle {
    static var plainPointing: Self { PlainPointingButtonStyle() }
}

extension ButtonStyle where Self == BorderlessPointingButtonStyle {
    static var borderlessPointing: Self { BorderlessPointingButtonStyle() }
}

extension ButtonStyle where Self == MenuRowButtonStyle {
    static var menuRow: Self { MenuRowButtonStyle() }
}

private struct Highlight: View {
    let isHovered: Bool
    let isPressed: Bool
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(isPressed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
            .opacity(isHovered || isPressed ? 1 : 0)
    }
}

/// The shared part of the styles: hover, cursor and the look of a disabled button.
private struct PressableBody<Content: View>: View {
    let configuration: ButtonStyleConfiguration
    @ViewBuilder let content: (ButtonStyleConfiguration.Label, Bool, Bool) -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        content(configuration.label, configuration.isPressed, isHovered && isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
            .pointerStyle(isEnabled ? .link : nil)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    /// For menus, toggles and pop-up lists that have no button style. A disabled control gets no hand.
    func pointing() -> some View {
        modifier(Pointing())
    }
}

private struct Pointing: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.pointerStyle(isEnabled ? .link : nil)
    }
}

/// A clickable row with its own buttons inside (hence not a Button): highlight and click over the whole area.
private struct TappableRow: ViewModifier {
    let action: () -> Void
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Highlight(isHovered: isHovered, isPressed: false, cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onTapGesture(perform: action)
            .onHover { isHovered = $0 }
            .pointerStyle(.link)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

extension View {
    func tappableRow(perform action: @escaping () -> Void) -> some View {
        modifier(TappableRow(action: action))
    }
}
