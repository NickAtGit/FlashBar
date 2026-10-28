# FlashBar

A flashcard app that lives in the macOS menu bar, with spaced repetition (an SM-2 variant).

- The menu bar icon shows how many cards are due now.
- Space flips a card. 1 to 4 rate it: Again, Hard, Good, Easy.
- Gear menu → Manage Decks to add, edit, import or export cards.
- Import format is one card per line, `front<TAB>back` or `front,back`.
- Data lives in `~/Library/Application Support/FlashBar/decks.json`.

## Build

    xcodegen generate
    open FlashBar.xcodeproj
