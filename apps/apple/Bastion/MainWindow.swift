import AppKit
import SwiftUI

/// What the sidebar selects.
///
/// Servers and clients carry an **id** rather than the value itself, and the
/// detail pane re-resolves it. A `BastionServer` captured in the selection
/// would be a copy of a generated table, and a `ClientWiring.Client` captured
/// there would be a snapshot of somebody else's config file — which is exactly
/// the thing `ClientDetail` refuses to cache.
enum MainPane: Hashable {
  case server(String)
  case client(String)
  case running
  case log
  case chat
}

/// `RawRepresentable` so the selection can live in `@AppStorage`. See
/// `MainView.pane` for why it has to.
extension MainPane: RawRepresentable {
  static let defaultsKey = "mainPane"

  init?(rawValue: String) {
    switch rawValue {
    case "running": self = .running
    case "log": self = .log
    case "chat": self = .chat
    default:
      guard let separator = rawValue.firstIndex(of: ":") else { return nil }
      let id = String(rawValue[rawValue.index(after: separator)...])
      guard !id.isEmpty else { return nil }
      switch rawValue[..<separator] {
      case "server": self = .server(id)
      case "client": self = .client(id)
      default: return nil
      }
    }
  }

  var rawValue: String {
    switch self {
    case .server(let id): "server:\(id)"
    case .client(let id): "client:\(id)"
    case .running: "running"
    case .log: "log"
    case .chat: "chat"
    }
  }
}

/// Bastion's main window.
///
/// This replaces two separate windows — Activity and MCP Clients — that could
/// not see each other. "Is Shopify running" and "is Claude Code wired to it"
/// are one question, and answering it used to mean opening two windows from a
/// menu and holding the answer to the first in your head while you found the
/// second.
///
/// Still not opened at launch. Bastion is started by a login item or by a
/// client's bridge far more often than by a person, and a window arriving while
/// someone is mid-sentence at an assistant is the interruption `open -g` exists
/// to avoid. `AppDelegate.applicationShouldHandleReopen` opens it — which is
/// what a Dock click, and a Finder double-click on an already-running app, both
/// become.
@MainActor
enum MainWindowController {
  static let autosaveName = "main"

  private static let hosted = HostedWindow(
    title: "Bastion", autosaveName: autosaveName,
    // Named only under a capture. Outside one this window wants SwiftUI's own
    // fitting size floored by `MainView`'s minimums, which is the right
    // behaviour and the reason it never passed a size before.
    contentSize: DemoSeed.isEnabled ? DemoSeed.contentSize : nil,
    content: { MainView() })

  static func show() { hosted.show() }

  /// Open onto a particular pane.
  ///
  /// The default is written **before** the window is shown, so this works on a
  /// window that is already open: `MainView` reads the selection through
  /// `@AppStorage`, which observes the write. A `@State` copy seeded once at
  /// init is exactly how a deep link into an open window stops working.
  static func show(_ pane: MainPane) {
    UserDefaults.standard.set(pane.rawValue, forKey: MainPane.defaultsKey)
    hosted.show()
  }
}

/// The entry point for callers that are not already on the main actor.
enum MainWindowOpener {
  static func show() {
    Task { @MainActor in MainWindowController.show() }
  }
}

struct MainView: View {
  @AppStorage(MainPane.defaultsKey) private var selection = MainPane.running.rawValue

  /// The add/edit sheet, held in a shared host rather than in `@State` so the
  /// menu bar can open it too. See `ServerEditorHost`.
  @Bindable private var editor = ServerEditorHost.shared

  /// `List(selection:)` drives an `Optional` for a single selection, and the
  /// stored value is a `String` because that is what `@AppStorage` can hold.
  /// Bridging here rather than mirroring into `@State` keeps one source of
  /// truth, which is what makes `MainWindowController.show(_:)` reach a window
  /// that is already open.
  private var pane: Binding<MainPane?> {
    Binding(
      get: { current },
      // Swallowed under a capture: `current` would ignore the write anyway, and
      // letting it through would put the stage's pane into the developer's own
      // `@AppStorage`.
      set: { if !DemoSeed.isEnabled { selection = ($0 ?? .running).rawValue } })
  }

