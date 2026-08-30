import Foundation
import os

/// The servers this install actually runs.
///
/// `ServerCatalog` is what Bastion *ships with*; this is what somebody *chose*.
/// Everything downstream — the gateway's 404, the supervisor's spawn, the
/// profile store's validation — resolves through here and never through the
/// catalog, which is the one line that keeps "a request cannot name a server
/// you did not install" true.
///
/// ## What is on disk
///
/// `servers.json`, beside `profiles.json`, and it holds one of two shapes per
/// row:
///
/// - a **catalog** row is an id and nothing else, re-resolved against
///   `ServerCatalog.byID` on every load. A definition copied at install time
///   would freeze the day it was installed: a new variable the server started
///   reading, a dialect that finally flipped, a corrected description — none of
///   it would ever reach an install that already existed, and the app would
///   quietly run a year-old idea of what the server needs.
/// - a **custom** row carries the whole definition, because nothing else
///   remembers it.
///
/// A catalog row whose id is gone from the catalog is dropped with a log line
/// rather than repaired. That is a downgrade or a hand-edit, and both are cases
/// where guessing at what was meant is worse than saying so.
///
/// ## What is not on disk
///
/// Whether a server is *installed*. That is a directory on disk, and
/// `ServerInstaller.state(of:)` reads it. A second copy of the same fact in
/// this file would be a copy that can be wrong — a bookkeeping row saying
/// "1.2.0" over a directory somebody deleted — and there is no version of that
/// which fails safely.
@MainActor
@Observable
final class ServerStore {
  static let shared = ServerStore()

  private(set) var servers: [BastionServer] = []

  /// The same list, readable without a hop to the main actor.
  ///
  /// Exactly `ProfileStore`'s reason: the gateway resolves a server on the
  /// connection's own blocking thread, and reaching an `@Observable` array from
  /// there would put a main-thread round trip in the hot path of every single
  /// request — on the same main thread that is drawing the menu.
  ///
  /// Written only from `refreshSnapshot`, which every mutation ends with.
  private nonisolated static let snapshot = OSAllocatedUnfairLock<[String: BastionServer]>(
    initialState: [:])

  /// The gateway's and the supervisor's lookup. A miss is a 404, never a spawn.
  nonisolated static func lookup(_ id: String) -> BastionServer? {
    snapshot.withLock { $0[id] }
  }

  /// Every installed id, for `/health`.
  nonisolated static func installedIDs() -> [String] {
    snapshot.withLock { $0.keys.sorted() }
  }

  private func refreshSnapshot() {
    let table = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
    Self.snapshot.withLock { $0 = table }
  }

  private var fileURL: URL { AppSupport.directory.appendingPathComponent("servers.json") }

  init() { load() }

  func contains(_ id: String) -> Bool { servers.contains { $0.id == id } }

  func server(id: String) -> BastionServer? { servers.first { $0.id == id } }

  /// Catalog entries not installed yet, in catalog order.
  var available: [BastionServer] {
    let installed = Set(servers.map(\.id))
    return ServerCatalog.all.filter { !installed.contains($0.id) }
  }

  // MARK: - Persistence

  /// One row. `definition` present means custom; absent means "look it up".
  private struct Stored: Codable {
    var id: String
    var definition: Definition?
  }

  /// A custom server, as typed. Deliberately not `Codable` on `BastionServer`
  /// itself: that would make every field of the runtime type part of the file
  /// format, including the ones only the catalog is allowed to set.
  struct Definition: Codable, Hashable {
    var displayName: String
    var summary: String
    var npmName: String
    var binName: String
    var docsUrl: String?
    var dialect: String
    var writeGate: String?
    var stateEnv: [String]
    var env: [Variable]

    struct Variable: Codable, Hashable {
      var name: String
      var required: Bool
      var secret: Bool
      var description: String
    }
  }

  func load() {
    guard let data = try? Data(contentsOf: fileURL),
      let rows = try? JSONDecoder().decode([Stored].self, from: data)
    else {
      // No file means an EMPTY LIST, and it means that even for an install
      // that already has profiles. "Ships with nothing installed" is the whole
      // ask, and the first version of this seeded the list from whatever the
      // existing profiles named — which was safe, and still wrong: it put three
      // servers in the sidebar that nobody had chosen in this app, each showing
      // "not installed", which is precisely the preloaded set the change was
      // supposed to remove.
      //
      // Nothing is lost by not doing it. `ProfileStore` sets aside a profile
      // whose server is not installed and keeps its row in `profiles.json`, and
      // installing that server hands the profile straight back. The setup is
      // waiting rather than adopted, which is a state the sidebar can show
      // honestly and an empty list cannot lie about.
      servers = []
      refreshSnapshot()
      return
    }

    var seen = Set<String>()
    servers = rows.compactMap { row -> BastionServer? in
      guard !seen.contains(row.id) else {
        hostLog("servers", .error, "ignoring duplicate server '\(row.id)'")
        return nil
      }
      guard let resolved = Self.resolve(row) else { return nil }
      seen.insert(row.id)
      return resolved
    }
    refreshSnapshot()
  }

