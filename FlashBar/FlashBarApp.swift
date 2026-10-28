import SwiftUI

@main
struct FlashBarApp: App {
    @State private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            StudyView()
                .environment(store)
        } label: {
            let count = store.dueCount
            Image(systemName: count > 0 ? "rectangle.stack.fill" : "rectangle.stack")
            if count > 0 { Text("\(count)") }
        }
        .menuBarExtraStyle(.window)

        Window("Manage Decks", id: "manage") {
            ManageView()
                .environment(store)
        }
        .defaultSize(width: 780, height: 500)
        .windowResizability(.contentMinSize)
    }
}
