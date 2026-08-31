import Foundation

/// What this build calls itself.
nonisolated enum AppInfo {
  static var version: String {
    // Pinned under a capture. This line renders in the sidebar of all five
    // main-window plates, so the real value would churn the golden gate into
    // noise on every release — and would put a version number into marketing
    // images before the listing showing them had caught up.
    if DemoSeed.isEnabled { return DemoSeed.version }
    return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "0.0.0"
  }

  /// The major version a licence key must cover.
  ///
  /// A key is issued against `2.x` and refused by a `3.x` build, which is what
  /// makes a paid major upgrade expressible without an expiry date on the key
  /// itself. Derived from the shipped version rather than hardcoded, so it
  /// cannot disagree with what the About line says.
  static var major: Int {
    Int(version.split(separator: ".").first ?? "1") ?? 1
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
  }

  /// Debug builds carry their own bundle identifier, and therefore their own
  /// Keychain items, their own profiles and their own port. Worth being able to
  /// say so on screen, because two menu bar icons that look identical and hold
  /// different credentials is otherwise a confusing afternoon.
  static var isDebugBuild: Bool {
    // `make screenshots` builds Release, so this is already false there. It is
    // branched anyway because the failure is silent and the window is wide: a
    // capture taken while TUNING the fixtures runs against the default Debug
    // build, and " (debug)" would then sit in the sidebar of five plates.
    if DemoSeed.isEnabled { return false }
    return AppSupport.identifier.hasSuffix(".debug")
  }
}
