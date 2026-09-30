import SwiftUI

/// Любая кнопка приложения показывает курсор-руку, сохраняя свой обычный вид.
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

extension PrimitiveButtonStyle where Self == PointingButtonStyle<PlainButtonStyle> {
    static var plainPointing: Self { PointingButtonStyle(base: PlainButtonStyle()) }
}

extension PrimitiveButtonStyle where Self == PointingButtonStyle<BorderlessButtonStyle> {
    static var borderlessPointing: Self { PointingButtonStyle(base: BorderlessButtonStyle()) }
}

extension PrimitiveButtonStyle where Self == PointingButtonStyle<BorderedProminentButtonStyle> {
    static var borderedProminentPointing: Self { PointingButtonStyle(base: BorderedProminentButtonStyle()) }
}

extension View {
    /// Для меню, переключателей и выпадающих списков, у которых нет стиля кнопки.
    func pointing() -> some View {
        pointerStyle(.link)
    }
}
