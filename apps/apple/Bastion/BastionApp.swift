import SwiftUI

/// Starting the gateway belongs to the app lifecycle, not to the menu: the
/// servers must be reachable whether or not anyone has opened the menu bar
/// item, and `MenuBarExtra` content is built lazily, so it cannot live there.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Screenshot mode, and nothing else this function does.
    //
    // First, and returning: everything below reaches the developer's real
    // machine. `ServerStore` and `ProfileStore` read their files, `DevSeed`
    // mints a gateway token and writes to the Keychain, `Gateway.start()` binds
    // the port the running copy already holds, and Sparkle opens a connection to
    // the network. A capture wants none of it, and the cheapest way to be sure
    // is to never reach any of it.
    //
    // `DockPresence.observe()` still runs: the policy flip it drives is what
    // brings an `LSUIElement` app forward at all, and `HostedWindow` explains
    // why the `activate` inside it is the part that is suppressed.
    if DemoSeed.isEnabled {
      DemoSeed.apply()
      DockPresence.observe()
      DemoSeed.openStagedWindow()
      return
    }

    // Explicitly, and before anything can ask for a profile.
    //
    // `ProfileStore` publishes a nonisolated snapshot that the connection
    // threads read without hopping to the main actor, and that snapshot is
    // filled by `load()` in its initialiser — so a lazily-constructed store is
    // an empty snapshot, and every request answers "no profile 'prod' for
    // shopify" while `profiles.json` sits on disk with the profile in it.
    // Nothing else on this path touches the store, so nothing else would
    // construct it.
    //
    // Servers first, then profiles: `ProfileStore.load` drops a profile naming
    // a server that is not installed, so a profile store built against an empty
    // server snapshot would drop every profile there is — and then save the
    // result over `profiles.json` at the first edit.
    _ = ServerStore.shared
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

    // One observer for every window the app will ever own. Bastion is
    // `LSUIElement`, which is right for the 99% of its life when it is a
    // gateway nobody is looking at and wrong the moment a titled window is on
    // screen — see `DockPresence`.
    DockPresence.observe()

    #if DEBUG
      // For looking at a window without hunting for the menu bar icon, and for
      // capturing one. A menu bar agent has no other way to be told "open your
      // window" from a script.
      if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--pane=") }),
        let pane = MainPane(rawValue: String(raw.dropFirst("--pane=".count)))
      {
        MainWindowController.show(pane)
      } else if CommandLine.arguments.contains("--window") {
        MainWindowController.show()
      }
      // Arms a REAL trial — the same thirty-minute in-memory window a person
      // gets from the button, not a forged licence. `make smoke` and
      // `make dialect` need to get past the gate, and the honest way to let
      // them is the mechanism that already exists rather than a second one that
      // pretends a key was entered.
      if CommandLine.arguments.contains("--trial") {
        Trial.start()
      }
      // Runs one profile's check and exits with its verdict. See
      // `ServerCheck.runHeadless`.
      if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--chat=") }) {
        let ask = CommandLine.arguments.first { $0.hasPrefix("--ask=") }
        ChatSession.runHeadless(
          String(raw.dropFirst("--chat=".count)),
          asking: ask.map { String($0.dropFirst("--ask=".count)) })
      }
      if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--check=") }) {
        ServerCheck.runHeadless(
          String(raw.dropFirst("--check=".count)),
          probing: CommandLine.arguments.contains("--probe"))
      }
    #endif
  }

  /// A click on the Dock icon, or opening the app while it is already running —
  /// which, since Bastion is started by a client's bridge and will be started by
  /// a login item, is what a Finder double-click almost always becomes.
  ///
  /// This is the only path that opens the main window automatically. Doing it
  /// from `applicationDidFinishLaunching` instead would need the app to work out
  /// whether a person or a tool call had started it, and it cannot: an
  /// `.accessory` app never becomes active, so `NSApp.isActive` is false either
  /// way. A cold double-click with the app not running therefore shows only the
  /// menu bar icon; opening it once more gets the window, and that case is rare
  /// precisely because the app is nearly always already up.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    guard !hasVisibleWindows else { return true }
    MainWindowController.show()
    return true
  }

  /// Stop the children before the app goes.
  ///
  /// Not merely tidiness. A child that outlives Bastion is a process holding
  /// the user's credentials with nothing supervising it, nothing recording what
  /// it does, and no parent to notice it is there — which is precisely the
  /// state the whole project exists to end.
  func applicationWillTerminate(_ notification: Notification) {
    Supervisor.shared.stopAll()
    Gateway.shared.stop()
  }
}

