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

struct SyncTests {
    @Test func parsesFeedNewestFirstWithExamples() throws {
        let json = """
        {"2026-01-01": [{"pt": "velho", "de": "alt"}],
         "2026-03-11": [{"pt": "regressar", "en": "to return", "de": "zurückkehren",
                         "example": "A chuva pode regressar.", "example_en": "The rain may return."},
                        {"pt": "regressar", "en": "duplicate"}, {"pt": "  ", "en": "blank"}]}
        """
        let cards = try VocabFeed.parse(Data(json.utf8))
        #expect(cards.map(\.front) == ["regressar", "velho"])
        #expect(cards[0].back == "to return\n\nA chuva pode regressar.\nThe rain may return.")
        #expect(cards[1].back == "alt") // falls back to German
        #expect(cards[0].sourceKey == "regressar")
    }

    @Test func mergeKeepsProgressAddsAndRemoves() {
        var known = Card(front: "a", back: "old", sourceKey: "a")
        known = Scheduler.review(known, rating: .good)
        let deck = Deck(name: "d", cards: [known, Card(front: "gone", back: "x", sourceKey: "gone")])

        let merged = deck.merging([Card(front: "a", back: "new", sourceKey: "a"),
                                   Card(front: "b", back: "b", sourceKey: "b")])

        #expect(merged.cards.map(\.front) == ["a", "b"])
        #expect(merged.cards[0].id == known.id)
        #expect(merged.cards[0].reps == 1)
        #expect(merged.cards[0].back == "new")
        #expect(merged.cards[1].isNew)
    }

    @Test func decodesCardsSavedBeforeSyncFields() throws {
        let json = #"[{"id":"7F0C1E52-5E8B-4C5B-9C7B-1C2D3E4F5A6B","name":"Old","cards":[{"id":"8F0C1E52-5E8B-4C5B-9C7B-1C2D3E4F5A6B","front":"f","back":"b"}]}]"#
        let decks = try JSONDecoder().decode([Deck].self, from: Data(json.utf8))
        #expect(decks[0].cards[0].sourceKey == nil)
        #expect(decks[0].source == nil)
    }
}

struct FeedLanguageTests {
    let json = Data("""
    {"2026-10-28": [{"pt": "alcançar", "en": "to reach", "de": "erreichen",
                     "example": "A paciência atingiu o limite",
                     "example_en": "Patience has reached the limit",
                     "example_de": "Die Geduld hat die Grenze erreicht"},
                    {"pt": "só alemão", "de": "nur Deutsch"}]}
    """.utf8)

    @Test func german() throws {
        let cards = try VocabFeed.parse(json, language: .german)
        #expect(cards[0].back == "erreichen\n\nA paciência atingiu o limite\nDie Geduld hat die Grenze erreicht")
    }

    @Test func both() throws {
        let cards = try VocabFeed.parse(json, language: .both)
        #expect(cards[0].back == "to reach\nerreichen\n\nA paciência atingiu o limite\nPatience has reached the limit\nDie Geduld hat die Grenze erreicht")
        #expect(cards[1].back == "nur Deutsch")
    }
}

struct ReverseTests {
    @Test func reverseProgressIsSeparate() {
        var card = Scheduler.review(Card(front: "a", back: "b"), rating: .good)
        #expect(card.flipped().isNew)
        #expect(card.flipped().isDue(at: .now))

        card.reverse = ReviewState(Scheduler.review(card.flipped(), rating: .easy))
        #expect(card.flipped().reps == 1)
        #expect(card.flipped().ease > card.ease)
        #expect(card.reps == 1 && card.ease == 2.5) // forward progress untouched
    }

    @Test func reverseSurvivesSaveAndSync() throws {
        var card = Card(front: "a", back: "b", sourceKey: "a")
        card.reverse = ReviewState(Scheduler.review(card.flipped(), rating: .good))
        let data = try JSONEncoder().encode(card)
        let decoded = try JSONDecoder().decode(Card.self, from: data)
        #expect(decoded.reverse == card.reverse)

        let merged = Deck(name: "d", cards: [decoded]).merging([Card(front: "a", back: "new", sourceKey: "a")])
        #expect(merged.cards[0].reverse?.reps == 1)
    }
}
