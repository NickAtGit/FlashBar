import Foundation
import Testing
@testable import FlashBar

struct SchedulerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let calendar = Calendar(identifier: .gregorian)

    func days(_ card: Card) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: card.due).day!
    }

    @Test func newCardGoodIsDueTomorrow() {
        let card = Scheduler.review(Card(front: "a", back: "b"), rating: .good, now: now, calendar: calendar)
        #expect(days(card) == 1)
        #expect(card.reps == 1)
    }

    @Test func newCardEasySkipsAhead() {
        let card = Scheduler.review(Card(front: "a", back: "b"), rating: .easy, now: now, calendar: calendar)
        #expect(days(card) == 4)
        #expect(card.ease > 2.5)
    }

    @Test func secondGoodReviewIsSixDays() {
        var card = Card(front: "a", back: "b")
        card = Scheduler.review(card, rating: .good, now: now, calendar: calendar)
        card = Scheduler.review(card, rating: .good, now: now, calendar: calendar)
        #expect(days(card) == 6)
    }

    @Test func laterReviewsGrowByEase() {
        var card = Card(front: "a", back: "b")
        for _ in 0..<3 { card = Scheduler.review(card, rating: .good, now: now, calendar: calendar) }
        #expect(days(card) == 15) // 6 * 2.5
    }

    @Test func againResetsAndComesBackSoon() {
        var card = Card(front: "a", back: "b")
        for _ in 0..<3 { card = Scheduler.review(card, rating: .good, now: now, calendar: calendar) }
        card = Scheduler.review(card, rating: .again, now: now, calendar: calendar)
        #expect(card.reps == 0)
        #expect(card.lapses == 1)
        #expect(card.ease == 2.3)
        #expect(card.due.timeIntervalSince(now) == 60)
    }

    @Test func easeNeverDropsBelowFloor() {
        var card = Card(front: "a", back: "b")
        for _ in 0..<20 { card = Scheduler.review(card, rating: .again, now: now, calendar: calendar) }
        #expect(card.ease == 1.3)
    }

    @Test func newCardIsDueImmediately() {
        #expect(Card(front: "a", back: "b").isDue(at: .now))
    }
}

struct ImportTests {
    @Test func parsesTabsAndCommas() {
        let cards = CardImporter.parse("hola\thello\nadiós, goodbye\n\n# comment\nbad line")
        #expect(cards.map(\.front) == ["hola", "adiós"])
        #expect(cards.map(\.back) == ["hello", "goodbye"])
    }
}
