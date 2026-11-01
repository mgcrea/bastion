import Foundation
import Security

/// A launch mode that proves the two iCloud stores work for this build, then
/// exits: `Bastion -iCloudProbe YES`, or `make icloud-probe`.
///
/// Both stores hang on restricted entitlements validated by the embedded
/// Developer ID profile, and nothing about a build says whether that worked
/// until something asks. A data protection keychain write that answers `-34018`
/// (`errSecMissingEntitlement`) means the entitlement or the profile is wrong,
/// and every line of sync code written on top of it would be wasted. So this
/// asks first, before any of that code exists, and is kept for the phases that
/// build on it.
///
/// It writes one synchronizable keychain item and one key-value pair, each
/// named after this Mac, and lists every other Mac's it can see. Run on two
/// Macs on one iCloud account, each should list the other's: that is iCloud
/// Keychain and the key-value store both syncing. Nothing is deleted, so the
/// second Mac's run can see the first's; `-iCloudProbeClean YES` removes this
/// Mac's.
///
/// Runs before anything real, as `DemoSeed` does: no store is loaded, no
/// gateway binds, and the lock the running copy holds is never asked for, so a
/// probe can run beside the copy somebody is working in.
enum ICloudProbe {
  /// The argument domain only, never `UserDefaults.standard` as a whole, for
  /// the reason `DemoSeed.argument` gives: `standard` also reads the persisted
  /// domain, and one `defaults write` of this key would make every launch of
  /// a shipped build a probe that exits twenty seconds later.
  nonisolated static var isRequested: Bool {
    let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    return requests("iCloudProbe", in: arguments) || requests("iCloudProbeClean", in: arguments)
  }

  /// Whether `key` is switched on in a set of launch arguments. `-key YES`
  /// arrives as a string; a Bool or a number is read the same way.
  nonisolated static func requests(_ key: String, in arguments: [String: Any]) -> Bool {
    switch arguments[key] {
    case let value as String: return ["yes", "true", "1"].contains(value.lowercased())
    case let value as Bool: return value
    case let value as NSNumber: return value.boolValue
    default: return false
    }
  }

  private static var cleaning: Bool {
    requests(
      "iCloudProbeClean",
      in: UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain))
  }

  private static var service: String { "\(AppSupport.identifier).probe" }
  private static var mac: String { Host.current().localizedName ?? "unknown" }
  private static var key: String { "probe/\(mac)" }

  @MainActor static func run() -> Never {
    if cleaning { clean() }
    let stamp = ISO8601DateFormatter().string(from: Date())
    var passed = true

    say("this Mac is '\(mac)', service \(service)")
    let added = write(stamp)
    say("keychain add: \(describe(added))")
    passed = passed && added == errSecSuccess

    let read = readBack()
    say("keychain read: \(describe(read))")
    passed = passed && read == errSecSuccess

    say("keychain accounts: \(accounts().joined(separator: ", "))")

    let store = NSUbiquitousKeyValueStore.default
    store.set(stamp, forKey: key)
    let synchronized = store.synchronize()
    say("kvs synchronize: \(synchronized)")
    passed = passed && synchronized

    // The key-value store pulls on its own schedule, and announces what it
    // pulled with a notification. Twenty seconds is long enough to see
    // another Mac's key when one is already up there, and short enough to
    // run again when one is not.
    let external = Flag()
    let observer = NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store,
      queue: .main
    ) { _ in external.isSet = true }
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline, !external.isSet, others(in: store).isEmpty {
      RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    NotificationCenter.default.removeObserver(observer)
    say("kvs external change seen: \(external.isSet)")
    let seen = store.dictionaryRepresentation.filter { $0.key.hasPrefix("probe/") }
    for (name, value) in seen.sorted(by: { $0.key < $1.key }) {
      say("kvs \(name) = \(value)")
    }
    say(others(in: store).isEmpty ? "no other Mac seen yet" : "another Mac seen")

    say(passed ? "passed" : "FAILED")
    exit(passed ? 0 : 1)
  }

  // MARK: - Keychain

  private static func base() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecUseDataProtectionKeychain as String: true,
    ]
  }

  private static func write(_ stamp: String) -> OSStatus {
    var item = base()
    item[kSecAttrAccount as String] = mac
    item[kSecAttrSynchronizable as String] = true
    let data = Data(stamp.utf8)
    let updated = SecItemUpdate(
      item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    guard updated == errSecItemNotFound else { return updated }
    // `AfterFirstUnlock` without `ThisDeviceOnly`, the accessibility a synced
    // credential will have: the second half is what makes sync possible.
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    item[kSecValueData as String] = data
    return SecItemAdd(item as CFDictionary, nil)
  }

  private static func readBack() -> OSStatus {
    var query = base()
    query[kSecAttrAccount as String] = mac
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    query[kSecReturnData as String] = true
    var result: CFTypeRef?
    return SecItemCopyMatching(query as CFDictionary, &result)
  }

  private static func accounts() -> [String] {
    var query = base()
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let rows = result as? [[String: Any]]
    else { return [] }
    return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
  }

  // MARK: - Helpers

  /// Set from the notification, read by the wait loop. Both on the main
  /// queue, which is what makes the unchecked conformance true.
  private final class Flag: @unchecked Sendable { var isSet = false }

  private static func others(in store: NSUbiquitousKeyValueStore) -> [String] {
    store.dictionaryRepresentation.keys.filter { $0.hasPrefix("probe/") && $0 != key }
  }

  private static func clean() -> Never {
    var query = base()
    query[kSecAttrAccount as String] = mac
    query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    say("keychain delete: \(describe(SecItemDelete(query as CFDictionary)))")
    NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    say("kvs remove \(key): \(NSUbiquitousKeyValueStore.default.synchronize())")
    exit(0)
  }

  private static func describe(_ status: OSStatus) -> String {
    if status == errSecSuccess { return "ok" }
    let message = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "unknown"
    return "\(status) \(message)"
  }

  private static func say(_ line: String) {
    print("probe: \(line)")
    fflush(stdout)
  }
}
