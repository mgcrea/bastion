import Foundation
import os

/// A named credential and configuration set for one server.
///
/// Profiles are the answer to the obvious objection to a shared gateway: one
/// global instance is one identity, and one identity is unusable. Every repo in
/// `mgcrea-ai` already carries its own `.mcp.json` with different credentials,
/// so a true singleton would be unusable for its own author on day one.
///
/// `shopify/prod`, `shopify/staging`, `keycloak/rgis`. The endpoint carries
/// both: `http://127.0.0.1:<port>/s/<profile>/<server>`.
nonisolated struct Profile: Identifiable, Hashable {
  /// Unique within a server. Kebab-case and no `/`, because it is a URL path
  /// segment, a Keychain account component and a directory name.
  let name: String
  let serverID: String
  /// Non-secret configuration. Secrets are not here and never are — they are
  /// read from the Keychain at spawn time and handed to the child directly.
  var values: [String: String]
  /// Whether this profile's write gate is set.
  ///
  /// Per profile, never global. This is Bastion's answer to the third reason
  /// `ServerHost.swift` gives for one process per connection: write permissions
  /// do not have to be shared just because a process is. One `tastytrade/cert`
  /// profile with trading on and one `tastytrade/prod` profile with trading off
  /// is a sane setup, and a single global switch makes it unexpressible.
  var allowWrites: Bool

  var id: String { "\(name)/\(serverID)" }

  static func isValidName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 64
      && name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
  }
}

/// The profiles on disk, and the environment they produce.
///
/// `profiles.json` holds names, server ids, write flags and non-secret values.
/// It deliberately holds nothing else: the file this replaces is a `.mcp.json`
/// with a brokerage refresh token in it.
@MainActor
@Observable
final class ProfileStore {
  static let shared = ProfileStore()

  private(set) var profiles: [Profile] = []

  /// The same profiles, readable without a hop to the main actor.
  ///
  /// The gateway resolves a profile on the connection's own thread, which is
  /// deliberately a blocking thread rather than a cooperative-pool one. Reaching
  /// the `@Observable` array from there would mean an `await MainActor.run` on
  /// every single request — a main-thread round trip in the hot path of a
  /// process whose job is to be a fast local relay, and a main thread that is
  /// also drawing a menu.
  ///
  /// Written only from `refreshSnapshot`, which every mutation ends with.
  private nonisolated static let snapshot = OSAllocatedUnfairLock<[String: Profile]>(
    initialState: [:])

  nonisolated static func lookup(name: String, server: String) -> Profile? {
    snapshot.withLock { $0["\(name)/\(server)"] }
  }

  private func refreshSnapshot() {
    let table = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
    Self.snapshot.withLock { $0 = table }
  }

  private var fileURL: URL { AppSupport.directory.appendingPathComponent("profiles.json") }

  init() { load() }

  func profile(named name: String, server: String) -> Profile? {
    profiles.first { $0.name == name && $0.serverID == server }
  }

  // MARK: - Persistence

  private struct Stored: Codable {
    var name: String
    var server: String
    var values: [String: String]
    var allowWrites: Bool
  }

  func load() {
    guard let data = try? Data(contentsOf: fileURL),
      let rows = try? JSONDecoder().decode([Stored].self, from: data)
    else {
      profiles = []
      refreshSnapshot()
      return
    }
    profiles = rows.compactMap { row in
      // Drop rather than repair. A row naming a server that is not in the
      // closed table, or a name that is not a legal path segment, is either a
      // hand-edit or a downgrade — and both are cases where guessing at what
      // was meant is worse than ignoring it. Logged so it is not silent.
      guard Profile.isValidName(row.name) else {
        hostLog("profiles", .error, "ignoring profile with unusable name '\(row.name)'")
        return nil
      }
      guard ServerCatalog.byID[row.server] != nil else {
        hostLog("profiles", .error, "ignoring profile '\(row.name)' for unknown server '\(row.server)'")
        return nil
      }
      return Profile(
        name: row.name, serverID: row.server, values: row.values, allowWrites: row.allowWrites)
    }
    refreshSnapshot()
  }

