import AppKit
import SwiftUI
import Testing
@testable import BackupEverything

@MainActor
struct TooltipBubbleTests {
    private func size(_ text: String) -> NSSize {
        NSHostingController(rootView: TooltipBubble(text: text)).sizeThatFits(in: NSSize(width: TooltipBubble.maxWidth, height: 10_000))
    }

    @Test func longTextWrapsAndTheBubbleGrowsToShowEveryLine() {
        let short = size("Refresh")
        let long = size(ConnectReminder.settingsExplanation)
        #expect(short.width < TooltipBubble.maxWidth)
        #expect(long.width <= TooltipBubble.maxWidth)
        #expect(long.height > short.height * 2.5)
    }
}
