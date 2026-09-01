import SwiftUI

/// One MCP client, and the file Bastion is about to write into.
///
/// This was a window listing all four clients at once. As a detail pane it can
/// afford to say the thing the list could only summarise in one sentence:
/// exactly which entries would be written, under which keys, pointing where, and
/// what is under each of those keys right now. The whole feature writes into
/// files somebody else owns — `~/.claude.json` here holds nine global servers and
/// ninety-eight project blocks — so the pane's job is as much reassurance as
/// action.
///
/// It also reports on the part of the file Bastion does **not** write. A config
/// still holding hand-configured servers is one where those servers carry no
/// token, no per-profile write gate and no line in the activity log, and this is
/// the only screen in the app with the file open.
struct ClientDetail: View {
  let client: ClientWiring.Client

  @State private var result: String?
  /// The keys a refused Configure named. Non-empty is the alert being up.
  @State private var collision: [String] = []
  /// The foreign entry whose removal is waiting to be confirmed.
  @State private var pending: Removal?
  /// Narrows the project list. Claude Code has ninety-eight folders in it.
  @State private var projectFilter = ""

  /// Every profile, which is what the pane draws keys from — not what Configure
  /// writes. A profile whose server is switched off keeps its key, because the
  /// file may still hold an entry under it and this pane's job is to say what is
  /// in the file.
  private var profiles: [Profile] { ProfileStore.shared.profiles }

  /// The profiles Configure writes, and the only ones the audit is taken over.
  private var writable: [Profile] { ProfileStore.shared.onEnabledServers }

  /// One entry Bastion would write — or one it wrote and no longer would — and
  /// what is under its key right now.
  private struct Row {
    let profile: Profile
    let key: String
    let state: ClientWiringMerge.EntryState
    let reach: String
    /// The client has this entry, and has switched it off.
    ///
    /// Not an `EntryState` case. `enabled` is a key only Codex has, and adding
    /// it to the audit would make four JSON clients carry a state describing
    /// something their files cannot say.
    var isDisabled = false
    /// The other switch, and the other end of it: this row's *server* is off in
    /// Bastion. The entry is in the file and still points at Bastion, so it
    /// audits as configured, and every request under it is refused at the
    /// gateway. Kept out of the audit and out of what Configure writes.
    var serverIsOff = false
  }

  /// Which entry a Remove button names, and where it lives.
  private struct Removal {
    let key: String
    /// A Claude Code project folder, or `nil` for the global scope.
    let folder: String?
  }

  /// Everything this pane knows about the config, from one read of it.
  private struct Snapshot {
    var status: ClientWiring.Status
    var rows: [Row]
    var others: [ClientWiringMerge.ForeignEntry]
    var projects: [(folder: String, entries: [ClientWiringMerge.ForeignEntry])]
    var hasOurEntries: Bool
  }

