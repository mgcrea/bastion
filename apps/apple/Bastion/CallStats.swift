import Foundation
import Observation
import os

/// What crossed the gateway, rolled up per day and kept across launches.
///
/// **The claim every other surface makes on this file's behalf.** Bastion keeps
/// a small usage rollup on disk, on by default. Per day, per profile and per
/// tool: how many calls, how many bytes came back, how long they took, how many
/// failed, and how many times a server restarted. Counts only, with no
/// arguments, no results, no resource URIs and no ids. Tens of kilobytes a day
/// on a busy machine and under two on a quiet one, under Application Support,
/// readable only by you, kept for ninety days, and nothing uploads it. Settings
/// › Activity turns it off and deletes it.
///
/// That paragraph is quoted by the EULA, the privacy page, the README and the
/// Activity settings pane. `make unit` holds the size half of it to a number, so
/// it stays a fact rather than an intention. Anything added here that is not a
/// counter makes all four wrong at once.
///
/// **Why the gateway and not the log.** `LogStore.record` looked like the
/// funnel and is not: it returns nil for `tools/list`, which is the single most
/// important frame for the context story, and its result hook only fires for a
/// profile that opted into recording results. `Gateway.handleRPC` sits above all
/// three transports, holds the bytes the client is actually sent, and is
/// synchronous on the connection's own thread — so latency is a subtraction and
/// needs no correlation mechanism at all. `Waiter` gains no field and `logID`
/// keeps its one meaning.
///
/// **Why there is no main-actor hop.** `Activity.called` hops per call and can
/// afford to, because it maintains an ordered array whose rows are mutated in
/// place. Counter accumulation is commutative — `make unit` asserts exactly
/// that — so there is nothing for an executor to order and nothing for
/// `Activity.priority` to protect. The lock is held for arithmetic only: no
/// syscall, no allocation on the common path, no encoding. Anything added here
/// that needs ordering makes this paragraph wrong, and the design with it.
nonisolated final class CallStats: Sendable {
  static let shared = CallStats()

  typealias Bucket = CallStatsRollup.Bucket
  typealias DayNumber = CallStatsRollup.DayNumber

  // MARK: - Settings

  static let enabledKey = "statsEnabled"
  static let maxDaysKey = "statsMaxDays"
  static let includeBuiltinKey = "statsIncludeBuiltin"

  /// On by default, unlike the audit log. The audit log records payloads and
  /// earns its opt-in; this records counts, and a statistics pane that is empty
  /// until somebody finds a switch is a statistics pane nobody ever sees.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  static var maxDays: Int {
    let stored = UserDefaults.standard.integer(forKey: maxDaysKey)
    return stored > 0 ? min(365, max(1, stored)) : CallStatsRollup.defaultMaxDays
  }

  /// Whether Bastion's own server appears in its own ranking. Off, and the
  /// reasoning is at `separatelyCounted`.
  static var includesBuiltin: Bool {
    UserDefaults.standard.bool(forKey: includeBuiltinKey)
  }

  // MARK: - What is counted, and what is not

  /// Counted, but kept out of the default view.
  ///
  /// Bastion's own server is real traffic and dropping it outright would make
  /// the settings toggle a lie. But it is traffic ABOUT the app, and leaving it
  /// in the ranking means the top row of the statistics pane is the statistics
  /// pane. `CallCapture.neverCaptureResults` makes the same call one layer down,
  /// for the same reason, against the same tool.
  ///
  /// Note that `server_stats` deliberately does NOT belong in
  /// `CallCapture.neverCaptureResults`: its result is counts, not the log, so it
  /// cannot inflate the log the way `recent_activity` did. The distortion it
  /// causes is a statistics concern and is handled here.
  static let separatelyCounted: Set<String> = [BuiltinServer.id]

  /// Never counted at all.
  ///
  /// A deep check is Bastion auditing a server, not a client using one. It
  /// already earns this exemption on the log path, and counting it would put
  /// Bastion's own diagnostics in a ranking of what the user does.
  static let neverCounted: Set<String> = [ServerCheck.client]

  // MARK: - A sample

  struct Sample: Sendable {
    var profile: String
    var server: String
    /// The authenticated identity the bearer token was issued to, not the
    /// client's self-reported name.
    var client: String
    var method: String?
    /// `params.name`, for `tools/call` only. A `resources/read` records its
    /// method and never its URI: a URI is a path and a path is content.
    var tool: String?
    /// What the client is sent, measured after `modernise` — the number
    /// `Content-Length` will carry.
    var bytes: Int
    var started: DispatchTime
    var failed: Bool
    /// A frame with no id is a notification, which is traffic and not a call.
    /// The rule is `Activity.called(counts:)`'s, reused rather than re-decided.
    var counted: Bool
  }

  // MARK: - State

  private struct CallKey: Hashable {
    var profile: String
    var server: String
    var label: String
    var isTool: Bool
  }

  private struct ClientKey: Hashable {
    var client: String
    var profile: String
    var server: String
  }

  private struct ServerKey: Hashable {
    var profile: String
    var server: String
  }

  private struct Table {
    var calls: [DayNumber: [CallKey: Bucket]] = [:]
    var clients: [DayNumber: [ClientKey: Bucket]] = [:]
    var life: [DayNumber: [ServerKey: CallStatsRollup.LifeRow]] = [:]
    /// How many distinct labels each server has minted today, so the
    /// cardinality guard can fold without scanning the table.
    var labels: [DayNumber: [ServerKey: Int]] = [:]
    var dirty = false
    var needsPrune = false
    /// False once a file from a newer build was found. Reading stops too, so a
    /// Sparkle rollback neither shows a history it half-understands nor
    /// overwrites one it cannot read.
    var writable = true
    var loaded = false
    var cachedDay: DayNumber = 0
    var dayExpires: UInt64 = 0
    var offset = 0
  }

  private let state = OSAllocatedUnfairLock(initialState: Table())

  /// Writes only. Serial and `.utility`, mirroring `AuditLog`'s writer: a
  /// counter is never what a user is waiting for.
  private let writer = DispatchQueue(label: "io.mgcrea.bastion.stats", qos: .utility)
  private let timer = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)

  private var fileURL: URL { AppSupport.directory.appendingPathComponent("call-stats.json") }
  private var corruptURL: URL {
    AppSupport.directory.appendingPathComponent("call-stats.corrupt.json")
  }

  // MARK: - Lifecycle

  /// Load what is on disk and start the flush timer.
  ///
  /// Called once from `BastionApp`, beside the audit log's installation. Sixty
  /// seconds, and a tick with nothing to write returns immediately — the cost of
  /// a crash is at most a minute of counters, which is a trade worth stating
  /// rather than an fsync per call nobody would notice the absence of.
  func start() {
    load()
    let source = DispatchSource.makeTimerSource(queue: writer)
    source.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
    source.setEventHandler { [weak self] in self?.flush() }
    source.resume()
    timer.withLock { existing in
      existing?.cancel()
      existing = source
    }
  }

  /// Write now, on the caller's thread. For `applicationWillTerminate`, where
  /// there is no later.
  func flushNow() { flush() }

  // MARK: - Recording

  func record(_ sample: Sample) {
    guard sample.counted, Self.isEnabled else { return }
    guard !Self.neverCounted.contains(sample.client) else { return }

    let elapsed = DispatchTime.now().uptimeNanoseconds &- sample.started.uptimeNanoseconds
    let milliseconds = Int(elapsed / 1_000_000)
    let requested = sample.tool ?? sample.method ?? "unknown"
    let isTool = sample.tool != nil

    state.withLock { table in
      guard table.writable else { return }
      let day = Self.today(&table)
      let serverKey = ServerKey(profile: sample.profile, server: sample.server)

      let used = table.labels[day]?[serverKey] ?? 0
      let label = CallStatsRollup.label(requested, existingLabels: used)
      let key = CallKey(
        profile: sample.profile, server: sample.server, label: label, isTool: isTool)
      if table.calls[day]?[key] == nil {
        table.labels[day, default: [:]][serverKey] = used + 1
      }
      table.calls[day, default: [:]][key, default: Bucket()]
        .record(milliseconds: milliseconds, bytes: sample.bytes, failed: sample.failed)

      let clientKey = ClientKey(
        client: sample.client, profile: sample.profile, server: sample.server)
      table.clients[day, default: [:]][clientKey, default: Bucket()]
        .record(milliseconds: milliseconds, bytes: sample.bytes, failed: sample.failed)

      table.dirty = true
    }
  }

  /// What the write gate and the facade kept out of a client's context.
  ///
  /// Not a call sample and never correlated to one. Both are `tools/list`-only
  /// and therefore cold, and both are measured rather than forecast — which is
  /// the whole reason they are worth a line of their own beside the ranking,
  /// where every other figure is a forecast from `ToolCostStore`.
  func noteSaved(profile: String, server: String, gate: Int = 0, facade: Int = 0) {
    guard Self.isEnabled, gate > 0 || facade > 0 else { return }
    mutateLife(profile: profile, server: server) {
      $0.savedByGate += max(0, gate)
      $0.savedByFacade += max(0, facade)
    }
  }

  func noteStarted(profile: String, server: String, isRestart: Bool) {
    guard Self.isEnabled else { return }
    mutateLife(profile: profile, server: server) {
      $0.starts += 1
      if isRestart { $0.restarts += 1 }
    }
  }

  func noteExited(profile: String, server: String) {
    guard Self.isEnabled else { return }
    mutateLife(profile: profile, server: server) { $0.exits += 1 }
  }

  private func mutateLife(
    profile: String, server: String, _ body: @Sendable (inout CallStatsRollup.LifeRow) -> Void
  ) {
    state.withLock { table in
      guard table.writable else { return }
      let day = Self.today(&table)
      let key = ServerKey(profile: profile, server: server)
      var row =
        table.life[day]?[key] ?? CallStatsRollup.LifeRow(profile: profile, server: server)
      body(&row)
      table.life[day, default: [:]][key] = row
      table.dirty = true
    }
  }

  // MARK: - Which day it is

  /// The local day, recomputed at most once a minute.
  ///
  /// `Calendar.startOfDay` is expensive enough to notice at gateway rates, and
  /// this is called under the lock on every call. The cost of the cache is that
  /// a sample within a minute of local midnight can land in the previous day;
  /// `make unit` holds the property that matters, which is that it can never
  /// skip one.
  private static func today(_ table: inout Table) -> DayNumber {
    let now = DispatchTime.now().uptimeNanoseconds
    if now < table.dayExpires { return table.cachedDay }
    table.offset = TimeZone.current.secondsFromGMT()
    let day = CallStatsRollup.day(for: Date(), secondsFromGMT: table.offset)
    if day != table.cachedDay && table.cachedDay != 0 { table.needsPrune = true }
    table.cachedDay = day
    table.dayExpires = now &+ 60_000_000_000
    return day
  }

  private var secondsFromGMT: Int {
    state.withLock { $0.offset != 0 ? $0.offset : TimeZone.current.secondsFromGMT() }
  }

  // MARK: - Disk

  private func load() {
    // Never the real file under a capture, and never a seed from here either:
    // `applicationDidFinishLaunching` returns before `start()` on that path, so
    // the fixture is installed by `DemoSeed.seedStores` alongside every other
    // store rather than arriving through a code path a capture does not run.
    if DemoSeed.isEnabled {
      state.withLock { $0.loaded = true }
      return
    }
    // A file this build can read, or a declared reason it cannot.
    guard let data = try? Data(contentsOf: fileURL) else {
      state.withLock { $0.loaded = true }
      return
    }
    switch CallStatsRollup.decode(data) {
    case .loaded(let file):
      state.withLock { table in
        Self.absorb(file.days, into: &table)
        table.loaded = true
        table.needsPrune = true
      }
    case .refused(let version):
      hostLog(
        "stats", .error,
        "call-stats.json was written by a newer build (version \(version)); "
          + "leaving it alone and recording nothing this session")
      state.withLock {
        $0.writable = false
        $0.loaded = true
      }
    case .corrupt:
      // Renamed rather than deleted, so "my stats vanished" becomes a file
      // somebody can hand over. One rename, not one per launch: if the aside
      // already exists it is replaced, which is the only way a repeatedly
      // corrupt file does not fill the directory.
      try? FileManager.default.removeItem(at: corruptURL)
      try? FileManager.default.moveItem(at: fileURL, to: corruptURL)
      hostLog(
        "stats", .error, "call-stats.json could not be read; kept aside as call-stats.corrupt.json")
      state.withLock { $0.loaded = true }
    }
  }

  private static func absorb(_ days: [CallStatsRollup.Day], into table: inout Table) {
    for day in days {
      for row in day.rows {
        let key = CallKey(
          profile: row.profile, server: row.server, label: row.label, isTool: row.isTool)
        table.calls[day.day, default: [:]][key, default: Bucket()].merge(row.bucket)
        let serverKey = ServerKey(profile: row.profile, server: row.server)
        table.labels[day.day, default: [:]][serverKey, default: 0] += 1
      }
      for row in day.clients {
        let key = ClientKey(client: row.client, profile: row.profile, server: row.server)
        table.clients[day.day, default: [:]][key, default: Bucket()].merge(row.bucket)
      }
      for row in day.life {
        let key = ServerKey(profile: row.profile, server: row.server)
        var existing =
          table.life[day.day]?[key]
          ?? CallStatsRollup.LifeRow(profile: row.profile, server: row.server)
        existing.merge(row)
        table.life[day.day, default: [:]][key] = existing
      }
    }
  }

  /// Encode outside the lock, taking a copy under it.
  ///
  /// The discipline `Supervisor.Instance.received` states when it moves the sink
  /// outside its own lock: a lock held across serialization is a lock held
  /// across an allocation storm, on a path every connection thread contends for.
  private func flush() {
    if DemoSeed.isEnabled { return }
    let snapshot: [CallStatsRollup.Day]? = state.withLock { table in
      guard table.writable, table.dirty, table.loaded else { return nil }
      table.dirty = false
      var days = Self.materialise(table)
      if table.needsPrune {
        table.needsPrune = false
        days = CallStatsRollup.prune(
          days, today: table.cachedDay, maxDays: Self.maxDays,
          maxBytes: CallStatsRollup.defaultMaxBytes)
        Self.replace(&table, with: days)
      }
      return days
    }
    guard let snapshot else { return }
    AppSupport.ensureDirectory()
    guard let data = try? CallStatsRollup.encoder().encode(CallStatsRollup.File(days: snapshot))
    else { return }
    do {
      try data.write(to: fileURL, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      hostLog("stats", .error, "could not write call-stats.json: \(error.localizedDescription)")
    }
  }

  private static func materialise(_ table: Table) -> [CallStatsRollup.Day] {
    let numbers = Set(table.calls.keys).union(table.clients.keys).union(table.life.keys)
    return numbers.sorted().map { number in
      CallStatsRollup.Day(
        day: number,
        rows: (table.calls[number] ?? [:]).map { key, bucket in
          CallStatsRollup.CallRow(
            profile: key.profile, server: key.server, label: key.label, isTool: key.isTool,
            bucket: bucket)
        },
        clients: (table.clients[number] ?? [:]).map { key, bucket in
          CallStatsRollup.ClientRow(
            client: key.client, profile: key.profile, server: key.server, bucket: bucket)
        },
        life: Array((table.life[number] ?? [:]).values))
    }
  }

  private static func replace(_ table: inout Table, with days: [CallStatsRollup.Day]) {
    let kept = Set(days.map(\.day))
    table.calls = table.calls.filter { kept.contains($0.key) }
    table.clients = table.clients.filter { kept.contains($0.key) }
    table.life = table.life.filter { kept.contains($0.key) }
    table.labels = table.labels.filter { kept.contains($0.key) }
  }

  // MARK: - The capture fixture

  /// Thirty fixed days, in memory, written nowhere.
  ///
  /// `load()` and `flush()` both refuse under a capture for the reason
  /// `ToolCostStore` gives: a seed that reached `UserDefaults` or Application
  /// Support would write the fixture into the developer's own state, and a
  /// capture that read the real file would photograph their traffic.
  ///
  /// Fixed rather than merely plausible, which is the rule this whole file is
  /// held to. The shape is one story a reader can follow across three cards: a
  /// weekly rhythm with weekends visibly quiet, one busy Thursday, and a single
  /// bad day where `lab/unifi-network` restarted twice, failed eleven calls and
  /// dragged its own latency band up with it. Calls, Response time and Restarts
  /// all point at the same day on purpose.
  func seedDemo() {
    guard DemoSeed.isEnabled else { return }
    let anchor = DemoSeed.at(41, 0)
    let offset = TimeZone.current.secondsFromGMT(for: anchor)
    let today = CallStatsRollup.day(for: anchor, secondsFromGMT: offset)

    /// share is in hundredths, so the weights read as percentages.
    let shape:
      [(profile: String, server: String, share: Int, latency: Int, tools: [(String, Int)])] = [
        (
          "prod", "shopify", 46, 60,
          [("get_order", 50), ("search_products", 30), ("get_customer", 20)]
        ),
        ("acme", "keycloak", 18, 120, [("list_users", 60), ("get_realm", 40)]),
        ("lab", "unifi-network", 16, 210, [("list_clients", 55), ("restart_device", 45)]),
        ("home", "unifi-network", 12, 190, [("list_clients", 100)]),
        ("staging", "shopify", 8, 55, [("get_order", 100)]),
      ]

    /// The day everything went wrong, counted back from the capture date.
    let badDay = 23
    let busyDay = 26

    state.withLock { table in
      table.offset = offset
      table.cachedDay = today
      table.dayExpires = .max
      for index in 0..<30 {
        let day = today - 29 + DayNumber(index)
        let isWeekend = (day + 4) % 7 >= 5
        var total = isWeekend ? 9 : 52
        total += (index * 7) % 13 - 6
        if index == busyDay { total = 118 }
        // Forced to a weekday's volume, whichever weekday it lands on. Left to
        // the rhythm it fell on a quiet Sunday, and eleven failures out of one
        // call is not a cluster anybody can see — the whole point of this day is
        // that Calls, Response time and Restarts all point at it.
        if index == badDay { total = 64 }

        for entry in shape {
          let serverKey = ServerKey(profile: entry.profile, server: entry.server)
          let calls = max(1, total * entry.share / 100)
          let broken = index == badDay && entry.server == "unifi-network" && entry.profile == "lab"
          var remaining = calls
          for (position, tool) in entry.tools.enumerated() {
            let count =
              position == entry.tools.count - 1 ? remaining : max(1, calls * tool.1 / 100)
            remaining -= count
            guard count > 0 else { continue }
            let key = CallKey(
              profile: entry.profile, server: entry.server, label: tool.0, isTool: true)
            var bucket = table.calls[day]?[key] ?? Bucket()
            // Two clients, and the split mirrors the `running` fixture, where
            // Cursor is attached to `prod/shopify` alone and drives a fraction
            // of what Claude Code does. One client leaves the client card a
            // single full-width bar, which is a ranking of one.
            //
            // Split from the SAME samples rather than invented beside them:
            // `record` writes both tables from one call, so a fixture that fed
            // them separately would put two different totals for one window on
            // one screen — the live path cannot do that and neither may this.
            var byClient: [String: Bucket] = [:]
            for sample in 0..<count {
              let jitter = (sample * 37 + index * 11) % max(20, entry.latency)
              let milliseconds = broken ? 4_200 + jitter : entry.latency + jitter
              let bytes = 2_400 + (sample * 311) % 3_000
              let failed = broken && sample < 11
              bucket.record(milliseconds: milliseconds, bytes: bytes, failed: failed)
              let client = entry.profile == "prod" && sample % 4 == 3 ? "cursor" : "claude-code"
              byClient[client, default: Bucket()]
                .record(milliseconds: milliseconds, bytes: bytes, failed: failed)
            }
            table.calls[day, default: [:]][key] = bucket
            table.labels[day, default: [:]][serverKey, default: 0] += 1

            for (client, split) in byClient {
              table.clients[
                day, default: [:]][
                  ClientKey(client: client, profile: entry.profile, server: entry.server),
                  default: Bucket()
                ].merge(split)
            }
          }

          var life =
            table.life[day]?[serverKey]
            ?? CallStatsRollup.LifeRow(profile: entry.profile, server: entry.server)
          life.starts += 1
          if broken { life.restarts += 2 }
          // The write gate hides tools when writes are OFF, so the saving
          // belongs to `home` and not to `lab`, whose gate is open. Nothing here
          // saves anything through the facade, because the capture pins
          // `lazyToolsDefault` to the product's own default of off and no
          // fixture server overrides it — so a facade figure would contradict
          // the card above it, which says in so many words that none of these
          // load on demand yet.
          if entry.profile == "home" { life.savedByGate += 2_900 }
          table.life[day, default: [:]][serverKey] = life
        }
      }
      table.loaded = true
      table.dirty = false
    }
  }

  /// Stop recording and delete the file.
  ///
  /// Both halves, because an off switch that leaves the file behind is an off
  /// switch whose claim expires the moment somebody looks in the directory.
  func disableAndForget() {
    state.withLock { table in
      table.calls = [:]
      table.clients = [:]
      table.life = [:]
      table.labels = [:]
      table.dirty = false
    }
    writer.async { [fileURL] in try? FileManager.default.removeItem(at: fileURL) }
  }
}

