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
  /// do not have to be shared just because a process is. One `lab/unifi-network`
  /// profile that may reconfigure a switch and one `home/unifi-network` profile
  /// that may only look is a sane setup, and a single global switch makes it
  /// unexpressible.
  var allowWrites: Bool
  /// How much of a call this profile records, or nil to follow the app-wide
  /// default. Per profile for the same reason the write gate is: a `lab`
  /// profile worth watching closely and a `prod` one worth watching quietly
  /// is a sane setup, and one global switch makes it unexpressible.
  var captureMode: CallCapture.Mode?

  var id: String { "\(name)/\(serverID)" }

  /// What this profile actually records, default resolved.
  var capture: CallCapture.Mode { captureMode ?? CallCapture.globalDefault }

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

  /// Rows whose server is not installed, kept out of `profiles` and kept in the
  /// file.
  ///
  /// This exists because the server list became editable. Dropping an
  /// unresolvable row used to be free: the table was fixed at compile time, so
  /// a row naming a server that was not in it could only be a hand-edit or a
  /// downgrade. Now the ordinary case is a server the user removed — or has not
  /// re-installed yet — and dropping the row from memory means the next `save()`
  /// drops it from disk, silently taking a profile's configuration with it.
  ///
  /// Deliberate removal is a different path and still deletes: `ServerStore`
  /// removes a server's profiles itself, with the Keychain sweep, before the
  /// server leaves the list. So what survives here is exactly what nobody asked
  /// to destroy.
  private var orphaned: [Stored] = []

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
    /// Optional so a `profiles.json` written before capture existed decodes
    /// unchanged, with nil meaning "follow the app-wide default" — the same
    /// additive rule `ServerStore.Stored.enabled` follows. Never make this
    /// required and never rename it.
    var captureMode: CallCapture.Mode?
  }

  func load() {
    // The fixture, and nothing off disk. See `ServerStore.load` — same branch,
    // same reason, and this one matters more: `profiles.json` names the
    // developer's own accounts.
    if DemoSeed.isEnabled {
      profiles = DemoSeed.profiles
      orphaned = []
      refreshSnapshot()
      return
    }
    guard let data = try? Data(contentsOf: fileURL),
      let rows = try? JSONDecoder().decode([Stored].self, from: data)
    else {
      profiles = []
      orphaned = []
      refreshSnapshot()
      return
    }
    orphaned = rows.filter { Profile.isValidName($0.name) && ServerStore.lookup($0.server) == nil }
    profiles = rows.compactMap { row in
      // Drop rather than repair. A row naming a server that is not installed,
      // or a name that is not a legal path segment, is either a hand-edit or a
      // downgrade — and both are cases where guessing at what was meant is
      // worse than ignoring it. Logged so it is not silent.
      //
      // `ServerStore.remove` deletes a server's profiles itself, with the
      // Keychain sweep, precisely so this path is never how they go.
      guard Profile.isValidName(row.name) else {
        hostLog("profiles", .error, "ignoring profile with unusable name '\(row.name)'")
        return nil
      }
      guard ServerStore.lookup(row.server) != nil else {
        hostLog(
          "profiles", .info,
          "'\(row.name)/\(row.server)' is set aside — \(row.server) is not installed")
        return nil
      }
      return Profile(
        name: row.name, serverID: row.server, values: row.values, allowWrites: row.allowWrites,
        captureMode: row.captureMode)
    }
    refreshSnapshot()
  }

  func save() throws {
    if DemoSeed.isEnabled { return }
    refreshSnapshot()
    AppSupport.ensureDirectory()
    let rows =
      profiles.map {
        Stored(
          name: $0.name, server: $0.serverID, values: $0.values, allowWrites: $0.allowWrites,
          captureMode: $0.captureMode)
      } + orphaned
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(rows).write(to: fileURL, options: .atomic)
    // 0o600 explicitly, and after every write: `.atomic` replaces the file, so
    // permissions set once do not survive the next save.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  /// Save a profile, and stop any child still holding the old environment.
  ///
  /// The stop is the whole reason this is not a two-line setter. A child is
  /// handed its environment once, at spawn, by `ProfileEnvironment.build` — so
  /// editing a value here changes what the NEXT process will get and nothing
  /// about the one that is running. Without this, turning off a TLS check or
  /// correcting a hostname appears to do nothing, the tool fails exactly as it
  /// did before, and the profile on disk says the change was made. There is no
  /// symptom pointing at the cause; the setting simply looks broken.
  ///
  /// Here rather than in the profile editor, because the editor is no longer
  /// the only caller: `upsert_profile` on Bastion's own server reaches the same
  /// state, and a rule kept in one of two callers is a rule that holds half the
  /// time.
  ///
  /// Only when something the environment is actually built from changed. Every
  /// save would otherwise kill a warm child for opening the editor and pressing
  /// Save, and a restart costs the next caller the whole spawn and handshake.
  func upsert(_ profile: Profile) throws {
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      let previous = profiles[index]
      profiles[index] = profile
      if previous.values != profile.values || previous.allowWrites != profile.allowWrites {
        Supervisor.shared.stop(profile: profile.name, server: profile.serverID)
      }
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
    // The set-aside copy too, or a removal would leave the row in the file to
    // be resurrected by the next load with its credentials already swept.
    orphaned.removeAll { $0.name == profile.name && $0.server == profile.serverID }
    let prefix = "\(profile.name)/\(profile.serverID)/"
    for account in CredentialStore.accounts(.profile) where account.hasPrefix(prefix) {
      try? CredentialStore.delete(.profile, account: account)
    }
    // And the OAuth token set, which lives under the same prefix in its own
    // scope. Leaving it would mean a profile recreated with the same name
    // silently inheriting the last one's authorization.
    for account in CredentialStore.accounts(.oauth) where account.hasPrefix(prefix) {
      try? CredentialStore.delete(.oauth, account: account)
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
      // The same move for caches, and stated less confidently on purpose. It is
      // pointed at the profile directory because the cost of being wrong is a
      // variable nothing reads, and the cost of leaving it is two profiles
      // writing into one `~/.cache/<server>` — which for mcp-unifi-protect is
      // two identities sharing a directory of camera footage. The variables
      // whose shape HAS been checked are in `stateEnv` and surfaced in the
      // profile editor; this is the floor under them, not a substitute.
      "XDG_CACHE_HOME": state.appendingPathComponent("cache", isDirectory: true).path,
    ]

    env.merge(values(for: profile, server: server)) { _, resolved in resolved }

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

  /// Every variable this profile has a value for, from `profiles.json` and the
  /// Keychain, with nothing else added.
  ///
  /// Split out of `build` when a second sink appeared. A child's variables
  /// become environment variables and a remote server's become headers, but
  /// *which variables are set* is one question with one answer, and asking it
  /// in two places is how the profile editor comes to disagree with the thing
  /// that actually sends them.
  ///
  /// The same rule as ever: a key the manifest does not list is dropped rather
  /// than passed through. "Set anything you like on the thing holding my
  /// credentials" is a capability, not a convenience.
  nonisolated static func values(for profile: Profile, server: BastionServer)
    -> [String: String]
  {
    var out: [String: String] = [:]
    let known = Set(server.env.map(\.name))
    for (key, value) in profile.values where known.contains(key) && !value.isEmpty {
      out[key] = value
    }
    for variable in server.env where variable.isSecret {
      let account = CredentialStore.account(
        profile: profile.name, server: server.id, variable: variable.name)
      if let secret = CredentialStore.read(.profile, account: account), !secret.isEmpty {
        out[variable.name] = secret
      }
    }
    return out
  }

  /// The other sink: what a remote server's request carries.
  ///
  /// A variable with no `header` produces nothing. That is not a silent drop —
  /// the manifest generator refuses a remote variable without one, and
  /// `ServerStore.upsert` refuses a typed entry without one — so reaching this
  /// with a headerless variable means a hand-edited file, where dropping it is
  /// the conservative answer.
  ///
  /// No write gate here and none possible: the gate on a remote server is the
  /// tool filter in `RemoteInstance`, because there is no environment to put a
  /// switch in. Nothing about `allowWrites` reaches the wire.
  nonisolated static func headers(for profile: Profile, server: BastionServer)
    -> [String: String]
  {
    let resolved = values(for: profile, server: server)
    var out: [String: String] = [:]
    for variable in server.env {
      guard let sink = variable.header, let value = resolved[variable.name], !value.isEmpty
      else { continue }
      out[sink.name] = sink.rendered(value)
    }
    return out
  }

  /// Which of this server's variables have something behind them.
  ///
  /// Names, not values. A variable is set or it is not, and that answer is the
  /// same whether it would have become an environment variable on a child or a
  /// header on a request — so the two sinks still cannot disagree, because both
  /// read the same account namespace this does.
  ///
  /// Asking by name is the whole point. `values(for:)` answers the same
  /// question by decrypting every secret, which meets a per-item Keychain ACL
  /// each time and turns a status request into a prompt storm — a modal dialog
  /// in the middle of a tool call nobody is sitting there to answer. Decryption
  /// is left to the paths that actually need a value: `values(for:)` at spawn
  /// and `headers(for:)` on the wire.
  ///
  /// Takes the stored set rather than fetching it, so a caller ranging over
  /// every profile pays for one Keychain query instead of one per profile.
  nonisolated static func present(
    for profile: Profile, server: BastionServer, stored: Set<String>
  ) -> Set<String> {
    // The same rule `values(for:)` applies: a key the manifest does not list is
    // not a variable, so it cannot satisfy a requirement either.
    let known = Set(server.env.map(\.name))
    var out = Set(
      profile.values.filter { known.contains($0.key) && !$0.value.isEmpty }.keys)
    let secrets = Set(server.env.filter(\.isSecret).map(\.name))
    out.formUnion(stored.filter { secrets.contains($0) })
    return out
  }

  /// What is missing before this profile can start.
  ///
  /// Reported rather than thrown at spawn time: a server that exits on a
  /// missing credential shows up in the client as a bare "Connection closed"
  /// with stderr swallowed, which is the failure mode every one of these
  /// servers has a comment about avoiding. Bastion is in a position to say the
  /// sentence instead.
  nonisolated static func missing(for profile: Profile, server: BastionServer) -> [String] {
    let stored = CredentialStore.storedVariables(profile: profile.name, server: server.id)
    return missing(
      for: profile, server: server,
      present: present(for: profile, server: server, stored: stored))
  }

  /// The same, for a caller that has already worked out what is present.
  nonisolated static func missing(
    for profile: Profile, server: BastionServer, present: Set<String>
  ) -> [String] {
    var missing = server.env.filter { $0.isRequired && !present.contains($0.name) }
      .map(\.name)

    // An auth mode is satisfied when every variable in it is set. None
    // satisfied means the profile cannot authenticate at all, and naming every
    // option is more useful than naming the first.
    if !server.authModes.isEmpty {
      let satisfied = server.authModes.contains { mode in
        switch mode.kind {
        case .env:
          return mode.env.allSatisfy { present.contains($0) }
        case .oauth:
          // Satisfied by having been authorized, which is a fact about the
          // Keychain rather than about any variable. This is why `missing` had
          // to learn about modes at all: an OAuth profile has no variable to be
          // missing, and naming one would send somebody looking for a field
          // that is supposed to stay empty.
          return CredentialStore.readTokens(profile: profile.name, server: server.id) != nil
        }
      }
      if !satisfied {
        let options = server.authModes
          .map { mode in
            switch mode.kind {
            case .env: "\(mode.displayName) (\(mode.env.joined(separator: " + ")))"
            case .oauth: "\(mode.displayName) — authorize it in Bastion"
            }
          }
          .joined(separator: ", or ")
        missing.append("one of: \(options)")
      }
    }
    return missing
  }
}