  func save() throws {
    refreshSnapshot()
    AppSupport.ensureDirectory()
    let rows = profiles.map {
      Stored(name: $0.name, server: $0.serverID, values: $0.values, allowWrites: $0.allowWrites)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(rows).write(to: fileURL, options: .atomic)
    // 0o600 explicitly, and after every write: `.atomic` replaces the file, so
    // permissions set once do not survive the next save.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  func upsert(_ profile: Profile) throws {
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    try save()
  }

  /// Remove a profile and every secret it owns.
  ///
  /// The secrets are found by prefix rather than by walking the manifest,
  /// because a variable the manifest has since dropped would otherwise leave a
  /// credential in the Keychain belonging to a profile that no longer exists.
  func remove(_ profile: Profile) throws {
    profiles.removeAll { $0.id == profile.id }
    let prefix = "\(profile.name)/\(profile.serverID)/"
    for account in CredentialStore.accounts(.profile) where account.hasPrefix(prefix) {
      try? CredentialStore.delete(.profile, account: account)
    }
    try save()
  }
}

/// Everything a child process is given.
///
/// Built fresh at spawn time and never written anywhere.
nonisolated enum ProfileEnvironment {
  /// Where one profile keeps the state its server writes.
  ///
  /// Per profile, not per server. Two profiles of `mcp-reddit` sharing one
  /// token file are two identities sharing one login — the concrete reason a
  /// naive singleton is wrong, and the reason `stateEnv` is in the manifest.
  nonisolated static func directory(profile: String, server: String) -> URL {
    AppSupport.directory
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(server, isDirectory: true)
      .appendingPathComponent(profile, isDirectory: true)
  }

  /// The environment for one child.
  ///
  /// Deliberately minimal: a server inherits nothing it was not given on
  /// purpose. It does not get the developer's shell environment, it does not
  /// get another profile's variables, and it does not get any variable the
  /// manifest does not list — an unknown key in `profiles.json` is dropped
  /// rather than passed through, because "set any environment variable on a
  /// process holding my credentials" is a capability, not a convenience.
  nonisolated static func build(for profile: Profile, server: BastionServer)
    -> [String: String]
  {
    let state = directory(profile: profile.name, server: server.id)
    try? FileManager.default.createDirectory(
      at: state, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    var env = [
      "PATH": "/usr/bin:/bin",
      "HOME": NSHomeDirectory(),
      // Three of the ten servers resolve their state as
      // `XDG_CONFIG_HOME ?? ~/.config` — appstore-connect, reddit and x-api.
      // Pointing this at the profile directory redirects all three without
      // Bastion having to know which of their `stateEnv` variables wants a file
      // and which wants a directory. The rest are surfaced in the profile
      // editor instead of guessed at: inventing path semantics for a variable
      // whose shape has not been checked is how a token file becomes a
      // directory and a server fails at startup with an EISDIR nobody expects.
      "XDG_CONFIG_HOME": state.path,
    ]

    let known = Set(server.env.map(\.name))
    for (key, value) in profile.values where known.contains(key) && !value.isEmpty {
      env[key] = value
    }

    for variable in server.env where variable.isSecret {
      let account = CredentialStore.account(
        profile: profile.name, server: server.id, variable: variable.name)
      if let secret = CredentialStore.read(.profile, account: account), !secret.isEmpty {
        env[variable.name] = secret
      }
    }

    // Last, and unconditionally in both directions. Setting the gate only when
    // it is on would let a stale value in `profiles.json` leave writes enabled
    // on a profile whose toggle reads as off.
    //
    // Being unconditional also closes a second hole, in mcp-appstore-connect
    // and mcp-x-api: both read `parseBool(env.X) ?? file.allowWrites`, so an
    // UNSET variable falls through to a value in a config file on disk. An
    // explicit "0" never falls through.
    if let gate = server.writeGate {
      env[gate] = profile.allowWrites ? "1" : "0"
    }

    // And after the gate, never before: anything that could turn writes on
    // around it. mcp-tastytrade ORs a second variable into its trading flag, so
    // without this a profile showing "writes off" could still place orders.
    // Forced off even when the gate is on, because the gate is then already
    // doing the job and two switches for one wire is how they drift.
    for bypass in server.gateBypass {
      env[bypass] = "0"
    }

    return env
  }

  /// What is missing before this profile can start.
  ///
  /// Reported rather than thrown at spawn time: a server that exits on a
  /// missing credential shows up in the client as a bare "Connection closed"
  /// with stderr swallowed, which is the failure mode every one of these
  /// servers has a comment about avoiding. Bastion is in a position to say the
  /// sentence instead.
  nonisolated static func missing(for profile: Profile, server: BastionServer) -> [String] {
    let env = build(for: profile, server: server)
    var missing = server.env.filter { $0.isRequired && (env[$0.name] ?? "").isEmpty }
      .map(\.name)

    // An auth mode is satisfied when every variable in it is set. None
    // satisfied means the profile cannot authenticate at all, and naming every
    // option is more useful than naming the first.
    if !server.authModes.isEmpty {
      let satisfied = server.authModes.contains { mode in
        mode.env.allSatisfy { !(env[$0] ?? "").isEmpty }
      }
      if !satisfied {
        let options = server.authModes
          .map { "\($0.displayName) (\($0.env.joined(separator: " + ")))" }
          .joined(separator: ", or ")
        missing.append("one of: \(options)")
      }
    }
    return missing
  }
}
