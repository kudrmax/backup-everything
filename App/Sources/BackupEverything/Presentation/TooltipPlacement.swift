import CoreGraphics

enum TooltipPlacement {
    private static let margin: CGFloat = 4

    /// Centred under the element; above it if there is no room below; always within the screen’s sides.
    static func origin(size: CGSize, below anchor: CGRect, on screen: CGRect, gap: CGFloat) -> CGPoint {
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + gap }
        origin.x = min(max(origin.x, screen.minX + margin), screen.maxX - size.width - margin)
        return origin
    }
}
