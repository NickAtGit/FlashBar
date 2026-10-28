import SwiftUI
import UniformTypeIdentifiers

struct ManageView: View {
    @Environment(Store.self) private var store
    @State private var selectedDeckID: UUID?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedDeckID) {
                ForEach(store.decks) { deck in
                    HStack {
                        Text(deck.name)
                        Spacer()
                        let due = store.dueCards(in: [deck]).count
                        if due > 0 {
                            Text("\(due)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .tag(deck.id)
                    .contextMenu {
                        Button("Delete Deck", role: .destructive) { store.deleteDeck(deck.id) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                Button {
                    selectedDeckID = store.addDeck(named: "New Deck").id
                } label: {
                    Label("New Deck", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            if let id = selectedDeckID, store.decks.contains(where: { $0.id == id }) {
                DeckDetailView(deckID: id)
            } else {
                ContentUnavailableView("No Deck Selected", systemImage: "rectangle.stack",
                                       description: Text("Pick a deck on the left or create a new one."))
            }
        }
        .onAppear { selectedDeckID = selectedDeckID ?? store.decks.first?.id }
    }
}

private struct DeckDetailView: View {
    @Environment(Store.self) private var store
    let deckID: UUID
    @State private var front = ""
    @State private var back = ""
    @State private var selection = Set<UUID>()
    @State private var confirmReset = false
    @FocusState private var frontFocused: Bool

    private var deck: Deck? { store.decks.first { $0.id == deckID } }

    var body: some View {
        VStack(spacing: 0) {
            addForm.padding(12)
            Divider()
            Table(deck?.cards ?? [], selection: $selection) {
                TableColumn("Front") { card in TextField("Front", text: field(card.id, \.front)) }
                TableColumn("Back") { card in TextField("Back", text: field(card.id, \.back)) }
                TableColumn("Due") { card in
                    Text(dueLabel(card)).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100, max: 140)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Delete", role: .destructive) { store.deleteCards(ids, from: deckID) }
            }
            .onDeleteCommand { store.deleteCards(selection, from: deckID) }
        }
        .navigationTitle(deck?.name ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                TextField("Deck name", text: deckName).frame(minWidth: 200)
            }
            ToolbarItemGroup {
                Button("Import…", systemImage: "square.and.arrow.down", action: importCards)
                    .help("Import a TSV or CSV file, one card per line: front, back")
                Button("Export…", systemImage: "square.and.arrow.up", action: exportCards)
                Button("Reset Progress", systemImage: "arrow.counterclockwise") { confirmReset = true }
            }
        }
        .confirmationDialog("Reset progress for every card in this deck?", isPresented: $confirmReset) {
            Button("Reset Progress", role: .destructive) { store.resetProgress(deckID: deckID) }
        }
        .onChange(of: deckID) { selection = [] }
    }

    private var addForm: some View {
        HStack {
            TextField("Front", text: $front).focused($frontFocused)
            TextField("Back", text: $back)
            Button("Add Card", action: addCard)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(front.trimmingCharacters(in: .whitespaces).isEmpty
                          || back.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit(addCard)
    }

    // MARK: Helpers

    private var deckName: Binding<String> {
        Binding(get: { deck?.name ?? "" }) { name in
            if let i = store.decks.firstIndex(where: { $0.id == deckID }) { store.decks[i].name = name }
        }
    }

    private func field(_ id: UUID, _ keyPath: WritableKeyPath<Card, String>) -> Binding<String> {
        Binding(get: { store.card(id)?[keyPath: keyPath] ?? "" }) { value in
            store.update(id) { var c = $0; c[keyPath: keyPath] = value; return c }
        }
    }

    private func dueLabel(_ card: Card) -> String {
        if card.isNew { return "New" }
        if card.isDue(at: store.now) { return "Now" }
        return card.due.formatted(.relative(presentation: .named))
    }

    private func addCard() {
        let f = front.trimmingCharacters(in: .whitespaces), b = back.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !b.isEmpty else { return }
        store.addCards([Card(front: f, back: b)], to: deckID)
        front = ""
        back = ""
        frontFocused = true
    }

    private func importCards() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tabSeparatedText, .commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let cards = panel.urls.flatMap { url in
            (try? String(contentsOf: url, encoding: .utf8)).map(CardImporter.parse) ?? []
        }
        store.addCards(cards, to: deckID)
    }

    private func exportCards() {
        guard let deck else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tabSeparatedText]
        panel.nameFieldStringValue = "\(deck.name).tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? CardImporter.export(deck).write(to: url, atomically: true, encoding: .utf8)
    }
}
