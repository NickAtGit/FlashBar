import Foundation

struct Card: Identifiable, Codable, Hashable {
    var id = UUID()
    var front: String
    var back: String
    var ease: Double = 2.5
    var intervalDays: Double = 0
    var reps = 0
    var lapses = 0
    var due = Date.distantPast
    var created = Date.now
    var firstReviewed: Date?
    /// Stable identity for cards that come from a synced deck, used to keep progress across syncs.
    var sourceKey: String?

    var isNew: Bool { reps == 0 && lapses == 0 }
    func isDue(at date: Date) -> Bool { due <= date }
}

extension Card {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        front = try c.decode(String.self, forKey: .front)
        back = try c.decode(String.self, forKey: .back)
        ease = try c.decodeIfPresent(Double.self, forKey: .ease) ?? 2.5
        intervalDays = try c.decodeIfPresent(Double.self, forKey: .intervalDays) ?? 0
        reps = try c.decodeIfPresent(Int.self, forKey: .reps) ?? 0
        lapses = try c.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        due = try c.decodeIfPresent(Date.self, forKey: .due) ?? .distantPast
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .now
        firstReviewed = try c.decodeIfPresent(Date.self, forKey: .firstReviewed)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
    }
}

struct Deck: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
    /// When set, the deck mirrors this remote file and its cards are read-only.
    var source: URL?
    var lastSynced: Date?

    var isSynced: Bool { source != nil }

    /// Replaces the cards with `remote`, carrying over review progress for cards with the same `sourceKey`.
    func merging(_ remote: [Card]) -> Deck {
        let existing = Dictionary(cards.compactMap { c in c.sourceKey.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
        var deck = self
        deck.cards = remote.map { incoming in
            guard let key = incoming.sourceKey, var card = existing[key] else { return incoming }
            card.front = incoming.front
            card.back = incoming.back
            card.created = incoming.created
            return card
        }
        return deck
    }
}

extension Deck {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        cards = try c.decodeIfPresent([Card].self, forKey: .cards) ?? []
        source = try c.decodeIfPresent(URL.self, forKey: .source)
        lastSynced = try c.decodeIfPresent(Date.self, forKey: .lastSynced)
    }
}

enum Rating: Int, CaseIterable, Identifiable {
    case again = 1, hard, good, easy
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .again: "Again"
        case .hard: "Hard"
        case .good: "Good"
        case .easy: "Easy"
        }
    }
}

/// A small SM-2 variant: intervals land on day boundaries so a day's cards come due together.
enum Scheduler {
    static let minEase = 1.3

    static func review(_ card: Card, rating: Rating, now: Date = .now, calendar: Calendar = .current) -> Card {
        var card = card
        if rating == .again {
            card.reps = 0
            card.lapses += 1
            card.intervalDays = 0
            card.ease = max(minEase, (card.ease - 0.2).rounded(toPlaces: 2))
            card.due = now.addingTimeInterval(60)
            return card
        }

        let interval: Double = switch (card.reps, rating) {
        case (0, .easy): 4
        case (0, _): 1
        case (1, .hard): 3
        case (1, .good): 6
        case (1, _): 6 * card.ease
        case (_, .hard): card.intervalDays * 1.2
        case (_, .good): card.intervalDays * card.ease
        default: card.intervalDays * card.ease * 1.3
        }

        switch rating {
        case .hard: card.ease = max(minEase, (card.ease - 0.15).rounded(toPlaces: 2))
        case .easy: card.ease = (card.ease + 0.15).rounded(toPlaces: 2)
        default: break
        }

        card.reps += 1
        card.intervalDays = max(1, interval.rounded())
        card.due = calendar.date(byAdding: .day, value: Int(card.intervalDays), to: calendar.startOfDay(for: now))!
        return card
    }

    /// Short label for the next interval a rating would give, shown under the rating buttons.
    static func preview(_ card: Card, rating: Rating, now: Date = .now) -> String {
        let next = review(card, rating: rating, now: now)
        if rating == .again { return "1m" }
        let d = Int(next.intervalDays)
        return d < 30 ? "\(d)d" : d < 365 ? "\(d / 30)mo" : String(format: "%.1fy", Double(d) / 365)
    }
}

enum CardImporter {
    /// One card per line, `front<TAB>back` or `front,back`. Blank lines and `#` comments are skipped.
    static func parse(_ text: String) -> [Card] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let separator: Character = line.contains("\t") ? "\t" : ","
            guard let i = line.firstIndex(of: separator) else { return nil }
            let front = line[..<i].trimmingCharacters(in: .whitespaces)
            let back = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            guard !front.isEmpty, !back.isEmpty else { return nil }
            return Card(front: front, back: back)
        }
    }

    static func export(_ deck: Deck) -> String {
        deck.cards.map { "\($0.front)\t\($0.back)" }.joined(separator: "\n")
    }
}

/// Parses the `vocab.json` format of github.com/robin-wonderboy/portuguese-flashcards:
/// `{ "YYYY-MM-DD": [{ "pt", "en", "de", "example", "example_en", "example_de" }] }`.
enum VocabFeed {
    static let portugueseURL = URL(string: "https://raw.githubusercontent.com/robin-wonderboy/portuguese-flashcards/main/data/vocab.json")!

    private struct Entry: Decodable {
        let pt: String
        let en: String?
        let de: String?
        let example: String?
        let example_en: String?
        let example_de: String?
    }

    static func parse(_ data: Data) throws -> [Card] {
        let days = try JSONDecoder().decode([String: [Entry]].self, from: data)
        let dateFormat = Date.ISO8601FormatStyle().year().month().day()
        var seen = Set<String>()
        // Newest days first, so new-card order follows the feed.
        return days.sorted { $0.key > $1.key }.flatMap { day, entries in
            let created = (try? dateFormat.parse(day)) ?? .distantPast
            return entries.compactMap { e -> Card? in
                let pt = e.pt.trimmingCharacters(in: .whitespaces)
                guard !pt.isEmpty, let meaning = e.en ?? e.de, seen.insert(pt).inserted else { return nil }
                var back = meaning
                if let example = e.example, !example.isEmpty {
                    back += "\n\n" + example
                    if let translation = e.example_en ?? e.example_de { back += "\n" + translation }
                }
                return Card(front: pt, back: back, created: created, sourceKey: pt)
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10, Double(places))
        return (self * m).rounded() / m
    }
}
