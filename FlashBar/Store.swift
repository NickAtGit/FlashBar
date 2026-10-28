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
    /// Which translations synced vocab cards show. Changing it rebuilds them from the cached feed.
    var feedLanguage = FeedLanguage(rawValue: UserDefaults.standard.string(forKey: "feedLanguage") ?? "") ?? .english {
        didSet {
            UserDefaults.standard.set(feedLanguage.rawValue, forKey: "feedLanguage")
            reapplyCachedFeeds()
        }
    }
    /// Which side is asked. Reverse cards have their own progress (`Card.reverse`).
    var direction = StudyDirection(rawValue: UserDefaults.standard.string(forKey: "studyDirection") ?? "") ?? .forward {
        didSet { UserDefaults.standard.set(direction.rawValue, forKey: "studyDirection") }
    }
    /// Last time a card was rated or practiced, for the idle reminder.
    /// Starts at launch time when unknown, so the reminder doesn't fire right away.
    private(set) var lastStudied = UserDefaults.standard.object(forKey: "lastStudied") as? Date ?? .now {
        didSet { UserDefaults.standard.set(lastStudied, forKey: "lastStudied") }
    }
    /// Colors the menu bar icon after an hour without studying, while there's something to study.
    var remindWhenIdle = UserDefaults.standard.object(forKey: "remindWhenIdle") as? Bool ?? true {
        didSet { UserDefaults.standard.set(remindWhenIdle, forKey: "remindWhenIdle") }
    }
    static let idleReminderAfter: TimeInterval = 60 * 60
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
                    try apply(data, to: deckID)
                    try? data.write(to: cacheURL(for: deckID), options: .atomic)
                    if let i = decks.firstIndex(where: { $0.id == deckID }) { decks[i].lastSynced = .now }
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

    private func apply(_ data: Data, to deckID: UUID) throws {
        let cards = try VocabFeed.parse(data, language: feedLanguage)
        if let i = decks.firstIndex(where: { $0.id == deckID }) { decks[i] = decks[i].merging(cards) }
    }

    private func cacheURL(for deckID: UUID) -> URL {
        fileURL.deletingLastPathComponent().appending(path: "feed-\(deckID.uuidString).json")
    }

    private func reapplyCachedFeeds() {
        var missing = false
        for deck in decks where deck.isSynced {
            if let data = try? Data(contentsOf: cacheURL(for: deck.id)) {
                try? apply(data, to: deck.id)
            } else {
                missing = true
            }
        }
        if missing { sync() }
    }

    // MARK: Queries

    var studyDecks: [Deck] {
        guard let id = studyDeckID, let deck = decks.first(where: { $0.id == id }) else { return decks }
        return [deck]
    }

    /// Due reviews first, then today's remaining allowance of new cards (newest first).
    func dueCards(in decks: [Deck]) -> [Card] {
        let cards = studyCards(in: decks)
        let reviews = cards.filter { !$0.isNew && $0.isDue(at: now) }.sorted { $0.due < $1.due }
        let introducedToday = cards.count { $0.firstReviewed.map(Calendar.current.isDateInToday) ?? false }
        let allowance = max(0, newCardsPerDay - introducedToday)
        let new = cards.filter(\.isNew).sorted { $0.created > $1.created }.prefix(allowance)
        return reviews + new
    }

    /// Cards already studied today in the current direction, in the order they were reviewed.
    func reviewedToday(in decks: [Deck]) -> [Card] {
        studyCards(in: decks)
            .filter { $0.wasReviewed(onDayOf: now) }
            .sorted { ($0.lastReviewed ?? .distantPast) < ($1.lastReviewed ?? .distantPast) }
    }

    var needsRepetition: Bool {
        guard remindWhenIdle, now.timeIntervalSince(lastStudied) >= Store.idleReminderAfter else { return false }
        return dueCount > 0 || !reviewedToday(in: studyDecks).isEmpty
    }

    func noteStudied() {
        lastStudied = .now
        now = .now
    }

    var dueCount: Int { dueCards(in: studyDecks).count }

    /// Unseen cards are waiting but today's new-card allowance is used up.
    var newCardsWaitingForTomorrow: Bool {
        studyCards(in: studyDecks).contains(where: \.isNew) && !dueCards(in: studyDecks).contains(where: \.isNew)
    }

    var nextDue: Date? { studyCards(in: studyDecks).map(\.due).filter { $0 > now }.min() }

    /// Synced vocab is European Portuguese; other decks let the speaker guess from the text.
    func speechLanguage(for cardID: UUID) -> String? {
        decks.first { $0.cards.contains { $0.id == cardID } }?.isSynced == true ? "pt-PT" : nil
    }

    func isSynced(_ cardID: UUID) -> Bool {
        decks.first { $0.cards.contains { $0.id == cardID } }?.isSynced ?? false
    }

    /// The cards as seen in the current direction: in reverse, scheduling fields hold the reverse progress.
    func studyCards(in decks: [Deck]) -> [Card] {
        let cards = decks.flatMap(\.cards)
        return direction == .reverse ? cards.map { $0.flipped() } : cards
    }

    func studyCard(_ id: UUID) -> Card? {
        card(id).map { direction == .reverse ? $0.flipped() : $0 }
    }

    func card(_ id: UUID) -> Card? {
        for deck in decks { if let c = deck.cards.first(where: { $0.id == id }) { return c } }
        return nil
    }

    // MARK: Mutations

    func review(_ cardID: UUID, rating: Rating) {
        let reverse = direction == .reverse
        update(cardID) { card in
            let seen = reverse ? card.flipped() : card
            var next = Scheduler.review(seen, rating: rating)
            next.firstReviewed = seen.firstReviewed ?? .now
            next.lastReviewed = .now
            guard reverse else { return next }
            var updated = card
            updated.reverse = ReviewState(next)
            return updated
        }
        noteStudied()
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
