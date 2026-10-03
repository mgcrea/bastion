import Foundation
import os

/// Exponential backoff with a ceiling, then a breaker, per profile.
///
/// A server that cannot start — a revoked credential, a bad endpoint — will not
/// start on the fourth try either, and retrying it on every request turns one
/// misconfigured profile into a fork bomb. The breaker makes the failure
/// legible instead: the error names the profile and says when it will be tried
/// again.
///
/// Owned by `Supervisor` and keyed by profile id, so it outlives the
/// `Instance` that failed. It used to live on the instance, and a dead child's
/// instance is replaced on the next request, so the count went back to zero
/// every time and the breaker never opened.
///
/// Its own file, Foundation and os only, so `scripts/unit-check.swift`
/// compiles it.
nonisolated final class RestartBackoff: Sendable {
  private struct Entry {
    var failures = 0
    var blockedUntil: Date?
  }

  private let entries = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

  /// When `key` may next be started, or nil if it may be started now.
  func blockedUntil(_ key: String, now: Date = Date()) -> Date? {
    guard let until = entries.withLock({ $0[key]?.blockedUntil }), until > now else { return nil }
    return until
  }

  /// The first failure is retried at once: one crash of a child that was
  /// serving should cost the next request nothing, and a healthy child clears
  /// the count at its handshake. From the second, two seconds, doubling, never
  /// more than a minute.
  func failed(_ key: String, now: Date = Date()) {
    entries.withLock { table in
      var entry = table[key] ?? Entry()
      entry.failures += 1
      if entry.failures > 1 {
        let delay = min(pow(2.0, Double(entry.failures - 1)), 60)
        entry.blockedUntil = now.addingTimeInterval(delay)
      }
      table[key] = entry
    }
  }

  func succeeded(_ key: String) {
    _ = entries.withLock { $0.removeValue(forKey: key) }
  }
}

/// Stopping a child, and making sure it stopped.
///
/// SIGTERM first, always: the child gets to close its own token file and flush
/// its own state. But SIGTERM was the whole of it, and a child that ignores it
/// or is wedged kept running with the profile's credentials and nothing
/// supervising it — which is the state Bastion exists to end. So SIGKILL
/// follows if it is still there after the grace.
nonisolated enum ChildTermination {
  /// SIGTERM now, SIGKILL after `grace` if it is still running. Returns at
  /// once; the escalation happens on a utility queue.
  static func terminate(_ process: Process, grace: TimeInterval) {
    guard process.isRunning else { return }
    process.terminate()
    let pid = process.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
      if process.isRunning, process.processIdentifier == pid { kill(pid, SIGKILL) }
    }
  }

  /// SIGTERM to all of them, wait up to `grace` for them to go, SIGKILL the
  /// rest, and wait briefly for those too. Synchronous, for the one caller that
  /// has no later: the app quitting, where a SIGKILL scheduled for after the
  /// grace would never fire.
  static func terminateAll(_ processes: [Process], grace: TimeInterval) {
    let running = processes.filter(\.isRunning)
    guard !running.isEmpty else { return }
    for process in running { process.terminate() }
    waitUntilGone(running, deadline: Date().addingTimeInterval(grace))
    let stubborn = running.filter(\.isRunning)
    for process in stubborn { kill(process.processIdentifier, SIGKILL) }
    waitUntilGone(stubborn, deadline: Date().addingTimeInterval(1))
  }

  private static func waitUntilGone(_ processes: [Process], deadline: Date) {
    while processes.contains(where: \.isRunning), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
  }
}