@main
struct BastionApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    // The menu bar is the only surface Bastion shows uninvited. It owns two
    // windows all the same, opened only when asked: the main window and
    // Settings. `DockPresence` gives the app a Dock icon for exactly as long as
    // one of them is open, because a titled window with no Dock icon and no app
    // menu is one you cannot get back to.
    MenuBarExtra {
      GatewayMenu()
    } label: {
      MenuBarLabel()
    }
    // Settings and its ⌘, declared to SwiftUI rather than inserted into
    // `NSApp.mainMenu` by hand.
    //
    // Cupertino did the latter and the item did not survive: SwiftUI installs
    // its own main menu after the delegate returns and builds another whenever
    // the activation policy flips, each one discarding whatever was in the menu
    // it replaced. Re-asserting on `didBecomeActive` and after every policy
    // change did not fix it either — SwiftUI's rebuild lands after those hooks.
    // `DockPresence` flips that policy on every window open and close, so this
    // is not optional here.
    //
    // `.appSettings`, not `after: .appInfo`. Both put an item in the app menu,
    // but only this one is the slot AppKit reserves for Settings, so the
    // separators around it are Apple's rather than ours to guess at.
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Settings…") { SettingsWindowController.show() }
          .keyboardShortcut(",", modifiers: .command)
      }
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
/// that failed to start says so in the menu and in the main window, which is
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
    Button("Open Bastion") { MainWindowController.show() }
      .keyboardShortcut("o")
    // Its own item for the same reason "MCP Clients…" is one, and more so on a
    // fresh install: with nothing installed, adding a server is the only useful
    // thing in the app, and the menu bar is where Bastion is when nobody has
    // opened a window yet.
    Button("Add Server…") { ServerEditorHost.present() }
      .keyboardShortcut("n")
    // Still its own item, and still ⌘K. Wiring a client is the one task
    // somebody arrives at the menu bar already intending to do, and making them
    // open a window and then find a sidebar row would be a step backwards from
    // the window this replaced.
    Button("MCP Clients…") { MainWindowController.show(.client(ClientWiring.all[0].id)) }
      .keyboardShortcut("k")
    // Reachable without a window for the same reason as the two above: trying a
    // server's tools by hand is a thing you decide to do, not a thing you
    // discover in a sidebar.
    Button("Chat…") { MainWindowController.show(.chat) }
      .keyboardShortcut("j")
    Divider()

    // The licence state, in the one place somebody will look when a client
    // starts refusing. The gateway returns the same sentence to the client, but
    // that lands in a log file nobody opens.
    switch Entitlement.current {
    case .licensed(let license):
      Text("Licensed to \(license.email)")
    case .trial:
      Text("Trial — \(Trial.remainingText)")
    case .refused:
      Text(Trial.hasRun ? "Trial ended — not licensed" : "Not licensed")
      if !Trial.hasRun {
        // Reachable only from here. A trial that armed itself when a bridge
        // launched the app would burn in a window nobody was watching.
        Button("Start \(Int(Trial.duration / 60))-Minute Trial") { Trial.start() }
      }
    }
    Button("Licence…") { SettingsWindowController.show(.licence) }

    Divider()

    // Check now stays; "may we check on our own" moved to Settings ▸ General.
    // The two are not the same kind of question — one is an action somebody
    // wants this second, the other is a standing preference — and the standing
    // one was the only thing keeping a toggle in a menu.
    Button(UpdateController.shared.isChecking ? "Checking…" : "Check for Updates…") {
      UpdateController.shared.checkNow()
    }
    .disabled(UpdateController.shared.isChecking)
    Button("Settings…") { SettingsWindowController.show() }
      .keyboardShortcut(",")

    Divider()
    Button("Quit Bastion") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
