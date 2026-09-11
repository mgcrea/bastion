import Foundation
import Observation

/// The two facts about the gateway a view needs, in a form SwiftUI can watch.
///
/// `Gateway` is `nonisolated ... Sendable` with its state behind an
/// `OSAllocatedUnfairLock`, because it is touched from every connection thread.
/// That is the right shape for the gateway and the wrong shape for a view:
/// there is nothing for SwiftUI to subscribe to, so `Gateway.shared.port` read
/// inside a `body` is a value sampled once and never revisited.
///
/// The popover got away with it only because `MenuBarExtra` rebuilds its content
/// on every open. A gateway that failed while the panel was on screen went on
/// showing "Serving on 127.0.0.1:…" — and that line exists precisely to beat the
/// client's "connection refused" to the user, so it is the one that must not be
/// stale. The main window had the same read with no lazy rebuild to hide it.
///
/// This is `Activity`'s pattern, for `Activity`'s reason: a projection a window
/// can watch, with the authority left where it was. Nothing here is read back by
/// the gateway.
@MainActor
@Observable
final class GatewayStatus {
  static let shared = GatewayStatus()

  /// Pinned for the reason `Activity` pins it: the executor only guarantees FIFO
  /// within one priority, and a status published from the starting thread must
  /// not be overtaken by a later one.
  nonisolated static let priority = TaskPriority.userInitiated

  private(set) var port: UInt16 = Gateway.defaultPort
  private(set) var startupError: String?

  private init() {}

  /// Called by `Gateway.start()` on both paths, so the projection carries the
  /// outcome rather than only the happy one.
  nonisolated static func publish(port: UInt16, startupError: String?) {
    Task(priority: priority) { @MainActor in
      shared.port = port
      shared.startupError = startupError
    }
  }
}
