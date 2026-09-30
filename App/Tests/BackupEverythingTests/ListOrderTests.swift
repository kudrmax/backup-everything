import Foundation
import Testing
@testable import BackupEverything

struct ListOrderTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()

    @Test func movingDownTakesThePlaceOfTheTargetAndShiftsItUp() {
        #expect(ListOrder.moving(a, onto: c, in: [a, b, c, d]) == [b, c, a, d])
    }

    @Test func movingUpTakesThePlaceOfTheTargetAndShiftsItDown() {
        #expect(ListOrder.moving(d, onto: b, in: [a, b, c, d]) == [a, d, b, c])
    }

    @Test func droppingOnItselfOrAnUnknownItemChangesNothing() {
        #expect(ListOrder.moving(b, onto: b, in: [a, b, c]) == nil)
        #expect(ListOrder.moving(UUID(), onto: b, in: [a, b, c]) == nil)
        #expect(ListOrder.moving(a, onto: UUID(), in: [a, b, c]) == nil)
    }

    @Test func movingToTheEndPutsTheItemLast() {
        #expect(ListOrder.movingToEnd(a, in: [a, b, c]) == [b, c, a])
        #expect(ListOrder.movingToEnd(c, in: [a, b, c]) == nil)
    }
}
