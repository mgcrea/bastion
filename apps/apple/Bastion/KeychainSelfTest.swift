import Foundation
import Security

/// A launch mode that runs the real keychain migration on this build, in a
/// throwaway namespace, then exits: `Bastion -keychainSelfTest YES`, or
/// `make keychain-selftest`.
///
/// The migration only means anything on the signed Release build: Debug has no
/// entitlement and never takes the data protection path. And the real thing
/// cannot be tried there before a release without moving the person's own
/// credentials out from under the installed copy, which still reads the login
/// keychain. So this points `CredentialStore.serviceBase` at
/// `<bundle id>.selftest` before anything touches the keychain, seeds the login
/// side, and walks the same code a launch does: the fallback, a delete before
/// the move, an account already on both sides, the pass, a second pass, and
/// the attributes every moved item ends up with. It leaves nothing behind.
///
/// Runs before anything real, beside the copy somebody is working in, as
/// `ICloudProbe` does.
enum KeychainSelfTest {
  nonisolated static var isRequested: Bool {
    ICloudProbe.requests(
      "keychainSelfTest",
      in: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
  }

  private static var failures = 0

  @MainActor static func run() -> Never {
    guard CredentialStore.usesDataProtection else {
      say("needs the Developer ID build — this one has no keychain-access-groups")
      exit(2)
    }
    CredentialStore.serviceBase = "\(AppSupport.identifier).selftest"
    say("namespace \(CredentialStore.serviceBase)")
    cleanUp()

    // The two keychains have to be two: a login-side call that reached a data
    // protection item would delete every moved credential at the last step of
    // its move. Checked first, on their own accounts, so a failure here names
    // the boundary rather than surfacing later as a value gone missing.
    do {
      try CredentialStore.modernAdd(.gatewayToken, account: "iso-modern", value: "m")
      try CredentialStore.legacyAdd(.gatewayToken, account: "iso-both", value: "l")
      try CredentialStore.modernAdd(.gatewayToken, account: "iso-both", value: "m")
    } catch {
      check("seeded the isolation accounts: \(error.localizedDescription)", false)
    }
    check(
      "a login-side listing leaves out a data-protection-only item",
      !CredentialStore.legacyAccounts(.gatewayToken).contains("iso-modern"))
    check(
      "a login-side read returns the login value",
      (try? CredentialStore.legacyLookup(.gatewayToken, account: "iso-both")) == "l")
    try? CredentialStore.legacyDelete(.gatewayToken, account: "iso-both")
    check(
      "a login-side delete leaves the data protection copy alone",
      (try? CredentialStore.modernLookup(.gatewayToken, account: "iso-both")) == "m")
    check(
      "and removes the login copy",
      !CredentialStore.legacyAccounts(.gatewayToken).contains("iso-both"))
    cleanUp()

    do {
      try CredentialStore.legacyAdd(.profile, account: "p/s/A", value: "alpha")
      try CredentialStore.legacyAdd(.profile, account: "p/s/B", value: "legacy-b")
      try CredentialStore.legacyAdd(.profile, account: "p/s/GONE", value: "gone")
      try CredentialStore.legacyAdd(.oauth, account: "p/s/oauth", value: #"{"access":"x"}"#)
      try CredentialStore.legacyAdd(.gatewayToken, account: "client", value: "token")
      // A pass that crashed between add and delete, or a write after a pass
      // that kept something: the account on both sides, the modern copy newer.
      try CredentialStore.modernAdd(.profile, account: "p/s/B", value: "modern-b")
      check("seeded the login keychain", true)
    } catch {
      check("seeded the login keychain: \(error.localizedDescription)", false)
      finish()
    }

    check("before the pass, a login item reads through", read(.profile, "p/s/A") == "alpha")
    check(
      "before the pass, an account in both reads the modern copy",
      read(.profile, "p/s/B") == "modern-b")
    check(
      "before the pass, the listing names each account once",
      CredentialStore.accounts(.profile) == ["p/s/A", "p/s/B", "p/s/GONE"])

    try? CredentialStore.delete(.profile, account: "p/s/GONE")
    check(
      "a delete before the pass leaves the account in neither keychain",
      !CredentialStore.legacyAccounts(.profile).contains("p/s/GONE")
        && !CredentialStore.modernAccounts(.profile).contains("p/s/GONE")
        && read(.profile, "p/s/GONE") == nil)
    check("the pass has not run yet", !CredentialStore.migrationDone)
    check(
      "before the pass, the data protection side lists only its own",
      CredentialStore.modernAccounts(.profile) == ["p/s/B"])

    KeychainMigration.run()

    check(
      "after the pass, nothing is left on the login side",
      CredentialStore.Scope.credentialScopes.allSatisfy {
        CredentialStore.legacyAccounts($0).isEmpty
      })
    check("every value survived the move", read(.profile, "p/s/A") == "alpha")
    check("the modern copy won over the stale one", read(.profile, "p/s/B") == "modern-b")
    check("an OAuth token set moved whole", read(.oauth, "p/s/oauth") == #"{"access":"x"}"#)
    check("a gateway token moved", read(.gatewayToken, "client") == "token")
    check(
      "the data protection side holds exactly what it should",
      CredentialStore.modernAccounts(.profile) == ["p/s/A", "p/s/B"])
    check("the marker is written", CredentialStore.migrationDone)

    let before = CredentialStore.Scope.credentialScopes.map(CredentialStore.modernAccounts)
    KeychainMigration.run()
    check(
      "a second pass changes nothing",
      before == CredentialStore.Scope.credentialScopes.map(CredentialStore.modernAccounts))

    // Once the marker exists the login side is never read again, so a delete
    // has no business there: on a locked login keychain it could only prompt,
    // or fail a delete that had already worked.
    try? CredentialStore.legacyAdd(.profile, account: "p/s/LATE", value: "late")
    try? CredentialStore.delete(.profile, account: "p/s/LATE")
    check(
      "after the marker, a delete leaves the login keychain alone",
      CredentialStore.legacyAccounts(.profile).contains("p/s/LATE"))
    try? CredentialStore.legacyDelete(.profile, account: "p/s/LATE")

    let rows = attributes(.profile) + attributes(.oauth) + attributes(.gatewayToken)
    check("every moved item was found by attributes", rows.count == 4)
    check(
      "none is synchronizable",
      rows.allSatisfy { ($0[kSecAttrSynchronizable as String] as? Bool) == false })
    check(
      "each is after-first-unlock, this device only",
      rows.allSatisfy {
        ($0[kSecAttrAccessible as String] as? String)
          == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
      })

    finish()
  }

  // MARK: - Helpers

  @MainActor private static func finish() -> Never {
    cleanUp()
    let left =
      CredentialStore.Scope.credentialScopes.flatMap(CredentialStore.legacyAccounts)
      + CredentialStore.Scope.credentialScopes.flatMap(CredentialStore.modernAccounts)
      + CredentialStore.modernAccounts(.migration)
    check("cleaned up after itself", left.isEmpty)
    say(failures == 0 ? "passed" : "FAILED: \(failures)")
    exit(failures == 0 ? 0 : 1)
  }

  /// Everything under the throwaway namespace, on both sides, marker included.
  private static func cleanUp() {
    for scope in CredentialStore.Scope.credentialScopes + [.migration] {
      for account in CredentialStore.modernAccounts(scope) {
        try? CredentialStore.delete(scope, account: account)
      }
      for account in CredentialStore.legacyAccounts(scope) {
        try? CredentialStore.legacyDelete(scope, account: account)
      }
    }
  }

  private static func read(_ scope: CredentialStore.Scope, _ account: String) -> String? {
    try? CredentialStore.lookup(scope, account: account)
  }

  /// One scope's items on the data protection side, attributes only.
  private static func attributes(_ scope: CredentialStore.Scope) -> [[String: Any]] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: scope.service,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
    return result as? [[String: Any]] ?? []
  }

  private static func check(_ label: String, _ condition: Bool) {
    if !condition { failures += 1 }
    say("\(condition ? "ok  " : "FAIL") \(label)")
  }

  private static func say(_ line: String) {
    print("selftest: \(line)")
    fflush(stdout)
  }
}
