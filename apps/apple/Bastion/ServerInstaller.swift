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
    guard server.origin != .builtin, !server.npmName.isEmpty else { return nil }
    var url = directory(of: server.id).appendingPathComponent("node_modules", isDirectory: true)
    // A scoped name is two path components on disk. Splitting rather than
    // appending the whole string keeps that true without a special case.
    for component in server.npmName.split(separator: "/") {
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
    guard let directory = packageDirectory(of: server),
      let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["version"] as? String
  }

  /// The script to hand to node.
  ///
  /// Taken from the package's own `bin` map, not assumed to be `dist/cli.js`.
  /// The catalog is uniform and the assumption would hold for all nine of them;
  /// a custom entry names somebody else's package, where it holds for no reason
  /// at all.
  nonisolated static func entryScript(of server: BastionServer) -> URL? {
    guard let directory = packageDirectory(of: server),
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
      relative = map[server.binName] ?? map[server.npmName] ?? (map.count == 1 ? map.values.first : nil)
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
    // The built-in server is always "installed": it is the running app.
    if server.origin == .builtin { return true }
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
  /// npm resolves `latest` again, which is what "Update" means.
  func install(_ server: BastionServer) async {
    // Nothing to fetch — it ships inside the app. Silently rather than as an
    // error: this is reachable from a bulk update, and a failure there would be
    // reporting a problem that does not exist.
    guard server.origin != .builtin else { return }
    guard !isRunning(server.id) else { return }
    running[server.id] = "Installing…"
    failures[server.id] = nil

    let result = await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
      do {
        try Self.runInstall(server)
        guard Self.entryScript(of: server) != nil else {
          throw InstallError.noEntryPoint(package: server.npmName)
        }
        return .success(Self.installedVersion(of: server) ?? "unknown")
      } catch {
        return .failure(error)
      }
    }.value

    running[server.id] = nil
    switch result {
    case .success(let version):
      hostLog("install", .info, "\(server.id): installed \(server.npmName)@\(version)")
    case .failure(let error):
      failures[server.id] = error.localizedDescription
      hostLog("install", .error, "\(server.id): \(error.localizedDescription)")
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

  private nonisolated static func runInstall(_ server: BastionServer) throws {
    guard server.distribution == .npm else {
      throw InstallError.notPublished(server.npmName)
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
    process.arguments = [
      npm.path, "install", "\(server.npmName)@latest",
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
    process.currentDirectoryURL = directory
    // Minimal, like every other environment Bastion builds — with one
    // deliberate exception. `HOME` means npm reads the user's `~/.npmrc`, which
    // carries their registry, their scope mappings and their auth token. That
    // is inherited on purpose: without it a private or scoped package cannot be
    // installed at all, which would rule out most of the servers somebody would
    // want to ADD rather than pick from the catalog.
    //
    // The cost is that npm policies apply here too, and the failure they cause
    // does not name itself. `min-release-age` in a developer's `.npmrc` filters
    // out every version of a package published today and npm reports it as
    // `ENOVERSIONS: No versions available` — a sentence that reads like the
    // package does not exist. `lastMeaningfulLine` at least surfaces it rather
    // than swallowing it.
    process.environment = [
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
      process.environment?["npm_config_min_release_age"] = String(days)
    }

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
        throw InstallError.quarantined(package: server.npmName)
      }
      throw InstallError.npmFailed(
        code: process.terminationStatus,
        detail: Self.lastMeaningfulLine(of: detail))
    }
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