// MARK: - Reading

/// Everything the panes ask for, as plain values.
///
/// Deliberately does NOT reach `ToolCostStore`. The context ranking needs both
/// this and that store, and composing them here would mean a nonisolated type
/// reading an `@Observable` one across isolation for no gain. The view already
/// holds both, so the ranking composes there — and keeping it there is also what
/// stops a second listing figure being derived from observed `tools/list`
/// traffic, which would disagree with the badge on `ProfileRow` while both were
/// correct.
extension CallStats {
  nonisolated struct Window: Sendable, Hashable {
    var days: Int
    static let today = Window(days: 1)
    static let week = Window(days: 7)
    static let month = Window(days: 30)
    static let quarter = Window(days: 90)
  }

  nonisolated enum Ranking: Sendable { case calls, responseBytes, failures, latency }

  nonisolated struct Latency: Sendable, Equatable {
    var count = 0
    var p50: Int?
    var p95: Int?
    var max: Int?
    var mean: Int?
    var p50IsFloor = false
    var p95IsFloor = false

    init() {}

    init(_ rollup: CallStatsRollup.Latency) {
      count = rollup.count
      p50 = rollup.p50
      p95 = rollup.p95
      max = rollup.max
      mean = rollup.mean
      p50IsFloor = rollup.p50IsFloor
      p95IsFloor = rollup.p95IsFloor
    }

    /// "about 240 ms" / "at least 60s", or nothing at all when nothing was
    /// measured. Never "0 ms", which reads as instantaneous.
    var p50Phrase: String? {
      p50.map { CallStatsRollup.phrase(milliseconds: $0, isFloor: p50IsFloor) }
    }

    var p95Phrase: String? {
      p95.map { CallStatsRollup.phrase(milliseconds: $0, isFloor: p95IsFloor) }
    }
  }

