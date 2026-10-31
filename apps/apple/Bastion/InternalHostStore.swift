import Foundation

/// The internal-host list, and the only writer of `InternalHosts.current`.
///
/// Written from Settings and from nowhere else: no tool of Bastion's own MCP
/// server reaches this type, which is the half of the rule that keeps an agent
/// from listing the router. `InternalHosts` says why.
///
/// Kept in the Keychain (`CredentialStore.Scope.internalHosts`), not in a file
/// beside `servers.json`. A file in Application Support is one any process of
/// the user's can rewrite, and a coding agent with a shell is exactly the
/// process this list must not trust. The item is created at launch, empty if
/// need be, so it always exists under Bastion's own access control rather than
/// one another process got to create first. Deleting it empties the list,
/// which refuses rather than allows.
@MainActor
@Observable
final class InternalHostStore {
  static let shared = InternalHostStore()

  private(set) var entries: [InternalHost] = []
  /// Set when the item is there and could not be read or decoded. Saves refuse
  /// while it is, so what is there is never written over with an empty list,
  /// and the guard runs with an empty list, which refuses rather than allows.
  private(set) var problem: String?

  private static let account = "list"

  init() { load() }

  func load() {
    // The fixture never lists anything: a capture must not show a real
    // company's internal names, and an empty list is the shipped default.
    if DemoSeed.isEnabled {
      entries = []
      publish()
      return
    }
    let stored: String?
    do {
      stored = try CredentialStore.lookup(.internalHosts, account: Self.account)
    } catch {
      fail("the internal-host list could not be read: \(error.localizedDescription)")
      return
    }
    guard let stored else {
      // First launch of a build that has this: claim the item now, empty.
      problem = nil
      entries = []
      do {
        try CredentialStore.write(.internalHosts, account: Self.account, value: "[]")
      } catch {
        hostLog("internal-hosts", .error, error.localizedDescription)
      }
      publish()
      return
    }
    guard let rows = try? JSONDecoder().decode([InternalHost].self, from: Data(stored.utf8))
    else {
      fail(
        "the internal-host list in the Keychain could not be decoded, so Bastion will not "
          + "write over it. Remove the '\(CredentialStore.Scope.internalHosts.service)' item in "
          + "Keychain Access to start again.")
      return
    }
    problem = nil
    // Re-validated, not trusted: a build that once allowed more must not be
    // what widens the rule. An entry that fails is dropped from the list the
    // guard sees, and written back out at the next save.
    entries = rows.compactMap { row in
      do {
        return try InternalHosts.validated(row)
      } catch {
        hostLog(
          "internal-hosts", .error,
          "ignoring internal host '\(row.host)': \(error.localizedDescription)")
        return nil
      }
    }
    publish()
  }

  /// Whether `host` is listed, for the badge on a server's header.
  func lists(_ host: String) -> Bool { InternalHosts.entry(for: host, in: entries) != nil }

  func add(host: String, networks: [String]) throws {
    let entry = try InternalHosts.validated(
      InternalHost(host: host, networks: networks, addedAt: Date()))
    guard InternalHosts.entry(for: entry.host, in: entries) == nil else {
      throw InternalHosts.Problem.duplicate(entry.host)
    }
    try replace(with: entries + [entry])
    hostLog(
      "internal-hosts", .info,
      "listed \(entry.host) for \(entry.networks.joined(separator: ", "))")
  }

  func remove(_ host: String) throws {
    let key = InternalHosts.normalize(host)
    guard entries.contains(where: { $0.host == key }) else { return }
    try replace(with: entries.filter { $0.host != key })
    hostLog("internal-hosts", .info, "removed \(key)")
  }

  struct Unwritable: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
  }

  private func replace(with next: [InternalHost]) throws {
    if DemoSeed.isEnabled { return }
    if let problem { throw Unwritable(reason: problem) }
    // Default date encoding, matching the decoder in `load`.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(next), as: UTF8.self)
    try CredentialStore.write(.internalHosts, account: Self.account, value: json)
    entries = next
    publish()
  }

  private func fail(_ message: String) {
    problem = message
    hostLog("internal-hosts", .error, message)
    entries = []
    publish()
  }

  private func publish() { InternalHosts.publish(entries) }
}
