import Foundation
import Security
import os

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
    /// OAuth token sets for remote servers.
    ///
    /// A third service rather than reusing `.profile`, because these are not
    /// the same kind of thing: a profile variable is something the user typed
    /// and can retype, and a token set is minted by Bastion, expires, refreshes
    /// itself, and must never be offered to `ProfileEditor` as an editable
    /// field. Keeping them apart is what makes "show the user their variables"
    /// unable to show a token by accident.
    case oauth
    /// The key that signs an audit export.
    ///
    /// A fourth service, and the first PRIVATE key this app has ever held —
    /// everything else here is a credential the user could retype or a token
    /// Bastion can mint again. This one cannot be re-derived: lose it and old
    /// exports still verify against the public half a recipient already has,
    /// while new ones need a fresh pin. `AuditSigning` says so on screen rather
    /// than implying a key is forever.
    ///
    /// Its own service so "delete this profile's secrets" cannot sweep it up,
    /// which is the same argument `.oauth` makes one case above.
    case auditSigning
    /// The internal-host list, as one JSON item.
    ///
    /// Not a secret, but kept here rather than in Application Support because
    /// it widens what a remote server may reach, and a JSON file there is one
    /// any local process can edit — an agent with a shell included. An item
    /// Bastion created can only be changed by another process through the
    /// Keychain, and deleting it empties the list rather than widening it. See
    /// `InternalHostStore`.
    case internalHosts
    /// One item, written when every credential has left the login keychain.
    ///
    /// On the data protection side, where only an app holding Bastion's access
    /// group can create it, so another process cannot write it early and turn
    /// the fallback off while credentials are still on the login side. See
    /// `KeychainMigration`.
    case migration
    /// Which custom servers that arrived from another Mac this Mac has
    /// allowed, as one JSON item. In the Keychain for the reason
    /// `.internalHosts` is: an approval a shell could forge by editing a file
    /// would make the wait mean nothing. Never synced. See
    /// `ServerApprovalStore`.
    case approvals

    /// Every scope that holds credentials, which is every scope a migration
    /// pass moves.
    static let credentialScopes: [Scope] = [
      .profile, .gatewayToken, .oauth, .auditSigning, .internalHosts,
    ]

    var service: String {
      let base = CredentialStore.serviceBase
      switch self {
      case .profile: return "\(base).profile"
      case .gatewayToken: return "\(base).gateway"
      case .oauth: return "\(base).oauth"
      case .auditSigning: return "\(base).audit"
      case .internalHosts: return "\(base).internal-hosts"
      case .migration: return "\(base).migration"
      case .approvals: return "\(base).approvals"
      }
    }
  }

  /// The prefix every service is built on: the bundle identifier, so a Debug
  /// build addresses its own namespace.
  ///
  /// Settable for one reason. `KeychainSelfTest` points it at a throwaway
  /// namespace before anything touches the keychain, so it can run the real
  /// migration on the signed build without going near a real credential.
  /// Nothing else sets it, and the self-test exits rather than handing the
  /// process back.
  nonisolated(unsafe) static var serviceBase = AppSupport.identifier

  /// Whether this process may use the data protection keychain.
  ///
  /// It may when it carries `keychain-access-groups`, which only the Release
  /// build signed with the Developer ID profile does. Debug and the Apple
  /// Development fallback carry none and stay on the login keychain, where they
  /// have always been: without the entitlement every data protection call
  /// answers `-34018`. Asked of the running process rather than decided at
  /// compile time, so a Release build signed without the profile still works.
  static let usesDataProtection: Bool = {
    guard let task = SecTaskCreateFromSelf(nil) else { return false }
    return SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) != nil
  }()

  private static let migrated = OSAllocatedUnfairLock(initialState: false)

  /// Whether a migration pass has moved everything, so the login keychain is
  /// no longer read.
  ///
  /// True once and then cached: the marker is never removed by this app. Asked
  /// by attributes only, which never meets an ACL.
  static var migrationDone: Bool {
    if !usesDataProtection || migrated.withLock({ $0 }) { return true }
    var query = baseQuery(.migration, account: "login-keychain")
    query[kSecReturnAttributes as String] = true
    var item: CFTypeRef?
    let found = SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    if found { migrated.withLock { $0 = true } }
    return found
  }

  enum StoreError: LocalizedError {
    case keychain(OSStatus, String)
    case emptyValue(String)

    var errorDescription: String? {
      switch self {
      case .keychain(let status, let what):
        let detail =
          SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
        return "keychain: could not \(what) — \(detail)"
      case .emptyValue(let account):
        return "keychain: refusing to store an empty value for \(account)"
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

  /// The one account a profile's OAuth token set lives under.
  ///
  /// Deliberately the same `<profile>/<server>/` prefix the variables use, so
  /// that `ProfileStore.remove`'s sweep catches it with the same prefix match
  /// rather than needing to know this exists.
  static func oauthAccount(profile: String, server: String) -> String {
    "\(profile)/\(server)/oauth"
  }

  /// Read a profile's OAuth token set, if it has one.
  static func readTokens(profile: String, server: String) -> RemoteOAuth.TokenSet? {
    // `ProfileEnvironment.missing` asks this for every OAuth auth mode, so it is
    // on the redraw path of any pane listing profiles. Same reason as
    // `accounts`: no real keychain under a capture.
    if DemoSeed.isEnabled { return nil }
    guard
      let raw = read(.oauth, account: oauthAccount(profile: profile, server: server)),
      let data = raw.data(using: .utf8)
    else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(RemoteOAuth.TokenSet.self, from: data)
  }

  /// Replace a profile's OAuth token set. One atomic write, never a field.
  static func writeTokens(_ tokens: RemoteOAuth.TokenSet, profile: String, server: String) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(tokens)
    try write(
      .oauth, account: oauthAccount(profile: profile, server: server),
      value: String(decoding: data, as: UTF8.self))
  }

  static func deleteTokens(profile: String, server: String) throws {
    try delete(.oauth, account: oauthAccount(profile: profile, server: server))
  }

  /// The value, or `nil` — but a refusal is never silent.
  ///
  /// Only `errSecItemNotFound` means "not set". Everything else means the item
  /// exists and we were not allowed to have it: a denied ACL prompt, a prompt
  /// suppressed because the code signature no longer validates, a keychain that
  /// has not been unlocked since boot. Collapsing those into the same `nil` is
  /// how a spawn comes to hand a child a missing credential while the UI
  /// cheerfully reports the variable unset. The call still returns `nil`,
  /// because there is no value to return — but it says so first.
  static func read(_ scope: Scope, account: String) -> String? {
    do {
      return try lookup(scope, account: account)
    } catch {
      hostLog("keychain", .error, error.localizedDescription)
      return nil
    }
  }

  /// The value, nil when it is not set, and an error when it is set and could
  /// not be had. For a caller whose next step depends on the difference — one
  /// that would otherwise replace a value it merely failed to read.
  static func lookup(_ scope: Scope, account: String) throws -> String? {
    if let value = try rawLookup(baseQuery(scope, account: account), account: account) {
      return value
    }
    // Not on the data protection side yet: the login keychain still holds
    // whatever a migration pass has not moved.
    guard usesDataProtection, !migrationDone else { return nil }
    return try legacyLookup(scope, account: account)
  }

  private static func rawLookup(_ base: [String: Any], account: String) throws -> String? {
    var query = base
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let data = item as? Data {
      return String(data: data, encoding: .utf8)
    }
    guard status == errSecItemNotFound else {
      throw StoreError.keychain(status, "read \(account)")
    }
    return nil
  }

  /// Write, replacing any existing value.
  ///
  /// `SecItemUpdate` after a failed add rather than delete-then-add: the delete
  /// half of a delete-then-add can succeed while the add fails, which loses a
  /// credential in exchange for nothing.
  ///
  /// An empty value is refused rather than stored. Presence is answered by
  /// account name — see `storedVariables` — and an item holding `""` is the one
  /// thing that can make presence-by-name and presence-by-value disagree, which
  /// shows up as a profile that reads as configured and cannot start. Refusing
  /// here is also the only place a caller learns: `secret_set` passes its
  /// argument through unchecked, so without this an empty write is a silent
  /// no-op the caller believes worked.
  static func write(_ scope: Scope, account: String, value: String) throws {
    guard !value.isEmpty else { throw StoreError.emptyValue(account) }
    // Never the real Keychain under a capture: a staged screen that saves a
    // fixture profile would otherwise write, or sweep, the developer's own
    // items. See `accounts` below for the read side of the same rule.
    if DemoSeed.isEnabled { return }
    let data = Data(value.utf8)
    var query = baseQuery(scope, account: account)

    let update = [kSecValueData as String: data] as CFDictionary
    let updated = SecItemUpdate(query as CFDictionary, update)
    if updated == errSecSuccess { return }
    guard updated == errSecItemNotFound else {
      throw StoreError.keychain(updated, "update \(account)")
    }

    try add(query, data: data, account: account)
    // A login copy left by a pass that has not finished would otherwise come
    // back through the fallback the moment this one is deleted.
    if usesDataProtection, !migrationDone { try? legacyDelete(scope, account: account) }
  }

  private static func add(_ base: [String: Any], data: Data, account: String) throws {
    var query = base
    query[kSecValueData as String] = data
    // The credential is needed whenever a tool call arrives, which may be while
    // the screen is locked — an agent working in the background is the normal
    // case, not the exception. `AfterFirstUnlock` is the weakest accessibility
    // that survives that.
    //
    // `ThisDeviceOnly` keeps every item out of iCloud Keychain. The login
    // keychain ignored the attribute; the data protection keychain honours it,
    // so from this build on it is a fact rather than an intent. Phase 3 of the
    // sync design lifts it for `.profile` alone, and only while the person has
    // sync on: a gateway token, an OAuth token set or the audit key has no
    // business on another device.
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    // An add names one item, so it cannot carry `Any`. Not synchronizable.
    if query[kSecUseDataProtectionKeychain as String] != nil {
      query[kSecAttrSynchronizable as String] = false
    }
    let added = SecItemAdd(query as CFDictionary, nil)
    guard added == errSecSuccess else { throw StoreError.keychain(added, "store \(account)") }
  }

  static func delete(_ scope: Scope, account: String) throws {
    // Never the real Keychain under a capture: a staged screen that saves a
    // fixture profile would otherwise write, or sweep, the developer's own
    // items. See `accounts` below for the read side of the same rule.
    if DemoSeed.isEnabled { return }
    try rawDelete(baseQuery(scope, account: account), account: account)
    // Both sides while a pass is pending: a credential deleted only here would
    // come back through the fallback from a login copy no pass had moved yet.
    // Not after: the login side is never read again, and on a locked login
    // keychain a delete there could only prompt, or fail one that had worked.
    if usesDataProtection, !migrationDone { try legacyDelete(scope, account: account) }
  }

  private static func rawDelete(_ query: [String: Any], account: String) throws {
    let status = SecItemDelete(query as CFDictionary)
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
    // Never the real keychain under a capture. Not for what it would *show* —
    // this returns account names, not values — but for what it would ask: the
    // query runs against the keychain of an app whose bundle identifier matches
    // the developer's own, and a per-item ACL prompt is a modal dialog arriving
    // in the middle of a shutter.
    if DemoSeed.isEnabled { return [] }
    let modern = rawAccounts(baseQuery(scope, account: nil))
    guard usesDataProtection, !migrationDone else { return modern }
    return KeychainMigration.union(modern: modern, legacy: legacyAccounts(scope))
  }

  /// The same, but a refusal is an error rather than an empty list. For the
  /// migration pass, where "nothing there" and "could not look" lead to
  /// opposite decisions. Only `errSecItemNotFound` is empty.
  private static func checkedAccounts(_ base: [String: Any], scope: Scope) throws -> [String] {
    var query = base
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return [] }
    guard status == errSecSuccess, let rows = item as? [[String: Any]] else {
      throw StoreError.keychain(status, "list \(scope.service)")
    }
    return rows.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  private static func rawAccounts(_ base: [String: Any]) -> [String] {
    var query = base
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll

    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let rows = item as? [[String: Any]]
    else { return [] }
    return rows.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  // MARK: - The migration's primitives
  //
  // One side each, named for it, so `KeychainMigration.run` says which keychain
  // every call reaches. Nothing else calls these.

  static func legacyAccounts(_ scope: Scope) -> [String] {
    rawAccounts(baseQuery(scope, account: nil, legacy: true))
  }

  /// Both listings a pass plans from, each throwing on a refusal. See
  /// `checkedAccounts`.
  static func checkedLegacyAccounts(_ scope: Scope) throws -> [String] {
    try checkedAccounts(baseQuery(scope, account: nil, legacy: true), scope: scope)
  }

  static func checkedModernAccounts(_ scope: Scope) throws -> [String] {
    try checkedAccounts(baseQuery(scope, account: nil), scope: scope)
  }

  static func legacyLookup(_ scope: Scope, account: String) throws -> String? {
    try rawLookup(baseQuery(scope, account: account, legacy: true), account: account)
  }

  static func legacyDelete(_ scope: Scope, account: String) throws {
    try rawDelete(baseQuery(scope, account: account, legacy: true), account: account)
  }

  /// For `KeychainSelfTest` alone, which seeds the login keychain to migrate.
  static func legacyAdd(_ scope: Scope, account: String, value: String) throws {
    try add(
      baseQuery(scope, account: account, legacy: true), data: Data(value.utf8), account: account)
  }

  /// Adds on the data protection side and refuses to replace: a pass that
  /// finds the account there already plans `.dropStale`, never `.move`.
  static func modernAdd(_ scope: Scope, account: String, value: String) throws {
    guard !value.isEmpty else { throw StoreError.emptyValue(account) }
    try add(baseQuery(scope, account: account), data: Data(value.utf8), account: account)
  }

  /// The account names on the data protection side only. A pass plans against
  /// these: `accounts` lists both keychains while one is pending.
  static func modernAccounts(_ scope: Scope) -> [String] {
    rawAccounts(baseQuery(scope, account: nil))
  }

  /// The value on the data protection side only, for the read-back a pass
  /// compares before it deletes the login copy.
  static func modernLookup(_ scope: Scope, account: String) throws -> String? {
    try rawLookup(baseQuery(scope, account: account), account: account)
  }

  /// The variable names one profile holds a secret for.
  ///
  /// Presence lives in the account namespace, so this answers "is it set"
  /// without decrypting anything: `accounts` asks for attributes only, which
  /// never meets the per-item ACL that guards a value and so never raises the
  /// prompt a background tool call cannot answer.
  ///
  /// Takes the account list rather than fetching it, so a caller ranging over
  /// every profile pays for one query instead of one per profile.
  static func storedVariables(in accounts: [String], profile: String, server: String) -> Set<String>
  {
    let prefix = "\(profile)/\(server)/"
    return Set(
      accounts
        .filter { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)) })
  }

  /// The same, for a caller with a single profile to ask about.
  static func storedVariables(profile: String, server: String) -> Set<String> {
    // `accounts` returns nothing under a capture, so without this every demo
    // profile would report every secret missing — and the server plate would be
    // four orange "cannot start" rows instead of the working ladder with one
    // deliberate gap in it that the caption is about.
    if DemoSeed.isEnabled { return DemoSeed.storedVariables(profile: profile, server: server) }
    return storedVariables(in: accounts(.profile), profile: profile, server: server)
  }

  /// The query every call starts from, on the data protection keychain when
  /// this build may use it, or on the login keychain when `legacy` asks for it.
  ///
  /// `kSecAttrSynchronizableAny` on every data protection query: a synced and an
  /// unsynced item with the same service and account are two items, and a query
  /// that omits the attribute matches only the unsynced one. Phase 3 writes
  /// synced `.profile` items, and a lookup, a listing or a delete that missed
  /// them would report a credential unset or leave one behind. `add` replaces
  /// it with `false`, since an add names one item.
  private static func baseQuery(_ scope: Scope, account: String?, legacy: Bool = false)
    -> [String: Any]
  {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: scope.service,
    ]
    if let account { query[kSecAttrAccount as String] = account }
    if usesDataProtection && !legacy {
      query[kSecUseDataProtectionKeychain as String] = true
      query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    } else if usesDataProtection {
      // `false`, stated, and never left out. In a process that carries
      // `keychain-access-groups`, a query without the key reaches the data
      // protection keychain as well: it lists those items, reads their values
      // and deletes them. Measured by `make keychain-selftest` on 2026-11-01,
      // where leaving it out made the pass's last step, deleting the login
      // copy, delete the copy it had just moved as well.
      query[kSecUseDataProtectionKeychain as String] = false
    }
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
    forget()
    return token
  }

  static func revoke(_ client: String) throws {
    // Forgotten even when the delete throws: it may have half-worked, and a
    // revoked token must not go on being accepted from the cache.
    defer { forget() }
    try CredentialStore.delete(.gatewayToken, account: client)
  }

  /// The issued tokens, held between requests.
  ///
  /// `identify` runs on EVERY request, before anything is served, and used to
  /// do a `SecItemCopyMatching` over the whole account namespace plus one
  /// decrypting read per issued client — up to 64 connections deep, for a set
  /// that changes when somebody wires or unwires an editor and at no other
  /// time.
  ///
  /// Invalidated explicitly by `issue` and `revoke`, which are the only ways
  /// this app changes it, and expired on a short timer anyway so a token
  /// deleted in Keychain Access stops working without a relaunch.
  private static let cache = OSAllocatedUnfairLock<(at: DispatchTime, map: [String: String])?>(
    initialState: nil)

  /// How long a cached token set may stand when nothing invalidated it.
  private static let cacheTTL: UInt64 = 60 * 1_000_000_000

  static func forget() { cache.withLock { $0 = nil } }

  /// `nil` means the keychain would not answer — which is NOT the same as
  /// "no such token", and the caller must not turn it into one.
  private static func issued() -> [String: String]? {
    let now = DispatchTime.now()
    if let warm = cache.withLock({ $0 }),
      now.uptimeNanoseconds &- warm.at.uptimeNanoseconds < cacheTTL
    {
      return warm.map
    }
    let clients = CredentialStore.accounts(.gatewayToken)
    var map: [String: String] = [:]
    for client in clients {
      guard let stored = CredentialStore.read(.gatewayToken, account: client) else { continue }
      map[client] = stored
    }
    // Names but no values is the locked-keychain shape, and it is transient.
    // Caching it would hold a blanket refusal in place for the whole TTL, and
    // answering "unknown token" would tell a client its credential is wrong
    // when the truth is that this app cannot read its own.
    if map.isEmpty && !clients.isEmpty { return nil }
    // A `let` for the lock's closure, which would otherwise capture the
    // variable rather than the finished map.
    let snapshot = map
    cache.withLock { $0 = (at: now, map: snapshot) }
    return snapshot
  }

  /// Which client, if any, this token belongs to.
  ///
  /// Linear over the issued tokens, compared in constant time. Both parts are
  /// deliberate: the set is a handful of entries, and a comparison that returns
  /// early on the first differing byte leaks the token prefix to anything that
  /// can time it — which, on a loopback listener a web page can reach, is not a
  /// theoretical attacker.
  static func identify(_ presented: String) -> Identity {
    guard let issued = issued() else { return .unavailable }
    let candidate = Array(presented.utf8)
    for (client, stored) in issued {
      if constantTimeEquals(candidate, Array(stored.utf8)) { return .client(client) }
    }
    return .unknown
  }

  /// Three answers, because two of them must not be collapsed.
  ///
  /// `unknown` is the client's problem and `unavailable` is this app's, and
  /// reporting the second as the first sends someone re-wiring a client that
  /// was never wrong.
  enum Identity {
    case client(String)
    case unknown
    case unavailable
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
