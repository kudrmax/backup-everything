import SwiftUI

/// Системные кнопки с рамкой: вид прежний, курсор — рука.
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

/// Кнопка без рамки, у которой собственный вид задаёт подпись: нажимается вся её площадь, при нажатии темнеет.
struct PlainPointingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration) { label, isPressed, _ in
            label
                .contentShape(Rectangle())
                .opacity(isPressed ? 0.55 : 1)
        }
    }
}

/// Значок или короткая подпись без рамки: под курсором подсвечивается подложкой, как кнопки панели инструментов.
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

/// Строка меню во всю ширину: подсвечивается целиком и нажимается в любом месте.
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

/// Общая часть стилей: наведение, курсор и вид выключенной кнопки.
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
    /// Для меню, переключателей и выпадающих списков, у которых нет стиля кнопки.
    func pointing() -> some View {
        pointerStyle(.link)
    }
}

/// Нажимаемая строка, внутри которой есть свои кнопки (поэтому это не Button): подсветка и клик по всей площади.
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
