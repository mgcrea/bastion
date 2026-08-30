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

  /// The key a profile gets in a client config.
  ///
  /// `bastion-<server>` while a server has one profile, which is the ordinary
  /// case and reads well in a client's server list. A second profile of the
  /// same server would collide, so both then carry the profile name. Decided
  /// across the whole set rather than per entry, so the key for `shopify` does
  /// not change shape depending on which profiles happen to be selected.
  static func keys(for profiles: [Profile]) -> [Profile: String] {
    var counts: [String: Int] = [:]
    for profile in profiles { counts[profile.serverID, default: 0] += 1 }
    var out: [Profile: String] = [:]
    for profile in profiles {
      let single = counts[profile.serverID] == 1
      // Bastion's own server would otherwise be `bastion-bastion`, which a
      // client turns into tool names like `mcp__bastion_bastion__list_servers`.
      // The stutter is not cosmetic at that point — it is in every tool name
      // the model reads.
      if profile.serverID == BuiltinServer.id {
        out[profile] = single ? "bastion" : "bastion-\(profile.name)"
        continue
      }
      out[profile] =
        single
        ? "bastion-\(profile.serverID)"
        : "bastion-\(profile.name)-\(profile.serverID)"
    }
    return out
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
    let expected = profiles.map {
      (
        key: keys[$0] ?? "bastion-\($0.serverID)",
        reach: reach(for: $0, transport: client.transport),
        label: $0.serverID
      )
    }
    return .audited(ClientWiringMerge.audit(servers: servers, expected: expected))
  }

  // MARK: - Writing

  @discardableResult
  static func wire(_ client: Client, profiles: [Profile]) throws -> URL? {
    let token = try token(for: client)
    let keys = keys(for: profiles)
    var entries: [String: [String: Any]] = [:]
    // What the step-5 migration wrote: the user's own key names, kept so their
    // tools kept working. Named as legacy so those entries are migrated rather
    // than left beside the new ones — but only when `isOurs` agrees we wrote
    // them.
    var legacy: [String: String] = [:]
    for profile in profiles {
      guard let key = keys[profile] else { continue }
      entries[key] = entry(for: profile, transport: client.transport, token: token)
      legacy[key] = profile.serverID
    }

    let root: [String: Any] =
      FileManager.default.fileExists(atPath: client.configURL.path)
      ? try ClientWiringMerge.readJSON(client.configURL) : [:]
    let merged = ClientWiringMerge.merged(
      into: root, rootKey: client.rootKey, entries: entries, legacy: legacy)
    let backup = try ClientWiringMerge.write(
      merged, to: client.configURL, backupSuffix: "bastion-backup")
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
    hostLog("wiring", .info, "\(client.displayName): removed Bastion's entries")
    return backup
  }

  /// Reveal the config in Finder, for someone who would rather look than trust.
  static func reveal(_ client: Client) {
    NSWorkspace.shared.activateFileViewerSelecting([client.configURL])
  }
}