  nonisolated struct ServerRow: Sendable, Identifiable {
    var profile: String
    var server: String
    var id: String { "\(profile)/\(server)" }
    var calls = 0
    var failures = 0
    var responseBytes = 0
    var latency = Latency()
    var restarts = 0
    var exits = 0
    /// Measured, in this window, rather than forecast from a stored listing.
    var savedByGate = 0
    var savedByFacade = 0

    /// Zero when nothing was called, never a NaN.
    var failureRate: Double { calls > 0 ? Double(failures) / Double(calls) : 0 }
  }

  nonisolated struct ToolRow: Sendable, Identifiable {
    var profile: String
    var server: String
    /// A tool name, or a method name when `isTool` is false.
    var label: String
    var isTool: Bool
    var id: String { "\(profile)/\(server)/\(isTool ? "t" : "m"):\(label)" }
    var calls = 0
    var failures = 0
    var responseBytes = 0
    var latency = Latency()
  }

  nonisolated struct Point: Sendable, Identifiable {
    var day: DayNumber
    var id: DayNumber { day }
    /// Local midnight, which is what a chart plots against.
    var date: Date
    var calls = 0
    var failures = 0
    var responseBytes = 0
    var restarts = 0
    var latency = Latency()

    /// Calls that came back without an error, which is what a stacked bar puts
    /// under the failures.
    var succeeded: Int { Swift.max(0, calls - failures) }
  }