  private static func resolve(_ row: Stored) -> BastionServer? {
    guard isValidID(row.id) else {
      hostLog("servers", .error, "ignoring server with unusable id '\(row.id)'")
      return nil
    }
    guard let definition = row.definition else {
      guard let entry = ServerCatalog.byID[row.id] else {
        hostLog(
          "servers", .error,
          "ignoring '\(row.id)' — it is no longer in the catalog this build ships")
        return nil
      }
      return entry
    }
    return make(id: row.id, from: definition)
  }

  /// A stored custom definition becomes a runtime one.
  ///
  /// The fields a custom entry does **not** get to set are the point of this
  /// function existing rather than a decoding initialiser:
  ///
  /// - `distribution` is always `.npm`, because an npm package is the only
  ///   thing a custom entry can name. There is no field for a path and no field
  ///   for an argv, and that is what stops "add a server" from being "run this
  ///   command".
  /// - `gateBypass` is always empty. It is the mechanism for neutralising a
  ///   variable the *manifest* knows about; a user-supplied list of variables
  ///   to force to `"0"` would be a footgun with no upside.
  /// - `authModes` is always empty. A mode set is a claim that some subsets of
  ///   the variables are individually sufficient, which nobody can state for a
  ///   server they are adding by hand — so a custom entry says what is required
  ///   and stops there.
  /// - `callbackEnv` is always empty, for the same reason: Bastion surfaces
  ///   those with a warning it cannot honestly attach to a variable it has not
  ///   seen.
  private static func make(id: String, from definition: Definition) -> BastionServer {
    BastionServer(
      id: id,
      displayName: definition.displayName,
      summary: definition.summary,
      npmName: definition.npmName,
      binName: definition.binName,
      distribution: .npm,
      localPath: "mcp-\(id)",
      docsURL: definition.docsUrl.flatMap(URL.init(string:)),
      dialect: BastionServer.Dialect(rawValue: definition.dialect) ?? .v2025_11_25,
      writeGate: definition.writeGate,
      gateBypass: [],
      authModes: [],
      stateEnv: definition.stateEnv,
      callbackEnv: [],
      env: definition.env.map {
        .init(
          name: $0.name, isRequired: $0.required, isSecret: $0.secret, summary: $0.description)
      },
      origin: .custom)
  }

  private func save() throws {
    refreshSnapshot()
    AppSupport.ensureDirectory()
    let rows = servers.map { server -> Stored in
      switch server.origin {
      case .catalog: Stored(id: server.id, definition: nil)
      case .custom: Stored(id: server.id, definition: Self.definition(of: server))
      }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(rows).write(to: fileURL, options: .atomic)
    // 0o600 explicitly, and after every write: `.atomic` replaces the file, so
    // permissions set once do not survive the next save.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  private static func definition(of server: BastionServer) -> Definition {
    Definition(
      displayName: server.displayName,
      summary: server.summary,
      npmName: server.npmName,
      binName: server.binName,
      docsUrl: server.docsURL?.absoluteString,
      dialect: server.dialect.rawValue,
      writeGate: server.writeGate,
      stateEnv: server.stateEnv,
      env: server.env.map {
        .init(
          name: $0.name, required: $0.isRequired, secret: $0.isSecret, description: $0.summary)
      })
  }

  // MARK: - Editing

  enum StoreError: LocalizedError {
    case duplicateID(String)
    case unusableID(String)
    case unknownCatalogEntry(String)
    case unusablePackage(String)
    case unusableVariable(String)
    case noVariables
    case renameWouldStrand(from: String, to: String, profiles: Int)

    var errorDescription: String? {
      switch self {
      case .duplicateID(let id):
        return "'\(id)' is already in your list"
      case .unusableID(let id):
        return "'\(id)' is not a usable name — lowercase letters, digits and dashes only"
      case .unknownCatalogEntry(let id):
        return "'\(id)' is not in the catalog"
      case .unusablePackage(let name):
        return "'\(name)' is not a usable npm package name"
      case .unusableVariable(let name):
        return "'\(name)' is not a usable environment variable name"
      case .noVariables:
        return "a server needs at least one environment variable"
      case .renameWouldStrand(let from, let to, let profiles):
        return
          "'\(from)' has \(profiles) profile\(profiles == 1 ? "" : "s"). Renaming it to '\(to)' would "
          + "leave \(profiles == 1 ? "it" : "them") behind — the name is part of every profile's "
          + "identity, its endpoint and its Keychain entries. Remove the profile\(profiles == 1 ? "" : "s") "
          + "first, or keep the name."
      }
    }
  }

  /// Same rule as the manifest's, and for the same three reasons: this becomes
  /// a URL path segment, a directory name and a JSON key.
  nonisolated static func isValidID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 64
      && id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
  }

