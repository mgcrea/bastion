import Foundation

/// The document a Debug build imports profiles and gateway tokens from:
/// `import.json` in its Application Support directory, read by `DevSeed` on
/// launch and stripped to `imported.json`.
///
/// Its own file and not `#if DEBUG`, because the Release build writes one. Its
/// credentials live in the data protection keychain, which `security` cannot
/// read, so `make dev-clone` can no longer build this document; Settings ›
/// General › Export to the Debug Build does, after a click. One type for both
/// ends, so the writer and the reader cannot drift.
///
/// Foundation only, so `scripts/unit-check.swift` compiles it.
nonisolated struct DevImportDocument: Codable {
  var token: String?
  /// Extra clients to mint a token for, each left in `dev-token-<client>`.
  ///
  /// Optional and additive, so every `import.json` that predates it still
  /// decodes. It exists because `scripts/facade-check.sh` has to prove that
  /// two clients on ONE profile are served differently, and bash has no
  /// honest way to get a second token: minting one with `security` means
  /// re-spelling `CredentialStore`'s service and account naming in shell,
  /// and reading the developer's real Claude Code token would put a live
  /// credential in a shell variable and make the check depend on whether
  /// that client happens to be wired.
  var tokens: [String]?
  /// Existing gateway tokens to adopt, by client, verbatim.
  ///
  /// Not minted, unlike the two fields above — carried. This is how
  /// `make dev-clone` makes a Debug build a drop-in replacement for the
  /// installed app on the same port: every client config Bastion wrote
  /// carries the INSTALLED app's token, and a Debug build checks tokens
  /// against its own Keychain service, so without this every editor gets a
  /// 401 the moment the Debug build is the one listening.
  ///
  /// Safe to copy where an OAuth token set is not, because a gateway token
  /// never rotates: `ClientWiring.token(for:)` mints one once and reuses it.
  /// Written here, by the app, rather than by `security` in the script, so
  /// the Keychain item carries this build's own ACL — an item the `security`
  /// tool created would prompt on every read — and the value never sits in
  /// a process's argv.
  var gatewayTokens: [String: String]?
  var profiles: [Row]

  struct Row: Codable {
    var name: String
    var server: String
    var allowWrites: Bool?
    var values: [String: String]
  }

  /// The document the Release build's export writes.
  ///
  /// `dev` is left out: it is the Debug build's own scripting identity, read
  /// back from its `dev-token` file by the check scripts, and replacing it
  /// would leave every one of them holding a token the Debug build no longer
  /// accepts. `make dev-clone` skipped it for the same reason.
  static func export(profiles: [Row], gatewayTokens: [String: String]) -> DevImportDocument {
    DevImportDocument(
      token: nil, tokens: nil, gatewayTokens: gatewayTokens.filter { $0.key != "dev" },
      profiles: profiles)
  }

  /// Where the export goes: `import.json` in the Debug build's Application
  /// Support directory, or nil when there is no such directory. An export
  /// never creates it — no Debug build has run on this Mac, and a file it
  /// would never read is a file of credentials for nothing.
  static func destination(debugSupport: URL, fileManager: FileManager = .default) -> URL? {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: debugSupport.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return nil }
    return debugSupport.appendingPathComponent("import.json")
  }
}
