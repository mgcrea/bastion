import Foundation
import Observation

/// What the Activity window shows.
///
/// The Activity window is the product. Bastion's claim is that a shared server
/// instance is *more* auditable than nine private ones, not less, and this is
/// where that is either true or marketing.
///
/// What it records, and the limit of the claim: Bastion sees the JSON-RPC
/// frames crossing the gateway — which profile, which method, which tool, and
/// the arguments it was called with; results too, for a profile that opts in.
/// Credentials are never recorded, and `CallCapture` is where that is enforced
/// rather than intended. It does not see what a server then does over the
/// network or on disk. README.md and docs/servers.md say so in the same words,
/// and the website must too.
///
/// Payloads live here and only here. Nothing writes them to disk — this store
/// is a ring buffer in memory, cleared on quit, and `hostCall` deliberately
/// keeps them off the stderr mirror that every other log line goes through.
@MainActor
@Observable
final class LogStore {
  static let shared = LogStore()

  enum Level: String {
    case info, call, error
  }

  struct Entry: Identifiable {
    var id = UUID()
    let at: Date
    /// `<profile>/<server>`, or a bare subsystem name like `gateway`.
    let origin: String
    let level: Level
    let text: String
    /// What a `tools/call` was called with, already redacted and capped by
    /// `CallCapture`. Nil when the profile records names only, when the tool is
    /// one whose arguments are never captured, or when there were none.
    var arguments: String?
    /// What came back, for a profile that opted into results. Attached later
    /// than the rest of the row: the reply arrives on another thread, after the
    /// entry it belongs to already exists.
    var result: String?
    /// Whether the reply was an error frame or an `isError` result. Only
    /// meaningful once a result has been attached.
    var failed = false

    /// Roughly what this row costs, for the byte budget below.
    var weight: Int { text.utf8.count + (arguments?.utf8.count ?? 0) + (result?.utf8.count ?? 0) }
  }

  /// Bounded: this runs for as long as the machine is up, and an unbounded log
  /// is a memory leak with a nice name.
  private let limit = 2000

  /// And bounded again, in bytes.
  ///
  /// The entry count alone stopped being a bound once rows could carry
  /// payloads: 2000 rows of a name is a few hundred kilobytes, 2000 rows of two
  /// capped payloads is sixteen megabytes pinned for as long as the app is up.
  /// Whichever limit is reached first trims.
  private let byteLimit = 4 * 1024 * 1024
  private var weight = 0

  private(set) var entries: [Entry] = []

  func append(origin: String, level: Level, _ text: String) {
    add(Entry(at: Date(), origin: origin, level: level, text: text))
  }

  /// Record a call under an id its reply will be attached to later.
  ///
  /// Separate from `append` because the arguments must not reach stderr — see
  /// `hostCall`, which is the only thing that should call this. The id is
  /// minted by the caller rather than here, so the calling thread can hold on
  /// to it without waiting for this main-actor hop to happen.
  func appendCall(origin: String, text: String, arguments: String?, id: UUID) {
    add(Entry(id: id, at: Date(), origin: origin, level: .call, text: text, arguments: arguments))
  }

  /// Attach a reply to the call it answers.
  ///
  /// A miss is ordinary rather than an error: the row may have been trimmed out
  /// of the ring buffer while the child was still working on it.
  func attachResult(_ id: UUID, _ result: String?, failed: Bool) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    weight -= entries[index].weight
    entries[index].result = result
    entries[index].failed = failed
    weight += entries[index].weight
  }

  /// Seed one entry at a fixed instant, for `DemoSeed` only.
  ///
  /// Separate from `append`/`appendCall` rather than an optional `at:` on
  /// either, and for two reasons. The live path must never be able to choose a
  /// timestamp — a log whose clock is an argument is a log nobody can reason
  /// about. And it must never be able to skip the stderr mirror, which is what
  /// this deliberately does: a capture run should not spray fixture lines into
  /// whatever terminal launched it.
  func appendDemo(
    at: Date, origin: String, level: Level, _ text: String,
    arguments: String? = nil, result: String? = nil, failed: Bool = false
  ) {
    add(
      Entry(
        at: at, origin: origin, level: level, text: text, arguments: arguments, result: result,
        failed: failed))
  }

  private func add(_ entry: Entry) {
    entries.append(entry)
    weight += entry.weight
    while entries.count > limit || (weight > byteLimit && entries.count > 1) {
      weight -= entries.removeFirst().weight
    }
  }

  func clear() {
    entries.removeAll()
    weight = 0
  }
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

/// Post a call line, with its arguments kept out of the stderr mirror.
///
/// The mirror is why this is not `hostLog(origin, .call, ...)` with a longer
/// string. `hostLog` writes every line it is given to stderr, and for an app
/// started by LaunchServices that lands outside Bastion's 0o700 directory and
/// outlives the process — so routing a payload through it would quietly persist
/// the one thing this feature promises to keep in memory. Only the tool name
/// goes to stderr here; the arguments go to the store and nowhere else.
///
/// Returns the entry id so the reply can be attached to the right row, or nil
/// if the hop has not happened yet — the caller treats that as "not recorded",
/// which is the correct failure.
@discardableResult
nonisolated func hostCall(_ origin: String, _ text: String, arguments: String?) -> UUID {
  let id = UUID()
  let bytes = Array("[\(origin)] call: \(text)\n".utf8)
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
  // Pinned to one priority, and the same one `Activity` uses. The main actor's
  // executor only guarantees FIFO *within* a priority, so a call hop left to
  // inherit could overtake the one before it — and a result attaching to a row
  // that has not been appended yet is silently dropped. Spelled out rather than
  // read from `Activity` so this file keeps a dependency closure small enough
  // for the standalone check targets to compile it.
  Task(priority: .userInitiated) { @MainActor in
    LogStore.shared.appendCall(origin: origin, text: text, arguments: arguments, id: id)
  }
  return id
}

/// Attach a reply from any thread.
nonisolated func hostCallResult(_ id: UUID, _ result: String?, failed: Bool) {
  guard result != nil || failed else { return }
  Task(priority: .userInitiated) { @MainActor in
    LogStore.shared.attachResult(id, result, failed: failed)
  }
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
