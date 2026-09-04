import Foundation
import os

/// Fetching a server's code, on demand, into Application Support.
///
/// Bastion used to ship its servers inside the app bundle. That is what made
/// the list feel closed even after the table stopped being one: a server you
/// could add was a server that had to already be in `Contents/Resources`, and
/// every id outside the bundle answered "not in this build". So nothing is
/// bundled now except the runtime, and the code arrives when somebody asks for
/// it.
///
/// ## Why npm rather than a downloader
///
/// These packages do not vendor their dependencies — a staged `dist/cli.js`
/// with no `node_modules` dies at startup on `ERR_MODULE_NOT_FOUND` for
/// `@modelcontextprotocol/sdk`, which is exactly what `verify-servers.sh` was
/// written to catch. Resolving a dependency tree, checking integrity hashes and
/// handling `peerDependencies` is a package manager, and one is already sitting
/// beside the runtime in the bundle. Writing a second one would be writing a
/// worse one.
///
/// ## What is installed, and where
///
///     ~/Library/Application Support/io.mgcrea.bastion/
///       servers/<id>/package.json          ← a private, generated stub
///       servers/<id>/node_modules/<pkg>/   ← the server and its closure
///
/// One prefix per server rather than one shared tree. They are independent
/// packages that happen to share a parent directory, and hoisting would make
/// one server's resolution depend on another's dependency ranges — a server
/// that breaks when an unrelated one is installed is a bug nobody would look
/// for here.
@MainActor
@Observable
final class ServerInstaller {
  static let shared = ServerInstaller()

  /// What is being installed right now, id to status line. Drives the UI and
  /// nothing else — the authority on whether a server is installed is the
  /// directory, never this.
  private(set) var running: [String: String] = [:]
  /// The last failure per server, kept until the next attempt so the sentence
  /// survives the sheet being closed.
  private(set) var failures: [String: String] = [:]

  func isRunning(_ id: String) -> Bool { running[id] != nil }

  /// What a check found, per server id, and which ids are being checked.
  ///
  /// In memory only, and that is the point: a check is a claim about a registry
  /// at one moment, and one made three days ago should not still be on screen
  /// wearing the same words as one made now. A relaunch forgets, an install
  /// forgets (see `install`), and the answer is otherwise as old as the button
  /// press that produced it.
  private(set) var availability: [String: Availability] = [:]
  private(set) var checking: Set<String> = []

  func isChecking(_ id: String) -> Bool { checking.contains(id) }

  /// The outcome of a check, as sentences rather than as a version plus a flag.
  ///
  /// `pinnedOlder` is the case a version number alone would misreport. A
  /// release-age window does not just hide new versions: with one set, npm
  /// resolves `@latest` to the newest version old *enough*, which can be older
  /// than what is already installed — pressing Update then downgrades, on
  /// purpose. Measured, not assumed: `npm install zod@latest --dry-run` under
  /// `min-release-age=30` plans `4.5.4 => 4.4.3`.
  enum Availability: Equatable {
    /// npm plans nothing at all — not one package in the closure would move.
    case upToDate
    case newer(String)
    case pinnedOlder(String)
    /// The server package is current and the tree around it is not what npm
    /// would build: dependencies missing, or sitting outside their ranges. The
    /// count is packages.
    case needsRepair(Int)
    case failed(String)
  }

  // MARK: - Where it lands

  nonisolated static var root: URL {
    AppSupport.directory.appendingPathComponent("servers", isDirectory: true)
  }

  nonisolated static func directory(of id: String) -> URL {
    root.appendingPathComponent(id, isDirectory: true)
  }