  nonisolated struct ClientTraffic: Sendable {
    var client: String
    var calls = 0
    var failures = 0
    var responseBytes = 0
    var latency = Latency()
    /// Distinct profiles this client has actually called in the window, which
    /// is a different number from how many it is wired to.
    var profilesCalled = 0
    var byServer: [ServerRow] = []
  }

  nonisolated struct Snapshot: Sendable {
    var window: Window
    var servers: [ServerRow] = []
    var tools: [ToolRow] = []
    var series: [Point] = []
    /// Every visible call in the window, as one distribution.
    ///
    /// Merged from the buckets rather than averaged from the per-server
    /// figures. A median of medians is not a median and a maximum of 95ths is
    /// not a 95th; both were on screen before this existed, and both were
    /// answering a question nobody asked.
    var latency = Latency()
    /// The oldest day with anything in it, or nil on a first run.
    var firstDay: DayNumber?
    /// How many days of the window actually have history behind them. When this
    /// is short of `window.days`, every total built from it is a floor and the
    /// copy says "since <date>" rather than "the last 30 days".
    var daysCovered = 0
    var includesBuiltin = false

    var calls: Int { servers.reduce(0) { $0 + $1.calls } }
    var failures: Int { servers.reduce(0) { $0 + $1.failures } }
    var responseBytes: Int { servers.reduce(0) { $0 + $1.responseBytes } }
    var savedByGate: Int { servers.reduce(0) { $0 + $1.savedByGate } }
    var savedByFacade: Int { servers.reduce(0) { $0 + $1.savedByFacade } }
    var isEmpty: Bool { calls == 0 && savedByGate == 0 && savedByFacade == 0 }
    /// True when the window reaches further back than the history does, so the
    /// totals are floors.
    var isPartialWindow: Bool { daysCovered < window.days }
  }

