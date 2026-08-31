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

    // Before anything can be logged. `LogStore` publishes rows through two
    // hooks rather than calling the audit log itself, so nothing is kept until
    // this runs — and with the Audit pane untouched `AuditLog` opens no file
    // even once it is listening.
    AuditLog.install()

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
    // A panel, not a column of menu items.
    //
    // The version beside the name, a gateway state that is a green or red glyph
    // rather than a sentence read to the end, a server row carrying its call
    // count on the trailing edge — a `.menu` builder can draw none of them. It
    // renders menu-item primitives and turns everything else into a disabled row
    // of text, which is why the port line was a sentence and the version was
    // nowhere. Cupertino's popover is this shape for the same reason.
    .menuBarExtraStyle(.window)
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

/// The mark, not an SF Symbol, in one of its two drawn states.
///
/// `MenuBarIcon` is `design/bastion-menubar.svg`, the fort on its own — the same
/// silhouette the app icon carries. `MenuBarIconActive` is
/// `design/bastion-menubar-active.svg`, that fort with its curtain wall standing
/// off it, and it is shown while at least one server is live. Both are pure
/// black plus alpha, so AppKit tints them for light menu bars, dark ones and the
/// highlighted state rather than us shipping six renderings.
///
/// This does not invent a second mark in code, which is why the old single glyph
/// existed: the wall is drawn in `design/`, the two files share the fort to the
/// decimal, and both carry the same downward offset so nothing shifts when the
/// state flips. Swapping a glyph that moved would read as the icon twitching
/// rather than as something happening.
///
/// It is deliberately not a *health* light. A gateway that failed to start says
/// so in the popover and in the main window; this says only whether Bastion is
/// holding anything open on your behalf, which is the fact you cannot get any
/// other way without opening something.
///
/// Read from `Activity`, not `Supervisor.running`, for the reason the popover's
/// rows do: the supervisor's view is a lock-protected snapshot with nothing for
/// SwiftUI to observe, so the icon would be whatever it was when the label was
/// last built.
private struct MenuBarLabel: View {
  private var activity = Activity.shared

  var body: some View {
    let serving = activity.instances.contains(where: \.isLive)
    Image(serving ? "MenuBarIconActive" : "MenuBarIcon")
      // The assets carry template-rendering-intent, but SwiftUI resolves an
      // Image by name without consulting it, so a plain Image ships black-on-
      // black in a dark menu bar. AppKit does the tinting; this only says it may.
      .renderingMode(.template)
      .accessibilityLabel(serving ? "Bastion, serving" : "Bastion")
  }
}

