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

    var isNew: Bool { reps == 0 && lapses == 0 }
    func isDue(at date: Date) -> Bool { due <= date }
}

struct Deck: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var cards: [Card] = []
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

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10, Double(places))
        return (self * m).rounded() / m
    }
}
