import Foundation

/// Where synced envelopes live: iCloud's key-value store in the Release
/// build, and a JSON file when a Debug build is pointed at one.
@MainActor
protocol SyncCloud: AnyObject {
  func all() -> [String: String]
  func set(_ value: String, for key: String)
  func remove(_ key: String)
  func synchronize()
}

/// `NSUbiquitousKeyValueStore`, which needs the
/// `com.apple.developer.ubiquity-kvstore-identifier` entitlement and so works
/// only in the signed Release build. Values are the envelopes' JSON text.
@MainActor
final class UbiquitousCloud: SyncCloud {
  private let store = NSUbiquitousKeyValueStore.default

  func all() -> [String: String] {
    store.dictionaryRepresentation.compactMapValues { $0 as? String }
  }

  func set(_ value: String, for key: String) { store.set(value, forKey: key) }
  func remove(_ key: String) { store.removeObject(forKey: key) }
  func synchronize() { store.synchronize() }
}

#if DEBUG
  /// A JSON file standing in for iCloud, for `make sync-check`. The Debug
  /// build carries no entitlement, so it cannot reach the real store; this is
  /// how the whole engine still runs end to end against a file the check
  /// seeds and reads. Reached only through `-syncCloudFile <path>`.
  @MainActor
  final class FileCloud: SyncCloud {
    private let url: URL
    private var values: [String: String]

    init(url: URL) {
      self.url = url
      values =
        (try? Data(contentsOf: url)).flatMap {
          try? JSONDecoder().decode([String: String].self, from: $0)
        } ?? [:]
    }

    func all() -> [String: String] { values }

    func set(_ value: String, for key: String) {
      values[key] = value
      write()
    }

    func remove(_ key: String) {
      values[key] = nil
      write()
    }

    func synchronize() {}

    private func write() {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      guard let data = try? encoder.encode(values) else { return }
      try? data.write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }
#endif
