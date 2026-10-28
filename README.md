# FlashBar

A flashcard app that lives in the macOS menu bar, with spaced repetition (an SM-2 variant).

- The menu bar icon shows how many cards are due now.
- Space flips a card. 1 to 4 rate it: Again, Hard, Good, Easy.
- Gear menu → Card Direction switches to Meaning → Word (English to Portuguese). That direction has its own progress.
- Gear menu → Practice Today's Cards Again re-studies what you reviewed today without changing its schedule (Again requeues, Space moves on).
- The menu bar icon turns orange after an hour without studying, while cards are due or today's cards can be practiced (gear menu toggle).
- Gear menu → Manage Decks to add, edit, import or export cards.
- Import format is one card per line, `front<TAB>back` or `front,back`.
- The "Portuguese (Coimbra News)" deck mirrors [robin-wonderboy/portuguese-flashcards](https://github.com/robin-wonderboy/portuguese-flashcards) `data/vocab.json`, synced on launch and every 3 hours. Progress survives syncs. New cards are capped per day (gear menu).
- Data lives in `~/Library/Application Support/FlashBar/decks.json`.

## Build

    xcodegen generate
    open FlashBar.xcodeproj
