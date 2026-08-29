import Foundation

/// What this build calls itself.
nonisolated enum AppInfo {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
  }

  /// Debug builds carry their own bundle identifier, and therefore their own
  /// Keychain items, their own profiles and their own port. Worth being able to
  /// say so on screen, because two menu bar icons that look identical and hold
  /// different credentials is otherwise a confusing afternoon.
  static var isDebugBuild: Bool {
    AppSupport.identifier.hasSuffix(".debug")
  }
}
