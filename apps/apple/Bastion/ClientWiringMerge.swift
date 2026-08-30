import Foundation

/// The part of client wiring that touches somebody else's file, with the app
/// taken out of it: no AppKit, no `ServerCatalog`, no `Bundle`, no logging.
///
/// That subtraction is the point. `make wiring-check` compiles this one file
/// beside `scripts/wiring-check.swift` and runs the result, which is the whole
/// test story for a project with no test target. Everything policy-shaped —
/// which clients exist, where their configs live, which key they get — stays in
/// `ClientWiring`, which can keep importing AppKit.
///
/// The stakes are concrete. `~/.claude.json` on the machine this was written on
/// holds nine global MCP servers and ninety-eight project blocks; Claude
/// Desktop's config carries seven entries plus `coworkUserFilesPath` and
/// `preferences`. Every one of those has to survive a write that adds one key.
enum ClientWiringMerge {
  /// The tail of every bridge `command` this app has ever written.
  static let bridgeSuffix = "/Contents/Helpers/bastion-bridge"

  /// How a client reaches Bastion. Two shapes, because clients differ: one that
  /// understands a URL needs nothing else, and one that only spawns processes
  /// needs the bridge.
  enum Reach: Equatable {
    /// `type: http` with a loopback URL and a bearer header.
    case http(url: String)
    /// The embedded bridge, spawned with `--profile=` and `--server=`.
    case bridge(command: String, args: [String])

    /// The one field that says where an entry points, for comparing a config
    /// against what it should be. A URL and a command are not interchangeable,
    /// so an entry of the wrong SHAPE is stale too — which is exactly what a
    /// config wired before the bridge existed looks like.
    var identity: String {
      switch self {
      case .http(let url): return url
      case .bridge(let command, _): return command
      }
    }
  }

  // MARK: - Reading

  enum ReadError: LocalizedError {
    case notJSONObject(URL)

    var errorDescription: String? {
      switch self {
      case .notJSONObject(let url):
        return "\(url.lastPathComponent) is not a JSON object; leaving it alone"
      }
    }
  }

  static func readJSON(_ url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    if data.isEmpty { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ReadError.notJSONObject(url)
    }
    return object
  }

  /// Where an existing entry points, whichever shape it is.
  static func identity(of entry: Any?) -> String? {
    guard let entry = entry as? [String: Any] else { return nil }
    if let command = entry["command"] as? String { return command }
    if let url = entry["url"] as? String { return url }
    return nil
  }

  /// Whether an entry is one this app wrote, wherever the bundle was at the
  /// time.
  ///
  /// Deliberately not compared against the CURRENT bridge path or port: an
  /// entry left by a copy that has since moved is exactly the one worth
  /// cleaning up, and refusing to recognise it would leave a dead entry in
  /// somebody's config forever.
  ///
  /// For the HTTP shape the marker is the endpoint grammar itself —
  /// `http://<loopback>:<port>/s/<profile>/<server>` — because there is no
  /// command path to recognise. Narrow on purpose: a loopback URL that is not
  /// exactly two path segments under `/s/` is somebody else's local server, and
  /// this has no business rewriting it.
  static func isOurs(_ entry: Any?) -> Bool {
    guard let identity = identity(of: entry) else { return false }
    if identity.hasSuffix(bridgeSuffix) { return true }
    guard let url = URLComponents(string: identity), let host = url.host else { return false }
    guard ["127.0.0.1", "localhost", "::1"].contains(host) else { return false }
    let segments = url.path.split(separator: "/", omittingEmptySubsequences: true)
    return segments.count == 3 && segments[0] == "s"
  }

  // MARK: - Merging

  /// Merge our servers in, leaving everything else untouched.
  ///
  /// `entries` maps server key to the entry to write. `legacy` maps a current
  /// key to one it replaces, removed only when `isOurs` says we wrote it — a
  /// third-party server that happens to be called `shopify` is someone else's
  /// entry, and this has no business removing it. That case is not theoretical
  /// here: the migration in step 5 deliberately kept the user's own key names,
  /// so `shopify` in a config may be Bastion's or may predate it.
  static func merged(
    into root: [String: Any],
    rootKey: String,
    entries: [String: [String: Any]],
    legacy: [String: String]
  ) -> [String: Any] {
    var root = root
    var servers = root[rootKey] as? [String: Any] ?? [:]
    for (key, entry) in entries {
      servers[key] = entry
      if let previous = legacy[key], previous != key, isOurs(servers[previous]) {
        servers.removeValue(forKey: previous)
      }
    }
    root[rootKey] = servers
    return root
  }