  /// Rebuilt on every redraw rather than cached. The file belongs to another
  /// application that may have rewritten it a second ago, so a remembered status
  /// is a claim about a file this app does not own and did not watch.
  ///
  /// One read, though. The status, the per-entry states, the foreign entries and
  /// "is there anything of ours to remove" used to be four independent computed
  /// properties, each opening a large JSON file on every pass — and each free to
  /// disagree with the others about what was in it.
  private func read() -> Snapshot {
    // As in `ClientDot`, and for the same reason: this subscribes the pane to
    // Bastion's own writes rather than leaving it to redraw by luck. The result
    // string happened to do it for Configure; nothing did it for a write made
    // from anywhere else.
    _ = ClientConfigRevision.shared.value
    let profiles = profiles
    let off = Set(profiles.map(\.serverID)).subtracting(writable.map(\.serverID))
    // Keyed off the full list, and identical to `keys(for: writable)` for every
    // profile in both: the `<profile>-<server>` disambiguation counts profiles
    // per server, and the switch is per server, so a server's profiles are
    // never split across the two lists. Written this way so a row for a
    // switched-off server names the key its entry is actually filed under.
    let keys = ClientWiring.keys(for: profiles)
    let ordered =
      profiles
      .compactMap { profile -> (profile: Profile, key: String)? in
        keys[profile].map { (profile, $0) }
      }
      .sorted { $0.key < $1.key }

    // What the rows say when there is no file to compare them against. Not an
    // empty list: "here is what would be written" is the useful answer for a
    // client that has never been configured.
    func unread(_ status: ClientWiring.Status) -> Snapshot {
      Snapshot(
        status: status,
        // Switched-off servers drop out entirely here. There is no file to hold
        // an entry for one, so all that is left to say about it is that Bastion
        // would not write it.
        rows: ordered.filter { !off.contains($0.profile.serverID) }.map {
          Row(
            profile: $0.profile, key: $0.key, state: .missing,
            reach: reachLine(for: $0.profile))
        },
        others: [], projects: [], hasOurEntries: false)
    }

    guard client.isInstalled else { return unread(.notInstalled) }
    guard ClientWiring.hasConfig(client) else { return unread(.audited(.notConfigured)) }
    let config: ClientWiring.Config
    do {
      config = try ClientWiring.read(client)
    } catch {
      return unread(.unreadable(error.localizedDescription))
    }

    let servers = config.servers
    let rows = ordered.compactMap { item -> Row? in
      let state = ClientWiringMerge.state(
        of: servers, key: item.key,
        reach: ClientWiring.reach(for: item.profile, transport: client.transport))
      let serverIsOff = off.contains(item.profile.serverID)
      // A switched-off server earns a row only for an entry of ours that is
      // really in this file — the one thing about it worth showing, since
      // Bastion is refusing every request that entry produces. Not for
      // `.missing`, which would be a row promising a write Configure will not
      // make; and not for `.foreign`, which is somebody else's server and is
      // already listed, with its own Remove, further down the pane.
      if serverIsOff {
        switch state {
        case .missing, .foreign: return nil
        case .matches, .stale: break
        }
      }
      return Row(
        profile: item.profile, key: item.key, state: state,
        reach: reachLine(for: item.profile),
        isDisabled: config.disabled.contains(item.key),
        serverIsOff: serverIsOff)
    }
    return Snapshot(
      // The same states the rows draw, reduced. The header sentence and the
      // badges cannot disagree because there is only one computation.
      //
      // Minus the switched-off servers: an entry Bastion refuses to serve and
      // refuses to write is not a thing this client is missing, and counting it
      // held a fully wired config at "not configured" until the server came
      // back.
      status: .audited(
        ClientWiringMerge.audit(
          states: rows.filter { !$0.serverIsOff }
            .map { (key: $0.key, label: $0.profile.serverID, state: $0.state) })),
      rows: rows,
      others: ClientWiringMerge.foreignEntries(in: servers),
      // Claude Code's alone. Codex keeps its project scope in a
      // `.codex/config.toml` inside each repository rather than a block in this
      // file, so there is nothing here to list -- and a card that rendered
      // anyway would be describing servers this file does not hold.
      // Called rather than passed as a function reference: `map` takes a
      // non-isolated closure, so handing it a main-actor method leaves the
      // isolation to be inferred at the call. `read()` is already on the main
      // actor, which is where this belongs.
      projects: config.root.map { ClientWiringMerge.foreignProjectEntries(in: $0) } ?? [],
      // Including entries for a profile that no longer exists, which is exactly
      // the case worth being able to clean up.
      hasOurEntries: servers.values.contains { ClientWiringMerge.isOurs($0) })
  }