  /// The stage decides under a capture, and `@AppStorage` decides otherwise.
  ///
  /// Deliberately not a launch argument routed through `MainPane.defaultsKey`.
  /// That would write the developer's remembered pane on every capture, and it
  /// would be a second parser for `MainPane.rawValue` to disagree with.
  private var current: MainPane {
    if DemoSeed.isEnabled { return DemoSeed.stage.pane }
    return MainPane(rawValue: selection) ?? .running
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    // The floor, and the number `HostedWindow.canHoldContent` reads back:
    // `NSHostingController` propagates these into `window.contentMinSize`. That
    // coupling is deliberate — the degenerate-frame check has no other source
    // of truth for how small this window is allowed to be.
    .frame(minWidth: 820, minHeight: 520)
    .sheet(item: $editor.subject) { subject in
      ServerEditor(subject: subject)
    }
    // Everything these panes read was seeded synchronously in `DemoSeed.apply()`
    // before this window existed, so the body running IS the content existing —
    // no network, no disk, nothing async. That is what makes the ready signal a
    // fact here rather than an optimisation over `--settle`.
    .task { DemoSeed.signalReady(from: .main) }
  }

  // MARK: - Sidebar

  /// The sidebar carries its own material on macOS 26, so there is no chrome to
  /// add here: hand-rolled backgrounds next to system ones is the arrangement
  /// that always looks wrong.
  private var sidebar: some View {
    List(selection: pane) {
      Section {
        let servers = ServerStore.shared.servers
        ForEach(servers) { server in
          Label {
            HStack(spacing: 6) {
              Text(server.displayName)
              Spacer(minLength: 4)
              ServerBadge(server: server)
            }
          } icon: {
            // Three glyphs for three transports: gears for Bastion's own
            // server, a box for a package it downloaded, a cloud for an
            // endpoint somebody else operates. It is the only thing on the row
            // that says which, and the sidebar is where a reader decides what
            // a server is before opening it.
            Image(systemName: server.transport.symbolName)
              .help(server.transport.summaryLabel)
          }
          // Dimmed rather than hidden or moved. A disabled server is still
          // something you own and still where you left it — the sidebar's job
          // is to say it will not answer, not to hide it until it does.
          .foregroundStyle(server.isEnabled ? .primary : .secondary)
          .tag(MainPane.server(server.id))
        }

        // The empty state is the first thing a new install shows, and Bastion
        // ships with nothing installed. A blank section under a heading reads
        // as a bug; a sentence that says what is true does not. It is a label
        // rather than a second button — the one under the list is right there,
        // and two buttons a row apart doing the same thing reads as two things.
        // Bastion's own server is always in the list, so "empty" now means
        // "nothing but Bastion" — otherwise the sentence would never appear
        // again and a fresh install would look furnished when it is not.
        if servers.allSatisfy({ $0.origin == .builtin }) {
          Text("None installed yet.")
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
      } header: {
        // The `+` is back in the header, and the reason it works now is that it
        // is no longer the only one. It was pulled from here because it was the
        // sole route to adding a server: small, unlabelled, and sitting in a row
        // that reads as a title. The labelled button under the list fixed that
        // and stays; this is an accelerator at the end of the sidebar the eye
        // reaches first, which is a different job from being the affordance.
        //
        // ⌘N is deliberately not repeated here. Two views in one window claiming
        // the same shortcut is ambiguous, and the one under the list already has
        // it. The label is spelled out rather than left to the glyph, because
        // this control has no text for VoiceOver to read — the one way the
        // original really was worse than the row below.
        HStack(spacing: 4) {
          Text("Servers")
          Spacer()
          Button {
            editor.subject = .adding
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .contentShape(.rect)
          .help("Add a server (⌘N)")
          .accessibilityLabel("Add server")
          // The `Spacer` above puts the glyph flush against the header's
          // trailing edge, which in this sidebar is nearer the window edge than
          // anything in the rows below sits. Small enough to read as breathing
          // room rather than an indent.
          .padding(.trailing, 10)
        }
      }

      // Installed only, and absent rather than empty when there are none. Which
      // editors this Mac happens to have is a fact about this Mac: a client
      // nobody has is not a client to nag anybody about, and a row that cannot
      // be acted on is a support burden with no action attached. The id space is
      // untouched — `wire_client` still resolves against `ClientWiring.all`, so
      // nothing here narrows what can be wired.
      if !installedClients.isEmpty {
        Section("Clients") {
          ForEach(installedClients) { client in
            Label {
              HStack(spacing: 6) {
                Text(client.displayName)
                Spacer(minLength: 4)
                ClientDot(client: client)
              }
            } icon: {
              // The client's own app icon, so a row is recognised before it is
              // read. The server rows above go the other way on purpose: their
              // three glyphs say what KIND of thing a server is, which is the
              // question there. Here there is nothing to encode — which client
              // this is IS the fact, and every one of them already has a picture
              // the reader knows.
              ClientIconView(client: client)
            }
            .tag(MainPane.client(client.id))
          }
        }
      }

      Section("Activity") {
        Label("Running", systemImage: "play.circle").tag(MainPane.running)
        Label("Log", systemImage: "list.bullet.rectangle").tag(MainPane.log)
        Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(MainPane.chat)
      }
    }
    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    .safeAreaInset(edge: .bottom) { sidebarStatus }
  }

  /// The MCP clients this Mac actually has. Recomputed per redraw, because
  /// `isInstalled` is a LaunchServices lookup and a directory check rather than
  /// a stored value, and installing an editor while this window is open is a
  /// perfectly ordinary thing to do.
  ///
  /// The detail pane deliberately does not filter: a pane remembered in
  /// `@AppStorage` for a client since uninstalled still renders, and says so.
  private var installedClients: [ClientWiring.Client] {
    ClientWiring.all.filter(\.isInstalled)
  }

  /// The add button, under the list where macOS puts one.
  ///
  /// This started as a `+` glyph in the "Servers" section header and that was
  /// the wrong place twice over: a header accessory is small, unlabelled, and
  /// sits in a row that reads as a title rather than as a control — so on the
  /// one screen where adding a server is the *only* thing to do, the control
  /// for it was the hardest thing on screen to find. Mail, Finder and System
  /// Settings all put this under the list, labelled. So does this.
  private var sidebarAdd: some View {
    Button {
      editor.subject = .adding
    } label: {
      Label("Add server", systemImage: "plus")
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    // ⌘N lives here now. It used to be left to the menu bar item, which worked
    // whether or not this window was key; that item went when the menu became a
    // summary panel, and this is the only Add there is left to hang it on.
    .keyboardShortcut("n")
    .help("Install a server from the catalog, or add one by npm package or URL (⌘N)")
  }

  /// What used to be the Activity window's header, moved to where it is true of
  /// the whole app rather than of one pane. The gateway is either serving or it
  /// is not, and that fact does not belong to any one screen.
  private var sidebarStatus: some View {
    let activity = Activity.shared
    return VStack(alignment: .leading, spacing: 8) {
      Divider()

      sidebarAdd

      Divider()

      if let error = Gateway.shared.startupError {
        // The one state where nothing will ever work, and the reason this is a
        // Label rather than a dot: an app that looks fine while every client
        // says "connection refused" is the worst thing this window could be.
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(spacing: 6) {
          Circle().fill(Color.green).frame(width: 7, height: 7)
          Text("127.0.0.1:\(String(Gateway.shared.port))")
            .font(.system(.caption, design: .monospaced))
          Spacer()
        }
        .help("Loopback only")
      }

      // The headline numbers for the whole idea. With one process per
      // connection these first two were the same by construction, so there was
      // nothing to say.
      HStack(spacing: 10) {
        Tally(value: "\(activity.attachedClients.count)", label: "clients")
        Tally(value: "\(activity.runningCount)", label: "processes")
        Tally(value: "\(activity.totalCalls)", label: "calls")
        Spacer()
      }

      HStack(spacing: 6) {
        Text("Version \(AppInfo.shortVersion)")
          .font(.caption)
          .foregroundStyle(.tertiary)
        Spacer()
        // The one entrance that says so. A status line that happens to be a
        // button is the right behaviour and no help at all to somebody who does
        // not already know it is one.
        Button {
          SettingsWindowController.show()
        } label: {
          Image(systemName: "gearshape")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Settings (⌘,)")
      }
    }
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 10)
    // Opaque, and that is not cosmetic. `safeAreaInset` reserves the space but
    // does not fill it, so once the sidebar holds more rows than fit — and the
    // server list has no ceiling any more — it scrolls *under* a transparent
    // footer and the gateway line is drawn through by whatever row happens to
    // be passing behind it. `.bar` is the material AppKit uses for exactly this
    // strip, so it occludes without inventing a colour the sidebar does not
    // already have.
    .background(.bar)
  }

  // MARK: - Detail

  @ViewBuilder
  private var detail: some View {
    switch current {
    case .server(let id):
      if let server = ServerStore.shared.server(id: id) {
        ServerDetail(server: server, edit: { editor.subject = .editing(server) })
      } else {
        // Reachable, and now routinely: a pane remembered in `@AppStorage`
        // outlives the server it named the moment somebody removes one.
        UnknownPane(what: "server", id: id)
      }
    case .client(let id):
      if let client = ClientWiring.all.first(where: { $0.id == id }) {
        ClientDetail(client: client)
      } else {
        UnknownPane(what: "client", id: id)
      }
    case .running:
      RunningPane()
    case .log:
      LogPane()
    case .chat:
      ChatPane()
    }
  }
}

/// The trailing accessory on a server row: what is running, what is still
/// downloading, what cannot run, or how many profiles could.
///
/// Facts competing for one slot, and the order is the order somebody wants
/// them. Running wins — a green dot answers "is this working", which is the
/// question somebody opening this window actually arrived with. Then the two
/// states that mean nothing will *ever* work, which the list could not express
/// at all while the servers were inside the app bundle. The profile count is
/// last, and nothing shows when there is none of it.
private struct ServerBadge: View {
  let server: BastionServer

  var body: some View {
    let live = Activity.shared.instances.filter { $0.server == server.id && $0.isLive }.count
    let profiles = ProfileStore.shared.profiles.filter { $0.serverID == server.id }.count

    // First in the ladder, because it outranks everything below it: a disabled
    // server is not installing, will not run, and its profile count is a fact
    // about something that is not going to answer.
    if !server.isEnabled {
      Image(systemName: "pause.circle")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .help("Disabled")
    } else if live > 0 {
      HStack(spacing: 3) {
        Circle().fill(Color.green).frame(width: 7, height: 7)
        if live > 1 {
          Text("\(live)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .help(live == 1 ? "Running" : "\(live) running")
    } else if ServerInstaller.shared.isRunning(server.id) {
      ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
    } else if !ServerInstaller.isInstalled(server) {
      // The state a bundled-servers app could not be in, and the one a user
      // will hit first: added, not downloaded, and silent about it unless the
      // row says so. Without this the only symptom is a client failing much
      // later with a sentence about a directory nobody has heard of.
      Image(systemName: "arrow.down.circle")
        .font(.caption2)
        .foregroundStyle(.orange)
        .help("Not installed")
    } else if profiles > 0 {
      Text("\(profiles)")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .help(profiles == 1 ? "1 profile" : "\(profiles) profiles")
    }
  }
}

/// Recomputed on every redraw rather than cached, for the same reason
/// `ClientDetail` does it: the file belongs to another application that may
/// have rewritten it a second ago, so a remembered status is a claim about a
/// file this app does not own and did not watch.
///
/// "On every redraw" is only worth anything if something makes it redraw. The
/// profile list does — it is observable, so adding a profile moves this dot —
/// but the config file does not, and Configure writes the config file. This row
/// sat on "not configured" while the pane beside it, redrawn by its own result
/// string, said "configured" about the same file.
private struct ClientDot: View {
  let client: ClientWiring.Client

  var body: some View {
    // Load-bearing, and not dead code: reading the revision is what subscribes
    // this row to Bastion's writes. Without it there is nothing observable in
    // this body that a Configure changes.
    let _ = ClientConfigRevision.shared.value
    // Switched-off servers excluded, exactly as in the pane this dot summarises
    // and in what Configure writes. A dot that went amber for a server nobody
    // can reach is a dot with no move behind it.
    let status = ClientWiring.status(of: client, profiles: ProfileStore.shared.onEnabledServers)
    Circle()
      .fill(ClientWiring.tint(status))
      .frame(width: 7, height: 7)
      .help(status.summary)
  }
}

private struct UnknownPane: View {
  let what: String
  let id: String

  var body: some View {
    ContentUnavailableView(
      "No such \(what)",
      systemImage: "questionmark.folder",
      description: Text("'\(id)' is not installed. It may have been removed."))
  }
}
