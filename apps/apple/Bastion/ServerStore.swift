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

  /// Every id that will actually answer, for `/health`.
  ///
  /// Enabled only. `/health` is what a client or a script asks to find out what
  /// is reachable, and listing a server that is switched off would make it the
  /// one endpoint the answer is wrong about.
  nonisolated static func installedIDs() -> [String] {
    snapshot.withLock { table in table.values.filter(\.isEnabled).map(\.id).sorted() }
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
  ///
  /// `enabled` is optional so that a `servers.json` written before the switch
  /// existed decodes unchanged, with `nil` meaning on. A server nobody ever
  /// switched off is on, which is the only reading that cannot surprise
  /// somebody on upgrade.
  private struct Stored: Codable {
    var id: String
    var definition: Definition?
    var enabled: Bool?
  }

  /// A custom server, as typed. Deliberately not `Codable` on `BastionServer`
  /// itself: that would make every field of the runtime type part of the file
  /// format, including the ones only the catalog is allowed to set.
  struct Definition: Codable, Hashable {
    var displayName: String
    var summary: String
    /// The npm package, for a child entry. Optional so that a `servers.json`
    /// written before remote servers existed decodes unchanged — every row in
    /// one carries both, and a row carrying neither is a row this build wrote
    /// for a remote server.
    var npmName: String?
    var binName: String?
    /// The endpoint, for a remote entry. Its presence is what makes a row
    /// remote; `transport(for:)` reads exactly this.
    var url: String?
    var docsUrl: String?
    var dialect: String
    var writeGate: String?
    /// Remote only, and the counterpart to `writeGate`.
    var writeTools: [String]?
    var stateEnv: [String]
    var env: [Variable]

    struct Variable: Codable, Hashable {
      var name: String
      var required: Bool
      var secret: Bool
      var description: String
      /// Where the value lands on a remote request. Absent for a child, whose
      /// variables are environment variables.
      var header: Header?
      /// Present when the variable is a switch rather than free text. Optional
      /// so a file written before typed booleans existed decodes unchanged,
      /// with absent meaning "free text" — the additive rule `enabled` and
      /// `captureMode` already follow.
      var boolean: BooleanShape?

      struct Header: Codable, Hashable {
        var name: String
        var format: String
      }

      /// Named the same as the manifest's key, and carrying the same single
      /// field, so `servers.json` and a hand-edited custom row read alike.
      struct BooleanShape: Codable, Hashable {
        /// What the server does with the variable unset. See
        /// `BastionServer.EnvVar.booleanDefault` for why this is a default and
        /// not simply the value.
        var `default`: Bool
      }
    }

    /// A URL means remote; anything else is the child shape this file has
    /// always held.
    ///
    /// Falls back to a child with empty names rather than trapping: this
    /// decodes a file a user can hand-edit, and a malformed row should reach
    /// the "not installed" state where it can be seen and fixed, not crash the
    /// app on launch.
    var transport: BastionServer.Transport {
      if let url, let endpoint = URL(string: url), endpoint.scheme == "https" {
        return .remote(endpoint: endpoint)
      }
      return .child(
        .init(
          npmName: npmName ?? "", binName: binName ?? "", distribution: .npm,
          localPath: "mcp-custom"))
    }
  }

  func load() {
    // The fixture, and nothing off disk. `init()` calls this, so without the
    // branch a capture run would open the developer's own `servers.json` and
    // photograph whatever they happen to have installed.
    if DemoSeed.isEnabled {
      servers = DemoSeed.servers
      // Sorted like any other list. The fixture names its servers in the order
      // it finds readable, which is not an order the app can actually produce —
      // and a marketing plate showing a sidebar the shipped build would never
      // draw is worse than one that is merely arbitrary.
      sort()
      refreshSnapshot()
      return
    }
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
      servers = [BuiltinServer.definition]
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
    // Always present, however the file was written or hand-edited. It is the
    // one row that is part of the app rather than part of the user's list, so
    // its absence is never a choice somebody made — it is a file from before
    // the feature, or one somebody deleted a line out of.
    if !seen.contains(BuiltinServer.id) {
      servers.insert(BuiltinServer.definition, at: 0)
    }
    sort()
    refreshSnapshot()
  }

  private static func resolve(_ row: Stored) -> BastionServer? {
    guard isValidID(row.id) else {
      hostLog("servers", .error, "ignoring server with unusable id '\(row.id)'")
      return nil
    }
    // Before the catalog, and ignoring any `definition` the row carries: the
    // built-in server is defined by this build, and a file claiming otherwise
    // is a hand-edit that must not be able to redefine the control plane.
    if row.id == BuiltinServer.id {
      var builtin = BuiltinServer.definition
      builtin.isEnabled = row.enabled ?? false
      return builtin
    }
    guard let definition = row.definition else {
      guard let entry = ServerCatalog.byID[row.id] else {
        hostLog(
          "servers", .error,
          "ignoring '\(row.id)' — it is no longer in the catalog this build ships")
        return nil
      }
      var resolved = entry
      resolved.isEnabled = row.enabled ?? true
      return resolved
    }
    var resolved = make(id: row.id, from: definition)
    resolved.isEnabled = row.enabled ?? true
    return resolved
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
      transport: definition.url == nil
        ? .child(
          .init(
            npmName: definition.npmName ?? "", binName: definition.binName ?? "",
            distribution: .npm, localPath: "mcp-\(id)"))
        : definition.transport,
      docsURL: definition.docsUrl.flatMap(URL.init(string:)),
      dialect: BastionServer.Dialect(rawValue: definition.dialect) ?? .v2025_11_25,
      writeGate: definition.writeGate,
      writeTools: definition.writeTools ?? [],
      gateBypass: [],
      authModes: [],
      stateEnv: definition.stateEnv,
      callbackEnv: [],
      env: definition.env.map {
        .init(
          name: $0.name, isRequired: $0.required, isSecret: $0.secret, summary: $0.description,
          header: $0.header.map { .init(name: $0.name, format: $0.format) },
          booleanDefault: $0.boolean?.default)
      },
      origin: .custom)
  }

  private func save() throws {
    // Belt and braces. Nothing in a staged capture clicks the Enabled toggle,
    // but `setEnabled` is one stray keystroke away and a capture must not be
    // able to write the fixture over the developer's real list.
    if DemoSeed.isEnabled { return }
    refreshSnapshot()
    AppSupport.ensureDirectory()
    let rows = servers.map { server -> Stored in
      switch server.origin {
      // A built-in row carries nothing but its id and its switch. Writing a
      // definition would freeze this build's idea of it into the file.
      case .catalog, .builtin:
        Stored(id: server.id, definition: nil, enabled: server.isEnabled)
      case .custom:
        Stored(id: server.id, definition: Self.definition(of: server), enabled: server.isEnabled)
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
      npmName: server.package?.npmName,
      binName: server.package?.binName,
      url: server.endpoint?.absoluteString,
      docsUrl: server.docsURL?.absoluteString,
      dialect: server.dialect.rawValue,
      writeGate: server.writeGate,
      writeTools: server.writeTools.isEmpty ? nil : server.writeTools,
      stateEnv: server.stateEnv,
      env: server.env.map {
        .init(
          name: $0.name, required: $0.isRequired, secret: $0.isSecret, description: $0.summary,
          header: $0.header.map { .init(name: $0.name, format: $0.format) },
          boolean: $0.booleanDefault.map { .init(default: $0) })
      })
  }

  // MARK: - Editing

  enum StoreError: LocalizedError {
    case duplicateID(String)
    case unusableID(String)
    case unknownCatalogEntry(String)
    case unusablePackage(String)
    case unusableEndpoint(String)
    case unusableVariable(String)
    case contradictoryVariable(name: String, detail: String)
    case noVariables
    case renameWouldStrand(from: String, to: String, profiles: Int)
    case cannotRemoveBuiltin
    case reservedID(String)
    case notInList(String)

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
      case .unusableEndpoint(let detail):
        return detail
      case .unusableVariable(let name):
        return "'\(name)' is not a usable environment variable name"
      case .contradictoryVariable(let name, let detail):
        return "'\(name)' \(detail)"
      case .noVariables:
        return "a server needs at least one environment variable"
      case .cannotRemoveBuiltin:
        return
          "Bastion's own server is part of the app and cannot be removed. Switch it off instead — "
          + "that stops it answering and keeps everything it owns."
      case .reservedID(let id):
        return "'\(id)' is reserved for Bastion's own server. Pick another name."
      case .notInList(let id):
        return "'\(id)' is not in your server list"
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
    // Reserved, or a custom row would shadow the control plane on the next
    // load — `resolve` returns the built-in definition for this id whatever the
    // row says, so the entry the user typed would silently stop existing.
    guard id != BuiltinServer.id else { throw StoreError.reservedID(id) }
    // A custom entry supplies a PACKAGE or an ENDPOINT, and both are checked
    // here rather than at the point of use. `spawn(whatever_you_typed)` and
    // `fetch(whatever_you_typed)` are the same hole wearing two transports, and
    // the list is the one place either can be closed before anything reaches
    // the supervisor.
    switch definition.transport {
    case .child(let package):
      guard Self.isValidPackage(package.npmName) else {
        throw StoreError.unusablePackage(package.npmName)
      }
    case .remote(let endpoint):
      // Shape only. Resolution happens at request time, where a name that
      // resolves somewhere else tomorrow is caught on the day it does — a
      // check here that passed once would be a check the user believes.
      do { try RemoteEndpoint.validateShape(endpoint) } catch {
        throw StoreError.unusableEndpoint(error.localizedDescription)
      }
    case .inProcess:
      throw StoreError.reservedID(id)
    }
    guard !definition.env.isEmpty else { throw StoreError.noVariables }
    for variable in definition.env where !Self.isValidVariable(variable.name) {
      throw StoreError.unusableVariable(variable.name)
    }
    // The three combinations a switch cannot be in. The editor clears these as
    // they are typed, so reaching here means a hand-edited file in Application
    // Support — where a contradiction would not crash anything, it would just
    // quietly render the wrong control: a boolean also marked secret is drawn
    // as a SecureField, so the switch never appears and its value goes into the
    // Keychain where the editor cannot read it back to show which way it is
    // set. Same rules the manifest generator applies, for the same reasons.
    for variable in definition.env where variable.boolean != nil {
      if variable.secret {
        throw StoreError.contradictoryVariable(
          name: variable.name, detail: "is a switch, so it cannot also be a secret")
      }
      if variable.required {
        throw StoreError.contradictoryVariable(
          name: variable.name,
          detail: "is a switch, so it always has an answer and cannot be required")
      }
      if variable.header != nil {
        throw StoreError.contradictoryVariable(
          name: variable.name, detail: "is a switch, and a header carries a credential")
      }
      if variable.name == definition.writeGate {
        throw StoreError.contradictoryVariable(
          name: variable.name, detail: "is the write gate, which is set from each profile's toggle")
      }
    }

    // A remote variable with no sink is collected, stored in the Keychain and
    // then never sent. The generator refuses that in the manifest; this is the
    // same rule for an entry somebody typed.
    if definition.url != nil {
      for variable in definition.env where variable.header == nil {
        throw StoreError.unusableEndpoint(
          "\(variable.name) has no header, so nothing would ever send it")
      }
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

    var made = Self.make(id: id, from: definition)
    if let original, let index = servers.firstIndex(where: { $0.id == original }) {
      // Carried across the edit. `make` builds a fresh definition from the
      // stored fields, and the switch is not one of them — so without this,
      // opening the editor on a disabled server and pressing Save would quietly
      // turn it back on.
      made.isEnabled = servers[index].isEnabled
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
    guard server.origin != .builtin else { throw StoreError.cannotRemoveBuiltin }
    for profile in ProfileStore.shared.profiles where profile.serverID == server.id {
      Supervisor.shared.stop(profile: profile.name, server: server.id)
      try? ProfileStore.shared.remove(profile)
    }
    ServerInstaller.removeInstall(id: server.id)
    servers.removeAll { $0.id == server.id }
    try save()
    hostLog("servers", .info, "removed '\(server.id)' and everything it owned")
  }

  /// Stop a server answering without destroying anything it owns.
  ///
  /// The middle setting the app was missing. Removing a server takes its
  /// profiles, their Keychain entries and its downloaded code with it, which is
  /// far too much to mean "not right now" — so that was the only way to say it,
  /// and nobody says it that way twice.
  ///
  /// The running children go, because a server that reports itself off while a
  /// process of it is still serving requests is a state nobody could reason
  /// about. Everything on disk stays: this is reversible by design, and
  /// `remove` is still how to mean "never again".
  ///
  /// Client configs are deliberately left alone. Rewriting somebody's
  /// `.claude.json` on a toggle is a much larger action than the toggle looks,
  /// and a disabled server's entry failing with Bastion's own sentence is a
  /// better outcome than an entry that silently vanished.
  ///
  /// Left alone is not the same as maintained, though, and it took a bug report
  /// to tell the two apart: while an existing entry stays, nothing writes a new
  /// one. `ProfileStore.onEnabledServers` is what Configure and `wire_client`
  /// write from, so switching a server off and then wiring a client for a
  /// different one no longer puts this one back.
  func setEnabled(_ enabled: Bool, for id: String) throws {
    guard let index = servers.firstIndex(where: { $0.id == id }) else {
      throw StoreError.notInList(id)
    }
    guard servers[index].isEnabled != enabled else { return }
    servers[index].isEnabled = enabled
    if !enabled {
      for profile in ProfileStore.shared.profiles where profile.serverID == id {
        Supervisor.shared.stop(profile: profile.name, server: id)
      }
    }
    try save()
    hostLog("servers", .info, "\(enabled ? "enabled" : "disabled") '\(id)'")
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

  /// Alphabetical by display name, with Bastion's own server pinned first.
  ///
  /// It used to follow `servers.json` order for catalog entries and go
  /// alphabetical only for custom ones. That order is the catalog's, not the
  /// user's: nothing in the app shows it, so a sidebar of five servers read as
  /// shuffled and a name had to be scanned for rather than jumped to.
  private func sort() {
    servers.sort { a, b in
      // Bastion itself first, always. It is the app rather than a choice, and a
      // control plane that moves around the list as servers are added and
      // removed is one nobody can find twice.
      if (a.origin == .builtin) != (b.origin == .builtin) { return a.origin == .builtin }
      switch a.displayName.localizedStandardCompare(b.displayName) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      // Two servers may share a display name; the id cannot repeat, so it
      // keeps the order stable rather than leaving it to the sort.
      case .orderedSame: return a.id < b.id
      }
    }
  }
}