  /// Every window in one lock take, which is what the pane calls.
  func snapshot(window: Window, ranking: Ranking = .calls, includeBuiltin: Bool? = nil) -> Snapshot
  {
    let builtin = includeBuiltin ?? Self.includesBuiltin
    let offset = secondsFromGMT
    return state.withLock { table in
      let today = Self.today(&table)
      let earliest = today - DayNumber(Swift.max(1, window.days)) + 1
      let visible = { (profile: String, server: String) -> Bool in
        builtin || !Self.separatelyCounted.contains(server)
      }

      var servers: [ServerKey: ServerRow] = [:]
      var tools: [CallKey: ToolRow] = [:]
      var buckets: [ServerKey: Bucket] = [:]
      var toolBuckets: [CallKey: Bucket] = [:]
      var points: [DayNumber: (Point, Bucket)] = [:]
      var present: Set<DayNumber> = []
      var overall = Bucket()

      for (day, rows) in table.calls where day >= earliest && day <= today {
        for (key, bucket) in rows where visible(key.profile, key.server) {
          present.insert(day)
          overall.merge(bucket)
          let serverKey = ServerKey(profile: key.profile, server: key.server)
          var row =
            servers[serverKey] ?? ServerRow(profile: key.profile, server: key.server)
          row.calls += bucket.calls
          row.failures += bucket.failures
          row.responseBytes += bucket.bytes
          servers[serverKey] = row
          buckets[serverKey, default: Bucket()].merge(bucket)

          var tool =
            tools[key]
            ?? ToolRow(
              profile: key.profile, server: key.server, label: key.label, isTool: key.isTool)
          tool.calls += bucket.calls
          tool.failures += bucket.failures
          tool.responseBytes += bucket.bytes
          tools[key] = tool
          toolBuckets[key, default: Bucket()].merge(bucket)

          var point =
            points[day]?.0
            ?? Point(day: day, date: CallStatsRollup.startOfDay(day, secondsFromGMT: offset))
          point.calls += bucket.calls
          point.failures += bucket.failures
          point.responseBytes += bucket.bytes
          var pointBucket = points[day]?.1 ?? Bucket()
          pointBucket.merge(bucket)
          points[day] = (point, pointBucket)
        }
      }

      for (day, rows) in table.life where day >= earliest && day <= today {
        for (key, row) in rows where visible(key.profile, key.server) {
          if row.restarts > 0 || row.exits > 0 || row.savedByGate > 0 || row.savedByFacade > 0 {
            present.insert(day)
          }
          var server = servers[key] ?? ServerRow(profile: key.profile, server: key.server)
          server.restarts += row.restarts
          server.exits += row.exits
          server.savedByGate += row.savedByGate
          server.savedByFacade += row.savedByFacade
          servers[key] = server

          var point =
            points[day]?.0
            ?? Point(day: day, date: CallStatsRollup.startOfDay(day, secondsFromGMT: offset))
          point.restarts += row.restarts
          points[day] = (point, points[day]?.1 ?? Bucket())
        }
      }

      for (key, bucket) in buckets { servers[key]?.latency = Latency(bucket.latency) }
      for (key, bucket) in toolBuckets { tools[key]?.latency = Latency(bucket.latency) }

      let firstDay = present.min()
      // One point per day from the first day with history to today, empty days
      // included and nothing before it. That is what stops a chart drawing a
      // flat line back to the epoch on day two.
      let start = Swift.max(earliest, firstDay ?? today)
      let series: [Point] =
        start > today
        ? []
        : (start...today).map { day in
          guard var point = points[day]?.0 else {
            return Point(day: day, date: CallStatsRollup.startOfDay(day, secondsFromGMT: offset))
          }
          point.latency = Latency(points[day]?.1.latency ?? .none)
          return point
        }

      return Snapshot(
        window: window,
        servers: Self.rank(Array(servers.values), by: ranking),
        tools: Self.rank(Array(tools.values), by: ranking),
        series: series,
        latency: Latency(overall.latency),
        firstDay: firstDay,
        daysCovered: firstDay.map { Int(today - Swift.max(earliest, $0)) + 1 } ?? 0,
        includesBuiltin: builtin)
    }
  }

