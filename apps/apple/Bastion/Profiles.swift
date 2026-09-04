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
  /// Whether this profile hands its clients `ToolFacade`'s three tools instead
  /// of the server's own, or nil to follow the app-wide default.
  ///
  /// Tri-state for `captureMode`'s reason, one line down: the answer is usually
  /// the same for every profile on the machine, so making it a per-profile
  /// setting alone buried the feature in a sheet — but it is not ALWAYS the
  /// same, so a profile has to be able to disagree. This one is a trade rather
  /// than a tightening: it buys back the whole tool listing, about 26.2k tokens
  /// on `prod/appstore-connect`, and spends the host's own allowlist to do it
  /// because every call arrives as `bastion_call_tool`. A profile feeding Claude
  /// Code, which defers tool schemas by itself, gains nothing and pays all of
  /// that — which is exactly the disagreement the override exists for.
  var lazyTools: Bool?

  var id: String { "\(name)/\(serverID)" }

  /// What this profile actually records, default resolved.
  var capture: CallCapture.Mode { captureMode ?? CallCapture.globalDefault }

  /// Whether this profile actually fronts its server with `ToolFacade`, default
  /// resolved. The only form the gateway ever reads — nothing branches on
  /// `lazyTools` directly, so a profile that has expressed no preference cannot
  /// be mistaken for one that said no.
  var loadsToolsOnDemand: Bool { lazyTools ?? ToolFacade.globalDefault }

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

  /// The profiles a client can usefully be wired to: those whose server is
  /// switched on.
  ///
  /// One definition, because two panes and two tools ask this same question and
  /// they used to answer it differently. `wire_client` filtered switched-off
  /// servers out; the Clients pane and `list_clients` did not — so the pane
  /// audited a client as half-written over an entry nothing would serve, and
  /// Configuring for one server put every switched-off server back into
  /// somebody's config.
  ///
  /// Reads `ServerStore.shared.servers` rather than the lock-free snapshot: the
  /// callers are SwiftUI bodies, and only the observable array makes a pane
  /// redraw when the switch moves.
  var onEnabledServers: [Profile] {
    let enabled = Set(ServerStore.shared.servers.filter(\.isEnabled).map(\.id))
    return profiles.filter { enabled.contains($0.serverID) }
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
    /// Optional for the same additive reason, with nil meaning "follow the
    /// app-wide default": a `profiles.json` written before the facade existed
    /// describes profiles that expressed no preference, which is exactly what
    /// nil says.
    var lazyTools: Bool?
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
      guard let server = ServerStore.lookup(row.server) else {
        hostLog(
          "profiles", .info,
          "'\(row.name)/\(row.server)' is set aside — \(row.server) is not installed")
        return nil
      }
      // A gate value written by a build that still offered it as a field. The
      // toggle is the record, so this is dropped and NEVER promoted into
      // `allowWrites`: `build` has been forcing the variable to "0" for a
      // profile whose toggle is off since before this line existed, so dropping
      // changes nothing about what runs, while reading the "1" as consent would
      // silently turn writes on for a profile whose owner had turned them off.
      var values = row.values
      if let gate = server.writeGate, values.removeValue(forKey: gate) != nil {
        hostLog(
          "profiles", .info,
          "'\(row.name)/\(row.server)' dropped a stored \(gate) — the toggle owns it")
      }
      return Profile(
        name: row.name, serverID: row.server, values: values, allowWrites: row.allowWrites,
        captureMode: row.captureMode, lazyTools: row.lazyTools)
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
          captureMode: $0.captureMode, lazyTools: $0.lazyTools)
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
      // `lazyTools` is deliberately NOT in this condition. The facade is applied
      // to a reply on its way out, from a catalog the instance already holds, so
      // it changes what clients are sent without changing anything the child was
      // spawned with. Killing a warm process to flip a switch it cannot observe
      // would cost the next caller a whole spawn and handshake for nothing.
      if previous.values != profile.values || previous.allowWrites != profile.allowWrites {
        Supervisor.shared.stop(profile: profile.name, server: profile.serverID)
        ServerCheck.shared.forget(profile.id)
        ToolCostStore.shared.forget(profile.id)
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
      // `XDG_CONFIG_HOME ?? ~/.config` — appstore-connect, reddit and x.
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

    // Before the merge, deliberately. A callback URL Bastion assigns is a
    // default, not an override: somebody who has already registered a URL with
    // the upstream app and typed it into the profile must keep it, or this
    // "fix" silently breaks the logins that were working.
    for callback in server.callbackEnv {
      // Spawn time is the only place a decision is made: there is certainly a
      // profile here, and it is certainly being run.
      if case .port(let port) = decideCallback(profile: profile.name, server: server.id) {
        env[callback.name] = callback.url(port: port)
      }
    }

    env.merge(values(for: profile, server: server)) { _, resolved in resolved }

    // Last, and unconditionally in both directions. Setting the gate only when
    // it is on would let a stale value in `profiles.json` leave writes enabled
    // on a profile whose toggle reads as off.
    //
    // Being unconditional also closes a second hole, in mcp-appstore-connect
    // and mcp-x: both read `parseBool(env.X) ?? file.allowWrites`, so an
    // UNSET variable falls through to a value in a config file on disk. An
    // explicit "0" never falls through.
    //
    // The value comes from `gateValue` rather than from a ternary here, because
    // not every gate points the same way: a third-party server's is typically a
    // READ-ONLY switch, where "1" is writes OFF. Deciding that at this call site
    // would put the rule in a file `make unit` does not compile.
    if let gate = server.writeGate, let value = server.gateValue(allowWrites: profile.allowWrites) {
      env[gate] = value
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

  // MARK: - Loopback callback ports

  /// What this profile's callback URL is built from, once something has
  /// decided. `nil` means undecided — nothing has spawned this profile yet.
  ///
  /// **Pure.** Reads a file and writes nothing, which is what makes it safe to
  /// call from a view body. Its absence was a real bug: the profile editor
  /// called the deciding function below on every render, with whatever name was
  /// in the text field, so typing "olouv" created a profile directory and
  /// burned an allocated port for `o`, `ol`, `olo`, `olou` and `olouv` — and
  /// the first keystroke claimed the server's default, so the profile the user
  /// actually meant was pushed onto a port their Reddit app had never heard of.
  nonisolated static func callbackAssignment(profile: String, server: String) -> CallbackAssignment?
  {
    let file = directory(profile: profile, server: server)
      .appendingPathComponent("callback-port", isDirectory: false)
    guard let decided = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    let text = decided.trimmingCharacters(in: .whitespacesAndNewlines)
    if text == defaultMarker { return .serverDefault }
    if let port = Int(text), (1024...65535).contains(port) { return .port(port) }
    return nil
  }

  /// Decide, once, and write it down. **Only for a profile that is being run.**
  ///
  /// The first profile of a server is left on the server's own default, and
  /// that is the whole point. Reddit and X compare `redirect_uri` byte for byte
  /// against a single URI registered on the app, and each server documents a
  /// default port its setup instructions tell people to register. Assigning a
  /// port to the only profile on the machine invalidates that registration to
  /// solve a collision that does not exist yet — which is exactly what it did,
  /// and the symptom was `invalid redirect_uri parameter` on a login that had
  /// worked the day before.
  ///
  /// So: first come, first served. A second profile is a second identity, needs
  /// its own socket, and needs its own upstream app registration anyway —
  /// Reddit allows one redirect URI per app — so a fresh port costs it nothing
  /// it was not already going to pay.
  ///
  /// Kept once written, because a port picked afresh on every spawn would match
  /// a registration exactly once.
  nonisolated static func decideCallback(profile: String, server: String) -> CallbackAssignment {
    if let already = callbackAssignment(profile: profile, server: server) { return already }

    // Racy in principle — two profiles first spawned in the same instant could
    // both read "unclaimed" — and not worth a lock: the loser gets a URL that
    // does not match its registration, which the editor shows and the user can
    // override by typing one.
    let claimed = defaultIsClaimed(server: server)
    let decision: CallbackAssignment =
      claimed ? (freePort().map(CallbackAssignment.port) ?? .serverDefault) : .serverDefault

    let file = directory(profile: profile, server: server)
      .appendingPathComponent("callback-port", isDirectory: false)
    try? FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let text: String
    switch decision {
    case .serverDefault: text = defaultMarker
    case .port(let port): text = String(port)
    }
    try? Data("\(text)\n".utf8).write(to: file, options: .atomic)
    return decision
  }

  /// What a profile's callback is built from.
  enum CallbackAssignment: Hashable {
    /// Leave the variable unset and let the server use the port it documents.
    case serverDefault
    /// A port of this profile's own, because another profile holds the default.
    case port(Int)
  }

  /// Written into `callback-port` for the profile using the server's own
  /// default. A word rather than the number, because Bastion does not know the
  /// number — the server does, and writing a guess would turn a value this code
  /// never has to know into one it can be wrong about.
  private nonisolated static let defaultMarker = "default"

  /// Whether some profile of this server already holds the documented default.
  private nonisolated static func defaultIsClaimed(server: String) -> Bool {
    let root = AppSupport.directory
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(server, isDirectory: true)
    let profiles =
      (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? []
    return profiles.contains { directory in
      let text = try? String(
        contentsOf: directory.appendingPathComponent("callback-port", isDirectory: false),
        encoding: .utf8)
      return text?.trimmingCharacters(in: .whitespacesAndNewlines) == defaultMarker
    }
  }

  /// One free loopback port, borrowed from the kernel and handed straight back.
  ///
  /// Bind to port 0, read what was assigned, close. There is a race here — the
  /// port is free at the moment it is read, not at the moment the child binds
  /// it — and it is the right race to take: the alternative is holding a socket
  /// open for a child that may not be spawned for days, on a port the child
  /// then cannot bind because Bastion is sitting on it.
  private nonisolated static func freePort() -> Int? {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = 0

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return nil }

    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else { return nil }
    return Int(UInt16(bigEndian: actual.sin_port))
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
    // `editableEnv` rather than `env`: the gate is not a variable a profile
    // fills in. Nothing depends on this today — `build` overwrites the gate
    // unconditionally two steps later and so already wins, and `headers(for:)`,
    // the other caller, only ever sees a remote server, which has no gate to
    // begin with. It is here because this is where the rule is *stated*, and a
    // rule stated in one place and relied on in another is how the profile
    // editor came to disagree with the thing that actually sets the variables.
    let known = Set(server.editableEnv.map(\.name))
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
        // A `.childOAuth` mode is NOT a gate, and this is the one place the
        // two OAuth kinds must part company. A remote server with no
        // credential can do nothing, so `.oauth` unsatisfied means unusable.
        // A child that logs itself in still works signed out — mcp-reddit
        // serves public reads anonymously, on purpose — and Bastion cannot
        // know whether it is signed in without asking it, which is a spawn
        // and a round trip. Answering "no" here would paint every Reddit
        // profile permanently unusable, including the ones working fine; the
        // authoritative answer is the Authorization section's own dot, which
        // asks the child.
        case .childOAuth:
          return true
        }
      }
      if !satisfied {
        let options = server.authModes
          .map { mode in
            switch mode.kind {
            case .env: "\(mode.displayName) (\(mode.env.joined(separator: " + ")))"
            case .oauth, .childOAuth: "\(mode.displayName) — authorize it in Bastion"
            }
          }
          .joined(separator: ", or ")
        missing.append("one of: \(options)")
      }
    }
    return missing
  }
}