  /// The installed package's own directory, or `nil` when nothing is there.
  ///
  /// The built-in server has no package and no directory, and this is the one
  /// choke point for that: `entryScript`, `installedVersion` and `isInstalled`
  /// all route through here. Guarded rather than left to fall through, because
  /// its `npmName` is empty and an unguarded walk would end up asking whether
  /// `servers/bastion/node_modules/package.json` exists.
  nonisolated static func packageDirectory(of server: BastionServer) -> URL? {
    guard let package = server.package, !package.npmName.isEmpty else { return nil }
    var url = directory(of: server.id).appendingPathComponent("node_modules", isDirectory: true)
    // A scoped name is two path components on disk. Splitting rather than
    // appending the whole string keeps that true without a special case.
    for component in package.npmName.split(separator: "/") {
      url = url.appendingPathComponent(String(component), isDirectory: true)
    }
    guard FileManager.default.fileExists(atPath: url.appendingPathComponent("package.json").path)
    else { return nil }
    return url
  }

  /// The version actually on disk, read from the installed `package.json`.
  ///
  /// Read rather than remembered. A version recorded at install time is a claim
  /// about a directory this app does not watch, and the first time somebody
  /// clears Application Support it becomes a confident lie.
  nonisolated static func installedVersion(of server: BastionServer) -> String? {
    // Off the fixture table, not off this Mac's Application Support. All three
    // of these answer a question about the capturing machine otherwise, so the
    // server plate's Package card would say whatever happened to be installed
    // the day the shot was taken.
    if DemoSeed.isEnabled { return DemoSeed.installedVersion(of: server) }
    guard let directory = packageDirectory(of: server),
      let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["version"] as? String
  }

  /// The newest MCP protocol the *installed code* can speak, with the SDK
  /// version that decides it — or `nil` when the package does not ship one.
  ///
  /// Read off disk, for the same reason `installedVersion` is: the alternative
  /// is a claim about a directory this app does not watch. `server.dialect` is
  /// the *catalog's* claim, written by hand in `servers.json` and generated
  /// into `ServerCatalog`; an npm update cannot move it, so after an update the
  /// two can disagree and only this one is about the code that is actually
  /// there.
  ///
  /// Off disk rather than over the wire, and that is the interesting choice.
  /// The wire cannot answer this question today: `Supervisor.performHandshake`
  /// asks the child for `server.dialect`, and the SDK's `initialize` echoes any
  /// version in its `SUPPORTED_PROTOCOL_VERSIONS` back — so a child that has
  /// gained a newer protocol still answers with the old one it was asked for,
  /// and the drift warning in `ServerCheck` never fires. Measuring it properly
  /// would mean asking for a version no child supports, which changes what
  /// every spawn negotiates; both `ServerCheck` and `ToolProbe` are built on
  /// reusing the live supervised child rather than probing a private one, and
  /// this file has no business changing that from underneath them. The SDK's
  /// own constant is the same fact, sitting in a file, costing nothing.
  nonisolated static func protocolCeiling(of server: BastionServer) -> (
    protocol: String, sdk: String
  )? {
    if DemoSeed.isEnabled { return DemoSeed.protocolCeiling(of: server) }
    guard server.origin != .builtin else { return nil }
    // Hoisted to the install prefix in practice — one prefix per server means
    // nothing competes for that slot — but a package that pins its own copy
    // nests it, and then the nested one is what runs.
    let candidates = [
      packageDirectory(of: server)?.appendingPathComponent("node_modules", isDirectory: true),
      directory(of: server.id).appendingPathComponent("node_modules", isDirectory: true),
    ].compactMap { $0?.appendingPathComponent("@modelcontextprotocol/sdk", isDirectory: true) }

    for sdk in candidates {
      guard
        let manifest = try? Data(contentsOf: sdk.appendingPathComponent("package.json")),
        let json = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
        let version = json["version"] as? String
      else { continue }
      for build in ["dist/esm/types.js", "dist/cjs/types.js"] {
        guard let latest = latestProtocol(in: sdk.appendingPathComponent(build)) else { continue }
        return (latest, version)
      }
    }
    return nil
  }