  func servers(window: Window, rankedBy ranking: Ranking = .calls, includeBuiltin: Bool? = nil)
    -> [ServerRow]
  {
    snapshot(window: window, ranking: ranking, includeBuiltin: includeBuiltin).servers
  }

  func series(window: Window) -> [Point] { snapshot(window: window).series }

  /// One server's own series, for the card on `ServerDetail`.
  func series(profile: String, server: String, window: Window) -> [Point] {
    filteredSeries(profile: profile, server: server, window: window)
  }

  func tools(
    window: Window, profile: String? = nil, server: String? = nil, limit: Int = 10,
    rankedBy ranking: Ranking = .calls
  ) -> [ToolRow] {
    let rows = snapshot(window: window, ranking: ranking, includeBuiltin: server != nil).tools
      .filter { row in
        (profile == nil || row.profile == profile) && (server == nil || row.server == server)
      }
    return Array(rows.prefix(limit))
  }

  /// What one client has actually pulled through, which is a measurement and a
  /// different fact from what `ClientDetail.contextBill` forecasts.
  func traffic(forClient client: String, window: Window, includeBuiltin: Bool? = nil)
    -> ClientTraffic
  {
    // The same exclusion `snapshot` applies, and it has to be the same or the
    // statistics pane puts two totals for one window on one screen: the calls
    // card counting everything but Bastion's own server, and the client card
    // under it counting that too.
    let builtin = includeBuiltin ?? Self.includesBuiltin
    return state.withLock { table in
      let today = Self.today(&table)
      let earliest = today - DayNumber(Swift.max(1, window.days)) + 1
      var traffic = ClientTraffic(client: client)
      var servers: [ServerKey: ServerRow] = [:]
      var buckets: [ServerKey: Bucket] = [:]
      var total = Bucket()
      for (day, rows) in table.clients where day >= earliest && day <= today {
        for (key, bucket) in rows
        where key.client == client
          && (builtin || !Self.separatelyCounted.contains(key.server))
        {
          let serverKey = ServerKey(profile: key.profile, server: key.server)
          var row = servers[serverKey] ?? ServerRow(profile: key.profile, server: key.server)
          row.calls += bucket.calls
          row.failures += bucket.failures
          row.responseBytes += bucket.bytes
          servers[serverKey] = row
          buckets[serverKey, default: Bucket()].merge(bucket)
          total.merge(bucket)
        }
      }
      for (key, bucket) in buckets { servers[key]?.latency = Latency(bucket.latency) }
      traffic.calls = total.calls
      traffic.failures = total.failures
      traffic.responseBytes = total.bytes
      traffic.latency = Latency(total.latency)
      traffic.profilesCalled = Set(servers.keys.map(\.profile)).count
      traffic.byServer = Self.rank(Array(servers.values), by: .calls)
      return traffic
    }
  }