/// The popover behind the menu bar icon.
///
/// A summary that carries the actions which will not wait: the name with its
/// version on one baseline, the gateway's state as a glyph, the running servers
/// as rows, and the entrances along the bottom. Everything that wants explaining
/// — why a server exited, which client called what, what a write gate is — is in
/// the main window or Settings, and stays there.
private struct GatewayMenu: View {
  private var activity = Activity.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Baseline-aligned so the version reads as a suffix to the name rather
      // than as a second heading. It goes beside the title because the popover
      // is capped at 340pt and this is the one piece of horizontal space that
      // costs nothing.
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text("Bastion").font(.headline)
        Text(AppInfo.shortVersion).font(.caption).foregroundStyle(.secondary)
        Spacer()
      }

      // First, above even the gateway line. Whoever is reading this has just
      // been told by their assistant that a call was refused, and the licence is
      // the reason — the gateway is up and answering, which is precisely why the
      // green line below is not the answer they need.
      EntitlementNotice()

      gatewayStatus

      Divider()

      ServersSection(activity: activity)

      Divider()

      // One row, as Cupertino has it. The three that were here — Add Server,
      // MCP Clients, Chat — each opened a pane of the window "Open Bastion"
      // opens, so they were a second way to do one click's work in a panel whose
      // whole claim is that it is a summary.
      //
      // ⌘N went with them and came back on the main window's own Add button,
      // which had been leaving the shortcut to this menu. ⌘K and ⌘J did not:
      // they only ever selected a sidebar row, and a shortcut for that is one
      // the window never had.
      //
      // Glass on the left, plain on the right. Only "Open Bastion" is tinted,
      // because a tinted button is a recommendation and it is the one being
      // recommended; the two glyphs beside Quit are routes, not advice.
      HStack {
        Button("Open Bastion") { MainWindowController.show() }
          .buttonStyle(.glass)
          .keyboardShortcut("o")

        Spacer()

        // Logs is the one exception to the paragraph above, and it is worth
        // naming rather than quietly re-adding a row that was deliberately
        // removed.
        //
        // Add Server, MCP Clients and Chat were destinations you go to once you
        // have decided to do something. The log is the destination this panel
        // ARGUES FOR: every line above is a count of calls, and "what were
        // those calls" is the only question the summary raises and cannot
        // answer. It is also what people arrive with urgently — an agent just
        // did something and they want to see what.
        //
        // Both are icons, and both sit right, which is the rule this row
        // already had: what opens something sits left, what you GO TO sits
        // right. A gear and a list are the two glyphs nobody needs taught, and
        // spelling them cost the width cupertino measured a fourth text button
        // truncating "Open Cupertino" at — same 320pt panel. The tooltips and
        // the shortcuts carry the names.
        Button {
          MainWindowController.show(.log)
        } label: {
          Image(systemName: "list.bullet.rectangle")
        }
        .keyboardShortcut("l")
        .help("Logs (⌘L) — what every client has called, live")

        Button {
          SettingsWindowController.show()
        } label: {
          Image(systemName: "gearshape")
        }
        .keyboardShortcut(",")
        .help("Settings (⌘,)")

        Button("Quit") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q")
      }
      .controlSize(.small)
    }
    .padding(14)
    // Cupertino's 320. It was 340 to fit a row of three buttons that is no
    // longer there, and the widest thing left is a `<profile> / <server>` row
    // before its trailing call count, which the narrower panel still carries.
    .frame(width: 320)
  }

  /// Green or red, rather than a sentence you have to read to the end.
  ///
  /// The address stays monospaced, as it is in the main window's sidebar: it is
  /// a thing to be copied into another app's config, not prose.
  @ViewBuilder
  private var gatewayStatus: some View {
    if let error = Gateway.shared.startupError {
      // The one state where nothing will ever work. It has to be visible from
      // here, because the alternative is a menu bar icon that looks fine and a
      // client that says "connection refused".
      VStack(alignment: .leading, spacing: 4) {
        Label("Not serving", systemImage: "xmark.circle.fill")
          .foregroundStyle(.red)
        Text(error)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else {
      Label {
        let address = Text("127.0.0.1:\(String(Gateway.shared.port))").monospaced()
        Text("Serving on \(address)")
      } icon: {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
      .help("Loopback only")
    }
  }
}

/// What is running, capped.
///
/// Four rows and then a link. The popover has no scroll view and its height is
/// bounded by construction, so a machine running eleven servers — which is not
/// hypothetical, it is the situation the whole project exists to end — would
/// otherwise grow a panel taller than the screen. The overflow goes to the
/// Running pane, which is the surface with room for it.
private struct ServersSection: View {
  let activity: Activity

  private static let visible = 4

  var body: some View {
    // Read from `Activity`, not from `Supervisor.running`. The supervisor's view
    // is a lock-protected snapshot taken on whatever thread asks, which is fine
    // for a script and wrong for a panel: SwiftUI has nothing to observe, so the
    // rows would be whatever they were when it was last built.
    let instances = activity.instances

    VStack(alignment: .leading, spacing: 6) {
      Text("Servers").font(.subheadline).bold()

      if instances.isEmpty {
        Text("No servers running.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(instances.prefix(Self.visible)) { instance in
          row(instance)
        }
        if instances.count > Self.visible {
          Button("\(instances.count - Self.visible) more…") {
            MainWindowController.show(.running)
          }
          .buttonStyle(.link)
          .font(.caption)
        }
      }
    }
  }

  private func row(_ instance: Activity.Instance) -> some View {
    HStack(spacing: 6) {
      // Grey, not green, for an instance that has exited. The row survives a
      // crash on purpose — "this has restarted four times today" is only visible
      // if it does — and a dead server still reading green is the one thing
      // worse than no row at all.
      Image(systemName: "circle.fill")
        .font(.system(size: 6))
        .foregroundStyle(instance.isLive ? Color.green : Color.secondary)
      Text(instance.displayName)
        .lineLimit(1)
        .truncationMode(.middle)
      // Orange, and a word rather than a dot. Writes being on is the fact this
      // panel exists to make impossible to hold wrongly.
      if instance.allowWrites {
        Text("writes")
          .foregroundStyle(.orange)
      }
      Spacer(minLength: 6)
      Text("\(instance.calls) call\(instance.calls == 1 ? "" : "s")")
        .foregroundStyle(.secondary)
        .monospacedDigit()
        // The last thing to give way. A long `<profile> / <server>` should
        // truncate through its middle before the count loses a digit.
        .layoutPriority(1)
    }
    .font(.caption)
  }
}

/// The licence state, and only when it is a problem.
///
/// Nothing at all when licensed. A row that answers "yes, still licensed" every
/// time the panel opens costs space and tells nobody anything; the email it used
/// to carry is in Settings ▸ Licence, which is where somebody checking which key
/// this Mac holds was going anyway.
private struct EntitlementNotice: View {
  @State private var revision = 0

  var body: some View {
    // A trial that runs out with the popover open must stop claiming twelve
    // minutes left. Fifteen seconds is finer than the minute the text rounds to.
    TimelineView(.periodic(from: .now, by: 15)) { _ in
      VStack(alignment: .leading, spacing: 12) {
        switch Entitlement.current {
        case .licensed:
          EmptyView()
        case .trial:
          TrialBanner()
          Divider()
        case .refused(let reason):
          LicenceBanner(reason: reason) { revision += 1 }
          Divider()
        }
      }
    }
    .id(revision)
  }
}

/// Unlicensed, with the reason attached and the way out under it.
private struct LicenceBanner: View {
  let reason: String
  /// Called once a trial is armed, so the panel redraws now rather than at the
  /// next tick. Pressing a button and watching nothing happen for fifteen
  /// seconds reads as a broken button.
  var onStartTrial: () -> Void = {}

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(
        "Unlicensed — relayed servers are refused",
        systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
      .font(.caption)
      .fixedSize(horizontal: false, vertical: true)
      Text(reason)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      // True, and load-bearing: the gate is on the relay, not on the app. An
      // unlicensed user can still install servers, set credentials and wire a
      // client, which is what makes the sentence above land at the moment they
      // have something to lose.
      Text("Bastion's own tools, the write gates and Settings are unaffected.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        // The trial leads, and only until it has been used. Somebody reading
        // this has just had a call refused; the useful offer is the one that
        // makes it work in the next ten seconds, not the one that opens a
        // checkout.
        //
        // Reachable only from here, as it was before. A trial that armed itself
        // when a bridge launched the app would burn in a window nobody was
        // watching.
        if !Trial.hasRun {
          Button("Start a \(Int(Trial.duration / 60))-minute trial") {
            Trial.start()
            onStartTrial()
          }
          .buttonStyle(.glassProminent)
          Button("Enter a key…") { SettingsWindowController.show(.licence) }
            .buttonStyle(.glass)
        } else {
          Button("Enter a licence key…") { SettingsWindowController.show(.licence) }
            .buttonStyle(.glassProminent)
        }
      }
      .controlSize(.small)
    }
  }
}

/// The trial, while it is running.
///
/// Deliberately not styled as a warning. Nothing is wrong — everything is
/// working, on purpose — and the orange triangle belongs to the state where it
/// is not.
private struct TrialBanner: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Trial · \(Trial.remainingText)", systemImage: "clock")
        .foregroundStyle(.blue)
        .font(.caption)
      Text(
        """
        Every server is relaying. When the window closes they stop answering, \
        and your client will report the calls refused.
        """
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Button("Buy a licence…") { NSWorkspace.shared.open(LicenceLinks.buy) }
        .buttonStyle(.glassProminent)
        .controlSize(.small)
    }
  }
}
