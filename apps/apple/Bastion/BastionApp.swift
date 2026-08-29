import SwiftUI

/// Bastion is a menu bar agent: `LSUIElement` is on, there is no Dock icon and
/// no main window at launch. The gateway has to be reachable whether or not
/// anyone has opened the menu, so starting it will belong to the app lifecycle
/// rather than to this menu — `MenuBarExtra` content is built lazily, so it
/// cannot live in the menu closure.
///
/// Nothing is started yet. This is the shell the Gateway and Supervisor land in.
@main
struct BastionApp: App {
  var body: some Scene {
    MenuBarExtra("Bastion", systemImage: "shield.lefthalf.filled") {
      Button("Quit Bastion") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
  }
}
