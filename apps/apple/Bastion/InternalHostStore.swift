import Foundation

/// The internal hosts on disk, and the only writer of `InternalHosts.current`.
///
/// Written from Settings and from nowhere else: no tool of Bastion's own MCP
/// server reaches this type, which is the half of the rule that keeps an agent
/// from listing the router. `InternalHosts` says why.
@MainActor
@Observable
final class InternalHostStore {
  static let shared = InternalHostStore()

  private(set) var entries: [InternalHost] = []
  /// Set when the file is there and would not decode. Saves refuse while it is
  /// — see `StoreFile` — and the guard runs with an empty list, which refuses
  /// rather than allows.
  private(set) var unreadable: StoreFile.Unreadable?

  private var fileURL: URL { AppSupport.directory.appendingPathComponent("internal-hosts.json") }

  init() { load() }

  func load() {
    // The fixture never lists anything: a capture must not show a real
    // company's internal names, and an empty list is the shipped default.
    if DemoSeed.isEnabled {
      entries = []
      publish()
      return
    }
    switch StoreFile.load([InternalHost].self, from: fileURL) {
    case .absent:
      unreadable = nil
      entries = []
    case .unreadable(let problem):
      unreadable = problem
      hostLog("internal-hosts", .error, problem.localizedDescription)
      entries = []
    case .decoded(let rows):
      unreadable = nil
      // Re-validated, not trusted. The file is the user's own and 0o600, but a
      // hand edit — or a build that once allowed more — must not be what widens
      // the rule. An entry that fails is dropped from the list the guard sees
      // and kept on disk until the next save, like every other store's rows.
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

  private func replace(with next: [InternalHost]) throws {
    if DemoSeed.isEnabled { return }
    if let unreadable { throw unreadable }
    AppSupport.ensureDirectory()
    let encoder = JSONEncoder()
    // Default date encoding, not ISO 8601: `StoreFile.load` decodes with a
    // default `JSONDecoder`, and a mismatch would make the next launch read
    // this file as unreadable and refuse every save after it.
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(next).write(to: fileURL, options: .atomic)
    // After every write: `.atomic` replaces the file, so permissions set once
    // do not survive the next save.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    entries = next
    publish()
  }

  private func publish() { InternalHosts.publish(entries) }
}
