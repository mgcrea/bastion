#if DEBUG
  import Foundation

  /// Import profiles from a file, in Debug builds only.
  ///
  /// There is no profile editor yet — that is step 6 of the build order — and
  /// step 3 has to be provable end-to-end before then. This is how a credential
  /// gets in until there is a window to type it into.
  ///
  /// It is also the shape of the migration in step 5. The four `.mcp.json`
  /// files in `mgcrea-ai` that currently hold real credentials in plaintext are
  /// exactly this document with different key names, and the important part of
  /// that migration is not the reading — it is the STRIPPING: an import that
  /// leaves the secret in the file it came from has moved nothing.
  ///
  /// Debug-only, and deliberately so. A release build that imported credentials
  /// from a file anyone could drop in its Application Support directory would
  /// be a way to add a profile to somebody else's gateway.
  enum DevSeed {
    private static var importURL: URL {
      AppSupport.directory.appendingPathComponent("import.json")
    }

    /// Where the minted token is left for `curl` and the audit script.
    ///
    /// A token in a file is not a violation of rule 5 — it is rule 5. The token
    /// is the thing that is *meant* to travel into a client's config; the
    /// credential is the thing that must not. What leaks if this file leaks is
    /// a revocable loopback token, which is the entire point of the split.
    private static var tokenURL: URL {
      AppSupport.directory.appendingPathComponent("dev-token")
    }

    private struct Document: Codable {
      var token: String?
      var profiles: [Row]

      struct Row: Codable {
        var name: String
        var server: String
        var allowWrites: Bool?
        var values: [String: String]
      }
    }

    @MainActor
    static func runIfPresent() {
      guard let data = try? Data(contentsOf: importURL) else { return }
      guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
        hostLog("import", .error, "import.json is not the expected shape")
        return
      }

      if let client = document.token {
        do {
          let token = try GatewayToken.issue(to: client)
          try Data("\(token)\n".utf8).write(to: tokenURL, options: .atomic)
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
          hostLog("import", .info, "issued a gateway token for '\(client)' → dev-token")
        } catch {
          hostLog("import", .error, "could not issue a token: \(error.localizedDescription)")
        }
      }

      var stripped = document
      for (index, row) in document.profiles.enumerated() {
        // Install it if the import names a catalog entry that is not in the
        // list yet. A seed file exists to get a working setup in one step, and
        // "add the server, then re-run the import" is a step that only exists
        // because the list became editable.
        if ServerStore.lookup(row.server) == nil, ServerCatalog.byID[row.server] != nil {
          try? ServerStore.shared.install(catalogEntry: row.server)
        }
        guard let server = ServerStore.lookup(row.server) else {
          hostLog("import", .error, "unknown server '\(row.server)'")
          continue
        }
        guard Profile.isValidName(row.name) else {
          hostLog("import", .error, "unusable profile name '\(row.name)'")
          continue
        }

        let secretNames = Set(server.env.filter(\.isSecret).map(\.name))
        var plain: [String: String] = [:]
        for (key, value) in row.values where !value.isEmpty {
          guard server.env.contains(where: { $0.name == key }) else {
            // Dropped, not passed through. An import that could set an
            // arbitrary environment variable on a process holding the user's
            // credentials is a capability, not a convenience.
            hostLog("import", .error, "\(row.server): ignoring unknown variable \(key)")
            continue
          }
          // The row carries `allowWrites` of its own, so a gate variable here is
          // a second spelling of the same choice — and the losing one, since
          // the toggle is what `ProfileEnvironment.build` reads.
          guard key != server.writeGate else {
            hostLog("import", .info, "\(row.server): \(key) is set from allowWrites, ignoring")
            continue
          }
          if secretNames.contains(key) {
            try? CredentialStore.write(
              .profile,
              account: CredentialStore.account(
                profile: row.name, server: row.server, variable: key),
              value: value)
          } else {
            plain[key] = value
          }
        }

        do {
          try ProfileStore.shared.upsert(
            Profile(
              name: row.name, serverID: row.server, values: plain,
              allowWrites: row.allowWrites ?? false))
          hostLog("import", .info, "imported \(row.name)/\(row.server)")
        } catch {
          hostLog("import", .error, "could not save \(row.name): \(error.localizedDescription)")
        }

        for key in row.values.keys where secretNames.contains(key) {
          stripped.profiles[index].values[key] = "(moved to the Keychain)"
        }
      }

      // Consumed, not rewritten in place. Rewriting was the first version and
      // it was wrong in a way that took a Shopify "Missing or invalid client
      // secret" to find: the stripped document was left under the name the
      // importer reads, so the NEXT launch re-imported it and stored the
      // literal string "(moved to the Keychain)" over the real credential. The
      // server still started — the value was non-empty, which is all its
      // config schema asks — and only failed at the first API call.
      //
      // Moving the file is what makes the import happen exactly once. The
      // stripped copy is kept rather than deleted so there is a record of what
      // was imported, with the secrets gone.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let consumed = AppSupport.directory.appendingPathComponent("imported.json")
      if let rewritten = try? encoder.encode(stripped) {
        try? rewritten.write(to: consumed, options: .atomic)
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o600], ofItemAtPath: consumed.path)
      }
      try? FileManager.default.removeItem(at: importURL)
      hostLog("import", .info, "import.json consumed → imported.json")
    }
  }
#endif
