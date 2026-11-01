import Foundation

/// The pass itself: the keychain calls `KeychainMigration` decides on.
///
/// Its own file, out of `make unit`, because it reaches `CredentialStore`,
/// `DemoSeed` and the log; `make keychain-selftest` proves it instead, on the
/// signed build, against a throwaway namespace.
extension KeychainMigration {
  /// Move whatever is still on the login side, then write the marker if
  /// nothing was left behind.
  ///
  /// Runs at launch, before anything asks for a credential. Returns at once on
  /// a build without the entitlement, after a pass has finished, and under a
  /// capture. A pass that keeps anything is tried again on the next launch;
  /// until then `CredentialStore` reads the kept items through its fallback,
  /// so they go on working.
  @MainActor static func run() {
    guard CredentialStore.usesDataProtection, !DemoSeed.isEnabled, !CredentialStore.migrationDone
    else { return }

    var outcomes: [String: [Outcome]] = [:]
    for scope in CredentialStore.Scope.credentialScopes {
      // `modernAccounts`, never `accounts`: while a pass is pending `accounts`
      // lists both keychains, so every login account would look moved already
      // and be dropped without a copy.
      //
      // And the checked listings: a locked login keychain refuses the search
      // itself, and an unchecked listing would read that as an empty scope.
      do {
        let steps = plan(
          legacy: try CredentialStore.checkedLegacyAccounts(scope),
          modern: try CredentialStore.checkedModernAccounts(scope))
        outcomes[scope.service] = steps.map { carry($0, in: scope) }
      } catch {
        hostLog("keychain", .error, error.localizedDescription)
        outcomes[scope.service] = [.listingRefused]
      }
    }

    let left = leftovers(after: outcomes)
    for (service, results) in outcomes.sorted(by: { $0.key < $1.key }) where !results.isEmpty {
      let moved = results.filter { if case .moved = $0 { true } else { false } }.count
      let dropped = results.filter { if case .dropped = $0 { true } else { false } }.count
      hostLog(
        "keychain", .info,
        "moved \(moved), dropped \(dropped), kept \(left[service]?.count ?? 0) for \(service)")
    }
    for (service, kept) in left where !kept.isEmpty {
      hostLog(
        "keychain", .error,
        "kept on the login keychain for \(service), to try again next launch: "
          + kept.joined(separator: ", "))
    }

    guard isComplete(leftover: left) else { return }
    do {
      try CredentialStore.modernAdd(
        .migration, account: "login-keychain",
        value: ISO8601DateFormatter().string(from: Date()))
      hostLog("keychain", .info, "every credential is on the data protection keychain")
    } catch {
      // Nothing is lost: the fallback stays on and the next launch writes it.
      hostLog("keychain", .error, error.localizedDescription)
    }
  }

  /// One account across, add first and delete on success.
  @MainActor private static func carry(_ step: Step, in scope: CredentialStore.Scope) -> Outcome {
    let account = step.account
    switch step.action {
    case .dropStale:
      do {
        try CredentialStore.legacyDelete(scope, account: account)
        return .dropped(account)
      } catch {
        hostLog("keychain", .error, error.localizedDescription)
        return .refused(account)
      }
    case .move:
      do {
        guard let value = try CredentialStore.legacyLookup(scope, account: account), !value.isEmpty
        else { return .refused(account) }
        try CredentialStore.modernAdd(scope, account: account, value: value)
        // Read back from the new side alone. Through the fallback, a failed
        // add would compare the login copy with itself and pass.
        guard try CredentialStore.modernLookup(scope, account: account) == value else {
          return .refused(account)
        }
        try CredentialStore.legacyDelete(scope, account: account)
        return .moved(account)
      } catch {
        hostLog("keychain", .error, error.localizedDescription)
        return .refused(account)
      }
    }
  }
}