  /// `LATEST_PROTOCOL_VERSION` out of one of the SDK's built files.
  ///
  /// Only the head of the file is read. This runs inside a SwiftUI body, the
  /// file is 80KB of bundled Zod schemas, and the constant is declared in the
  /// first few lines of both builds — paying for the rest on every redraw would
  /// be paying for nothing.
  private nonisolated static func latestProtocol(in file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let head = try? handle.read(upToCount: 16 * 1024) else { return nil }

    let text = String(decoding: head, as: UTF8.self)
    guard
      let declaration = text.range(
        of: "LATEST_PROTOCOL_VERSION[^0-9]{1,32}[0-9]{4}-[0-9]{2}-[0-9]{2}",
        options: .regularExpression),
      let date = text[declaration].range(
        of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression)
    else { return nil }
    return String(text[declaration][date])
  }

  /// The script to hand to node.
  ///
  /// Taken from the package's own `bin` map, not assumed to be `dist/cli.js`.
  /// The catalog is uniform and the assumption would hold for all nine of them;
  /// a custom entry names somebody else's package, where it holds for no reason
  /// at all.
  nonisolated static func entryScript(of server: BastionServer) -> URL? {
    guard let package = server.package, let directory = packageDirectory(of: server),
      let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }

    let relative: String?
    switch json["bin"] {
    case let single as String:
      relative = single
    case let map as [String: String]:
      // The named one, then the package's own name, then the only one there is.
      // A package with one unnamed-looking bin is the common case and refusing
      // it over a name mismatch would be pedantry with a broken server at the
      // end of it.
      relative =
        map[package.binName] ?? map[package.npmName] ?? (map.count == 1 ? map.values.first : nil)
    default:
      relative = nil
    }
    guard let relative else { return nil }
    let script = URL(fileURLWithPath: relative, relativeTo: directory).standardizedFileURL
    // Contained, checked, and not a formality: `bin` is a string out of a
    // downloaded package, and `"../../../etc/something"` is a thing a file can
    // say. It would be a strange package rather than a dangerous one — Bastion
    // is about to run its code either way — but resolving outside the install
    // means the path is not the thing that was installed, and that is worth
    // refusing on its own.
    guard script.path.hasPrefix(directory.standardizedFileURL.path + "/") else {
      hostLog("install", .error, "\(server.id): bin escapes the package directory")
      return nil
    }
    guard FileManager.default.fileExists(atPath: script.path) else { return nil }
    return script
  }

  nonisolated static func isInstalled(_ server: BastionServer) -> Bool {
    if DemoSeed.isEnabled { return DemoSeed.isInstalled(server) }
    // Nothing to install means nothing missing. Bastion's own server is the
    // running app, and a remote one is somebody else's process on somebody
    // else's machine — neither has a directory, and reporting either as "not
    // installed" would put a permanent red badge next to a server that works.
    guard server.package != nil else { return true }
    return entryScript(of: server) != nil
  }

  // MARK: - Installing

  /// How old a published version must be before Bastion will install it,
  /// in days — or `nil` to leave npm's own configuration alone.
  ///
  /// Absent by default, and absent is not the same as zero. npm reads the
  /// user's `~/.npmrc` here (see `runInstall`), and `min-release-age` there is
  /// a deliberate supply-chain quarantine: a window in which a compromised
  /// release is likely to be caught and unpublished before anything installs
  /// it. Bastion defaulting to an override would quietly switch that off for
  /// the one kind of package it exists to run, which is the wrong way round.
  ///
  /// What the setting is *for* is the other half of the problem: the policy is
  /// global, and relaxing it in `~/.npmrc` to install one day-old server
  /// weakens every install on the machine. This narrows the exception to
  /// Bastion.
  nonisolated static let releaseAgeKey = "npmMinReleaseAge"

  nonisolated static var releaseAgeOverride: Int? {
    guard let stored = UserDefaults.standard.object(forKey: releaseAgeKey) as? Int,
      stored >= 0
    else { return nil }
    return stored
  }

  enum InstallError: LocalizedError {
    case notPublished(String)
    case noRuntime
    case npmFailed(code: Int32, detail: String)
    case noEntryPoint(package: String)
    case quarantined(package: String)

    var errorDescription: String? {
      switch self {
      case .notPublished(let name):
        return
          "\(name) is not published to npm yet. It runs only against a local checkout — see `make dev-config`."
      case .noRuntime:
        return "this build has no embedded node runtime to install with"
      case .npmFailed(let code, let detail):
        return detail.isEmpty ? "npm exited \(code)" : detail
      case .noEntryPoint(let package):
        return "\(package) installed, but declares no runnable bin — it may not be an MCP server"
      case .quarantined(let package):
        // npm says "No versions available", which reads exactly like the
        // package does not exist. It does; every version of it is simply
        // younger than the window npm was told to apply.
        return
          "every published version of \(package) is newer than the release-age window npm is "
          + "applying — `min-release-age` or `before`, usually from ~/.npmrc. Wait until a "
          + "version is old enough, or set a shorter window for Bastion alone in Settings › "
          + "General."
      }
    }
  }

  /// Install or re-install one server. Safe to call on something already there:
  /// npm resolves `latest` again, which is what "Update" means — and on success
  /// any running child of this server is stopped, because the code it was
  /// running is no longer the code on disk.
  func install(_ server: BastionServer) async {
    // Nothing to fetch — Bastion's own server ships inside the app, and a
    // remote one is not code Bastion holds. Silently rather than as an error:
    // this is reachable from a bulk update, and a failure there would be
    // reporting a problem that does not exist.
    guard let package = server.package else { return }
    guard !isRunning(server.id) else { return }
    running[server.id] = "Installing…"
    failures[server.id] = nil
    // Whatever a check last said is about to stop being true either way.
    availability[server.id] = nil

    let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
      do {
        try Self.runInstall(server, package: package)
        guard Self.entryScript(of: server) != nil else {
          throw InstallError.noEntryPoint(package: package.npmName)
        }
        return .success(Self.installedVersion(of: server) ?? "unknown")
      } catch {
        return .failure(error)
      }
    }.value

    running[server.id] = nil
    switch result {
    case .success(let version):
      hostLog("install", .info, "\(server.id): installed \(package.npmName)@\(version)")
      // The code under any running child has just been replaced, so the child
      // goes. Same rule as `ProfileStore.upsert` and `ServerStore.setEnabled`,
      // and for the same reason: a process still answering out of the tree that
      // was there a moment ago, while the detail pane reads the new version
      // straight off disk, is a disagreement with nothing pointing at the cause.
      //
      // Unconditional rather than only when the version moved. `--no-package-lock`
      // means a re-resolve can change the dependency closure under an unchanged
      // top-level version, and npm swaps `node_modules` in place either way —
      // enough on its own to leave a live child lazily requiring out of a tree
      // that no longer matches the one it started from. It costs the next caller
      // one spawn and handshake, and a stop with nothing running is a no-op.
      for profile in ProfileStore.shared.profiles where profile.serverID == server.id {
        Supervisor.shared.stop(profile: profile.name, server: server.id)
      }
    case .failure(let error):
      failures[server.id] = error.localizedDescription
      hostLog("install", .error, "\(server.id): \(error.localizedDescription)")
    }
  }

  /// Ask npm what it would install, and keep the answer for the UI.
  ///
  /// User-initiated, never on a timer. `UpdateController` documents Bastion's
  /// one outbound connection and `scripts/audit-listener.sh` guards the shape
  /// of that claim; `npm install` reaches the registry too, but only ever
  /// because somebody pressed something. A background poll for nine packages
  /// would make "Bastion talks to the network when you ask it to" stop being
  /// true, for a badge nobody asked for.
  func checkForUpdate(_ server: BastionServer) async {
    guard let package = server.package, package.distribution == .npm else { return }
    guard !isRunning(server.id), !isChecking(server.id) else { return }
    // Nothing on disk to compare against, and "up to date" would be a lie about
    // a package that is not there. Install is the button for this state.
    guard let installed = Self.installedVersion(of: server) else { return }

    checking.insert(server.id)
    let result = await Task.detached(priority: .userInitiated) { () -> Result<Plan, Error> in
      do { return .success(try Self.runCheck(server, package: package)) } catch {
        return .failure(error)
      }
    }.value
    checking.remove(server.id)

    switch result {
    case .success(.nothing):
      availability[server.id] = .upToDate
    case .success(.dependencies(let count)):
      availability[server.id] = .needsRepair(count)
      hostLog(
        "install", .info,
        "\(server.id): \(package.npmName) is current, but \(count) package(s) in its tree are not")
    case .success(.package(let resolved)):
      guard resolved != installed else {
        availability[server.id] = .upToDate
        return
      }
      availability[server.id] =
        Self.isVersion(resolved, newerThan: installed) ? .newer(resolved) : .pinnedOlder(resolved)
      hostLog(
        "install", .info, "\(server.id): \(package.npmName) \(installed) → \(resolved) available")
    case .failure(let error):
      availability[server.id] = .failed(error.localizedDescription)
      hostLog("install", .error, "\(server.id): check failed — \(error.localizedDescription)")
    }
  }

  /// Delete an install. Called when a server is removed or renamed, and
  /// tolerant of there being nothing there — removing a `.local` server that was
  /// never installed is the normal case, not an error.
  ///
  /// Takes an **id**, not a server, because the caller that matters most is a
  /// rename: by the time it runs, the definition holding the old id has already
  /// been replaced, and a `BastionServer` parameter would quietly delete the new
  /// install instead of the stale one.
  nonisolated static func removeInstall(id: String) {
    try? FileManager.default.removeItem(at: directory(of: id))
  }

  // MARK: - The subprocess

  private nonisolated static func runInstall(
    _ server: BastionServer, package: BastionServer.Package
  ) throws {
    guard package.distribution == .npm else {
      throw InstallError.notPublished(package.npmName)
    }
    guard let node = ServerLocator.nodeExecutable(), let npm = ServerLocator.npmCLI() else {
      throw InstallError.noRuntime
    }

    let directory = directory(of: server.id)
    let manager = FileManager.default
    try manager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

    // A private stub, so npm has a package.json at the prefix and does not walk
    // up looking for one. Rewritten every time rather than merged: nothing
    // reads it but npm, and a stale one is a dependency range nobody chose.
    let stub: [String: Any] = [
      "name": "bastion-server-\(server.id)", "version": "0.0.0", "private": true,
    ]
    try JSONSerialization.data(withJSONObject: stub, options: [.prettyPrinted])
      .write(to: directory.appendingPathComponent("package.json"), options: .atomic)

    let process = Process()
    process.executableURL = node
    process.arguments = Self.installArguments(package, npm: npm, in: directory)
    process.currentDirectoryURL = directory
    process.environment = Self.npmEnvironment()

    let errors = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    closeOnExec(errors.fileHandleForReading.fileDescriptor)

    try process.run()
    // Read before waiting. npm on a slow registry writes more than a pipe
    // buffer holds, and waiting first would deadlock against a child blocked on
    // a write nobody is draining.
    let detail = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      // Checked against the code rather than the sentence: `lastMeaningfulLine`
      // drops the `code ENOVERSIONS` line on purpose, and the sentence it keeps
      // is the one that does not explain itself.
      if detail.contains("ENOVERSIONS") {
        throw InstallError.quarantined(package: package.npmName)
      }
      throw InstallError.npmFailed(
        code: process.terminationStatus,
        detail: Self.lastMeaningfulLine(of: detail))
    }
  }

  /// The argv both the install and the check are built from.
  ///
  /// Shared rather than written twice, because the check is only worth showing
  /// if it answers the question the button will act on. Resolution depends on
  /// the prefix, the registry, the auth and the release-age window; two
  /// argument lists that drifted apart would produce a badge advertising a
  /// version the install then refuses.
  private nonisolated static func installArguments(
    _ package: BastionServer.Package, npm: URL, in directory: URL
  ) -> [String] {
    [
      npm.path, "install", "\(package.npmName)@latest",
      "--prefix", directory.path,
      // What ships is the runtime closure and nothing else.
      "--omit=dev", "--no-package-lock", "--no-audit", "--no-fund",
      // A postinstall from a transitive dependency has no business running
      // here. Not a security boundary — Bastion is about to run this package's
      // code on purpose — but a build step firing inside Application Support
      // during what the UI calls "Installing…" is a surprise with no upside.
      "--ignore-scripts",
      "--loglevel=error",
    ]
  }

  /// Minimal, like every other environment Bastion builds — with one deliberate
  /// exception. `HOME` means npm reads the user's `~/.npmrc`, which carries
  /// their registry, their scope mappings and their auth token. That is
  /// inherited on purpose: without it a private or scoped package cannot be
  /// installed at all, which would rule out most of the servers somebody would
  /// want to ADD rather than pick from the catalog.
  ///
  /// The cost is that npm policies apply here too, and the failure they cause
  /// does not name itself. `min-release-age` in a developer's `.npmrc` filters
  /// out every version of a package published today and npm reports it as
  /// `ENOVERSIONS: No versions available` — a sentence that reads like the
  /// package does not exist. `lastMeaningfulLine` at least surfaces it rather
  /// than swallowing it.
  private nonisolated static func npmEnvironment() -> [String: String] {
    var environment = [
      "PATH": "/usr/bin:/bin",
      "HOME": NSHomeDirectory(),
      // Bastion's own cache, not the user's. npm's default cache is shared with
      // whatever else on the machine writes to it, and a permissions problem
      // there would surface here as an install failure nobody could act on.
      "npm_config_cache": root.appendingPathComponent(".npm-cache", isDirectory: true).path,
      "npm_config_update_notifier": "false",
    ]
    // env beats the user's `.npmrc`, which is the whole point: the exception is
    // Bastion's, and `~/.npmrc` keeps saying what it said for everything else.
    if let days = releaseAgeOverride {
      environment["npm_config_min_release_age"] = String(days)
    }
    return environment
  }

  /// What npm *would* install, without installing it. `nil` when it plans no
  /// change, which is the up-to-date answer.
  ///
  /// This is the install command with `--dry-run --json` on the end, and using
  /// the resolver rather than asking the registry directly is the whole design.
  /// `npm view <pkg> version` reports the `latest` dist-tag and ignores
  /// `min-release-age` entirely — measured, not assumed: under a 3650-day
  /// window `npm view zod version` still answers `4.5.4` while an install of
  /// the same package fails `ENOVERSIONS`. A badge built on `npm view` would
  /// therefore advertise versions this app refuses to install, which is a worse
  /// state than no badge at all.
  ///
  /// Only stdout is read. `--json` puts the plan there and, on failure, an
  /// `error` object with npm's own code in it, so the second pipe the human
  /// text would need is not worth the deadlock it has to be written around.
  /// What one dry run came back with.
  private enum Plan {
    /// An empty plan. Not "the server package is current" — nothing is.
    case nothing
    /// The server package itself would land at this version.
    case package(String)
    /// The server package is untouched and this many other packages are not.
    case dependencies(Int)
  }

  private nonisolated static func runCheck(
    _ server: BastionServer, package: BastionServer.Package
  ) throws -> Plan {
    guard package.distribution == .npm else {
      throw InstallError.notPublished(package.npmName)
    }
    guard let node = ServerLocator.nodeExecutable(), let npm = ServerLocator.npmCLI() else {
      throw InstallError.noRuntime
    }

    let directory = directory(of: server.id)
    let process = Process()
    process.executableURL = node
    // Nothing is written: no stub is rewritten, no tree is touched. The prefix
    // already has the `package.json` the install left there, and `--dry-run`
    // resolves against the installed tree without changing it.
    process.arguments =
      installArguments(package, npm: npm, in: directory) + ["--dry-run", "--json"]
    process.currentDirectoryURL = directory
    process.environment = npmEnvironment()

    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    closeOnExec(output.fileHandleForReading.fileDescriptor)

    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    // npm prints a human summary line ("change zod 4.5.0 => 4.5.4") *before*
    // the JSON, on the same stream. Parsing from the first brace rather than
    // from the start of the buffer is what makes that line harmless.
    let text = String(decoding: data, as: UTF8.self)
    let plan =
      text.firstIndex(of: "{").flatMap {
        try? JSONSerialization.jsonObject(with: Data(text[$0...].utf8))
      } as? [String: Any]

    if let error = plan?["error"] as? [String: Any] {
      if error["code"] as? String == "ENOVERSIONS" {
        throw InstallError.quarantined(package: package.npmName)
      }
      throw InstallError.npmFailed(
        code: process.terminationStatus, detail: error["summary"] as? String ?? "")
    }
    guard process.terminationStatus == 0, let plan else {
      throw InstallError.npmFailed(code: process.terminationStatus, detail: "")
    }

    let added = (plan["add"] as? [[String: Any]]) ?? []
    let changed = (plan["change"] as? [[String: Any]]) ?? []
    let removed = (plan["remove"] as? [[String: Any]]) ?? []

    // The package by name, not the first entry: the plan covers the whole
    // dependency closure, and a transitive bump is not the version on screen.
    if let change = changed.first(where: {
      ($0["to"] as? [String: Any])?["name"] as? String == package.npmName
    }), let version = (change["to"] as? [String: Any])?["version"] as? String {
      return .package(version)
    }
    // `add` rather than `change` when the tree lost the package underneath us.
    if let add = added.first(where: { $0["name"] as? String == package.npmName }),
      let version = add["version"] as? String
    {
      return .package(version)
    }

    // Everything else npm plans. Filtering this away made a half-deleted
    // `node_modules` report as "up to date", which is the one state where the
    // button matters most: measured, an install of `@mgcrea/mcp-shopify` with
    // `zod` and the SDK removed plans two adds and says nothing about the
    // server package at all.
    let rest = added.count + changed.count + removed.count
    return rest == 0 ? .nothing : .dependencies(rest)
  }

  /// Newer for the purpose of choosing a *sentence*, and nothing else.
  ///
  /// npm has already done the resolving; this only decides whether the version
  /// it picked is ahead of or behind the one on disk, so numeric components
  /// compared left to right is enough. A prerelease sorts below the release it
  /// leads to, which is the one semver rule that would otherwise read backwards.
  nonisolated static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
    func parts(_ version: String) -> ([Int], Bool) {
      let release = version.split(separator: "-", maxSplits: 1)[0]
      return (release.split(separator: ".").map { Int($0) ?? 0 }, version.contains("-"))
    }
    let (left, leftPre) = parts(candidate)
    let (right, rightPre) = parts(installed)
    for index in 0..<max(left.count, right.count) {
      let a = index < left.count ? left[index] : 0
      let b = index < right.count ? right[index] : 0
      if a != b { return a > b }
    }
    return rightPre && !leftPre
  }

  /// npm's failures are several screens of stack trace with the sentence in the
  /// middle. This finds the sentence, because the alternative is a dialog that
  /// technically contains the answer.
  private nonisolated static func lastMeaningfulLine(of output: String) -> String {
    let lines = output.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(
          of: "^npm (error|ERR!) +", with: "", options: .regularExpression)
    }
    let interesting = lines.filter {
      !$0.isEmpty && !$0.hasPrefix("A complete log") && !$0.hasPrefix("code ")
        && $0.range(of: "^[a-z]+\\.log$", options: .regularExpression) == nil
    }
    return interesting.first ?? ""
  }
}
