import ServiceManagement
import SwiftUI

struct StudyView: View {
    @Environment(Store.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var queue: [UUID] = []
    @State private var revealed = false
    @State private var reviewedThisSession = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private var speaker: Speaker { .shared }

    private var current: Card? { queue.first.flatMap(store.card) }

    var body: some View {
        VStack(spacing: 12) {
            header
            if let card = current {
                cardFace(card)
                controls(card)
            } else {
                doneState
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear(perform: refillIfEmpty)
        .onChange(of: store.studyDeckID) { rebuildQueue() }
        .onChange(of: queue.first, initial: true) { autoSpeak() }
        .onDisappear { speaker.stop() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack {
            Picker("Deck", selection: Binding(get: { store.studyDeckID }, set: { store.studyDeckID = $0 })) {
                Text("All Decks").tag(UUID?.none)
                Divider()
                ForEach(store.decks) { deck in
                    Text(deck.name).tag(UUID?.some(deck.id))
                }
            }
            .labelsHidden()
            .fixedSize()

            Spacer()

            Text(queue.isEmpty ? "" : "\(queue.count) left")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Menu {
                Button("Manage Decks…") { openManager() }
                    .keyboardShortcut(",")
                Picker("New Cards per Day", selection: Binding(get: { store.newCardsPerDay },
                                                               set: { store.newCardsPerDay = $0 })) {
                    ForEach([0, 10, 20, 30, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Translations", selection: Binding(get: { store.feedLanguage },
                                                          set: { store.feedLanguage = $0 })) {
                    ForEach(FeedLanguage.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Read Words Aloud Automatically", isOn: Binding(get: { speaker.autoSpeak },
                                                                         set: { speaker.autoSpeak = $0 }))
                Toggle("Slow Speech", isOn: Binding(get: { speaker.slow }, set: { speaker.slow = $0 }))
                Button(store.isSyncing ? "Syncing…" : "Sync Now") { store.sync() }
                    .disabled(store.isSyncing)
                Divider()
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                Divider()
                Button("Quit FlashBar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func cardFace(_ card: Card) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.front)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                speakButton(card.front, language: store.speechLanguage(for: card.id))
                    .keyboardShortcut("s", modifiers: [])
                    .help("Listen (S)")
            }
            if revealed {
                Divider()
                answer(card)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .multilineTextAlignment(.center)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, minHeight: 150)
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            if card.isNew {
                Text("NEW").font(.caption2.bold()).foregroundStyle(.blue).padding(8)
            }
        }
        .contentShape(.rect)
        .onTapGesture { reveal() }
    }

    /// The meaning, then any example (everything after the first blank line) in a quieter style.
    /// In synced vocab the example's first line is Portuguese, so it gets its own listen button.
    private func answer(_ card: Card) -> some View {
        let parts = card.back.components(separatedBy: "\n\n")
        let exampleLines = parts.dropFirst().joined(separator: "\n\n").components(separatedBy: "\n")
        let spokenExample = store.isSynced(card.id) ? exampleLines.first.flatMap { $0.isEmpty ? nil : $0 } : nil
        let rest = (spokenExample == nil ? exampleLines : Array(exampleLines.dropFirst())).joined(separator: "\n")
        return VStack(spacing: 10) {
            Text(parts[0])
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                if let spokenExample {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(spokenExample)
                            .foregroundStyle(.primary.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                        speakButton(spokenExample, language: store.speechLanguage(for: card.id))
                            .help("Listen to the example")
                    }
                }
                if !rest.isEmpty {
                    Text(rest)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .italic()
        }
    }

    private func speakButton(_ text: String, language: String?) -> some View {
        Button {
            speaker.toggle(text, language: language)
        } label: {
            Image(systemName: speaker.speakingText == text ? "stop.circle.fill" : "speaker.wave.2.fill")
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func controls(_ card: Card) -> some View {
        if revealed {
            HStack(spacing: 6) {
                ForEach(Rating.allCases) { rating in
                    Button { rate(rating) } label: {
                        VStack(spacing: 2) {
                            Text(rating.title)
                            Text(Scheduler.preview(card, rating: rating, now: store.now))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .tint(color(for: rating))
                    .keyboardShortcut(KeyEquivalent(Character("\(rating.rawValue)")), modifiers: [])
                    .help("Press \(rating.rawValue)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        } else {
            Button(action: reveal) {
                Text("Show Answer").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .help("Press Space")
        }
    }

    private var doneState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 36))
                .foregroundStyle(.green)
            Text("All caught up").font(.headline)
            Group {
                if reviewedThisSession > 0 {
                    Text("\(reviewedThisSession) reviewed this session.")
                }
                if store.dueCount > 0 {
                    Button("Study \(store.dueCount) more") { rebuildQueue() }
                } else if store.newCardsWaitingForTomorrow {
                    Text("More new cards tomorrow.")
                } else if let next = store.nextDue {
                    Text("Next card due \(next, format: .relative(presentation: .named)).")
                } else if store.studyDecks.allSatisfy(\.cards.isEmpty) {
                    Button("Add some cards…") { openManager() }
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
    }

    // MARK: Actions

    private func reveal() {
        withAnimation(.snappy(duration: 0.2)) { revealed = true }
    }

    private func autoSpeak() {
        guard speaker.autoSpeak, let card = current else { return }
        speaker.speak(card.front, language: store.speechLanguage(for: card.id))
    }

    private func rate(_ rating: Rating) {
        guard let id = queue.first else { return }
        store.review(id, rating: rating)
        queue.removeFirst()
        if rating == .again { queue.append(id) } else { reviewedThisSession += 1 }
        revealed = false
    }

    private func refillIfEmpty() {
        // Drop cards deleted in the manager while the session was open.
        queue.removeAll { store.card($0) == nil }
        if queue.isEmpty { rebuildQueue() }
    }

    private func rebuildQueue() {
        queue = store.dueCards(in: store.studyDecks).map(\.id)
        revealed = false
        reviewedThisSession = 0
    }

    private func openManager() {
        openWindow(id: "manage")
        NSApp.activate()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func color(for rating: Rating) -> Color {
        switch rating {
        case .again: .red
        case .hard: .orange
        case .good: .green
        case .easy: .blue
        }
    }
}