  /// Remove every entry this app wrote, and nothing else.
  ///
  /// The counterpart to `merged`, and the reason `isOurs` is narrow: unwiring
  /// must not be a way to delete a config.
  static func unmerged(from root: [String: Any], rootKey: String) -> [String: Any] {
    var root = root
    guard var servers = root[rootKey] as? [String: Any] else { return root }
    for (key, entry) in servers where isOurs(entry) {
      servers.removeValue(forKey: key)
    }
    root[rootKey] = servers
    return root
  }

  // MARK: - Auditing

  /// What a status check concludes from a servers object alone.
  ///
  /// Deliberately not `ClientWiring.Status`: the cases missing here —
  /// `notInstalled`, `unreadable` — are facts about I/O, and this file does
  /// none it was not handed a URL for.
  enum Audit: Equatable {
    case configured
    case notConfigured
    /// Present, but pointing somewhere else — a previous build, a different
    /// port, or the other transport.
    case stale(String)
    /// Wired for some servers and not others — what an existing config looks
    /// like the day a new profile is added.
    case incomplete([String])
  }

  /// `expected` is the server key paired with where it should point and the
  /// human label to name in `.incomplete`, in the order the labels should read.
  static func audit(
    servers: [String: Any],
    expected: [(key: String, reach: Reach, label: String)]
  ) -> Audit {
    var missing: [String] = []
    for item in expected {
      guard let entry = servers[item.key] as? [String: Any] else {
        missing.append(item.label)
        continue
      }
      if identity(of: entry) != item.reach.identity {
        return .stale(identity(of: entry) ?? "unknown")
      }
    }
    // A partially wired config must not report `.configured`. Treating any one
    // matching entry as enough is what made a newly added server invisible to
    // everyone who had already configured the client — a green check beside a
    // config that would never gain it.
    if missing.count == expected.count { return .notConfigured }
    return missing.isEmpty ? .configured : .incomplete(missing)
  }

  // MARK: - Writing

  /// Backup, atomic temp, swap. Returns the backup URL if one was made.
  ///
  /// Three properties this has to hold, because the file belongs to someone
  /// else: every unrelated key survives, the previous contents are
  /// recoverable, and a crash mid-write cannot leave a truncated config.
  @discardableResult
  static func write(_ root: [String: Any], to url: URL, backupSuffix: String) throws -> URL? {
    let fm = FileManager.default
    var backup: URL?

    if fm.fileExists(atPath: url.path) {
      backup = url.appendingPathExtension(backupSuffix)
      try? fm.removeItem(at: backup!)
      try fm.copyItem(at: url, to: backup!)
    } else {
      try fm.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    let data = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

    // Write beside the target, then swap: a config half-written because the
    // machine slept is worse than one not written at all.
    let temp = url.deletingLastPathComponent()
      .appendingPathComponent(".bastion-\(UUID().uuidString).tmp")
    try data.write(to: temp, options: .atomic)
    do {
      _ = try fm.replaceItemAt(url, withItemAt: temp)
    } catch {
      // `replaceItemAt` consumes the temp on success only. A failure here would
      // otherwise leave a dotfile in someone's config directory forever.
      try? fm.removeItem(at: temp)
      throw error
    }
    // The file now carries a bearer token. It did not necessarily before.
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return backup
  }

  /// The servers a Claude Code **project**-scope entry holds for one folder.
  ///
  /// Two shapes mean two different things and must not collapse into one: `nil`
  /// is "this folder has no entry at all", while an empty dictionary is "Claude
  /// Code knows this folder and no Bastion server is in it". The first is a
  /// folder nobody has wired; the second was wired and then emptied, or wired
  /// for a different tool. `audit` gives a useful answer for the second and a
  /// misleading one for the first.
  static func projectScopeServers(in root: [String: Any], folder: String) -> [String: Any]? {
    guard let projects = root["projects"] as? [String: Any] else { return nil }
    guard let entry = projects[folder] as? [String: Any] else { return nil }
    return entry["mcpServers"] as? [String: Any] ?? [:]
  }

  /// Merge into one folder's project scope, leaving the other ninety-seven
  /// alone.
  ///
  /// Written as an explicit read-modify-write of two nested dictionaries rather
  /// than anything clever, because Swift dictionaries are value types and the
  /// obvious `root["projects"]![folder]!["mcpServers"]` chain silently operates
  /// on copies. The bug that produces is a write that appears to succeed and
  /// changes nothing.
  static func mergedIntoProject(
    _ root: [String: Any],
    folder: String,
    entries: [String: [String: Any]],
    legacy: [String: String]
  ) -> [String: Any] {
    var root = root
    var projects = root["projects"] as? [String: Any] ?? [:]
    var project = projects[folder] as? [String: Any] ?? [:]
    project = merged(into: project, rootKey: "mcpServers", entries: entries, legacy: legacy)
    projects[folder] = project
    root["projects"] = projects
    return root
  }
}
