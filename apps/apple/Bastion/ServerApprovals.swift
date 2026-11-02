import Foundation

/// Which custom servers this Mac has said yes to, and which arrived from
/// another Mac and are waiting for one.
///
/// The guard's third mechanism (`docs/superpowers/specs/2026-11-01-icloud-config-sync-design.md`,
/// "The guard"): synced data must not choose code or an endpoint on another
/// Mac. A custom server names a package or a URL, so one that arrives new or
/// changed waits until a person here allows it. Approval is per server and per
/// value: approving `url = X` does not approve a later `url = Y`.
///
/// A change made on this Mac, through the app, a tool or a hand edit, counts
/// as approved here. Only arrivals wait. `ServerApprovalStore` keeps this in
/// the Keychain, never synced, so approving on one Mac approves nothing on
/// another, and an agent cannot forge a yes by editing a file.
///
/// Its own file, Foundation only, so `scripts/unit-check.swift` compiles it.
nonisolated struct ServerApprovals: Codable, Equatable, Sendable {
  struct Pending: Codable, Equatable, Sendable {
    var value: String
    var from: String
  }

  /// Server id → every value approved on this Mac.
  var approved: [String: [String]] = [:]
  /// Server id → the value waiting, and the Mac it came from.
  var pending: [String: Pending] = [:]

  /// What a custom server runs or reaches, as one comparable string.
  static func value(npmName: String?, binName: String?, url: String?) -> String {
    if let url { return "url:\(url)" }
    return "npm:\(npmName ?? "")|\(binName ?? "")"
  }

  mutating func approve(_ id: String, value: String) {
    var values = approved[id] ?? []
    if !values.contains(value) { values.append(value) }
    approved[id] = values
    pending[id] = nil
  }

  /// A custom server arrived from `from` with `value`: waiting, unless this
  /// Mac has approved that value for it before.
  mutating func arrived(_ id: String, value: String, from: String) {
    if approved[id]?.contains(value) == true {
      pending[id] = nil
    } else {
      pending[id] = Pending(value: value, from: from)
    }
  }

  mutating func forget(_ id: String) {
    approved[id] = nil
    pending[id] = nil
  }

  func isPending(_ id: String) -> Pending? { pending[id] }
}
