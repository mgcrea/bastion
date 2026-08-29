import SwiftUI

/// Starting the gateway belongs to the app lifecycle, not to the menu: the
/// servers must be reachable whether or not anyone has opened the menu bar
/// item, and `MenuBarExtra` content is built lazily, so it cannot live there.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Explicitly, and before anything can ask for a profile.
    //
    // `ProfileStore` publishes a nonisolated snapshot that the connection
    // threads read without hopping to the main actor, and that snapshot is
    // filled by `load()` in its initialiser — so a lazily-constructed store is
    // an empty snapshot, and every request answers "no profile 'prod' for
    // shopify" while `profiles.json` sits on disk with the profile in it.
    // Nothing else on this path touches the store, so nothing else would
    // construct it.
    _ = ProfileStore.shared
    #if DEBUG
      DevSeed.runIfPresent()
    #endif
    do {
      try Gateway.shared.start()
    } catch {
      hostLog("gateway", .error, error.localizedDescription)
    }
  }

  /// Stop the children before the app goes.
  ///
  /// Not merely tidiness. A child that outlives Bastion is a process holding
  /// the user's credentials with nothing supervising it, no Activity window
  /// recording what it does, and no parent to notice it is there — which is
  /// precisely the state the whole project exists to end.
  func applicationWillTerminate(_ notification: Notification) {
    Supervisor.shared.stopAll()
    Gateway.shared.stop()
  }
}

@main
struct BastionApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    MenuBarExtra("Bastion", systemImage: "shield.lefthalf.filled") {
      GatewayMenu()
    }
  }
}

private struct GatewayMenu: View {
  var body: some View {
    if let error = Gateway.shared.startupError {
      // The one state where nothing will ever work. It has to be visible from
      // the menu, because the alternative is a menu bar icon that looks fine
      // and a client that says "connection refused".
      Text("Not serving — \(error)")
    } else {
      Text("Serving on 127.0.0.1:\(String(Gateway.shared.port))")
    }
    Divider()

    let running = Supervisor.shared.running
    if running.isEmpty {
      Text("No servers running")
    } else {
      ForEach(running, id: \.id) { instance in
        Text("\(instance.id) — pid \(String(instance.pid))")
      }
    }

    Divider()
    Button("Quit Bastion") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
