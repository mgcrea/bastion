import AppKit
import Foundation

/// Which MCP clients Bastion knows how to configure, and what to write into
/// each one.
///
/// Everything that touches the file itself lives in `ClientWiringMerge`, which
/// imports nothing but Foundation so `make wiring-check` can compile and
/// exercise it directly. This half is policy: paths, keys, transports.
///
/// Two facts shape the whole design. Clients disagree about where MCP servers
/// live — `mcpServers` here, `servers` there, nested under a folder in a third
/// — and they disagree about whether they can reach a URL at all. Claude
/// Desktop cannot, so it gets the bridge; everything else gets an HTTP entry
/// and no child process of its own.
/// Bumped whenever Bastion writes a client config.
///
/// Every reader of a client's status goes to the file on every redraw and caches
/// nothing, which is right — the file belongs to another application. It leaves
/// one gap, though: nothing in SwiftUI's dependency graph changes when the file
/// does, so a view showing that status has no reason to redraw when Bastion
/// rewrites it. The detail pane got away with it by accident, because wiring
/// sets its `result` string; the sidebar dot had no such trigger and went on
/// showing the answer it computed at first render while the pane beside it
/// showed the new one.
///
/// A revision rather than the status itself. What is observable here is "the
/// file changed" — every reader still goes to the file for what it now says,
/// which is the property that makes a stale answer impossible rather than
/// merely unlikely.
///
/// It counts Bastion's own writes only. A config rewritten by the client that
/// owns it does not bump this, and the dot beside that client stays on its last
/// answer until something else redraws it — the same limit the sidebar has
/// always had, and the reason this is a revision to bump rather than a status
/// to store.
@MainActor
@Observable
final class ClientConfigRevision {
  static let shared = ClientConfigRevision()

  private(set) var value = 0

  func bump() { value += 1 }
}

@MainActor
enum ClientWiring {
  enum Transport {
    /// `type: http` with a loopback URL and a bearer header.
    case http
    /// The embedded bridge, spawned per server.
    case bridge
  }

  struct Client: Identifiable {
    let id: String
    let displayName: String
    let configURL: URL
    /// Where servers live in that file. Not a constant across clients: Claude
    /// uses `mcpServers`, VS Code uses `servers`.
    let rootKey: String
    let transport: Transport
    /// A note about this client worth showing next to it.
    let caveat: String?

    /// Whether the client appears to be installed at all.
    ///
    /// The parent directory, not the config file: a client that has never been
    /// given an MCP server has no config yet, and "not installed" is a
    /// different and more discouraging answer than "not configured".
    var isInstalled: Bool {
      FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    }
  }

