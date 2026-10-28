import SwiftUI

@main
struct FlashBarApp: App {
    // Unit tests run inside the app; keep them away from the real decks file.
    @State private var store = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        ? Store()
        : Store(fileURL: .temporaryDirectory.appending(path: "FlashBarTests.json"))

    var body: some Scene {
        MenuBarExtra {
            StudyView()
                .environment(store)
        } label: {
            let count = store.dueCount
            if store.needsRepetition {
                Image(nsImage: .reminderIcon)
            } else {
                Image(systemName: count > 0 ? "rectangle.stack.fill" : "rectangle.stack")
            }
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

private extension NSImage {
    /// Menu bar icons are drawn as monochrome templates; this one opts out so the color shows.
    static let reminderIcon: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.init(paletteColors: [.systemOrange]))
        let image = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: "Time to review")!
            .withSymbolConfiguration(config)!
        image.isTemplate = false
        return image
    }()
}
