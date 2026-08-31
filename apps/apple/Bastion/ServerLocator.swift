import Foundation

/// Where a server's code actually lives.
nonisolated struct ServerBinaries {
  let node: URL
  let script: URL
  /// True when these came from the dev override rather than from an install.
  let isDevelopment: Bool
}

enum LocateError: LocalizedError {
  case notInstalled(server: String)
  case noRuntime
  case devConfigInvalid(String)
  case builtin
  case remote(server: String)

  var errorDescription: String? {
    switch self {
    case .notInstalled(let server):
      return "the \(server) server is not installed — install it in Bastion"
    case .builtin:
      return "Bastion's own server runs in-process and has no code to locate"
    case .remote(let server):
      return "\(server) is a remote server — there is nothing to install and no process to start"
    case .noRuntime:
      return "this build has no embedded node runtime"
    case .devConfigInvalid(let detail):
      return "dev.json is unusable: \(detail)"
    }
  }
}

nonisolated enum ServerLocator {
  /// The embedded runtime.
  ///
  ///     Bastion.app/Contents/Resources/node
  ///     Bastion.app/Contents/Resources/npm/bin/npm-cli.js
  ///
  /// Node is embedded rather than borrowed from the system. The official
  /// nodejs.org darwin builds are a single self-contained binary, which removes
  /// any "which node?" question — and that question is not academic here: the
  /// gateway spawns children with a deliberately minimal environment, so a
  /// server resolved through the developer's `PATH` would work in a terminal
  /// and fail under LaunchServices.
  ///
  /// npm rides along because installs happen on demand now. It is the same
  /// npm that runtime shipped with, which is the version its own `engines`
  /// ranges were written against.
  static func nodeExecutable() -> URL? {
    if let resources = Bundle.main.resourceURL {
      let bundled = resources.appendingPathComponent("node")
      if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    }
    #if DEBUG
      if let dev = try? developmentConfig() { return URL(fileURLWithPath: dev.node) }
    #endif
    return nil
  }

  static func npmCLI() -> URL? {
    if let resources = Bundle.main.resourceURL {
      let bundled = resources.appendingPathComponent("npm/bin/npm-cli.js")
      if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    }
    #if DEBUG
      // Beside the developer's own node, in the layout every distribution of it
      // uses: <prefix>/bin/node and <prefix>/lib/node_modules/npm. Debug only —
      // a release build that reached outside its bundle for a package manager
      // would be running code nobody signed.
      if let dev = try? developmentConfig() {
        let prefix = URL(fileURLWithPath: dev.node).deletingLastPathComponent()
          .deletingLastPathComponent()
        let cli = prefix.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js")
        if FileManager.default.fileExists(atPath: cli.path) { return cli }
      }
    #endif
    return nil
  }

  /// Resolve one server to a runtime and a script.
  ///
  /// The argument is a `BastionServer` the user installed, never a path. Same
  /// invariant the closed table used to carry and the only half of it that was
  /// ever load-bearing: a component that ran whatever path it was handed would
  /// be a way for anything reaching the gateway to execute arbitrary code with
  /// the user's credentials already in the environment. What changed is who
  /// writes the list, not how a request selects from it.
  static func locate(_ server: BastionServer) throws -> ServerBinaries {
    // Belt and braces. `Supervisor.call` branches on the transport before it
    // can reach a spawn, so neither of these is reachable today — and they are
    // the sentences worth having if that branch is ever moved.
    switch server.transport {
    case .inProcess: throw LocateError.builtin
    case .remote: throw LocateError.remote(server: server.id)
    case .child: break
    }
    guard let package = server.package else { throw LocateError.builtin }
    guard let node = nodeExecutable() else { throw LocateError.noRuntime }

    #if DEBUG
      // The checkout wins in Debug, which is what `make dev-config` is for:
      // dogfooding against an edit you just made beats whatever npm last
      // resolved. One catalog entry is still unpublished, so for that one this
      // is not a preference but the only path that resolves.
      if let dev = try developmentBinaries(package, node: node) { return dev }
    #endif

    guard let script = ServerInstaller.entryScript(of: server) else {
      throw LocateError.notInstalled(server: server.id)
    }
    return ServerBinaries(node: node, script: script, isDevelopment: false)
  }

  #if DEBUG
    private struct DevConfig {
      let node: String
      let repo: String
    }

    /// `~/Library/Application Support/io.mgcrea.bastion.debug/dev.json`:
    ///
    ///     { "node": "/opt/homebrew/opt/node@24/bin/node",
    ///       "repo": "/Users/you/Projects/mgcrea/mgcrea-ai" }
    ///
    /// `repo` is the directory holding the server checkouts, and the manifest's
    /// `localPath` names the one to use.
    private static func developmentConfig() throws -> DevConfig? {
      let url = AppSupport.directory.appendingPathComponent("dev.json")
      guard let data = try? Data(contentsOf: url) else { return nil }
      guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
        let node = json["node"], let repo = json["repo"]
      else { throw LocateError.devConfigInvalid("expected {\"node\": …, \"repo\": …}") }
      guard FileManager.default.fileExists(atPath: node) else {
        throw LocateError.devConfigInvalid("no node at \(node)")
      }
      return DevConfig(node: node, repo: repo)
    }

    private static func developmentBinaries(_ package: BastionServer.Package, node: URL) throws
      -> ServerBinaries?
    {
      guard let dev = try developmentConfig() else { return nil }

      let script = URL(fileURLWithPath: dev.repo)
        .appendingPathComponent(package.localPath)
        .appendingPathComponent("dist/cli.js")

      // Absent, not fatal. A custom server the developer added by package name
      // has no checkout under `repo` and must fall through to its install — so
      // "no build here" is a miss, and only a `dev.json` that cannot be read at
      // all is an error.
      guard FileManager.default.fileExists(atPath: script.path) else { return nil }
      return ServerBinaries(node: node, script: script, isDevelopment: true)
    }
  #endif
}
