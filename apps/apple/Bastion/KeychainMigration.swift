import Foundation

/// Moving every credential from the login keychain to the data protection
/// keychain, once, and the decisions that move makes.
///
/// The Release build carries `keychain-access-groups`, so `CredentialStore`
/// writes to the data protection keychain and reads through to the login one
/// until this has run. A pass adds each item on the new side, reads it back,
/// and only then deletes the old one, so no path through it loses a
/// credential: a crash leaves at worst one account in both, and a refused read
/// leaves it where it was, still readable through the fallback.
///
/// The decisions live here, Foundation only, so `scripts/unit-check.swift`
/// compiles them. The pass that makes the keychain calls is in
/// `KeychainMigrationRun.swift`, and `make keychain-selftest` proves it on the
/// signed build.
nonisolated enum KeychainMigration {
  enum Action: Equatable {
    /// Only in the login keychain: copy it across, then delete it there.
    case move
    /// In both. The modern copy can only have been written after a pass
    /// started — every write goes there — so it is the newer one and wins.
    case dropStale
  }

  struct Step: Equatable {
    let account: String
    let action: Action
  }

  /// One step per login keychain account, sorted so a pass reads the same in
  /// the log every time.
  static func plan(legacy: [String], modern: [String]) -> [Step] {
    let present = Set(modern)
    return Set(legacy).sorted().map {
      Step(account: $0, action: present.contains($0) ? .dropStale : .move)
    }
  }

  /// Whether a pass left nothing behind, which is the only time the marker is
  /// written: while one item could not be read, the fallback has to stay on.
  static func isComplete(leftover: [String: [String]]) -> Bool {
    leftover.values.allSatisfy(\.isEmpty)
  }

  /// The account names across both keychains, each once, for the window in
  /// which the fallback is on.
  static func union(modern: [String], legacy: [String]) -> [String] {
    Set(modern).union(legacy).sorted()
  }

  /// What became of one account in a pass.
  enum Outcome: Equatable {
    case moved(String)
    case dropped(String)
    /// Could not be read (a denied or unanswered prompt, a keychain locked
    /// since boot) or could not be written across. Left where it was.
    case refused(String)
    /// The scope could not even be listed: a locked login keychain refuses
    /// the search itself, or shows an unlock dialog somebody cancels. Not the
    /// same as an empty scope, and must never be read as one — an empty plan
    /// would write the marker and end the fallback with every credential
    /// still on the login side.
    case listingRefused
  }

  /// What a refused listing leaves in its scope's leftovers, so the scope is
  /// incomplete without naming an account nobody could read.
  static let unlistedScope = "(the listing was refused)"

  /// The accounts a pass left on the login side, by scope. Only a refusal
  /// leaves one.
  static func leftovers(after outcomes: [String: [Outcome]]) -> [String: [String]] {
    outcomes.mapValues { results in
      results.compactMap {
        switch $0 {
        case .refused(let account): account
        case .listingRefused: unlistedScope
        case .moved, .dropped: nil
        }
      }
    }
  }
}