  /// Every client that actually called something, ranked, in one lock take.
  func clients(window: Window, includeBuiltin: Bool? = nil) -> [ClientTraffic] {
    let builtin = includeBuiltin ?? Self.includesBuiltin
    let names: Set<String> = state.withLock { table in
      let today = Self.today(&table)
      let earliest = today - DayNumber(Swift.max(1, window.days)) + 1
      var found: Set<String> = []
      for (day, rows) in table.clients where day >= earliest && day <= today {
        for key in rows.keys where builtin || !Self.separatelyCounted.contains(key.server) {
          found.insert(key.client)
        }
      }
      return found
    }
    // A client whose only traffic was to Bastion's own server drops out here
    // rather than appearing with a zero, which would read as "it called nothing"
    // instead of "what it called is not in this view".
    return names.map { traffic(forClient: $0, window: window, includeBuiltin: builtin) }
      .filter { $0.calls > 0 }
      .sorted { ($0.calls, $0.client) > ($1.calls, $1.client) }
  }

  private func filteredSeries(profile: String, server: String, window: Window) -> [Point] {
    let offset = secondsFromGMT
    return state.withLock { table in
      let today = Self.today(&table)
      let earliest = today - DayNumber(Swift.max(1, window.days)) + 1
      var points: [DayNumber: (Point, Bucket)] = [:]
      var present: Set<DayNumber> = []
      for (day, rows) in table.calls where day >= earliest && day <= today {
        for (key, bucket) in rows where key.profile == profile && key.server == server {
          present.insert(day)
          var point =
            points[day]?.0
            ?? Point(day: day, date: CallStatsRollup.startOfDay(day, secondsFromGMT: offset))
          point.calls += bucket.calls
          point.failures += bucket.failures
          point.responseBytes += bucket.bytes
          var merged = points[day]?.1 ?? Bucket()
          merged.merge(bucket)
          points[day] = (point, merged)
        }
      }
      for (day, rows) in table.life where day >= earliest && day <= today {
        guard let row = rows[ServerKey(profile: profile, server: server)] else { continue }
        if row.restarts > 0 { present.insert(day) }
        var point =
          points[day]?.0
          ?? Point(day: day, date: CallStatsRollup.startOfDay(day, secondsFromGMT: offset))
        point.restarts += row.restarts
        points[day] = (point, points[day]?.1 ?? Bucket())
      }
      guard let first = present.min() else { return [] }
      return (first...today).map { day in
        guard var point = points[day]?.0 else {
          return Point(day: day, date: CallStatsRollup.startOfDay(day, secondsFromGMT: offset))
        }
        point.latency = Latency(points[day]?.1.latency ?? .none)
        return point
      }
    }
  }

  nonisolated private static func rank(_ rows: [ServerRow], by ranking: Ranking) -> [ServerRow] {
    switch ranking {
    case .calls: rows.sorted { ($0.calls, $0.id) > ($1.calls, $1.id) }
    case .responseBytes: rows.sorted { ($0.responseBytes, $0.id) > ($1.responseBytes, $1.id) }
    case .failures: rows.sorted { ($0.failures, $0.id) > ($1.failures, $1.id) }
    case .latency: rows.sorted { ($0.latency.p95 ?? 0, $0.id) > ($1.latency.p95 ?? 0, $1.id) }
    }
  }

  nonisolated private static func rank(_ rows: [ToolRow], by ranking: Ranking) -> [ToolRow] {
    switch ranking {
    case .calls: rows.sorted { ($0.calls, $0.id) > ($1.calls, $1.id) }
    case .responseBytes: rows.sorted { ($0.responseBytes, $0.id) > ($1.responseBytes, $1.id) }
    case .failures: rows.sorted { ($0.failures, $0.id) > ($1.failures, $1.id) }
    case .latency: rows.sorted { ($0.latency.p95 ?? 0, $0.id) > ($1.latency.p95 ?? 0, $1.id) }
    }
  }
}
