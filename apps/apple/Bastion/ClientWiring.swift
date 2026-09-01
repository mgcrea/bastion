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

  /// What the config file is written in.
  ///
  /// Only Codex is not JSON, and the difference is confined to opening and
  /// writing the file: `ClientWiringMerge` decides what an entry MEANS and does
  /// not read `type`, so a Codex entry flows through `isOurs`, `target`,
  /// `audit`, `collisions` and `merged` without any of them learning the file
  /// is TOML.
  enum Format {
    case json
    /// `ClientWiringTOML`, which edits the `[mcp_servers]` blocks in place and
    /// leaves every other byte of somebody's hand-written file alone.
    case toml
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
    let format: Format

    /// Spelled out rather than memberwise, so that adding a format did not put
    /// a line on every client that does not have one.
    init(
      id: String, displayName: String, configURL: URL, rootKey: String,
      transport: Transport, caveat: String?, format: Format = .json
    ) {
      self.id = id
      self.displayName = displayName
      self.configURL = configURL
      self.rootKey = rootKey
      self.transport = transport
      self.caveat = caveat
      self.format = format
    }

    /// Whether the client appears to be installed at all.
    ///
    /// The parent directory, not the config file: a client that has never been
    /// given an MCP server has no config yet, and "not installed" is a
    /// different and more discouraging answer than "not configured".
    var isInstalled: Bool {
      // Every fixture client is rooted at `/Users/you`, which exists on nobody's
      // Mac — so without this the client plate is the "not installed" empty
      // state on every run.
      if DemoSeed.isEnabled { return true }
      return FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    }
  }

  static var all: [Client] {
    if DemoSeed.isEnabled { return DemoSeed.clients }
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
      Client(
        id: "codex",
        displayName: "ChatGPT & Codex",
        // One client, not three. The ChatGPT desktop app, the Codex CLI and the
        // Codex IDE extension read this same file, so three rows would mean
        // three tokens overwriting each other's and an unwire of any one of
        // them taking the other two out.
        configURL: home.appendingPathComponent(".codex/config.toml"),
        rootKey: ClientWiringTOML.rootKey,
        // Codex reaches a URL, so no bridge: it runs on this machine, unlike
        // Claude Desktop's connectors, which dial from Anthropic's cloud and
        // cannot see loopback at all.
        transport: .http,
        caveat: "the ChatGPT app, the Codex CLI and the IDE extension all read this one file, "
          + "and the ChatGPT app rewrites it on launch",
        format: .toml),
    ]
  }

  // MARK: - What gets written

  /// The bridge inside this bundle.
  ///
  /// By path, so a config names the copy that wrote it. A bridge from a build
  /// directory and one from /Applications are different files and a config that
  /// pointed at the wrong one would start the wrong app.
  static var bridgePath: String {
    // Under a capture this would be the path inside the build directory the
    // shot was taken from — `apps/apple/.build/Build/Products/Release/…`, with
    // the developer's home in front of it. Claude Desktop's `reachLine` renders
    // it verbatim.
    if DemoSeed.isEnabled { return DemoSeed.bridgePath }
    return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bastion-bridge").path
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
  static func entry(
    for profile: Profile, transport: Transport, token: String, format: Format = .json
  ) -> [String: Any] {
    switch (reach(for: profile, transport: transport), format) {
    case (.http(let url), .json):
      return ["type": "http", "url": url, "headers": ["Authorization": "Bearer \(token)"]]
    // Codex has no `type`: a `url` is what makes an entry streamable HTTP. And
    // `http_headers` takes a literal, which is the fact that makes wiring it
    // possible at all -- its `bearer_token_env_var` names an environment
    // variable, and Bastion has no way to put one in Codex's environment.
    case (.http(let url), .toml):
      return ["url": url, "http_headers": ["Authorization": "Bearer \(token)"]]
    // Unused today, and right anyway: Codex spells a stdio server with the same
    // three keys the JSON clients do.
    case (.bridge(let command, let args), _):
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

  // MARK: - Opening the file

  /// Everything a reader needs from a client's config, whichever format it is
  /// in. The one place either format is opened.
  ///
  /// `servers` is the JSON-flavoured dictionary every function in
  /// `ClientWiringMerge` already takes, which is the point of the shape: the
  /// whole policy layer -- `isOurs`, `state`, `audit`, `collisions`,
  /// `foreignEntries` -- never learns that one of these files is TOML.
  struct Config {
    let servers: [String: Any]
    /// The whole document, for the one question only Claude Code's file can
    /// answer. `nil` for TOML: Codex's project scope is a `.codex/config.toml`
    /// inside each repository rather than a block in this file, so there is
    /// nothing here to list and a project card that rendered would be lying.
    let root: [String: Any]?
    /// Names the client has switched off with `enabled = false`. Empty for
    /// JSON, which has no such key.
    let disabled: Set<String>
  }

  /// Whether the file itself is there.
  ///
  /// One place rather than a bare `fileExists` at each of the two call sites —
  /// `status` below and `ClientDetail.read()` — because both have to answer the
  /// same way under a capture, and a guard on one of them is a guard on
  /// neither.
  static func hasConfig(_ client: Client) -> Bool {
    if DemoSeed.isEnabled { return true }
    return FileManager.default.fileExists(atPath: client.configURL.path)
  }

  static func read(_ client: Client) throws -> Config {
    // The fixture, and never the developer's own file. This is the single worst
    // leak in the set: `ClientDetail` renders every foreign entry's argv — which
    // routinely holds a token — and one heading per project folder, which
    // routinely holds a client's name.
    if DemoSeed.isEnabled { return DemoSeed.config(for: client) }
    switch client.format {
    case .json:
      let root = try ClientWiringMerge.readJSON(client.configURL)
      return Config(
        servers: root[client.rootKey] as? [String: Any] ?? [:], root: root, disabled: [])
    case .toml:
      let document = try ClientWiringTOML.read(client.configURL)
      return Config(servers: document.servers, root: nil, disabled: document.disabled)
    }
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
    guard hasConfig(client) else { return .audited(.notConfigured) }
    let config: Config
    do {
      config = try read(client)
    } catch {
      return .unreadable(error.localizedDescription)
    }
    let servers = config.servers
    let keys = keys(for: profiles)
    let expected = profiles.compactMap {
      profile -> (key: String, reach: ClientWiringMerge.Reach, label: String)? in
      guard let key = keys[profile] else { return nil }
      return (key, reach(for: profile, transport: client.transport), profile.serverID)
    }
    return .audited(ClientWiringMerge.audit(servers: servers, expected: expected))
  }

  // MARK: - Writing

  /// Run a read-modify-write again if the file changed underneath it.
  ///
  /// Wrapping the whole operation and not just the write is what makes the
  /// retry correct rather than merely repeated: the second pass re-reads, and
  /// so re-runs the collision check against the entries that arrived in the
  /// window. A retry that only re-serialised the first pass's merge would write
  /// over exactly the entry it was supposed to notice.
  ///
  /// Twice, not until it succeeds: a file being rewritten faster than this can
  /// read it is not a race to keep entering, and every caller already has
  /// somewhere to put the sentence.
  private static func retryingIfChanged<T>(_ url: URL, _ body: () throws -> T) throws -> T {
    let attempts = 2
    for attempt in 1...attempts {
      do { return try body() } catch ClientWiringMerge.WriteError.changedUnderneath(_)
        where attempt < attempts
      {
        continue
      }
    }
    throw ClientWiringMerge.WriteError.changedUnderneath(url)
  }

  /// `force` overwrites entries Bastion did not write. Off by default, and the
  /// caller has to say so twice — once in the UI, once here — because the thing
  /// being overwritten is a server somebody configured by hand.
  @discardableResult
  static func wire(_ client: Client, profiles: [Profile], force: Bool = false) throws -> URL? {
    try retryingIfChanged(client.configURL) {
      try wireOnce(client, profiles: profiles, force: force)
    }
  }

  private static func wireOnce(_ client: Client, profiles: [Profile], force: Bool) throws -> URL? {
    let keys = keys(for: profiles)
    // Unreachable while the prefix was a constant; reachable the moment it is
    // typed by hand. Refusing beats writing one of the two entries and leaving
    // the other profile silently unwired.
    let duplicates = Dictionary(grouping: keys.values, by: { $0 }).filter { $0.value.count > 1 }
    guard duplicates.isEmpty else { throw WireError.ambiguousKeys(duplicates.keys.sorted()) }

    // One read, whichever format. For TOML the whole document is kept and not
    // just its servers, because the splice quotes the original text back out of
    // it; `root` is the synthetic wrapper that lets the merge below be the same
    // merge every other client gets.
    //
    // The stamp is taken first, before either read, so it describes the bytes
    // this merge is computed from. Every write below is conditional on it.
    let stamp = ClientWiringMerge.stamp(of: client.configURL)
    let exists = stamp != .absent
    var document = ClientWiringTOML.empty
    var root: [String: Any] = [:]
    switch client.format {
    case .toml:
      if exists { document = try ClientWiringTOML.read(client.configURL) }
      root = [client.rootKey: document.servers]
    case .json:
      if exists { root = try ClientWiringMerge.readJSON(client.configURL) }
    }

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
      entries[key] = entry(
        for: profile, transport: client.transport, token: token, format: client.format)
    }

    let merged = ClientWiringMerge.merged(
      into: root, rootKey: client.rootKey, entries: entries)
    let backup: URL?
    switch client.format {
    case .toml:
      backup = try splice(
        client, document, into: servers(merged, client.rootKey), upserting: entries,
        expecting: stamp)
    case .json:
      backup = try ClientWiringMerge.write(
        merged, to: client.configURL, backupSuffix: "bastion-backup", expecting: stamp)
    }
    ClientConfigRevision.shared.bump()
    hostLog(
      "wiring", .info,
      "\(client.displayName): wrote \(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
        + (backup.map { " (backup at \($0.lastPathComponent))" } ?? ""))
    return backup
  }

  @discardableResult
  static func unwire(_ client: Client) throws -> URL? {
    try retryingIfChanged(client.configURL) { try unwireOnce(client) }
  }

  private static func unwireOnce(_ client: Client) throws -> URL? {
    let stamp = ClientWiringMerge.stamp(of: client.configURL)
    guard stamp != .absent else { return nil }
    let backup: URL?
    switch client.format {
    case .toml:
      let document = try ClientWiringTOML.read(client.configURL)
      let stripped = ClientWiringMerge.unmerged(
        from: [client.rootKey: document.servers], rootKey: client.rootKey)
      backup = try splice(
        client, document, into: servers(stripped, client.rootKey), expecting: stamp)
    case .json:
      let root = try ClientWiringMerge.readJSON(client.configURL)
      let stripped = ClientWiringMerge.unmerged(from: root, rootKey: client.rootKey)
      backup = try ClientWiringMerge.write(
        stripped, to: client.configURL, backupSuffix: "bastion-backup", expecting: stamp)
    }
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
    try retryingIfChanged(client.configURL) {
      try removeEntryOnce(key, from: client, inProject: folder)
    }
  }

  private static func removeEntryOnce(
    _ key: String,
    from client: Client,
    inProject folder: String?
  ) throws -> URL? {
    let stamp = ClientWiringMerge.stamp(of: client.configURL)
    guard stamp != .absent else { return nil }
    let backup: URL?
    switch client.format {
    case .toml:
      // Through `removing` rather than around it. Its refusal of a key `isOurs`
      // claims is what keeps this door and `unwire`'s from doing each other's
      // job, and that has to have exactly one implementation.
      let document = try ClientWiringTOML.read(client.configURL)
      let stripped = ClientWiringMerge.removing(
        key: key, from: [client.rootKey: document.servers], rootKey: client.rootKey)
      backup = try splice(
        client, document, into: servers(stripped, client.rootKey), expecting: stamp)
    case .json:
      let root = try ClientWiringMerge.readJSON(client.configURL)
      let stripped =
        folder.map { ClientWiringMerge.removing(key: key, inProject: $0, from: root) }
        ?? ClientWiringMerge.removing(key: key, from: root, rootKey: client.rootKey)
      backup = try ClientWiringMerge.write(
        stripped, to: client.configURL, backupSuffix: "bastion-backup", expecting: stamp)
    }
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

  // MARK: - Writing TOML

  /// The TOML half of a write, in one rule: run the same dictionary policy the
  /// JSON clients run, diff what it did, and splice the difference.
  ///
  /// Deriving the change from `ClientWiringMerge`'s own output rather than
  /// re-deciding it here is what keeps this from being a second implementation
  /// of the rules that matter -- the rename cleanup, the refusal to sweep up
  /// another profile's entry, the refusal to remove one of ours through the
  /// wrong door. There is one implementation and this reads its answer.
  private static func splice(
    _ client: Client,
    _ document: ClientWiringTOML.Document,
    into after: [String: Any],
    upserting entries: [String: [String: Any]] = [:],
    expecting: ClientWiringMerge.Stamp? = nil
  ) throws -> URL? {
    let removed = Set(document.tables.keys).subtracting(after.keys)
    let text = ClientWiringTOML.spliced(document, removing: removed, upserting: entries)
    // A write that changes nothing is still a write to somebody else's file:
    // a new backup, a new mtime, and a client told to restart for no reason.
    guard text != document.text else { return nil }
    return try ClientWiringMerge.write(
      Data(text.utf8), to: client.configURL, backupSuffix: "bastion-backup", expecting: expecting)
  }

  /// The servers dictionary a merge produced, unwrapped from its synthetic root.
  private static func servers(_ root: [String: Any], _ key: String) -> [String: Any] {
    root[key] as? [String: Any] ?? [:]
  }
}
