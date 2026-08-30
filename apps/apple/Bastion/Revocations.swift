import Foundation

/// Licence ids that have been withdrawn — a chargeback, a refund, a key posted
/// somewhere public.
///
/// Baked in rather than fetched, because fetching it would be the network call
/// `License.swift` refuses to make. That means a revocation only takes effect
/// when someone updates, which is the trade: a check that works offline, or one
/// that works instantly. Offline wins, because the alternative phones home on
/// every launch for every honest user in order to inconvenience a dishonest one.
nonisolated enum Revocations {
  static let ids: Set<String> = []
}
