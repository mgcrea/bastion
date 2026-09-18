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

  /// What an entry reaches, as distinct from `identity(of:)`, which says where
  /// it points.
  ///
  /// This pair is what survives a rename. The key an entry is filed under is the
  /// user's to choose — the prefix is a setting — while the profile and server
  /// it serves are not. That makes "this entry is the old name of that one" a
  /// fact about the endpoint rather than a guess about naming conventions,
  /// which is the whole reason `merged` can clean up after a prefix change.
  ///
  /// `nil` for anything this app did not write, so it can never claim somebody
  /// else's entry is a stale copy of one of ours.
  static func target(of entry: Any?) -> (profile: String, server: String)? {
    guard let entry = entry as? [String: Any] else { return nil }

    if let command = entry["command"] as? String, command.hasSuffix(bridgeSuffix) {
      let args = entry["args"] as? [String] ?? []
      func value(_ flag: String) -> String? {
        guard let match = args.first(where: { $0.hasPrefix(flag) }) else { return nil }
        let value = String(match.dropFirst(flag.count))
        return value.isEmpty ? nil : value
      }
      guard let profile = value("--profile="), let server = value("--server=") else { return nil }
      return (profile, server)
    }

    // `isOurs` has already established the grammar for the HTTP shape — loopback
    // host, exactly `/s/<profile>/<server>` — so this only has to read it.
    guard isOurs(entry), let url = entry["url"] as? String,
      let path = URLComponents(string: url)?.path
    else { return nil }
    let segments = path.split(separator: "/", omittingEmptySubsequences: true)
    guard segments.count == 3, segments[0] == "s" else { return nil }
    return (String(segments[1]), String(segments[2]))
  }

  /// An entry in a client config that this app did not write.
  ///
  /// `identity` is `nil` for a shape carrying neither `command` nor `url` —
  /// something hand-written and malformed, or a key holding a string. Listing it
  /// anyway is deliberate: it is in the file, it is not ours, and a view that
  /// silently skipped it would be lying about what the file holds.
  struct ForeignEntry: Equatable {
    let key: String
    let identity: String?
  }

  /// Everything under a servers object that `isOurs` does not claim.
  ///
  /// The counterpart to `collisions`, which only looks at the keys Bastion is
  /// about to write. This looks at all of them, because the interesting question
  /// for somebody adopting Bastion is not "what is in my way" but "what is still
  /// bypassing it".
  static func foreignEntries(in servers: [String: Any]) -> [ForeignEntry] {
    servers
      .compactMap { key, entry in
        isOurs(entry) ? nil : ForeignEntry(key: key, identity: identity(of: entry))
      }
      .sorted { $0.key < $1.key }
  }

  /// The same question asked of every **project** block.
  ///
  /// Claude Code keeps a servers object per folder as well as one global one,
  /// and on a machine that has been using MCP for a while that is where most of
  /// the un-migrated servers actually live — ninety-eight folders in the file
  /// this was written against. Folders with nothing foreign in them are dropped
  /// rather than listed empty.
  static func foreignProjectEntries(
    in root: [String: Any]
  ) -> [(folder: String, entries: [ForeignEntry])] {
    guard let projects = root["projects"] as? [String: Any] else { return [] }
    return projects.keys.sorted().compactMap { folder in
      guard let servers = projectScopeServers(in: root, folder: folder) else { return nil }
      let entries = foreignEntries(in: servers)
      return entries.isEmpty ? nil : (folder, entries)
    }
  }

  /// An entry Bastion wrote that no profile serves any more.
  ///
  /// `endpoint` is the `<profile>/<server>` it points at, and `nil` for an entry
  /// of ours that names none — a bridge entry whose `--profile=`/`--server=`
  /// args cannot be read. Listing that one anyway is the same judgement
  /// `ForeignEntry` makes about a malformed shape: it is in the file, nothing
  /// can repair it, and a view that skipped it would be lying about what the
  /// file holds.
  struct StaleEntry: Equatable {
    let key: String
    let endpoint: String?
  }

  /// Entries of ours pointing at a profile that no longer exists.
  ///
  /// The third question to ask of a servers object, after `collisions` ("what is
  /// in my way") and `foreignEntries` ("what is still bypassing Bastion"): what
  /// did Bastion leave behind. Until this existed the answer was invisible in
  /// the pane — `isOurs` claims these, so `foreignEntries` does not list them,
  /// and no profile matches them, so they get no row of their own either.
  ///
  /// `serving` is every `<profile>/<server>` that currently exists, passed in
  /// rather than read so this file goes on importing nothing but Foundation.
  /// It must be built from EVERY profile and not only the ones on enabled
  /// servers: a switched-off server's profile still exists, and treating its
  /// entries as stale would delete a correct config the moment somebody flipped
  /// a switch.
  ///
  /// Three things it deliberately does not claim, because each has a remedy of
  /// its own and deleting the entry would be throwing away a working one:
  /// an entry filed under a key the current scheme would not write (`merged`
  /// renames it), an entry pointing at a stale host or port (`state` reports it
  /// and Configure rewrites it), and anything `isOurs` does not claim.
  static func staleEntries(in servers: [String: Any], serving: Set<String>) -> [StaleEntry] {
    servers
      .compactMap { key, entry -> StaleEntry? in
        guard isOurs(entry) else { return nil }
        guard let endpoint = endpoint(of: entry) else { return StaleEntry(key: key, endpoint: nil) }
        return serving.contains(endpoint) ? nil : StaleEntry(key: key, endpoint: endpoint)
      }
      .sorted { $0.key < $1.key }
  }

  /// Of the keys we are about to write, the ones already taken by an entry this
  /// app did not write.
  ///
  /// The whole collision feature rests on this. Bastion used to prefix every key
  /// with `bastion-` and call the problem solved, which made the defence a
  /// naming convention rather than a check — and left it with nothing to say the
  /// day somebody turned the prefix off.
  static func collisions(servers: [String: Any], keys: [String]) -> [String] {
    keys.filter { servers[$0] != nil && !isOurs(servers[$0]) }.sorted()
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
  /// `entries` maps the key to write to the entry to write there. A key the
  /// config already holds is removed when all three are true: we wrote it, it
  /// reaches one of the profile/server pairs being written now, and it is not
  /// itself one of the new keys. That is the same entry under its old name, and
  /// removing it is what leaves a rename with one entry rather than two pointing
  /// at the same endpoint.
  ///
  /// Deciding that from `target(of:)` rather than from a passed-in list of
  /// previous names is what makes the key prefix safe to change at all — a list
  /// can only hold the renames somebody thought of. It still covers the one it
  /// replaces: the step-5 migration deliberately kept the user's own key names,
  /// so a bare `shopify` in a config may be Bastion's. A third-party `shopify`
  /// is left alone, because `isOurs` never claims it.
  ///
  /// `retiring` names profile/server pairs that are gone rather than renamed —
  /// a deleted profile, whose entry no endpoint being written will ever match.
  /// It has to be passed in: every other entry this removes is recognised by
  /// colliding with something in `entries`, and a profile that no longer exists
  /// produces no entry to collide with. Without it a removed profile would
  /// leave a key pointing at an endpoint the gateway has stopped serving, which
  /// is worse than the stale-but-working entry the rename case used to leave.
  static func merged(
    into root: [String: Any],
    rootKey: String,
    entries: [String: [String: Any]],
    retiring: Set<String> = []
  ) -> [String: Any] {
    var root = root
    var servers = root[rootKey] as? [String: Any] ?? [:]

    let written = Set(entries.values.compactMap { endpoint(of: $0) })
    for (key, entry) in servers where entries[key] == nil {
      guard let endpoint = endpoint(of: entry) else { continue }
      guard written.contains(endpoint) || retiring.contains(endpoint) else { continue }
      servers.removeValue(forKey: key)
    }

    for (key, entry) in entries { servers[key] = entry }
    root[rootKey] = servers
    return root
  }

  /// `target(of:)` flattened to something hashable, for comparing entries.
  ///
  /// Safe as a string join because both halves are validated names: a profile
  /// name is `^[a-z0-9][a-z0-9-]*$` and a server id is a path segment, so
  /// neither can contain the separator.
  private static func endpoint(of entry: Any?) -> String? {
    target(of: entry).map { "\($0.profile)/\($0.server)" }
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

  /// Remove one named entry, and nothing else.
  ///
  /// Deliberately refuses a key `isOurs` claims. Taking Bastion's own entries
  /// out is `unmerged`, which knows about the whole set; this is the path for a
  /// server somebody configured by hand and has since moved into Bastion, and
  /// the two must not be reachable from each other. A key that is absent, or
  /// that turns out to be ours because the file changed under the caller, is a
  /// no-op rather than an error — there is nothing to undo and nothing to say.
  static func removing(key: String, from root: [String: Any], rootKey: String) -> [String: Any] {
    var root = root
    guard var servers = root[rootKey] as? [String: Any] else { return root }
    guard let entry = servers[key], !isOurs(entry) else { return root }
    servers.removeValue(forKey: key)
    // Assigned back even when this empties it: an absent `mcpServers` and an
    // empty one are different statements, and `projectScopeServers` reads the
    // difference.
    root[rootKey] = servers
    return root
  }

  /// Remove every entry of ours that no profile serves, and nothing else.
  ///
  /// The third door, and the two beside it are the reason it has to be its own
  /// function rather than a flag on one of them: `unmerged` takes out every
  /// entry of ours regardless of whether it works, and `removing(key:)` refuses
  /// a key `isOurs` claims. Neither can express "ours, and dead", so a caller
  /// reaching for this through either of them would be reaching for the wrong
  /// behaviour.
  ///
  /// A no-op when nothing is stale — the dictionary comes back equal, which is
  /// what lets `write` refuse it and keeps the button from rotating a backup of
  /// a file it had nothing to change in.
  static func removingStale(
    from root: [String: Any],
    rootKey: String,
    serving: Set<String>
  ) -> [String: Any] {
    var root = root
    guard var servers = root[rootKey] as? [String: Any] else { return root }
    for entry in staleEntries(in: servers, serving: serving) {
      servers.removeValue(forKey: entry.key)
    }
    root[rootKey] = servers
    return root
  }

  /// The same, inside one project block, leaving the other ninety-seven alone.
  ///
  /// Written as an explicit read-modify-write for the reason `mergedIntoProject`
  /// spells out: Swift dictionaries are value types, and the obvious nested
  /// subscript chain edits copies and changes nothing.
  static func removing(
    key: String,
    inProject folder: String,
    from root: [String: Any]
  ) -> [String: Any] {
    var root = root
    guard var projects = root["projects"] as? [String: Any],
      let project = projects[folder] as? [String: Any]
    else { return root }
    projects[folder] = removing(key: key, from: project, rootKey: "mcpServers")
    root["projects"] = projects
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
    /// The keys Bastion would write are taken by entries somebody else wrote.
    /// Not a state to fix by writing: it is the one case where writing is the
    /// damage.
    case collides([String])
  }

  /// What is under **one** key, against what should be.
  ///
  /// `Audit` is this reduced over every expected entry, and a pane that shows a
  /// row per entry needs the un-reduced form: a header reading "points elsewhere
  /// — http://127.0.0.1:8719/s/prod/shopify" over four identical-looking rows
  /// says nothing about which of the four it means.
  ///
  /// The two failure cases stay apart for the same reason they do in `Audit`.
  /// `.stale` is an entry of ours that has drifted and the remedy is to write
  /// over it; `.foreign` is somebody else's server and writing over it is the
  /// damage.
  enum EntryState: Equatable {
    /// No entry under that key — or something there that is not an object at
    /// all, which nothing downstream could read as a server anyway.
    case missing
    /// Ours, pointing where it should.
    case matches
    /// Ours, pointing somewhere else: a previous build, a different port, or
    /// the other transport. Carries where it points now.
    case stale(String)
    /// Present and not ours. Carries where it points, or `nil` for a shape with
    /// neither a `command` nor a `url`.
    case foreign(String?)
  }

  static func state(of servers: [String: Any], key: String, reach: Reach) -> EntryState {
    guard let entry = servers[key] as? [String: Any] else { return .missing }
    guard isOurs(entry) else { return .foreign(identity(of: entry)) }
    // `isOurs` has already established there is an identity to read, so the
    // fallback is unreachable; it is here so this cannot return `.matches` for
    // an entry it could not actually compare.
    let here = identity(of: entry) ?? "unknown"
    return here == reach.identity ? .matches : .stale(here)
  }

  /// `expected` is the server key paired with where it should point and the
  /// human label to name in `.incomplete`, in the order the labels should read.
  static func audit(
    servers: [String: Any],
    expected: [(key: String, reach: Reach, label: String)]
  ) -> Audit {
    audit(
      states: expected.map {
        (key: $0.key, label: $0.label, state: state(of: servers, key: $0.key, reach: $0.reach))
      })
  }

  /// The same conclusion from states already computed.
  ///
  /// Split out so a view that draws a badge per entry and the sentence in its
  /// header are two renderings of one computation rather than two
  /// implementations of one rule — which is how they end up disagreeing about a
  /// file neither of them owns.
  static func audit(states: [(key: String, label: String, state: EntryState)]) -> Audit {
    var missing: [String] = []
    var collisions: [String] = []
    var stale: String?
    for item in states {
      switch item.state {
      case .missing:
        missing.append(item.label)
      // Present, but not ours. Calling that `.stale` would describe somebody
      // else's server as a drifted copy of one of ours, and the remedy for
      // stale — write over it — is exactly the wrong move here.
      case .foreign:
        collisions.append(item.key)
      case .stale(let where_):
        if stale == nil { stale = where_ }
      case .matches:
        break
      }
    }
    // Outranks everything below: a config that would clobber an entry is worth
    // saying before a config that is merely out of date or half-written.
    if !collisions.isEmpty { return .collides(collisions.sorted()) }
    if let stale { return .stale(stale) }
    // A partially wired config must not report `.configured`. Treating any one
    // matching entry as enough is what made a newly added server invisible to
    // everyone who had already configured the client — a green check beside a
    // config that would never gain it.
    if missing.count == states.count { return .notConfigured }
    return missing.isEmpty ? .configured : .incomplete(missing)
  }

  // MARK: - Writing

  enum WriteError: LocalizedError {
    /// The file moved on between the read and the swap, so the merge in hand
    /// was computed from bytes that are no longer there.
    case changedUnderneath(URL)

    var errorDescription: String? {
      switch self {
      case .changedUnderneath(let url):
        return "\(url.lastPathComponent) changed while it was being read; nothing was written"
      }
    }
  }

  /// What a config looked like when the caller read it, so a write can refuse to
  /// land a merge computed from bytes somebody has since replaced.
  ///
  /// The stakes here are not the ones the backup covers. Bastion's entries carry
  /// a bearer token, so a write that loses the race does not leave a server
  /// merely missing — it leaves a client reaching the endpoint and failing to
  /// authenticate, which reads as Bastion being broken. And one of the five
  /// configs has a documented concurrent writer: the row for `~/.codex/config.toml`
  /// says the ChatGPT app rewrites it on launch.
  ///
  /// Size and modification date rather than a hash of the contents: the question
  /// is only "did anything touch it", which two `stat` fields answer for free.
  ///
  /// `absent` is a state and not an error. A file that does not exist yet is
  /// exactly as legitimate a precondition as one that does — and a config
  /// created in the window between the two is precisely what this is for.
  enum Stamp: Equatable {
    case absent
    case present(size: Int, modified: Date)
  }

  /// `FileManager`, deliberately, and not `URL.resourceValues`: an `NSURL`
  /// caches the values it has already been asked for, so two stamps taken from
  /// the same `URL` around a write come back identical and the precondition this
  /// exists for silently passes.
  static func stamp(of url: URL) -> Stamp {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? Int, let modified = attributes[.modificationDate] as? Date
    else { return .absent }
    return .present(size: size, modified: modified)
  }

  /// Backup, atomic temp, swap. Returns the backup URL if one was made.
  ///
  /// Four properties this has to hold, because the file belongs to someone
  /// else: every unrelated key survives, the previous contents are
  /// recoverable, a crash mid-write cannot leave a truncated config, and a
  /// merge is never landed on bytes it was not computed from.
  ///
  /// The fourth is `expecting`, and it narrows a window rather than closing
  /// one. A mismatch means the file changed since the caller read it, and the
  /// merge in hand would drop that change; `ClientWiring.retryingIfChanged`
  /// re-reads and runs the whole operation again. What no writer can promise is
  /// the last word — a process holding its own copy of the file, Claude Code
  /// for the length of a session or the ChatGPT app on launch, still wins by
  /// writing after us.
  ///
  /// Takes bytes rather than a root object, because the two config formats this
  /// app writes disagree about everything except this. A JSON client's file is
  /// serialised from a dictionary; Codex's is spliced from the text already on
  /// disk. Backup, atomicity and mode are the same question either way, and
  /// asking it twice is how the second one ends up subtly weaker.
  @discardableResult
  static func write(
    _ data: Data,
    to url: URL,
    backupSuffix: String,
    expecting: Stamp? = nil
  ) throws -> URL? {
    let fm = FileManager.default
    var backup: URL?

    // Before the backup: a write that is not going to happen must not leave a
    // new `.bastion-backup` behind claiming it did.
    if let expecting, stamp(of: url) != expecting { throw WriteError.changedUnderneath(url) }

    // Neither must one that would change nothing. The TOML splice has refused
    // this since it was written — a write to somebody else's file is a new
    // backup, a new mtime and a client told to restart for no reason — and the
    // JSON half wanted the same guard the moment anything started rewiring on
    // its own rather than only when somebody pressed Configure.
    if let current = try? Data(contentsOf: url), current == data { return nil }

    if fm.fileExists(atPath: url.path) {
      backup = url.appendingPathExtension(backupSuffix)
      try? fm.removeItem(at: backup!)
      try fm.copyItem(at: url, to: backup!)
      // Same 0600 the target gets below, and for a stronger reason: a copy
      // inherits the mode of what it copied, so re-wiring a client that was
      // world-readable left a sibling file holding the PREVIOUS bearer token at
      // that mode, indefinitely, where nobody thinks to look for it. The token
      // in it stays valid until it is revoked.
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup!.path)
    } else {
      try fm.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

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
    // A no-op for Codex, whose `config.toml` and `auth.json` are both already
    // `-rw-------`; nothing here loosened them.
    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return backup
  }

  /// The JSON half: serialise, then write the bytes.
  @discardableResult
  static func write(
    _ root: [String: Any],
    to url: URL,
    backupSuffix: String,
    expecting: Stamp? = nil
  ) throws -> URL? {
    try write(
      JSONSerialization.data(
        withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
      to: url, backupSuffix: backupSuffix, expecting: expecting)
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
    entries: [String: [String: Any]]
  ) -> [String: Any] {
    var root = root
    var projects = root["projects"] as? [String: Any] ?? [:]
    var project = projects[folder] as? [String: Any] ?? [:]
    project = merged(into: project, rootKey: "mcpServers", entries: entries)
    projects[folder] = project
    root["projects"] = projects
    return root
  }
}
