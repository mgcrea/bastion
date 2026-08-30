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

    // Builds nothing unless the user has already opted in. Sparkle starts a
    // scheduler the moment it is constructed, so this must not be a
    // constructor call guarded by a later check.
    UpdateController.shared.startIfConsented()

    #if DEBUG
      // For looking at the window without hunting for the menu bar icon, and
      // for capturing it. A menu bar agent has no other way to be told "open
      // your window" from a script.
      if CommandLine.arguments.contains("--activity") {
        ActivityWindowController.show()
      }
      if CommandLine.arguments.contains("--clients") {
        ClientsWindowController.show()
      }
    #endif
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
    MenuBarExtra {
      GatewayMenu()
    } label: {
      MenuBarLabel()
    }
  }
}

/// The mark, not an SF Symbol. `MenuBarIcon` is `design/bastion-menubar.svg`:
/// direction 4a's own menu bar glyph — the curtain wall closed at the base, with
/// the spur inside it — pure black plus alpha, so AppKit tints it for light menu
/// bars, dark ones and the highlighted state rather than us shipping three
/// renderings.
///
/// It does not change with gateway state. There is one drawn glyph and inventing
/// a second in code would be a mark nothing in `design/` accounts for; a gateway
/// that failed to start says so in the menu and in the Activity window, which is
/// where somebody who noticed the icon would look next.
private struct MenuBarLabel: View {
  var body: some View {
    Image("MenuBarIcon")
      // The asset carries template-rendering-intent, but SwiftUI resolves an
      // Image by name without consulting it, so a plain Image ships black-on-
      // black in a dark menu bar. AppKit does the tinting; this only says it may.
      .renderingMode(.template)
      .accessibilityLabel("Bastion")
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

    // Read from `Activity`, not from `Supervisor.running`. The supervisor's
    // view is a lock-protected snapshot taken on whatever thread asks, which is
    // fine for a script and wrong for a menu: SwiftUI has nothing to observe,
    // so the rows would be whatever they were when the menu was last built.
    let instances = Activity.shared.instances
    if instances.isEmpty {
      Text("No servers running")
    } else {
      ForEach(instances) { instance in
        Text(
          "\(instance.displayName) — \(instance.calls) call\(instance.calls == 1 ? "" : "s")"
            + (instance.allowWrites ? " · writes on" : ""))
      }
    }

    Divider()
    Button("Activity…") { ActivityWindowController.show() }
      .keyboardShortcut("a")
    Button("MCP Clients…") { ClientsWindowController.show() }
      .keyboardShortcut("k")
    Divider()

    // Two items rather than a settings pane, because there are exactly two
    // questions: check now, and may we check on our own. The default is no,
    // set explicitly in Bastion-Info.plist so Sparkle never asks in its own
    // words on second launch.
    Button(UpdateController.shared.isChecking ? "Checking…" : "Check for Updates…") {
      UpdateController.shared.checkNow()
    }
    .disabled(UpdateController.shared.isChecking)
    Toggle(
      "Check Automatically",
      isOn: Binding(
        get: { UpdateController.shared.automatic },
        set: { UpdateController.shared.setAutomatic($0) }))

    Divider()
    Button("Quit Bastion") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
