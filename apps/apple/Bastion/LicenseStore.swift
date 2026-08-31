import Foundation

/// Where this Mac's licence key lives, and whether it is any good.
///
/// `UserDefaults`, not the Keychain — and that is a deliberate exception in an
/// app whose whole point is that credentials belong in the Keychain. A licence
/// key is not a secret: it is issued to the user, rendered in their menu bar,
/// emailed to them in plain text and re-sendable on demand. Encrypting at rest
/// something the UI displays would be ceremony, and it would put a licence key
/// in the same store as a brokerage refresh token, which is exactly the
/// conflation `CredentialStore` exists to prevent.
///
/// Nothing is cached. Ed25519 verification is microseconds, and re-checking on
/// every read means entering a key takes effect immediately with no
/// invalidation to get wrong.
nonisolated enum LicenseStore {
  private static let defaultsKey = "license"

  /// What `DemoSeed` wants this Mac to look like. Set before any view is built,
  /// read by everything below.
  ///
  /// This is not a hole in the licence check. Bastion's source is public and the
  /// gate is a dozen readable lines in `Gateway`; anyone minded to bypass it
  /// would edit those rather than hunt for a flag that is false unless
  /// `appshot capture` set it.
  nonisolated(unsafe) static var demoLicensed = false

  /// A key of the right SHAPE and deliberately not of the right signature.
  ///
  /// It is rendered, never verified — `check` below branches before
  /// `LicenseKey.check` ever sees it. That is the point: a demo key that
  /// actually verified would be a valid licence sitting in a public repository.
  static let demoKey =
    "BSTN1-DEMO0000-0000AAAA-BBBBCCCC-DDDDEEEE-FFFF0000-11112222-3333DEMO"

  /// The stored key as typed, or nil. Kept separate from `check` so the entry
  /// field can show what is there even when it is being refused.
  static var raw: String? {
    // `LicencePane.onAppear` puts this into a 92pt `TextEditor`, in every
    // entitlement state — so without the branch the developer's own 240-character
    // key is photographed at full size on the licence plate.
    if DemoSeed.isEnabled { return demoLicensed ? demoKey : nil }
    return UserDefaults.standard.string(forKey: defaultsKey)
  }

  static var check: LicenseCheck {
    if DemoSeed.isEnabled {
      return demoLicensed
        ? .valid(DemoSeed.license)
        : .refused("no licence key on this Mac")
    }
    return LicenseKey.check(raw)
  }
  static var current: License? { check.license }
  static var isLicensed: Bool { current != nil }

  /// Store a key only if it verifies, and say why if it does not.
  ///
  /// Refusing to persist a bad key is what keeps `raw` and `check` from
  /// disagreeing in a way the user cannot see — a key that is saved but refused
  /// looks like the app losing it.
  @discardableResult
  static func store(_ key: String) -> LicenseCheck {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = LicenseKey.check(trimmed)
    if case .valid = result {
      UserDefaults.standard.set(trimmed, forKey: defaultsKey)
    }
    return result
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }
}
