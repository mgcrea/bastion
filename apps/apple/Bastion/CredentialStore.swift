import Foundation
import Security

/// Every secret Bastion holds, in the login Keychain.
///
/// This is the point of the whole exercise. Right now `mcp-tastytrade`,
/// `mcp-shopify`, `mcp-keycloak` and `mcp-appstore-connect` each keep a
/// `.mcp.json` with real credentials in plaintext, readable by anything running
/// as this user and one careless `git add` from being published. A secret that
/// lives here is readable only by this app, gated by the login keychain, and
/// never appears in any file a client reads.
///
/// **Scoped by bundle identifier.** Keychain items belong to the app that made
/// them, so a Debug build with the same identifier as the release would read,
/// overwrite and delete the credentials the real app is holding. That is why
/// the Debug build carries `.debug` on its identifier, and why that suffix is
/// load-bearing rather than cosmetic.
nonisolated enum CredentialStore {
  /// Generic passwords, keyed by service + account.
  ///
  /// Two services rather than one: profile credentials and the gateway's own
  /// bearer tokens are different kinds of thing with different lifetimes, and
  /// "delete everything for this profile" must not be able to sweep up the
  /// token a client is authenticating with.
  enum Scope {
    case profile
    case gatewayToken

    var service: String {
      let base = AppSupport.identifier
      switch self {
      case .profile: return "\(base).profile"
      case .gatewayToken: return "\(base).gateway"
      }
    }
  }

  enum StoreError: LocalizedError {
    case keychain(OSStatus, String)

    var errorDescription: String? {
      switch self {
      case .keychain(let status, let what):
        let detail =
          SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return "keychain: could not \(what) — \(detail)"
      }
    }
  }

  /// The account name for one variable of one profile.
  ///
  /// `<profile>/<server>/<VAR>`. Profile names are validated at creation to
  /// exclude `/`, so this cannot be made ambiguous by a name — see
  /// `Profile.isValidName`.
  static func account(profile: String, server: String, variable: String) -> String {
    "\(profile)/\(server)/\(variable)"
  }

  static func read(_ scope: Scope, account: String) -> String? {
    var query = baseQuery(scope, account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Write, replacing any existing value.
  ///
  /// `SecItemUpdate` after a failed add rather than delete-then-add: the delete
  /// half of a delete-then-add can succeed while the add fails, which loses a
  /// credential in exchange for nothing.
  static func write(_ scope: Scope, account: String, value: String) throws {
    let data = Data(value.utf8)
    var query = baseQuery(scope, account: account)

    let update = [kSecValueData as String: data] as CFDictionary
    let updated = SecItemUpdate(query as CFDictionary, update)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else {
      throw StoreError.keychain(updated, "update \(account)")
    }

    query[kSecValueData as String] = data
    // The credential is needed whenever a tool call arrives, which may be while
    // the screen is locked — an agent working in the background is the normal
    // case, not the exception. `AfterFirstUnlock` is the weakest accessibility
    // that survives that, and `ThisDeviceOnly` keeps it out of iCloud Keychain:
    // a gateway credential has no business syncing to a phone.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(query as CFDictionary, nil)
    guard added == errSecSuccess else { throw StoreError.keychain(added, "store \(account)") }
  }

  static func delete(_ scope: Scope, account: String) throws {
    let status = SecItemDelete(baseQuery(scope, account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw StoreError.keychain(status, "delete \(account)")
    }
  }

  /// Every account name stored under one scope.
  ///
  /// Used to find a profile's secrets without knowing which variables it set,
  /// which matters for deletion: a profile that is removed must not leave a
  /// credential behind under a variable name the manifest has since dropped.
  static func accounts(_ scope: Scope) -> [String] {
    var query = baseQuery(scope, account: nil)
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll

    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let rows = item as? [[String: Any]]
    else { return [] }
    return rows.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  private static func baseQuery(_ scope: Scope, account: String?) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: scope.service,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    return query
  }
}

/// The gateway's bearer token.
///
/// Security rule 3: every client authenticates with a token minted here and
/// written into that client's MCP configuration. The token goes in the config
/// file; the *credential* never does. That split is the whole design — a
/// `.mcp.json` that leaks now leaks a revocable loopback token instead of a
/// Shopify secret and a brokerage refresh token.
///
/// One token per client, addressed by client name, so revoking VS Code does not
/// sign Claude Code out.
nonisolated enum GatewayToken {
  /// 256 bits from the system CSPRNG, base64url so it survives a shell, a JSON
  /// file and an HTTP header without escaping.
  static func mint() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    // There is no safe fallback. A predictable bearer token on a loopback
    // listener holding every credential the user owns is the whole CVE-2025-
    // 49596 shape, so a CSPRNG that will not answer is fatal rather than
    // something to paper over with `arc4random`.
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func issue(to client: String) throws -> String {
    let token = mint()
    try CredentialStore.write(.gatewayToken, account: client, value: token)
    return token
  }

  static func revoke(_ client: String) throws {
    try CredentialStore.delete(.gatewayToken, account: client)
  }

  /// Which client, if any, this token belongs to.
  ///
  /// Linear over the issued tokens, compared in constant time. Both parts are
  /// deliberate: the set is a handful of entries, and a comparison that returns
  /// early on the first differing byte leaks the token prefix to anything that
  /// can time it — which, on a loopback listener a web page can reach, is not a
  /// theoretical attacker.
  static func identify(_ presented: String) -> String? {
    let candidate = Array(presented.utf8)
    for client in CredentialStore.accounts(.gatewayToken) {
      guard let stored = CredentialStore.read(.gatewayToken, account: client) else { continue }
      if constantTimeEquals(candidate, Array(stored.utf8)) { return client }
    }
    return nil
  }

  private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    // The length difference is not secret — it is visible in the request — but
    // the contents are, so the loop must not short-circuit on a mismatch.
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in 0..<a.count { difference |= a[i] ^ b[i] }
    return difference == 0
  }
}
