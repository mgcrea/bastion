import Foundation
import MCPKitWiring

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

  // `WiringFile.readJSON`, swift-mcp-kit's: an empty file looked at twice, and a root that is
  // not an object refused by name. It was this file's until the kit took the I/O.

  /// A file's bytes, looked at twice when the first read finds it empty: a client mid-write
  /// truncates before it fills, and an empty read written back replaces the whole file.
  /// `WiringFile` keeps its own to itself; `settings.json`, which is Bastion's alone to
  /// splice, reads through this one.
  static func settledContents(of url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard data.isEmpty else { return data }
    Thread.sleep(forTimeInterval: 0.25)
    return try Data(contentsOf: url)
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

    for (key, entry) in entries {
      servers[key] = overlaid(entry, on: servers[key])
    }
    root[rootKey] = servers
    return root
  }

  /// `entry`, written at a key that currently holds `existing`.
  ///
  /// Over an entry that is already ours, only what Bastion owns is replaced.
  /// Rewires run unattended on every profile save, and replacing the whole
  /// entry switched a server the user had turned off in their client
  /// (`disabled`, `enabled = false`) back on and dropped any timeout they had
  /// set. Anything else at this key — somebody's own server — is replaced
  /// whole, as before; `wire` has already refused that unless the user forced
  /// it. `merged` and `reconciledProjects` both write through here.
  private static func overlaid(_ entry: [String: Any], on existing: Any?) -> [String: Any] {
    guard let existing = existing as? [String: Any], isOurs(existing) else { return entry }
    // The keys of the three shapes `entry` builds, swift-mcp-kit's list: dropped before the
    // new entry is laid over the old, so switching transport leaves no key of the old shape.
    return existing.filter { !WiringMerge.ownedKeys.contains($0.key) }
      .merging(entry) { _, new in new }
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
  /// Written as an explicit read-modify-write of two nested dictionaries rather
  /// than anything clever: Swift dictionaries are value types, and the obvious
  /// `root["projects"]![folder]!["mcpServers"]` chain edits copies and changes
  /// nothing, a write that appears to succeed.
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

  // The stamp, the guard against a file changed underneath, the backup at 0600 and the
  // swap are `WiringFile`'s, swift-mcp-kit's. What stays here is the JSON comparison below.

  /// `root`, serialised and written through `WiringFile.write`, unless the file already holds
  /// the same values.
  ///
  /// The file on disk was last written by its client, in its own formatting, so its bytes
  /// never equal these even when nothing changed, and a byte comparison would back it up and
  /// rewrite it on every unattended rewire. Compared as this would write it instead.
  @discardableResult
  static func write(
    _ root: [String: Any],
    to url: URL,
    backupSuffix: String,
    expecting: WiringFile.Stamp? = nil
  ) throws -> URL? {
    let options: JSONSerialization.WritingOptions = [
      .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    let data = try JSONSerialization.data(withJSONObject: root, options: options)
    if let expecting, WiringFile.stamp(of: url) != expecting {
      throw WiringFile.WriteError.changedUnderneath(url)
    }
    if let current = try? Data(contentsOf: url.resolvingSymlinksInPath()),
      let parsed = try? JSONSerialization.jsonObject(with: current),
      (try? JSONSerialization.data(withJSONObject: parsed, options: options)) == data
    {
      return nil
    }
    return try WiringFile.write(
      data, to: url, backupSuffix: backupSuffix, expecting: expecting)
  }

  /// `entries`, each laid over the Codex block of ours it replaces, so the user's own keys
  /// come through a rewire: `enabled = false`, a timeout, a tool list.
  ///
  /// The TOML half of `overlaid`. Our block is re-rendered rather than edited in place, so
  /// what is carried has to be something the scanner read and the renderer can write back;
  /// swift-mcp-kit's `WiringTOML.checkCarriable` refuses, by line, a block that would lose
  /// anything else. A block that is not ours is not merged into: it is replaced whole, which
  /// `wire` has already refused unless forced.
  static func carried(
    _ document: WiringTOML.Document, upserting entries: [String: [String: Any]]
  ) throws -> [String: [String: Any]] {
    var out: [String: [String: Any]] = [:]
    for (name, entry) in entries {
      guard let table = document.tables[name], isOurs(table.value) else {
        out[name] = entry
        continue
      }
      let merged = table.value.filter { !WiringMerge.ownedKeys.contains($0.key) }
        .merging(entry) { _, new in new }
      // The new entry, not `merged`: the merged one holds the user's readable keys too, and
      // a readable `tools.get_shop` would wave through the `tools.timeout = 1.5` beside it.
      try WiringTOML.checkCarriable(document, name: name, entry: entry)
      out[name] = merged
    }
    return out
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

  /// Make Bastion's entries in every project block exactly `desired`.
  ///
  /// `desired` maps a project key to the entries that belong there. Every block
  /// that is either desired or already holds an entry `isOurs` claims is
  /// visited: desired entries are written, entries of ours not desired there
  /// are removed, and nothing else in the block changes. Every other block is
  /// left alone.
  ///
  /// No ledger of past writes, on purpose. `isOurs` is the ledger here as it is
  /// for the global block, so a folder, a profile or a whole workspace taken
  /// away cleans up by itself. A block this empties keeps its `mcpServers: {}`
  /// rather than being deleted, because Claude Code may have filed other fields
  /// under that folder.
  static func reconciledProjects(
    _ root: [String: Any], desired: [String: [String: [String: Any]]]
  ) -> [String: Any] {
    var projects = root["projects"] as? [String: Any] ?? [:]
    var folders = Set(desired.keys)
    for (folder, block) in projects {
      let servers = (block as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
      if servers.values.contains(where: { isOurs($0) }) { folders.insert(folder) }
    }
    guard !folders.isEmpty else { return root }

    var root = root
    for folder in folders {
      var project = projects[folder] as? [String: Any] ?? [:]
      var servers = project["mcpServers"] as? [String: Any] ?? [:]
      let wanted = desired[folder] ?? [:]
      for (key, entry) in servers where isOurs(entry) && wanted[key] == nil {
        servers.removeValue(forKey: key)
      }
      for (key, entry) in wanted {
        // `merged`'s rule, so `disabled` or a timeout the user set survives.
        servers[key] = overlaid(entry, on: servers[key])
      }
      project["mcpServers"] = servers
      projects[folder] = project
    }
    root["projects"] = projects
    return root
  }

  /// `collisions`, asked of every project block Bastion is about to write. Each
  /// answer names its folder, because the same key can be foreign in one
  /// repository and free in the next.
  static func projectCollisions(
    in root: [String: Any], keys: [String: [String]]
  ) -> [String] {
    keys.keys.sorted().flatMap { folder -> [String] in
      let servers = projectScopeServers(in: root, folder: folder) ?? [:]
      return collisions(servers: servers, keys: keys[folder] ?? []).map { "\(folder): \($0)" }
    }
  }

  /// Keys two profiles would both be written under, per project folder, as
  /// `<folder>: <key>`, sorted. The project-block counterpart to the global
  /// block's refusal in `ClientWiring.wireOnce`: writing one of the two and
  /// silently dropping the other is worse than refusing, and here the one
  /// kept used to be whichever a dictionary yielded first.
  static func ambiguousKeys(_ keys: [String: [String]]) -> [String] {
    keys.keys.sorted().flatMap { folder -> [String] in
      let counts = Dictionary(grouping: keys[folder] ?? [], by: { $0 })
      return counts.filter { $0.value.count > 1 }.keys.sorted().map { "\(folder): \($0)" }
    }
  }

  /// Whether any project block holds an entry `isOurs` claims.
  static func hasOurProjectEntries(_ root: [String: Any]) -> Bool {
    guard let projects = root["projects"] as? [String: Any] else { return false }
    return projects.values.contains { block in
      ((block as? [String: Any])?["mcpServers"] as? [String: Any])?.values
        .contains(where: { isOurs($0) }) == true
    }
  }
}