  /// npm's own rule, narrowed: no uppercase, no leading dot or underscore.
  nonisolated static func isValidPackage(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 214
      && name.range(
        of: "^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil
  }

  nonisolated static func isValidVariable(_ name: String) -> Bool {
    name.range(of: "^[A-Z][A-Z0-9_]*$", options: .regularExpression) != nil
  }

  /// Add a catalog entry to the list. Installing its code is a separate step,
  /// so that a failed download leaves a server you can retry rather than
  /// nothing at all.
  func install(catalogEntry id: String) throws {
    guard let entry = ServerCatalog.byID[id] else { throw StoreError.unknownCatalogEntry(id) }
    guard !contains(id) else { throw StoreError.duplicateID(id) }
    servers.append(entry)
    sort()
    try save()
    reclaimProfiles()
    hostLog("servers", .info, "added '\(id)' from the catalog")
  }

  /// Add or replace a custom entry.
  ///
  /// `original` is the id being edited, so that renaming is expressible without
  /// a delete-then-add that would strand the profiles in between.
  func upsert(custom id: String, definition: Definition, replacing original: String? = nil)
    throws
  {
    guard Self.isValidID(id) else { throw StoreError.unusableID(id) }
    guard Self.isValidPackage(definition.npmName) else {
      throw StoreError.unusablePackage(definition.npmName)
    }
    guard !definition.env.isEmpty else { throw StoreError.noVariables }
    for variable in definition.env where !Self.isValidVariable(variable.name) {
      throw StoreError.unusableVariable(variable.name)
    }
    if id != original, contains(id) { throw StoreError.duplicateID(id) }

    // A rename is a new identity, not a new label. `name/server` is the profile
    // id, the URL path, the state directory and the Keychain account prefix, so
    // carrying profiles across one means rewriting all four — and getting it
    // half right means a credential left in the Keychain under a name nothing
    // will ever look up again. Refused rather than attempted, with the count,
    // because silently stranding them is the outcome nobody would notice until
    // a client stopped working.
    if let original, id != original {
      let stranded = ProfileStore.shared.profiles.filter { $0.serverID == original }.count
      guard stranded == 0 else {
        throw StoreError.renameWouldStrand(from: original, to: id, profiles: stranded)
      }
    }

    let made = Self.make(id: id, from: definition)
    if let original, let index = servers.firstIndex(where: { $0.id == original }) {
      servers[index] = made
      // The old id's install is now unreachable — nothing resolves through it —
      // so it goes with the name rather than sitting in Application Support as
      // a directory no code can name.
      if id != original { ServerInstaller.removeInstall(id: original) }
    } else {
      servers.append(made)
    }
    sort()
    try save()
    reclaimProfiles()
    hostLog("servers", .info, "saved custom server '\(id)'")
  }

  /// Remove a server, its profiles, its credentials and its installed code.
  ///
  /// All four together, and that is deliberate. `ProfileStore.load` already
  /// drops a profile naming a server it cannot resolve, so leaving the profiles
  /// behind would not preserve them — it would delete them on the next launch,
  /// silently, without the Keychain sweep that `ProfileStore.remove` does. A
  /// removal that quietly leaks credentials for servers you removed months ago
  /// is the worst version of this, so it happens here, at once, behind a
  /// confirmation that says so.
  func remove(_ server: BastionServer) throws {
    for profile in ProfileStore.shared.profiles where profile.serverID == server.id {
      Supervisor.shared.stop(profile: profile.name, server: server.id)
      try? ProfileStore.shared.remove(profile)
    }
    ServerInstaller.removeInstall(id: server.id)
    servers.removeAll { $0.id == server.id }
    try save()
    hostLog("servers", .info, "removed '\(server.id)' and everything it owned")
  }

  /// Re-read `profiles.json` so profiles waiting on a server just added come
  /// back with it.
  ///
  /// This is the other half of `ProfileStore`'s set-aside rule, and without it
  /// that rule only half works: the rows survive on disk and never return, so
  /// re-adding a server you removed last week looks like it lost your
  /// credentials — which are, in fact, still in the Keychain, waiting for a
  /// profile that is still in the file.
  ///
  /// A reload rather than a targeted move, because `ProfileStore` owns the
  /// partition and duplicating the rule here is how the two come to disagree.
  /// Safe because every mutation in that store saves immediately, so there is
  /// never unsaved state for a reload to discard.
  private func reclaimProfiles() {
    ProfileStore.shared.load()
  }

  /// Catalog order for catalog entries, then custom ones alphabetically.
  ///
  /// Not alphabetical throughout: the catalog is ordered on purpose in
  /// `servers.json`, and re-sorting it here would throw that away for no
  /// reader's benefit.
  private func sort() {
    let rank = Dictionary(
      uniqueKeysWithValues: ServerCatalog.all.enumerated().map { ($0.element.id, $0.offset) })
    servers.sort { a, b in
      switch (rank[a.id], rank[b.id]) {
      case (let x?, let y?): x < y
      case (_?, nil): true
      case (nil, _?): false
      case (nil, nil): a.id < b.id
      }
    }
  }
}
