import Foundation
import Observation

/// What the Activity window shows.
///
/// The Activity window is the product. Bastion's claim is that a shared server
/// instance is *more* auditable than nine private ones, not less, and this is
/// where that is either true or marketing.
///
/// What it records, and the limit of the claim: Bastion sees the JSON-RPC
/// frames crossing the gateway — which profile, which method, which tool, how
/// long. It does not see what a server then does over the network or on disk.
/// docs/servers.md says so in the same words, and the website must too.
@MainActor
@Observable
final class LogStore {
  static let shared = LogStore()

  enum Level: String {
    case info, call, error
  }

  struct Entry: Identifiable {
    let id = UUID()
    let at: Date
    /// `<profile>/<server>`, or a bare subsystem name like `gateway`.
    let origin: String
    let level: Level
    let text: String
  }

  /// Bounded: this runs for as long as the machine is up, and an unbounded log
  /// is a memory leak with a nice name.
  private let limit = 2000
  private(set) var entries: [Entry] = []

  func append(origin: String, level: Level, _ text: String) {
    entries.append(Entry(at: Date(), origin: origin, level: level, text: text))
    if entries.count > limit { entries.removeFirst(entries.count - limit) }
  }

  func clear() { entries.removeAll() }
}

/// Post a log line from any thread.
///
/// Also mirrored to stderr, which is where it shows up when the app is launched
/// from a terminal instead of by LaunchServices — the difference between being
/// able to debug the gateway and guessing at it.
///
/// The stderr mirror goes through `write(2)` rather than `FileHandle`:
/// `-[NSFileHandle writeData:]` raises an Objective-C exception on a failed
/// write, Swift cannot catch it, and the process aborts. A logging call must
/// not be able to take the app down. A dropped line is the correct failure.
nonisolated func hostLog(_ origin: String, _ level: LogStore.Level, _ text: String) {
  let bytes = Array("[\(origin)] \(level.rawValue): \(text)\n".utf8)
  var offset = 0
  while offset < bytes.count {
    let written = bytes.withUnsafeBufferPointer {
      write(STDERR_FILENO, $0.baseAddress! + offset, bytes.count - offset)
    }
    if written <= 0 {
      if errno == EINTR { continue }
      break
    }
    offset += written
  }
  Task { @MainActor in LogStore.shared.append(origin: origin, level: level, text) }
}

/// Where Bastion keeps everything that is not a secret.
///
/// Keyed by bundle identifier, so a Debug build never reads or writes the real
/// app's state — the same reason the Debug build has its own bundle id at all.
nonisolated enum AppSupport {
  static var identifier: String {
    Bundle.main.bundleIdentifier ?? "io.mgcrea.bastion"
  }

  static var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent(identifier, isDirectory: true)
  }

  @discardableResult
  static func ensureDirectory() -> URL {
    let url = directory
    try? FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true,
      // 0o700. This directory holds profile configuration and per-profile
      // OAuth token files written by the child servers. None of it is
      // world-readable business.
      attributes: [.posixPermissions: 0o700])
    return url
  }
}

nonisolated func errnoText() -> String { String(cString: strerror(errno)) }

/// Mark `fd` FD_CLOEXEC, so spawned servers do not inherit it.
///
/// This matters more here than it did in cupertino. A child that inherited the
/// listening socket would keep the gateway's port bound after Bastion quit, and
/// a child that inherited another profile's pipe would hold that pipe open past
/// its owner's exit — a cross-profile leak in a process whose entire job is
/// keeping profiles apart.
nonisolated func closeOnExec(_ fd: Int32) {
  let flags = fcntl(fd, F_GETFD)
  if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
}

/// Run `body` on a thread of its own, off libdispatch's global pools.
///
/// Inherited from cupertino, where it was learned expensively: everything a
/// relay does per connection blocks — a pump sits in `read(2)` for the life of
/// a child, a reader sits waiting on a response. libdispatch's global queues
/// are a BOUNDED pool (roughly 64 threads per QoS) and a blocked thread is not
/// a free one, so connections consumed the pool instead of sharing it.
///
/// Past the limit the failure was not slowness, it was silence: already-queued
/// blocks stayed queued forever, so `accept` kept succeeding and every new
/// client waited on a reply from a function that was never scheduled. Nothing
/// logged an error, because from the host's point of view nothing had failed.
///
/// A pump is a long-lived blocking task. That is what a thread is for, and
/// precisely what a bounded work queue is not.
nonisolated func onDedicatedThread(_ name: String, _ body: @escaping @Sendable () -> Void) {
  let thread = Thread(block: body)
  thread.name = name
  thread.stackSize = 512 * 1024
  thread.start()
}

@discardableResult
nonisolated func writeAll(_ fd: Int32, _ data: Data) -> Bool {
  data.withUnsafeBytes { raw -> Bool in
    guard let base = raw.baseAddress else { return true }
    var offset = 0
    while offset < raw.count {
      let n = write(fd, base + offset, raw.count - offset)
      if n <= 0 {
        if errno == EINTR { continue }
        return false
      }
      offset += n
    }
    return true
  }
}