  static var all: [Client] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let support = home.appendingPathComponent("Library/Application Support")
    return [
      Client(
        id: "claude-code",
        displayName: "Claude Code",
        configURL: home.appendingPathComponent(".claude.json"),
        rootKey: "mcpServers",
        transport: .http,
        caveat: nil),
      Client(
        id: "claude-desktop",
        displayName: "Claude Desktop",
        configURL: support.appendingPathComponent("Claude/claude_desktop_config.json"),
        rootKey: "mcpServers",
        // Every entry in this file is a `command`; it has no `type: http` among
        // them. That is the whole reason `bastion-bridge` exists.
        transport: .bridge,
        caveat: "spawns bastion-bridge, which starts Bastion on demand"),
      Client(
        id: "vscode",
        displayName: "VS Code",
        // `User/mcp.json`, NOT `User/settings.json`. settings.json is JSONC —
        // it has comments and trailing commas — and round-tripping it through
        // JSONSerialization would silently delete every comment in a file the
        // user hand-wrote. mcp.json is strict JSON and is where VS Code keeps
        // MCP servers anyway.
        configURL: support.appendingPathComponent("Code/User/mcp.json"),
        rootKey: "servers",
        transport: .http,
        caveat: nil),
      Client(
        id: "cursor",
        displayName: "Cursor",
        configURL: home.appendingPathComponent(".cursor/mcp.json"),
        rootKey: "mcpServers",
        transport: .http,
        caveat: nil),
    ]
  }

  // MARK: - What gets written

  /// The bridge inside this bundle.
  ///
  /// By path, so a config names the copy that wrote it. A bridge from a build
  /// directory and one from /Applications are different files and a config that
  /// pointed at the wrong one would start the wrong app.
  static var bridgePath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bastion-bridge").path
  }

  /// What every entry key starts with, and the reason it is a setting rather
  /// than the constant it used to be.
  ///
  /// It was `bastion-`, always. That is Bastion's opinion imposed on a file
  /// somebody else owns, and it is not free: the key becomes part of every tool
  /// name the model reads, so a `shopify` entry is `mcp__bastion_shopify__…` for
  /// as long as the config lives. Empty by default — the prefix is opt-in now,
  /// and the collision it was there to prevent is checked in `wire` rather than
  /// assumed away by a naming convention.
  nonisolated static let prefixKey = "clientKeyPrefix"

  nonisolated static var prefix: String {
    let stored = UserDefaults.standard.string(forKey: prefixKey) ?? ""
    return isValidPrefix(stored) ? stored : ""
  }

  /// Empty, or something that reads as the front of a key.
  ///
  /// A trailing dash is the ordinary case here rather than an edge one —
  /// `bastion-` is the whole point — so this is `Profile.isValidName` loosened
  /// by exactly that much, plus the empty string.
  nonisolated static func isValidPrefix(_ candidate: String) -> Bool {
    if candidate.isEmpty { return true }
    return candidate.count <= 32
      && candidate.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
  }

  /// The key a profile gets in a client config.
  ///
  /// `<prefix><server>` while a server has one profile, which is the ordinary
  /// case and reads well in a client's server list. A second profile of the
  /// same server would collide, so both then carry the profile name. Decided
  /// across the whole set rather than per entry, so the key for `shopify` does
  /// not change shape depending on which profiles happen to be selected.
  static func keys(for profiles: [Profile]) -> [Profile: String] {
    let prefix = prefix
    // `bastion-` in front of Bastion's own server would be `bastion-bastion`,
    // which a client turns into tool names like
    // `mcp__bastion_bastion__list_servers`. The stutter is not cosmetic at that
    // point — it is in every tool name the model reads. Written as a rule about
    // the prefix rather than a check for the built-in id, so a `mcp-` prefix
    // still gives `mcp-bastion`.
    var stem = prefix
    while stem.hasSuffix("-") { stem.removeLast() }

    var counts: [String: Int] = [:]
    for profile in profiles { counts[profile.serverID, default: 0] += 1 }
    var out: [Profile: String] = [:]
    for profile in profiles {
      let body =
        counts[profile.serverID] == 1
        ? profile.serverID
        : "\(profile.name)-\(profile.serverID)"
      out[profile] = profile.serverID == stem ? body : prefix + body
    }
    return out
  }

  /// The two reasons Bastion declines to write a config.
  ///
  /// Both are about a file it does not own. Neither is recoverable by trying
  /// again, so both name what to change.
  enum WireError: LocalizedError {
    /// Keys the config already holds under entries Bastion did not write.
    case collision(client: String, keys: [String])
    /// Two profiles that reduce to one key, which would write one entry and
    /// silently drop the other.
    case ambiguousKeys([String])

    var errorDescription: String? {
      switch self {
      case .collision(let client, let keys):
        let names = keys.map { "'\($0)'" }.joined(separator: ", ")
        let one = keys.count == 1
        return
          "\(client)'s config already has \(one ? "an entry" : "entries") named \(names) that "
          + "Bastion did not write. Overwriting would replace \(one ? "a server" : "servers") "
          + "you configured yourself. Change the entry name prefix in Settings, or remove "
          + "\(one ? "it" : "them") from the config first."
      case .ambiguousKeys(let keys):
        return
          "Two profiles would be written under the same name: "
          + keys.map { "'\($0)'" }.joined(separator: ", ")
          + ". Rename a profile, or change the entry name prefix in Settings."
      }
    }
  }

  static func reach(for profile: Profile, transport: Transport) -> ClientWiringMerge.Reach {
    switch transport {
    case .http:
      return .http(url: "http://127.0.0.1:\(Gateway.shared.port)/s/\(profile.name)/\(profile.serverID)")
    case .bridge:
      return .bridge(
        command: bridgePath,
        args: ["--profile=\(profile.name)", "--server=\(profile.serverID)"])
    }
  }

  /// The entry itself, token included.
  ///
  /// The token goes in the config; the credential does not. That split is rule
  /// 5, and it is the reason writing a client config is defensible at all —
  /// what leaks if this file leaks is a revocable loopback token, not a
  /// brokerage refresh token.
  static func entry(for profile: Profile, transport: Transport, token: String) -> [String: Any] {
    switch reach(for: profile, transport: transport) {
    case .http(let url):
      return ["type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]
    case .bridge(let command, let args):
      return ["command": command, "args": args, "env": ["BASTION_TOKEN": token]]
    }
  }

  /// One token per client, minted once and reused.
  ///
  /// Reused rather than reminted, because minting replaces the Keychain item
  /// and every config already carrying the old token would stop working — so
  /// re-running "Configure" to pick up a new server would silently break the
  /// entries it was not touching.
  static func token(for client: Client) throws -> String {
    if let existing = CredentialStore.read(.gatewayToken, account: client.id), !existing.isEmpty {
      return existing
    }
    return try GatewayToken.issue(to: client.id)
  }

  // MARK: - Status

  enum Status: Equatable {
    case notInstalled
    case unreadable(String)
    case audited(ClientWiringMerge.Audit)

    var summary: String {
      switch self {
      case .notInstalled: return "not installed"
      case .unreadable(let why): return "unreadable — \(why)"
      case .audited(.configured): return "configured"
      case .audited(.notConfigured): return "not configured"
      case .audited(.stale(let where_)): return "points elsewhere — \(where_)"
      case .audited(.incomplete(let missing)):
        return "missing \(missing.joined(separator: ", "))"
      case .audited(.collides(let keys)):
        return "\(keys.joined(separator: ", ")) already taken by another server"
      }
    }
  }

  static func status(of client: Client, profiles: [Profile]) -> Status {
    guard client.isInstalled else { return .notInstalled }
    guard FileManager.default.fileExists(atPath: client.configURL.path) else {
      return .audited(.notConfigured)
    }
    let root: [String: Any]
    do {
      root = try ClientWiringMerge.readJSON(client.configURL)
    } catch {
      return .unreadable(error.localizedDescription)
    }
    let servers = root[client.rootKey] as? [String: Any] ?? [:]
    let keys = keys(for: profiles)
    let expected = profiles.compactMap {
      profile -> (key: String, reach: ClientWiringMerge.Reach, label: String)? in
      guard let key = keys[profile] else { return nil }
      return (key, reach(for: profile, transport: client.transport), profile.serverID)
    }
    return .audited(ClientWiringMerge.audit(servers: servers, expected: expected))
  }

  // MARK: - Writing

  /// `force` overwrites entries Bastion did not write. Off by default, and the
  /// caller has to say so twice — once in the UI, once here — because the thing
  /// being overwritten is a server somebody configured by hand.
  @discardableResult
  static func wire(_ client: Client, profiles: [Profile], force: Bool = false) throws -> URL? {
    let keys = keys(for: profiles)
    // Unreachable while the prefix was a constant; reachable the moment it is
    // typed by hand. Refusing beats writing one of the two entries and leaving
    // the other profile silently unwired.
    let duplicates = Dictionary(grouping: keys.values, by: { $0 }).filter { $0.value.count > 1 }
    guard duplicates.isEmpty else { throw WireError.ambiguousKeys(duplicates.keys.sorted()) }

    let root: [String: Any] =
      FileManager.default.fileExists(atPath: client.configURL.path)
      ? try ClientWiringMerge.readJSON(client.configURL) : [:]

    // Before the token, so a refusal does not leave a Keychain item behind for a
    // client that was never configured.
    if !force {
      let existing = root[client.rootKey] as? [String: Any] ?? [:]
      let taken = ClientWiringMerge.collisions(servers: existing, keys: Array(keys.values))
      guard taken.isEmpty else {
        throw WireError.collision(client: client.displayName, keys: taken)
      }
    }

    let token = try token(for: client)
    var entries: [String: [String: Any]] = [:]
    for profile in profiles {
      guard let key = keys[profile] else { continue }
      entries[key] = entry(for: profile, transport: client.transport, token: token)
    }

    let merged = ClientWiringMerge.merged(
      into: root, rootKey: client.rootKey, entries: entries)
    let backup = try ClientWiringMerge.write(
      merged, to: client.configURL, backupSuffix: "bastion-backup")
    ClientConfigRevision.shared.bump()
    hostLog(
      "wiring", .info,
      "\(client.displayName): wrote \(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
        + (backup.map { " (backup at \($0.lastPathComponent))" } ?? ""))
    return backup
  }

  @discardableResult
  static func unwire(_ client: Client) throws -> URL? {
    guard FileManager.default.fileExists(atPath: client.configURL.path) else { return nil }
    let root = try ClientWiringMerge.readJSON(client.configURL)
    let stripped = ClientWiringMerge.unmerged(from: root, rootKey: client.rootKey)
    let backup = try ClientWiringMerge.write(
      stripped, to: client.configURL, backupSuffix: "bastion-backup")
    ClientConfigRevision.shared.bump()
    hostLog("wiring", .info, "\(client.displayName): removed Bastion's entries")
    return backup
  }

  /// Take out one entry Bastion did not write.
  ///
  /// The counterpart to `unwire`, and pointed the other way: that removes every
  /// entry of ours, this removes exactly one of somebody else's — a server that
  /// was configured by hand and has since been moved into Bastion. Which is why
  /// `ClientWiringMerge.removing` refuses a key `isOurs` claims: the two paths
  /// must not be able to do each other's job by accident.
  ///
  /// `folder` names a Claude Code project block. `nil` is the global scope.
  @discardableResult
  static func removeEntry(
    _ key: String,
    from client: Client,
    inProject folder: String? = nil
  ) throws -> URL? {
    guard FileManager.default.fileExists(atPath: client.configURL.path) else { return nil }
    let root = try ClientWiringMerge.readJSON(client.configURL)
    let stripped =
      folder.map { ClientWiringMerge.removing(key: key, inProject: $0, from: root) }
      ?? ClientWiringMerge.removing(key: key, from: root, rootKey: client.rootKey)
    let backup = try ClientWiringMerge.write(
      stripped, to: client.configURL, backupSuffix: "bastion-backup")
    ClientConfigRevision.shared.bump()
    hostLog(
      "wiring", .info,
      "\(client.displayName): removed '\(key)'" + (folder.map { " from \($0)" } ?? ""))
    return backup
  }

  /// Reveal the config in Finder, for someone who would rather look than trust.
  static func reveal(_ client: Client) {
    NSWorkspace.shared.activateFileViewerSelecting([client.configURL])
  }
}