  var body: some View {
    let snapshot = read()

    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header(snapshot)
        fileCard
        entriesCard(snapshot)
        if !snapshot.others.isEmpty { othersCard(snapshot) }
        if !snapshot.projects.isEmpty { projectsCard(snapshot) }
        if let result {
          Text(result)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)
    }
    .alert(
      removalTitle,
      isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Remove", role: .destructive) { if let pending { remove(pending) } }
    } message: {
      Text(removalMessage)
    }
    .alert(
      collisionTitle,
      isPresented: Binding(get: { !collision.isEmpty }, set: { if !$0 { collision = [] } })
    ) {
      Button("Cancel", role: .cancel) {}
      Button("Change the prefix…") { SettingsWindowController.show(.general) }
      Button("Overwrite anyway", role: .destructive) { wire(force: true) }
    } message: {
      Text(collisionMessage)
    }
  }

  // MARK: - The refusal

  private var collisionTitle: String {
    let what: String = collision.count == 1 ? "an entry" : "\(collision.count) entries"
    return "Overwrite \(what) in \(client.configURL.lastPathComponent)?"
  }

  /// Written out rather than inlined into the alert: it names what is about to
  /// be destroyed, which is the one sentence in this pane worth being sure of.
  private var collisionMessage: String {
    let one: Bool = collision.count == 1
    let names: String = collision.joined(separator: ", ")
    let verb: String = one ? "was" : "were"
    let those: String = one ? "that server" : "those servers"
    return
      "\(names) \(verb) not written by Bastion. Overwriting replaces \(those) with Bastion's own. "
      + "The previous file is kept as \(backupName)."
  }

  // MARK: - The removal

  private var removalTitle: String {
    "Remove '\(pending?.key ?? "")' from \(client.configURL.lastPathComponent)?"
  }

  /// Names the one key, where it lives, and what survives. The same care the
  /// collision alert takes, for the same reason: this writes somebody else's
  /// file, and this time it takes something out of it.
  private var removalMessage: String {
    guard let pending else { return "" }
    let scope: String =
      pending.folder.map { "the project block for \(abbreviate($0))" }
      ?? "the '\(client.rootKey)' key"
    return
      "'\(pending.key)' is taken out of \(scope) in \(client.configURL.path). Nothing else in "
      + "the file changes, and the previous version is kept as \(backupName). Restart "
      + "\(client.displayName) afterwards."
  }

  private var backupName: String {
    "\(client.configURL.lastPathComponent).bastion-backup"
  }

  // MARK: - Header

  private func header(_ snapshot: Snapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(client.displayName)
        .font(.title2).bold()

      HStack(spacing: 8) {
        Circle().fill(ClientWiring.tint(snapshot.status)).frame(width: 8, height: 8)
        Text(snapshot.status.summary).font(.callout)
        Spacer()
      }

      if let caveat = client.caveat {
        // Claude Desktop's, and the reason `bastion-bridge` exists at all:
        // every entry in that file is a `command`, so there is no URL to give
        // it.
        Text(caveat)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 8) {
        Button("Configure") { wire() }
          .disabled(writable.isEmpty || !client.isInstalled)
        // Named, because it is no longer the only Remove on this screen: every
        // foreign entry below carries one that takes out exactly that entry.
        // Offered only when there is something of ours to take out — a "Remove"
        // that rewrites a config to make no change is a write to somebody
        // else's file for nothing.
        Button("Remove Bastion's entries") { unwire() }
          .disabled(!snapshot.hasOurEntries)
        Button("Reveal in Finder") { ClientWiring.reveal(client) }
          .disabled(!client.isInstalled)
        Spacer()
      }

      if profiles.isEmpty {
        Text("No profiles yet. A client can only be wired to something that exists.")
          .font(.caption).foregroundStyle(.secondary)
      } else if writable.isEmpty {
        Text("Every server with a profile is switched off. Nothing to write.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - The file

  private var fileCard: some View {
    Card(title: "Config file") {
      VStack(alignment: .leading, spacing: 6) {
        // The path, always. Someone about to let an app write to a config is
        // owed the name of the file.
        Text(client.configURL.path)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)

        Text(
          "Bastion writes only the entries below, under the '\(client.rootKey)' key. Everything "
            + "else in the file is left byte-for-byte alone, and the previous version is saved "
            + "beside it as \(backupName) first.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - What gets written

  private func entriesCard(_ snapshot: Snapshot) -> some View {
    Card(title: "Entries") {
      VStack(alignment: .leading, spacing: 10) {
        if snapshot.rows.isEmpty {
          Text("Nothing to write.")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(snapshot.rows, id: \.profile) { row in
            entryRow(row)
            if row.profile != snapshot.rows.last?.profile { Divider() }
          }

          Divider()
          // The sentence that makes writing another app's config defensible at
          // all. What leaks if this file leaks is a revocable loopback token,
          // not a brokerage refresh token.
          Text(
            "Each entry carries a bearer token issued to \(client.displayName), and never a "
              + "credential. Credentials stay in the Keychain.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func entryRow(_ row: Row) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(row.key)
          .font(.system(.caption, design: .monospaced)).bold()
          .textSelection(.enabled)
        Spacer(minLength: 8)
        // No badge for a switched-off server. Every one of them would be a
        // claim about wiring, and the wiring is not what is wrong: the entry is
        // exactly right and the door behind it is shut.
        if row.serverIsOff {
          Badge("server off", tint: .secondary)
        } else {
          stateBadge(row.state)
        }
      }
      Text(row.reach)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      // Only the states with something to add. "configured" and "not written"
      // are fully said by the badge, and a sentence repeating a badge is noise
      // on a pane that already has a lot to say.
      switch row.state {
      case .stale(let where_):
        // The remedy has to name the switch when the switch is what is stopping
        // it. Configure skips this row entirely while the server is off, so
        // "Configure rewrites it" would be a promise the button does not keep.
        Text(
          row.serverIsOff
            ? "Points at \(where_) right now. Switch the server back on and Configure rewrites it."
            : "Points at \(where_) right now. Configure rewrites it.")
          .font(.caption2)
          .foregroundStyle(row.serverIsOff ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
          .fixedSize(horizontal: false, vertical: true)
      case .foreign(let what):
        Text(
          "Already taken by \(what ?? "an entry Bastion did not write"). Configure will refuse "
            + "rather than replace it.")
          .font(.caption2).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      case .matches, .missing:
        EmptyView()
      }
      // The blind spot this pane CAN see, unlike Claude Desktop's. An entry the
      // client has switched off still points where it should, so it audits as
      // configured while the client runs none of it -- but unlike a silently
      // dropped config, the fact is a key in the file.
      if row.isDisabled, !row.serverIsOff {
        Text(
          "\(client.displayName) has this entry switched off. Configure turns it back on.")
          .font(.caption2).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      // The row Bastion's own switch produces. Left in the list rather than
      // hidden, because it is in the file whether this pane draws it or not,
      // and this is the only screen that reads the file.
      if row.serverIsOff {
        Text(
          "'\(row.profile.serverID)' is switched off in Bastion, so requests under this entry "
            + "are refused. Configure leaves it alone; Remove Bastion's entries takes it out.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    // Dimmed the same way the servers list dims a switched-off server, so the
    // two screens say the same thing about it without either having to explain
    // the other.
    .opacity(row.serverIsOff ? 0.55 : 1)
  }

  /// The per-entry counterpart to the header dot, in the same colours, so a row
  /// and the sidebar never describe the same file differently.
  @ViewBuilder
  private func stateBadge(_ state: ClientWiringMerge.EntryState) -> some View {
    switch state {
    case .matches: Badge("configured", tint: .green)
    case .missing: Badge("not written", tint: .secondary)
    case .stale: Badge("points elsewhere", tint: .red)
    case .foreign: Badge("taken", tint: .red)
    }
  }

  private func reachLine(for profile: Profile) -> String {
    switch ClientWiring.reach(for: profile, transport: client.transport) {
    case .http(let url): url
    case .bridge(let command, let args): ([command] + args).joined(separator: " ")
    }
  }

  // MARK: - What Bastion did not write

  /// The servers in this file that go around Bastion.
  ///
  /// The point of the app, stated against somebody's actual config: these are
  /// the ones the client starts itself, and everything Bastion offers — one
  /// token per client, a write gate per profile, one activity log — is exactly
  /// what they do not have. Removing one is the last step of moving it over, so
  /// the button is here rather than in a client's own settings screen.
  private func othersCard(_ snapshot: Snapshot) -> some View {
    // What Configure would write, so a foreign entry is only flagged as
    // colliding with a key something is actually going to claim.
    let wanted = Set(ClientWiring.keys(for: writable).values)
    let count = snapshot.others.count

    return Card(title: "Other servers in this file (\(count))") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "\(client.displayName) starts \(count == 1 ? "this one" : "these") itself. "
            + "\(count == 1 ? "It carries" : "They carry") no Bastion token and no write gate, "
            + "and nothing \(count == 1 ? "it does" : "they do") reaches the activity log. "
            + "Remove one once the same server is running through Bastion.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        ForEach(snapshot.others, id: \.key) { entry in
          Divider()
          foreignRow(entry, folder: nil, colliding: wanted.contains(entry.key))
        }
      }
    }
  }

  /// The same question asked of Claude Code's per-folder blocks.
  ///
  /// Its own card rather than more rows in the one above, because these are a
  /// different scope with a different remedy: a project server is wired for one
  /// folder and invisible everywhere else, which is exactly why they accumulate.
  /// Scrolling, and filterable, because there can be a hundred folders.
  private func projectsCard(_ snapshot: Snapshot) -> some View {
    let folders = snapshot.projects.count
    let servers = snapshot.projects.reduce(0) { $0 + $1.entries.count }
    let shown = filtered(snapshot.projects)

    return Card(
      title: "Project servers (\(servers) across \(folders) folder\(folders == 1 ? "" : "s"))"
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "\(client.displayName) also keeps servers per project folder. These go around Bastion "
            + "the same way, and only apply inside the folder they are filed under.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        // Only once there are enough folders for scrolling to be worse than
        // typing. Below that the field is a control with nothing to do.
        if folders > 6 {
          TextField("Filter by folder or server", text: $projectFilter)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }

        if shown.isEmpty {
          Text("No folder matches '\(projectFilter)'.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          // A nested scroller, with a ceiling. Ninety-eight folders inline
          // would push the rest of the pane — including the result line these
          // buttons write to — permanently off the bottom of the window.
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              ForEach(shown, id: \.folder) { group in
                VStack(alignment: .leading, spacing: 6) {
                  Text(abbreviate(group.folder))
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .textSelection(.enabled)
                  ForEach(group.entries, id: \.key) { entry in
                    foreignRow(entry, folder: group.folder, colliding: false)
                  }
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .frame(maxHeight: 240)
        }
      }
    }
  }

  private func filtered(
    _ groups: [(folder: String, entries: [ClientWiringMerge.ForeignEntry])]
  ) -> [(folder: String, entries: [ClientWiringMerge.ForeignEntry])] {
    let needle = projectFilter.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return groups }
    return groups.filter { group in
      group.folder.localizedCaseInsensitiveContains(needle)
        || group.entries.contains { $0.key.localizedCaseInsensitiveContains(needle) }
    }
  }

  private func foreignRow(
    _ entry: ClientWiringMerge.ForeignEntry,
    folder: String?,
    colliding: Bool
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(entry.key)
          .font(.system(.caption, design: .monospaced)).bold()
          .textSelection(.enabled)
        // Truncated in the middle: an `npx` line's useful half is the package
        // at the end, and a URL's is the host at the start.
        Text(entry.identity ?? "no command or url in this entry")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(2).truncationMode(.middle)
          .textSelection(.enabled)
        if colliding {
          Text("This is the entry standing in the way of Bastion's own '\(entry.key)'.")
            .font(.caption2).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      Button("Remove…") { pending = Removal(key: entry.key, folder: folder) }
        .controlSize(.small)
    }
  }

  /// `/Users/olivier/Projects/…` as `~/Projects/…`. These paths are long enough
  /// that the home prefix is the least useful part of every one of them.
  private func abbreviate(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
  }

  // MARK: - Actions

  private func wire(force: Bool = false) {
    do {
      let profiles = writable
      let backup = try ClientWiring.wire(client, profiles: profiles, force: force)
      collision = []
      result =
        "Wrote \(profiles.count) entr\(profiles.count == 1 ? "y" : "ies") to \(client.configURL.path)."
        + (backup.map { " Previous version saved as \($0.lastPathComponent)." } ?? "")
        + " Restart \(client.displayName) to pick them up."
    } catch ClientWiring.WireError.collision(let name, let keys) {
      // The refusal is the feature. It also lands in `result`, so the reason
      // survives after the alert is dismissed.
      result = ClientWiring.WireError.collision(client: name, keys: keys).localizedDescription
      collision = keys
    } catch {
      result = "Could not write \(client.configURL.path): \(error.localizedDescription)"
    }
  }

  private func unwire() {
    do {
      let backup = try ClientWiring.unwire(client)
      result =
        "Removed Bastion's entries from \(client.configURL.path)."
        + (backup.map { " Previous version saved as \($0.lastPathComponent)." } ?? "")
    } catch {
      result = "Could not write \(client.configURL.path): \(error.localizedDescription)"
    }
  }

  private func remove(_ removal: Removal) {
    do {
      let backup = try ClientWiring.removeEntry(
        removal.key, from: client, inProject: removal.folder)
      let scope: String = removal.folder.map { " in \(abbreviate($0))" } ?? ""
      result =
        "Removed '\(removal.key)'\(scope) from \(client.configURL.path)."
        + (backup.map { " Previous version saved as \($0.lastPathComponent)." } ?? "")
        + " Restart \(client.displayName) to pick it up."
    } catch {
      result = "Could not write \(client.configURL.path): \(error.localizedDescription)"
    }
    pending = nil
  }
}

/// The status colour, shared with the sidebar dot.
///
/// Declared here rather than on `ClientWiring` itself so that file keeps its
/// split: it is policy — paths, keys, transports — and imports no SwiftUI.
extension ClientWiring {
  static func tint(_ status: Status) -> Color {
    switch status {
    case .audited(.configured): .green
    case .audited(.notConfigured), .notInstalled: .secondary
    case .audited(.incomplete): .orange
    case .audited(.stale), .audited(.collides), .unreadable: .red
    }
  }
}
