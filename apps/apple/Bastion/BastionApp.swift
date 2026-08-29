import SwiftUI

/// Bastion is a menu bar agent: `LSUIElement` is on, there is no Dock icon and
/// no main window at launch. The gateway has to be reachable whether or not
/// anyone has opened the menu, so starting it will belong to the app lifecycle
/// rather than to this menu — `MenuBarExtra` content is built lazily, so it
/// cannot live in the menu closure.
///
/// Nothing is started yet. This is the shell the Gateway and Supervisor land
/// in; what it does today is prove the catalog compiles and show what Bastion
/// is allowed to run.
@main
struct BastionApp: App {
  var body: some Scene {
    MenuBarExtra("Bastion", systemImage: "shield.lefthalf.filled") {
      CatalogMenu()
    }
  }
}

private struct CatalogMenu: View {
  var body: some View {
    ForEach(ServerCatalog.all) { server in
      // Disabled, not absent. The list is the closed table, and showing it
      // greyed out is the honest state of the app right now: these are the
      // servers Bastion may supervise, and it supervises none of them yet.
      Button(server.displayName) {}
        .disabled(true)
    }
    Divider()
    Button("Quit Bastion") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
