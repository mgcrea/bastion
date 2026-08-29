import Foundation

/// Where a server's code actually lives.
nonisolated struct ServerBinaries {
  let node: URL
  let script: URL
  /// True when these came from the dev override rather than the bundle.
  let isDevelopment: Bool
}

enum LocateError: LocalizedError {
  case notBundled(server: String, expected: String)
  case devConfigInvalid(String)

  var errorDescription: String? {
    switch self {
    case .notBundled(let server, let expected):
      return "the \(server) server is not in this build (expected \(expected))"
    case .devConfigInvalid(let detail):
      return "dev.json is unusable: \(detail)"
    }
  }
}

nonisolated enum ServerLocator {
  /// Production layout:
  ///
  ///     Bastion.app/Contents/Resources/node
  ///     Bastion.app/Contents/Resources/servers/<id>/package.json
  ///     Bastion.app/Contents/Resources/servers/<id>/dist/cli.js
  ///
  /// The `package.json` + `dist/` shape is not decoration: these servers read
  /// their own version from `new URL("../package.json", import.meta.url)`, so a
  /// flat `servers/<id>/cli.js` would resolve to one shared file and report the
  /// wrong version in every diagnostic.
  ///
  /// Node is embedded rather than borrowed from the system. The official
  /// nodejs.org darwin builds are a single self-contained binary, which removes
  /// any "which node?" question — and that question is not academic here: the
  /// gateway spawns children with a deliberately minimal environment, so a
  /// server resolved through the developer's `PATH` would work in a terminal
  /// and fail under LaunchServices.
  ///
  /// The argument is `server`, never a path. Same closed-table invariant as
  /// `ServerCatalog`: a component that ran whatever path it was handed would be
  /// a way for anything that reached the gateway to execute arbitrary code with
  /// the user's credentials already in the environment.
  static func locate(_ server: BastionServer) throws -> ServerBinaries {
    guard let resources = Bundle.main.resourceURL else {
      throw LocateError.notBundled(server: server.id, expected: "Contents/Resources")
    }
    let node = resources.appendingPathComponent("node")
    let script =
      resources
      .appendingPathComponent("servers")
      .appendingPathComponent(server.id)
      .appendingPathComponent("dist/cli.js")

    let exists = FileManager.default.fileExists(atPath:)
    if exists(node.path), exists(script.path) {
      return ServerBinaries(node: node, script: script, isDevelopment: false)
    }

    #if DEBUG
      // Before the release staging exists, run the servers straight out of the
      // checkout. Read from a file rather than the environment because
      // LaunchServices does not hand an app the developer's shell environment.
      if let dev = try developmentBinaries(server) { return dev }
    #endif

    throw LocateError.notBundled(server: server.id, expected: script.path)
  }

  #if DEBUG
    /// `~/Library/Application Support/io.mgcrea.bastion.debug/dev.json`:
    ///
    ///     { "node": "/opt/homebrew/opt/node@24/bin/node",
    ///       "repo": "/Users/you/Projects/mgcrea/mgcrea-ai" }
    ///
    /// `repo` is the directory holding the server checkouts, and the manifest's
    /// `localPath` names the one to use. Seven of the ten servers are not
    /// published at all, so for most of v1's dogfooding this is not a fallback
    /// — it is the only path that resolves.
    private static func developmentBinaries(_ server: BastionServer) throws -> ServerBinaries? {
      let url = AppSupport.directory.appendingPathComponent("dev.json")
      guard let data = try? Data(contentsOf: url) else { return nil }

      guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
        let node = json["node"], let repo = json["repo"]
      else { throw LocateError.devConfigInvalid("expected {\"node\": …, \"repo\": …}") }

      let script = URL(fileURLWithPath: repo)
        .appendingPathComponent(server.localPath)
        .appendingPathComponent("dist/cli.js")

      let exists = FileManager.default.fileExists(atPath:)
      guard exists(node) else { throw LocateError.devConfigInvalid("no node at \(node)") }
      guard exists(script.path) else {
        throw LocateError.devConfigInvalid("no build at \(script.path) — run `pnpm build` there")
      }
      return ServerBinaries(
        node: URL(fileURLWithPath: node), script: script, isDevelopment: true)
    }
  #endif
}
