import SwiftUI

/// One MCP client, and the file Bastion is about to write into.
///
/// This was a window listing all four clients at once. As a detail pane it can
/// afford to say the thing the list could only summarise in one sentence:
/// exactly which entries would be written, under which keys, and pointing
/// where. The whole feature writes into files somebody else owns — `~/.claude.json`
/// here holds nine global servers and ninety-eight project blocks — so the
/// pane's job is as much reassurance as action.
struct ClientDetail: View {
  let client: ClientWiring.Client

  @State private var result: String?
  /// The keys a refused Configure named. Non-empty is the alert being up.
  @State private var collision: [String] = []

  private var profiles: [Profile] { ProfileStore.shared.profiles }

  /// Recomputed on every redraw rather than cached. The file belongs to another
  /// application that may have rewritten it a second ago, so a remembered
  /// status is a claim about a file this app does not own and did not watch.
  private var status: ClientWiring.Status {
    ClientWiring.status(of: client, profiles: profiles)
  }

  /// Whether the config currently holds anything `isOurs` recognises —
  /// including entries for a profile that no longer exists, which is exactly
  /// the case worth being able to clean up.
  private var hasOurEntries: Bool {
    guard client.isInstalled,
      let root = try? ClientWiringMerge.readJSON(client.configURL),
      let servers = root[client.rootKey] as? [String: Any]
    else { return false }
    return servers.values.contains { ClientWiringMerge.isOurs($0) }
  }

  /// Of the keys Bastion would write, the ones already taken by an entry it did
  /// not write, mapped to what is there now.
  ///
  /// Shown before Configure is pressed rather than only in its refusal: the
  /// pane's job is to say what would happen to this file, and "your own shopify
  /// server is in the way" is the most important thing it can say.
  private var foreign: [String: String] {
    guard client.isInstalled,
      let root = try? ClientWiringMerge.readJSON(client.configURL),
      let servers = root[client.rootKey] as? [String: Any]
    else { return [:] }
    var out: [String: String] = [:]
    for key in ClientWiring.keys(for: profiles).values {
      guard let entry = servers[key], !ClientWiringMerge.isOurs(entry) else { continue }
      out[key] = ClientWiringMerge.identity(of: entry) ?? "an entry Bastion did not write"
    }
    return out
  }

  var body: some View {
    let status = status

    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header(status)
        fileCard
        entriesCard
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
    let backup: String = "\(client.configURL.lastPathComponent).bastion-backup"
    return
      "\(names) \(verb) not written by Bastion. Overwriting replaces \(those) with Bastion's own. "
      + "The previous file is kept as \(backup)."
  }

  // MARK: - Header

  private func header(_ status: ClientWiring.Status) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(client.displayName)
        .font(.title2).bold()

      HStack(spacing: 8) {
        Circle().fill(ClientWiring.tint(status)).frame(width: 8, height: 8)
        Text(status.summary).font(.callout)
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
          .disabled(profiles.isEmpty || !client.isInstalled)
        // Offered only when there is something of ours to take out. A "Remove"
        // that rewrites a config to make no change is a write to somebody
        // else's file for nothing.
        Button("Remove") { unwire() }
          .disabled(!hasOurEntries)
        Button("Reveal in Finder") { ClientWiring.reveal(client) }
          .disabled(!client.isInstalled)
        Spacer()
      }

      if profiles.isEmpty {
        Text("No profiles yet. A client can only be wired to something that exists.")
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
            + "beside it as \(client.configURL.lastPathComponent).bastion-backup first.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - What gets written

  private var entriesCard: some View {
    let keys = ClientWiring.keys(for: profiles)
    let ordered =
      profiles
      .compactMap { profile in keys[profile].map { (profile: profile, key: $0) } }
      .sorted { $0.key < $1.key }
    let taken = foreign

    return Card(title: "Entries") {
      VStack(alignment: .leading, spacing: 10) {
        if ordered.isEmpty {
          Text("Nothing to write.")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(ordered, id: \.profile) { item in
            VStack(alignment: .leading, spacing: 2) {
              Text(item.key)
                .font(.system(.caption, design: .monospaced)).bold()
                .foregroundStyle(taken[item.key] == nil ? Color.primary : Color.red)
                .textSelection(.enabled)
              Text(reachLine(for: item.profile))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
              if let existing = taken[item.key] {
                Text("Already taken by \(existing). Configure will refuse rather than replace it.")
                  .font(.caption2).foregroundStyle(.red)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
            if item.profile != ordered.last?.profile { Divider() }
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

  private func reachLine(for profile: Profile) -> String {
    switch ClientWiring.reach(for: profile, transport: client.transport) {
    case .http(let url): url
    case .bridge(let command, let args): ([command] + args).joined(separator: " ")
    }
  }

  // MARK: - Actions

  private func wire(force: Bool = false) {
    do {
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
