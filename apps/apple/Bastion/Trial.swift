import Foundation
import os

/// A full-function evaluation window, started by a person and held in memory.
///
/// The problem it solves is narrow. Unlicensed, the gate in `Gateway` refuses
/// every request, so nobody could find out whether one supervised instance
/// actually works with *their* clients and *their* credentials before paying.
/// A refund is the trial for the purchase decision; this is for the technical
/// one, which is a different question and is asked first.
///
/// Three properties, each load-bearing:
///
/// **Full function.** Every server, every profile, write gates obeying their
/// own toggles. A crippled demo answers the wrong question — the thing being
/// evaluated is whether this works on this Mac against these servers, and a
/// degraded mode cannot answer that.
///
/// **In memory.** The deadline dies with the process, so there is no expiry
/// state on disk, nothing to invalidate, and no "one trial per machine" fiction
/// to pretend to enforce. Quitting and reopening starts another one. That is
/// not an oversight: somebody relaunching the app every half hour to avoid the
/// price was never going to buy it, and the code to stop them would cost more
/// than they are worth.
///
/// **Started by hand.** `start()` is reachable only from a button. A stdio
/// client's bridge launches Bastion on demand while somebody is mid-sentence at
/// an assistant, and a trial that armed itself there would burn silently in a
/// window nobody was watching.
nonisolated enum Trial {
  static let duration: TimeInterval = 30 * 60

  /// The lock is not ceremony. `Gateway` reads this from a connection thread
  /// while the button that writes it runs on the main actor, so the two
  /// genuinely race. `UserDefaults` gets away with a bare read because it is
  /// itself thread-safe; a stored `Date?` is not.
  private static let state = OSAllocatedUnfairLock<Date?>(initialState: nil)

  /// Arm the window, or extend nothing. Starting a trial that is already
  /// running returns the existing deadline rather than pushing it out, so
  /// leaning on the button cannot stretch the half hour.
  @discardableResult
  static func start() -> Date {
    let (deadline, isFresh) = state.withLock { stored -> (Date, Bool) in
      if let stored, stored > Date() { return (stored, false) }
      let next = Date().addingTimeInterval(duration)
      stored = next
      return (next, true)
    }
    if isFresh {
      hostLog("licence", .info, "trial started — \(Int(duration / 60)) minutes")
      // `wallDeadline`, not `deadline`: the dispatch clock stops while the Mac
      // is asleep and `Date` does not, so a monotonic timer would leave the
      // gate refusing while the children it was meant to reap kept running.
      DispatchQueue.main.asyncAfter(wallDeadline: .now() + duration) { expire() }
    }
    return deadline
  }

  /// Stop the children when the window closes.
  ///
  /// Refusing new requests is already immediate — every request is its own
  /// HTTP POST, so unlike cupertino's long-lived stdio connections there is no
  /// session to outlive the gate. But a supervised child is kept alive for half
  /// an hour after its last call, and one left running past the trial is a
  /// process holding the user's credentials for a gateway that will no longer
  /// route to it.
  private static func expire() {
    guard !LicenseStore.isLicensed else {
      // A key entered during the window keeps everything running. The half hour
      // bought the answer it was for; taking the servers away from somebody who
      // has just paid, because a timer they have already satisfied went off,
      // would be indefensible.
      return
    }
    hostLog("licence", .info, "trial ended — stopping every supervised server")
    Supervisor.shared.stopAll()
  }

  static var deadline: Date? { state.withLock { $0 } }

  static var isActive: Bool {
    guard let deadline else { return false }
    return deadline > Date()
  }

  /// Whether a window was opened this launch, expired or not. What the menu
  /// needs to tell "not tried yet" from "tried, and it ran out" — two states
  /// that want different words and a different button.
  static var hasRun: Bool { deadline != nil }

  static var remaining: TimeInterval {
    guard let deadline else { return 0 }
    return max(0, deadline.timeIntervalSinceNow)
  }

  /// Minutes, rounded up, so a window with forty seconds left reads "1 minute"
  /// rather than "0 minutes" while it is still working.
  static var remainingMinutes: Int { Int(ceil(remaining / 60)) }

  static var remainingText: String {
    let minutes = remainingMinutes
    return minutes == 1 ? "1 minute left" : "\(minutes) minutes left"
  }
}

/// What this Mac may do right now, as one answer with the reason attached.
///
/// Three places ask: the gate in `Gateway`, the menu, and the licence window.
/// Joining a key and a trial window at each of them separately is how the menu
/// ends up saying "unlicensed" while the servers are happily running.
nonisolated enum Entitlement {
  case licensed(License)
  case trial
  case refused(String)

  static var current: Entitlement {
    switch LicenseStore.check {
    case .valid(let license):
      return .licensed(license)
    case .refused(let reason):
      // A key first, always. Someone who has paid must never be told about a
      // trial, and a trial armed before a key was entered must not outrank it.
      return Trial.isActive ? .trial : .refused(reason)
    }
  }

  var allowsServers: Bool {
    if case .refused = self { return false }
    return true
  }
}
