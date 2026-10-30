import AppKit
import SwiftUI

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
  @Bindable private var handoff = ServerHandoff.shared

  /// The conversation, held here rather than inside `ChatPane`.
  ///
  /// The pane is one arm of the `switch` below, so a trip to the Log and back
  /// destroyed it — taking the transcript, the tool selection, a live
  /// `LanguageModelSession` and a reply that was still arriving.
  ///
  /// Here and not in a `shared`, unlike `ServerEditorHost`: `HostedWindow`
  /// retains its `NSWindow` with `isReleasedWhenClosed = false`, so this
  /// `@State` already outlives every close and reopen — the lifetime a
  /// singleton would buy is the lifetime this has. What a singleton would add
  /// is a second global that can have a model request and a supervised tool
  /// call in flight, which is a different kind of object from a registry.
  ///
  /// Under a capture this builds `DemoSeed.chatSession()` whatever stage is
  /// showing rather than only the chat one. It is in-memory fixture
  /// construction that runs after `DemoSeed.apply()` in every case, so no plate
  /// is affected.
  @State private var chat = DemoSeed.isEnabled ? DemoSeed.chatSession() : ChatSession()

  /// The server a sidebar right-click asked to remove, waiting on the
  /// confirmation. Held here, not in `ServerDetail`, because the row it came
  /// from need not be the one selected.
  @State private var pendingRemoval: BastionServer?
  @State private var sidebarError: String?
  @State private var workspaceSheet: WorkspaceSheet?
  @State private var pendingWorkspaceDeletion: String?
  @AppStorage(CollapsedServerSections.defaultsKey) private var collapsedSections = ""

  /// `List(selection:)` drives an `Optional` for a single selection, and the
  /// stored value is a `String` because that is what `@AppStorage` can hold.
  /// Bridging here rather than mirroring into `@State` keeps one source of
  /// truth, which is what makes `MainWindowController.show(_:)` reach a window
  /// that is already open.
  ///
  /// Read through `WorkspaceSidebar.rowPane`, because the pane remembered or
  /// deep-linked to can name a server row that is not in the list: every one
  /// of its profiles is in a workspace, or the profile it was dragged with has
  /// moved on.
  private var pane: Binding<MainPane?> {
    Binding(
      get: { WorkspaceSidebar.rowPane(for: current, in: serverSections) },
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
    // A server handed over by another app, waiting to be confirmed. On a background view of
    // its own, since two sheet presenters on one view race each other.
    .background {
      Color.clear.sheet(item: $handoff.pending) { request in
        ServerHandoffSheet(request: request)
      }
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
      // One section while there is no workspace, which is the sidebar this
      // always was, and then one per workspace with Everywhere last.
      let sections = serverSections
      ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
        serverSection(section, isFirst: index == 0)
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
        // Between the two it summarises, and the order is granularity
        // descending with the verb last: Running is now, Stats is over time,
        // Log is every line, Chat is a thing you do.
        Label("Stats", systemImage: "chart.bar").tag(MainPane.stats)
        Label("Log", systemImage: "list.bullet.rectangle").tag(MainPane.log)
        Label("Chat", systemImage: "bubble.left.and.text.bubble.right").tag(MainPane.chat)
      }
    }
    .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    .safeAreaInset(edge: .bottom) { sidebarStatus }
    .confirmationDialog(
      "Remove \(pendingRemoval?.displayName ?? "")?",
      isPresented: Binding(
        get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
      titleVisibility: .visible, presenting: pendingRemoval
    ) { server in
      Button("Remove", role: .destructive) { remove(server) }
      Button("Cancel", role: .cancel) {}
    } message: { server in
      Text(
        server.removalWarning(
          profiles: ProfileStore.shared.profiles.filter { $0.serverID == server.id }.count))
    }
    .alert(
      "Could not change the server",
      isPresented: Binding(get: { sidebarError != nil }, set: { if !$0 { sidebarError = nil } })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(sidebarError ?? "")
    }
    // On the list, not on `body`: two sheet presenters on one view race.
    .workspaceSheet($workspaceSheet, renamed: workspaceRenamed)
    .workspaceDeletion($pendingWorkspaceDeletion) { sidebarError = $0 }
  }

  /// The MCP clients this Mac actually has. Recomputed per redraw, because
  /// `isInstalled` is a LaunchServices lookup and a directory check rather than
  /// a stored value, and installing an editor while this window is open is a
  /// perfectly ordinary thing to do.
  ///
  /// The detail pane deliberately does not filter: a pane remembered in
  /// `@AppStorage` for a client since uninstalled still renders, and says so.
  // MARK: - Server sections

  /// The server list's sections; see `WorkspaceSidebar`.
  ///
  /// An unreadable `workspaces.json` reads as no workspaces, as the store
  /// treats it: nothing is scoped, so every profile really does go to every
  /// client, and the footer says why.
  private var serverSections: [ServerSection] {
    let workspaces = WorkspaceStore.shared
    return WorkspaceSidebar.sections(
      servers: ServerStore.shared.servers.map(\.id),
      profiles: ProfileStore.shared.profiles.map { (id: $0.id, serverID: $0.serverID) },
      workspaces: workspaces.unreadable == nil ? workspaces.workspaces : [])
  }

  @ViewBuilder
  private func serverSection(_ section: ServerSection, isFirst: Bool) -> some View {
    switch section.kind {
    case .servers:
      Section {
        serverRows(section)

        // The empty state is the first thing a new install shows, and Bastion
        // ships with nothing installed. A blank section under a heading reads
        // as a bug; a sentence that says what is true does not. It is a label
        // rather than a second button — the one under the list is right there,
        // and two buttons a row apart doing the same thing reads as two things.
        // Bastion's own server is always in the list, so "empty" now means
        // "nothing but Bastion" — otherwise the sentence would never appear
        // again and a fresh install would look furnished when it is not.
        if ServerStore.shared.servers.allSatisfy({ $0.origin == .builtin }) {
          Text("None installed yet.")
            .font(.callout)
            .foregroundStyle(.tertiary)
        }
      } header: {
        HStack(spacing: 4) {
          Text("Servers")
          Spacer()
          serverHeaderButtons
        }
      }
    case .workspace(let name):
      Section(isExpanded: expansion(section.kind)) {
        serverRows(section)
        if section.rows.isEmpty {
          // Somewhere to drop, so a workspace just made is visibly a place.
          Text("Drag servers here")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .selectionDisabled()
        }
      } header: {
        HStack(spacing: 4) {
          WorkspaceSectionHeader(
            name: name, folderCount: WorkspaceStore.shared.resolved[name]?.count ?? 0,
            open: { pane.wrappedValue = .workspace(name) },
            rename: { workspaceSheet = .rename(name) },
            delete: { pendingWorkspaceDeletion = name })
          Spacer()
          if isFirst { serverHeaderButtons }
        }
      }
    case .everywhere:
      Section(isExpanded: expansion(section.kind)) {
        serverRows(section)
      } header: {
        HStack(spacing: 4) {
          Text("Everywhere")
            .help("Profiles in no workspace, which every configured client gets")
          Spacer()
          if isFirst { serverHeaderButtons }
        }
      }
    }
  }

  /// The header's update check and `+`, on whichever section comes first.
  ///
  /// The `+` is back in the header, and the reason it works now is that it is
  /// no longer the only one. It was pulled from here because it was the sole
  /// route to adding a server: small, unlabelled, and sitting in a row that
  /// reads as a title. The labelled button under the list fixed that and
  /// stays; this is an accelerator at the end of the sidebar the eye reaches
  /// first, which is a different job from being the affordance.
  ///
  /// ⌘N is deliberately not repeated here. Two views in one window claiming the
  /// same shortcut is ambiguous, and the one under the list already has it. The
  /// label is spelled out rather than left to the glyph, because this control
  /// has no text for VoiceOver to read — the one way the original really was
  /// worse than the row below.
  @ViewBuilder private var serverHeaderButtons: some View {
    // The only place in the window that asks about every server at once, and
    // the reason the dots below it can ever appear: `availability` is empty
    // until something asks, so a badge with no way to populate it but nine
    // visits to nine panes would be a feature nobody finds.
    //
    // Still a press, which is the whole constraint — see
    // `ServerInstaller.checkForUpdate`. Nothing here runs on a timer, on
    // launch, or when this view appears.
    if ServerInstaller.shared.hasCheckableServers {
      Button {
        let installer = ServerInstaller.shared
        if installer.isCheckingAll {
          installer.cancelCheckAll()
        } else {
          installer.checkAll()
        }
      } label: {
        if ServerInstaller.shared.isCheckingAll {
          ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
        } else {
          Image(systemName: "arrow.triangle.2.circlepath")
        }
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .contentShape(.rect)
      .help(
        ServerInstaller.shared.isCheckingAll
          ? "Stop checking — anything already asking npm finishes"
          : "Check all servers for updates"
      )
      .accessibilityLabel(
        ServerInstaller.shared.isCheckingAll ? "Stop checking" : "Check all for updates")
    }
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
    // The `Spacer` before this puts the glyph flush against the header's
    // trailing edge, which in this sidebar is nearer the window edge than
    // anything in the rows below sits. Small enough to read as breathing room
    // rather than an indent.
    .padding(.trailing, 10)
  }

  private func serverRows(_ section: ServerSection) -> some View {
    ForEach(section.rows) { row in
      if let server = ServerStore.shared.server(id: row.serverID) {
        serverRow(server, row: row, in: section)
      }
    }
  }

  private func serverRow(_ server: BastionServer, row: ServerRow, in section: ServerSection)
    -> some View
  {
    Label {
      HStack(spacing: 6) {
        Text(server.displayName)
        // Which of its profiles this row is, for a server split between
        // sections. Absent otherwise, so the usual row reads as it always did.
        if let caption = row.caption {
          Text(caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        ServerBadge(server: server)
      }
    } icon: {
      // One glyph per transport: gears for Bastion's own server, a box for a
      // package it downloaded, a terminal for a system command, a cloud for an
      // endpoint somebody else operates and a computer for one on 127.0.0.1.
      // It is the only thing on the row that says which, and the sidebar is
      // where a reader decides what a server is before opening it.
      Image(systemName: server.transport.symbolName)
        .help(server.transport.summaryLabel)
    }
    // Dimmed rather than hidden or moved. A disabled server is still something
    // you own and still where you left it — the sidebar's job is to say it will
    // not answer, not to hide it until it does.
    .foregroundStyle(server.isEnabled ? .primary : .secondary)
    .tag(row.pane)
    .contextMenu { serverMenu(server, row: row, in: section) }
  }

  /// Per Mac and per section, through `CollapsedServerSections`. Always open
  /// under a capture, whatever the developer left collapsed.
  private func expansion(_ kind: ServerSectionKind) -> Binding<Bool> {
    Binding(
      get: {
        guard !DemoSeed.isEnabled, let key = kind.collapseKey else { return true }
        return !CollapsedServerSections.decode(collapsedSections).contains(key)
      },
      set: { expanded in
        if DemoSeed.isEnabled { return }
        collapsedSections = CollapsedServerSections.setting(
          kind, expanded: expanded, in: collapsedSections)
      })
  }

  /// Move profiles between sections, from a drop or the Move to menu.
  private func move(_ ids: [String], from: ServerSectionKind, to: ServerSectionKind) {
    do {
      try WorkspaceStore.shared.moveProfiles(
        ids, from: from.workspaceName, to: to.workspaceName)
    } catch {
      sidebarError = error.localizedDescription
    }
  }

  /// A rename follows the page it renamed, rather than leaving it on a name
  /// that is gone.
  private func workspaceRenamed(from old: String, to new: String) {
    if current == .workspace(old) { pane.wrappedValue = .workspace(new) }
  }

  private var installedClients: [ClientWiring.Client] {
    ClientWiring.all.filter(\.isInstalled)
  }

  /// The right-click on a server row: the detail pane's actions, reachable
  /// without opening the pane first. Each one is offered only where that pane
  /// offers it, so the menu never holds an item the pane would refuse.
  @ViewBuilder private func serverMenu(
    _ server: BastionServer, row: ServerRow, in section: ServerSection
  ) -> some View {
    if server.origin == .custom {
      Button("Edit…") { editor.subject = .editing(server) }
    }
    Button(server.isEnabled ? "Disable" : "Enable") {
      do { try ServerStore.shared.setEnabled(!server.isEnabled, for: server.id) } catch {
        sidebarError = error.localizedDescription
      }
    }
    moveMenus(row: row, in: section)
    if server.origin != .builtin {
      Divider()
      Button("Remove Server…", role: .destructive) { pendingRemoval = server }
    }
  }

  /// Move to, per profile the row holds: the way to split a server between
  /// sections, which a drag of the whole row cannot do, and the way in for
  /// anybody not using a pointer.
  @ViewBuilder private func moveMenus(row: ServerRow, in section: ServerSection) -> some View {
    let store = WorkspaceStore.shared
    if store.unreadable == nil, !store.workspaces.isEmpty, !row.profileIDs.isEmpty {
      let targets = store.workspaces.map(\.name).filter { $0 != section.kind.workspaceName }
      Divider()
      ForEach(row.profileIDs, id: \.self) { id in
        Menu(row.profileIDs.count == 1 ? "Move to" : "Move \(id) to") {
          ForEach(targets, id: \.self) { name in
            Button(name) { move([id], from: section.kind, to: .workspace(name)) }
          }
          if section.kind != .everywhere {
            if !targets.isEmpty { Divider() }
            Button("Everywhere") { move([id], from: section.kind, to: .everywhere) }
          }
        }
      }
    }
  }

  private func remove(_ server: BastionServer) {
    do {
      try ServerStore.shared.remove(server)
    } catch {
      sidebarError = "Could not remove '\(server.id)': \(error.localizedDescription)"
    }
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

  /// Under Add server and styled like it, as Finder and Mail put New Folder
  /// and New Mailbox: it is how the first workspace gets made, so it is always
  /// there rather than appearing once one exists.
  private var sidebarNewWorkspace: some View {
    Button {
      workspaceSheet = .create
    } label: {
      Label("New workspace", systemImage: "folder.badge.plus")
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.primary)
    .disabled(WorkspaceStore.shared.unreadable != nil)
    .help("Give some profiles to Claude Code only in chosen folders")
  }

  /// What used to be the Activity window's header, moved to where it is true of
  /// the whole app rather than of one pane. The gateway is either serving or it
  /// is not, and that fact does not belong to any one screen.
  private var sidebarStatus: some View {
    let activity = Activity.shared
    let gateway = GatewayStatus.shared
    return VStack(alignment: .leading, spacing: 8) {
      Divider()

      // Above the buttons it explains: New workspace is disabled while it shows.
      if let problem = WorkspaceStore.shared.unreadable {
        Label(problem.localizedDescription, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      sidebarAdd

      sidebarNewWorkspace

      Divider()

      // `GatewayStatus`, not `Gateway.shared`: the gateway's state is behind a
      // lock with nothing for SwiftUI to observe, so this row was a value
      // sampled when the sidebar was last built. The popover got away with the
      // same read because `MenuBarExtra` rebuilds on every open; this window
      // does not, so a gateway that died left a green dot on screen indefinitely
      // — in the one place whose whole job is to beat "connection refused" to
      // the user.
      if let error = gateway.startupError {
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
          Text("127.0.0.1:\(String(gateway.port))")
            .font(.system(.caption, design: .monospaced))
          Spacer()
        }
        .help("Loopback only")
      }

      // The headline numbers for the whole idea. With one process per
      // connection these first two were the same by construction, so there was
      // nothing to say.
      MetricRow {
        Tally(value: "\(activity.attachedClients.count)", label: "clients")
        Tally(value: "\(activity.runningCount)", label: "processes")
        Tally(value: "\(activity.totalCalls)", label: "calls")
      }

      HStack(spacing: 6) {
        // The version, and — only when something shipped that has not been
        // read — a way to find out what. The gear's comment below applies here
        // too, which is why this is not simply always a button: the line stays
        // a line until there is something behind it, and the dot is the part
        // that announces itself.
        if Changelog.hasUnseen {
          Button {
            SettingsWindowController.show(.whatsNew)
          } label: {
            HStack(spacing: 4) {
              Text("Version \(AppInfo.shortVersion)")
              Circle().fill(Color.accentColor).frame(width: 5, height: 5)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
          }
          .buttonStyle(.plain)
          .help("What's new in \(AppInfo.version)")
        } else {
          Text("Version \(AppInfo.shortVersion)")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
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
    // Both rows of a split server open the same pane, keyed by the server, so
    // moving between them keeps an open profile editor rather than resetting it.
    case .server(let id), .scopedServer(_, let id):
      // `.id`, so another server gets another pane. As one branch of this
      // switch the pane was reused across servers with its `@State`: a profile
      // editor open on one server stayed up for the next and saved its fields
      // under that server's id, and an error or a pending removal carried over.
      if let server = ServerStore.shared.server(id: id) {
        ServerDetail(server: server, edit: { editor.subject = .editing(server) })
          .id(id)
      } else {
        // Reachable, and now routinely: a pane remembered in `@AppStorage`
        // outlives the server it named the moment somebody removes one.
        UnknownPane(what: "server", id: id)
      }
    case .workspace(let name):
      UnknownPane(what: "workspace", id: name)
    case .client(let id):
      if let client = ClientWiring.all.first(where: { $0.id == id }) {
        ClientDetail(client: client)
          .id(id)
      } else {
        UnknownPane(what: "client", id: id)
      }
    case .running:
      RunningPane()
    case .stats:
      StatsPane()
    case .log:
      LogPane()
    case .chat:
      ChatPane(chat: chat)
    }
  }
}

/// The trailing accessory on a server row: whether there is a newer version,
/// then what is running, what is still downloading, what cannot run, or how
/// many profiles could.
///
/// Two channels, not one — see `updateDot` for why the first is not simply the
/// top of the ladder. Below it, facts competing for one slot, and the order is the order somebody wants
/// them. Running wins — a green dot answers "is this working", which is the
/// question somebody opening this window actually arrived with. Then the two
/// states that mean nothing will *ever* work, which the list could not express
/// at all while the servers were inside the app bundle. The profile count is
/// last, and nothing shows when there is none of it.
private struct ServerBadge: View {
  let server: BastionServer

  var body: some View {
    HStack(spacing: 4) {
      updateDot
      ladder
    }
  }

  /// Beside the ladder rather than in it, and that is the point.
  ///
  /// Every state below competes for one slot because they answer the same
  /// question — *is this working* — and only one of them can be true. "There is
  /// a newer version" answers a different question, is true at the same time as
  /// running, disabled or a profile count, and would be invisible in the case
  /// that matters most: a server anybody actually uses is a server with a green
  /// dot on it. So it gets a channel of its own, narrow enough that the row is
  /// still the ladder's.
  ///
  /// Orange, matching the `Badge` on the detail pane's Package card, and a dot
  /// rather than `arrow.up.circle`, which at `.caption2` is the same shape as
  /// the `arrow.down.circle` two branches below it meaning the opposite thing.
  @ViewBuilder private var updateDot: some View {
    if case .newer(let latest) = ServerInstaller.shared.availability(of: server.id) {
      Circle()
        .fill(Color.orange)
        .frame(width: 5, height: 5)
        .help("Update available (\(latest))")
        .accessibilityLabel("Update available, version \(latest)")
    }
  }

  /// One square every glyph of the ladder is centred in. The symbols at
  /// `.caption2` are wider than the 7pt green dot, and each flush against the
  /// row's trailing edge put a failing row's red mark a few points off the
  /// running row's dot above it: the column only reads as one when they share
  /// a centre.
  private static let slot: CGFloat = 12

  @ViewBuilder private var ladder: some View {
    let live = Activity.shared.instances.filter { $0.server == server.id && $0.isLive }.count
    let failing = Activity.shared.instances.filter {
      $0.server == server.id && $0.upstreamFailure != nil
    }
    let profiles = ProfileStore.shared.profiles.filter { $0.serverID == server.id }.count

    // First in the ladder, because it outranks everything below it: a disabled
    // server is not installing, will not run, and its profile count is a fact
    // about something that is not going to answer.
    if !server.isEnabled {
      Image(systemName: "pause.circle")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(width: Self.slot, height: Self.slot)
        .help("Disabled")
    } else if let first = failing.first {
      // Ahead of a live sibling: one profile answering does not help the
      // client wired to the one that is not, and this is the row it has to
      // be found from.
      Image(systemName: "exclamationmark.circle.fill")
        .font(.caption2)
        .foregroundStyle(.red)
        .frame(width: Self.slot, height: Self.slot)
        .help(
          failing.count == 1
            ? "\(first.profile): \(first.upstreamFailure ?? "")"
            : "\(failing.count) profiles failing")
    } else if live > 0 {
      HStack(spacing: 3) {
        Circle().fill(Color.green).frame(width: 7, height: 7)
          .frame(width: Self.slot, height: Self.slot)
        if live > 1 {
          Text("\(live)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      .help(live == 1 ? "Running" : "\(live) running")
    } else if ServerInstaller.shared.isRunning(server.id) {
      ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: Self.slot, height: Self.slot)
    } else if !ServerInstaller.isInstalled(server) {
      // The state a bundled-servers app could not be in, and the one a user
      // will hit first: added, not downloaded, and silent about it unless the
      // row says so. Without this the only symptom is a client failing much
      // later with a sentence about a directory nobody has heard of.
      Image(systemName: "arrow.down.circle")
        .font(.caption2)
        .foregroundStyle(.orange)
        .frame(width: Self.slot, height: Self.slot)
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
