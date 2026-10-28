import Foundation
import Observation

@MainActor @Observable
final class Store {
    var decks: [Deck] = [] { didSet { save() } }
    /// `nil` studies every deck.
    var studyDeckID: UUID? {
        didSet { UserDefaults.standard.set(studyDeckID?.uuidString, forKey: "studyDeckID") }
    }
    /// How many never-seen cards are introduced per day, so a big synced deck doesn't land all at once.
    var newCardsPerDay = UserDefaults.standard.object(forKey: "newCardsPerDay") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(newCardsPerDay, forKey: "newCardsPerDay") }
    }
    /// Ticks every 30s so due counts update while the app idles in the menu bar.
    private(set) var now = Date.now
    private(set) var isSyncing = false
    private(set) var syncError: String?

    private let fileURL: URL
    private var timer: Timer?
    private var syncTimer: Timer?
    private static let syncInterval: TimeInterval = 3 * 60 * 60

    init(fileURL: URL = Store.defaultURL) {
        self.fileURL = fileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? decoder.decode([Deck].self, from: data) {
            decks = decoded
        } else {
            decks = [Store.sampleDeck]
        }
        studyDeckID = UserDefaults.standard.string(forKey: "studyDeckID").flatMap(UUID.init)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = .now }
        }
        addBuiltInFeedsOnce()
        syncTimer = Timer.scheduledTimer(withTimeInterval: Store.syncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    /// Subscribes to the Portuguese vocab feed on first run. Deleting the deck afterwards sticks.
    private func addBuiltInFeedsOnce() {
        let key = "addedPortugueseFeed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !decks.contains(where: { $0.source == VocabFeed.portugueseURL }) {
            decks.append(Deck(name: "Portuguese (Coimbra News)", source: VocabFeed.portugueseURL))
        }
    }

    // MARK: Sync

    func sync() {
        guard !isSyncing else { return }
        let feeds = decks.compactMap { d in d.source.map { (d.id, $0) } }
        guard !feeds.isEmpty else { return }
        isSyncing = true
        Task {
            var errors: [String] = []
            for (deckID, url) in feeds {
                do {
                    var request = URLRequest(url: url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw URLError(.badServerResponse)
                    }
                    let cards = try VocabFeed.parse(data)
                    if let i = decks.firstIndex(where: { $0.id == deckID }) {
                        var deck = decks[i].merging(cards)
                        deck.lastSynced = .now
                        decks[i] = deck
                    }
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
            syncError = errors.first
            isSyncing = false
            now = .now
        }
    }

    nonisolated static var defaultURL: URL {
        let dir = URL.applicationSupportDirectory.appending(path: "FlashBar", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "decks.json")
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(decks) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Queries

    var studyDecks: [Deck] {
        guard let id = studyDeckID, let deck = decks.first(where: { $0.id == id }) else { return decks }
        return [deck]
    }

    /// Due reviews first, then today's remaining allowance of new cards (newest first).
    func dueCards(in decks: [Deck]) -> [Card] {
        let cards = decks.flatMap(\.cards)
        let reviews = cards.filter { !$0.isNew && $0.isDue(at: now) }.sorted { $0.due < $1.due }
        let introducedToday = cards.count { $0.firstReviewed.map(Calendar.current.isDateInToday) ?? false }
        let allowance = max(0, newCardsPerDay - introducedToday)
        let new = cards.filter(\.isNew).sorted { $0.created > $1.created }.prefix(allowance)
        return reviews + new
    }

    var dueCount: Int { dueCards(in: studyDecks).count }

    /// Unseen cards are waiting but today's new-card allowance is used up.
    var newCardsWaitingForTomorrow: Bool {
        studyDecks.contains { $0.cards.contains(where: \.isNew) } && !dueCards(in: studyDecks).contains(where: \.isNew)
    }

    var nextDue: Date? { studyDecks.flatMap(\.cards).map(\.due).filter { $0 > now }.min() }

    func card(_ id: UUID) -> Card? {
        for deck in decks { if let c = deck.cards.first(where: { $0.id == id }) { return c } }
        return nil
    }

    // MARK: Mutations

    func review(_ cardID: UUID, rating: Rating) {
        update(cardID) { card in
            var next = Scheduler.review(card, rating: rating)
            next.firstReviewed = card.firstReviewed ?? .now
            return next
        }
        now = .now
    }

    func update(_ cardID: UUID, _ transform: (Card) -> Card) {
        for d in decks.indices {
            if let c = decks[d].cards.firstIndex(where: { $0.id == cardID }) {
                decks[d].cards[c] = transform(decks[d].cards[c])
                return
            }
        }
    }

    @discardableResult
    func addDeck(named name: String) -> Deck {
        let deck = Deck(name: name)
        decks.append(deck)
        return deck
    }

    func deleteDeck(_ id: UUID) {
        decks.removeAll { $0.id == id }
        if studyDeckID == id { studyDeckID = nil }
    }

    func addCards(_ cards: [Card], to deckID: UUID) {
        guard let d = decks.firstIndex(where: { $0.id == deckID }) else { return }
        decks[d].cards.append(contentsOf: cards)
    }

    func deleteCards(_ ids: Set<UUID>, from deckID: UUID) {
        guard let d = decks.firstIndex(where: { $0.id == deckID }) else { return }
        decks[d].cards.removeAll { ids.contains($0.id) }
    }

    func resetProgress(deckID: UUID) {
        guard let d = decks.firstIndex(where: { $0.id == deckID }) else { return }
        decks[d].cards = decks[d].cards.map { Card(id: $0.id, front: $0.front, back: $0.back, created: $0.created, sourceKey: $0.sourceKey) }
    }

    static let sampleDeck = Deck(name: "Getting Started", cards: [
        Card(front: "How do I flip a card?", back: "Press Space, or click the card."),
        Card(front: "How do I rate a card?", back: "Press 1 Again, 2 Hard, 3 Good or 4 Easy."),
        Card(front: "Where do I add my own cards?", back: "Click the gear, then Manage Decks. You can also import a TSV or CSV file."),
        Card(front: "What does the number in the menu bar mean?", back: "How many cards are due right now."),
    ])
}
