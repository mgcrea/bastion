import Foundation
import os

/// `ServerApprovals`, kept in the Keychain.
///
/// One item (`CredentialStore.Scope.approvals`), for the reason
/// `InternalHostStore` gives for its own: a file in Application Support is one
/// any process of the user's can rewrite, and an approval that a shell could
/// forge would make the wait mean nothing. Never synced: approving on one Mac
/// approves nothing on another.
///
/// The supervisor reads `pending(_:)` on the connection's own thread, so it is
/// published to a lock as `ServerStore.lookup` is.
@MainActor
@Observable
final class ServerApprovalStore {
  static let shared = ServerApprovalStore()

  private(set) var approvals = ServerApprovals()
  /// Set when the item is there and could not be read or decoded. Saves
  /// refuse while it is, and sync holds every custom server that arrives
  /// rather than apply one it cannot record as waiting.
  private(set) var problem: String?

  private static let account = "servers"
  private struct Published {
    var pending: [String: ServerApprovals.Pending] = [:]
    var unreadable = false
  }
  private nonisolated static let published = OSAllocatedUnfairLock(initialState: Published())

  /// The arrival a server is waiting on, read from any thread. Nil for every
  /// server that did not arrive from another Mac, which is every server on a
  /// Mac that has never synced.
  nonisolated static func pending(_ id: String) -> ServerApprovals.Pending? {
    published.withLock { $0.pending[id] }
  }

  /// Why the supervisor must not start or reach `server`, read from any
  /// thread. Fails closed: while the item cannot be read, no custom server
  /// runs, because whether it is waiting is unknown.
  nonisolated static func refusal(for server: BastionServer) -> ServerApprovals.Refusal? {
    let state = published.withLock { $0 }
    return ServerApprovals.refusal(
      custom: server.origin == .custom, pending: state.pending[server.id],
      unreadable: state.unreadable)
  }

  init() { load() }

  func load() {
    if DemoSeed.isEnabled { return }
    let stored: String?
    do {
      stored = try CredentialStore.lookup(.approvals, account: Self.account)
    } catch {
      fail("server approvals could not be read: \(error.localizedDescription)")
      // Most often a keychain still locked at a login launch. Tried again, so
      // custom servers do not stay refused until the next relaunch.
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(30))
        self?.load()
      }
      return
    }
    guard let stored else {
      problem = nil
      approvals = ServerApprovals()
      publish()
      return
    }
    guard let decoded = try? JSONDecoder().decode(ServerApprovals.self, from: Data(stored.utf8))
    else {
      fail(
        "server approvals in the Keychain could not be decoded, so Bastion will not write over "
          + "them. Remove the '\(CredentialStore.Scope.approvals.service)' item in Keychain "
          + "Access to start again.")
      return
    }
    problem = nil
    approvals = decoded
    publish()
  }

  /// A yes on this Mac: a click on Install or Allow, or a save made here.
  func approve(_ id: String, value: String) throws {
    var next = approvals
    next.approve(id, value: value)
    try replace(with: next)
  }

  func arrived(_ id: String, value: String, from: String) throws {
    var next = approvals
    next.arrived(id, value: value, from: from)
    try replace(with: next)
    if next.isPending(id) != nil {
      hostLog("sync", .info, "'\(id)' arrived from \(from) and waits to be allowed here")
    }
  }

  /// Every server set up here allowed at its current value, when sync is
  /// switched on, except one that is waiting. See `ServerApprovals`.
  func approveExisting(_ current: [String: String]) throws {
    var next = approvals
    next.approveExisting(current)
    try replace(with: next)
  }

  func forget(_ id: String) throws {
    guard approvals.approved[id] != nil || approvals.pending[id] != nil else { return }
    var next = approvals
    next.forget(id)
    try replace(with: next)
  }

  struct Unwritable: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
  }

  private func replace(with next: ServerApprovals) throws {
    if DemoSeed.isEnabled { return }
    if let problem { throw Unwritable(reason: problem) }
    guard next != approvals else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(next), as: UTF8.self)
    try CredentialStore.write(.approvals, account: Self.account, value: json)
    approvals = next
    publish()
  }

  private func fail(_ message: String) {
    problem = message
    hostLog("sync", .error, message)
    approvals = ServerApprovals()
    publish()
  }

  private func publish() {
    let next = Published(pending: approvals.pending, unreadable: problem != nil)
    Self.published.withLock { $0 = next }
  }
}
