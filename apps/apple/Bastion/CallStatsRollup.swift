import Foundation

/// The arithmetic behind the usage rollup, and nothing else.
///
/// Counts only. Per day, per profile, per tool: how many calls, how many bytes
/// came back, how long they took, how many failed, how many times a server
/// restarted. No arguments, no results, no resource URIs, no ids — a URI is a
/// path and a path is content, so `resources/read` is recorded as a method and
/// never as the thing it read. That sentence is the claim the EULA, the privacy
/// page and the README all make on this file's behalf, and `make unit` holds it
/// to a size so it stays a fact rather than an intention.
///
/// Its own file with no dependency on anything in the app, so `make unit` can
/// compile it alone — the argument `ToolCost` makes, for the same reason and
/// with more force. A percentile read out of a histogram is arithmetic nobody
/// can eyeball, and a retention rule that drops the wrong day is invisible until
/// somebody opens the pane in November.
///
/// `CallStats` holds the lock, the timer and the file. Everything here is pure.
nonisolated enum CallStatsRollup {
  /// Bumped when a shape stops decoding. `CallStats` refuses a file from the
  /// future rather than overwriting it — see `decode(_:)`.
  static let version = 1

  // MARK: - Latency

  /// Upper bounds, in milliseconds, of sixteen buckets.
  ///
  /// Chosen against the real range rather than round numbers: a builtin call is
  /// sub-millisecond, a child call is tens to hundreds, a remote HTTPS call is
  /// hundreds to thousands, and `Supervisor.callTimeout` sits at the top. The
  /// last bucket is open-ended on purpose, and a percentile landing in it is
  /// reported as a floor rather than as a number nobody measured.
  ///
  /// Sixteen `Int`s serialize to about thirty-five bytes when mostly zero, which
  /// is the whole reason percentiles are stored this way instead of as samples.
  static let latencyBounds: [Int] = [
    1, 2, 5, 10, 25, 50, 100, 250, 500,
    1_000, 2_500, 5_000, 10_000, 30_000, 60_000, .max,
  ]

  /// What a percentile read off a histogram can honestly say.
  ///
  /// `nil` throughout when nothing was measured. Never zero: a p95 rendered as
  /// `0 ms` reads as "instantaneous", which is the opposite of "unmeasured", and
  /// distinguishing those two is most of the point of a latency card.
  struct Latency: Sendable, Equatable {
    var count: Int
    var p50: Int?
    var p95: Int?
    /// Stored exactly rather than read off the histogram, because the maximum is
    /// the one statistic a histogram genuinely cannot approximate and it is one
    /// of the four things this feature was asked for.
    var max: Int?
    var mean: Int?
    /// The percentile landed in the open-ended top bucket, so the figure is a
    /// lower bound and every sentence built from it says "at least".
    var p50IsFloor: Bool
    var p95IsFloor: Bool

    static let none = Latency(
      count: 0, p50: nil, p95: nil, max: nil, mean: nil, p50IsFloor: false, p95IsFloor: false)
  }

  /// One cell of the rollup: the counters that accumulate for a key on a day.
  ///
  /// Every field is a sum or a maximum, which is what makes `merge` commutative
  /// and lets `CallStats` accumulate under a plain lock with no ordering to
  /// preserve. `make unit` asserts that property directly, because the whole
  /// threading design rests on it.
  struct Bucket: Codable, Sendable, Equatable {
    var calls = 0
    var failures = 0
    var bytes = 0
    var totalMilliseconds = 0
    var maxMilliseconds = 0
    var histogram: [Int] = Array(repeating: 0, count: latencyBounds.count)

    enum CodingKeys: String, CodingKey {
      case calls = "n"
      case failures = "f"
      case bytes = "b"
      case totalMilliseconds = "ms"
      case maxMilliseconds = "mx"
      case histogram = "h"
    }

    /// A file written by a future build, or edited by hand, can carry a
    /// histogram of the wrong length. Reading it as zero-padded keeps the totals
    /// honest instead of trapping on a subscript.
    func weight(at index: Int) -> Int {
      index >= 0 && index < histogram.count ? histogram[index] : 0
    }

    mutating func record(milliseconds: Int, bytes: Int, failed: Bool) {
      calls += 1
      if failed { failures += 1 }
      self.bytes += bytes
      let clamped = Swift.max(0, milliseconds)
      totalMilliseconds += clamped
      maxMilliseconds = Swift.max(maxMilliseconds, clamped)
      let slot = CallStatsRollup.slot(forMilliseconds: clamped)
      if histogram.count < CallStatsRollup.latencyBounds.count {
        histogram += Array(
          repeating: 0, count: CallStatsRollup.latencyBounds.count - histogram.count)
      }
      histogram[slot] += 1
    }

    mutating func merge(_ other: Bucket) {
      calls += other.calls
      failures += other.failures
      bytes += other.bytes
      totalMilliseconds += other.totalMilliseconds
      maxMilliseconds = Swift.max(maxMilliseconds, other.maxMilliseconds)
      let width = Swift.max(histogram.count, other.histogram.count)
      var merged = Array(repeating: 0, count: width)
      for index in 0..<width { merged[index] = weight(at: index) + other.weight(at: index) }
      histogram = merged
    }

    func merged(with other: Bucket) -> Bucket {
      var copy = self
      copy.merge(other)
      return copy
    }

    /// The percentile, and whether it is a floor.
    ///
    /// Interpolates linearly inside the containing bucket, so a p50 sitting in
    /// the 250-500 band is not reported as a flat 500. The exception is the
    /// open-ended top bucket, where there is no upper bound to interpolate
    /// towards: that returns the bucket's lower bound flagged as a floor, and
    /// the caller says "at least".
    func percentile(_ fraction: Double) -> (milliseconds: Int, isFloor: Bool)? {
      guard calls > 0, fraction > 0, fraction <= 1 else { return nil }
      let rank = Swift.min(calls, Swift.max(1, Int((fraction * Double(calls)).rounded(.up))))
      var seen = 0
      for index in 0..<CallStatsRollup.latencyBounds.count {
        let count = weight(at: index)
        guard count > 0 else { continue }
        guard seen + count >= rank else {
          seen += count
          continue
        }
        let lower = index == 0 ? 0 : CallStatsRollup.latencyBounds[index - 1]
        let upper = CallStatsRollup.latencyBounds[index]
        if upper == Int.max { return (lower, true) }
        let position = Double(rank - seen) / Double(count)
        let span = Double(upper - lower) * position
        return (lower + Int(span.rounded()), false)
      }
      // Only reachable when the histogram disagrees with `calls`, which a
      // hand-edited file can produce. The exact maximum is still true.
      return (maxMilliseconds, false)
    }

    var latency: Latency {
      guard calls > 0 else { return .none }
      let median = percentile(0.5)
      let tail = percentile(0.95)
      return Latency(
        count: calls,
        p50: median?.milliseconds,
        p95: tail?.milliseconds,
        max: maxMilliseconds,
        mean: totalMilliseconds / calls,
        p50IsFloor: median?.isFloor ?? false,
        p95IsFloor: tail?.isFloor ?? false)
    }
  }

  /// Which bucket a duration falls in.
  static func slot(forMilliseconds milliseconds: Int) -> Int {
    for (index, bound) in latencyBounds.enumerated() where milliseconds <= bound { return index }
    return latencyBounds.count - 1
  }

  // MARK: - Saying a duration out loud

  /// "240 ms", "1.4s", "21s".
  ///
  /// Integer arithmetic rather than a formatter, for the reason `ToolCost.short`
  /// gives: one decimal place is the whole requirement, and a locale that writes
  /// "1,4s" would make the unit check a claim about the build machine rather
  /// than about the code.
  static func duration(milliseconds: Int) -> String {
    guard milliseconds >= 1_000 else { return "\(Swift.max(0, milliseconds)) ms" }
    guard milliseconds < 10_000 else { return "\((milliseconds + 500) / 1_000)s" }
    let tenths = (milliseconds + 50) / 100
    return tenths % 10 == 0 ? "\(tenths / 10)s" : "\(tenths / 10).\(tenths % 10)s"
  }

  /// The clause every caller says, so they cannot disagree about the hedge.
  ///
  /// `isFloor` is the percentile that landed in the open-ended top bucket, where
  /// "about" would be a straight lie. The shape is `ToolCost.phrase`'s, because
  /// a reader meeting both on one pane should not have to learn two hedges.
  static func phrase(milliseconds: Int, isFloor: Bool = false) -> String {
    "\(isFloor ? "at least" : "about") \(duration(milliseconds: milliseconds))"
  }

  // MARK: - Days

  /// Days since 1970-01-01 in the machine's local zone.
  typealias DayNumber = Int32

  /// The local day an instant belongs to.
  ///
  /// A fixed offset rather than `Calendar`, because this runs on the gateway's
  /// hot path and `Calendar.startOfDay` is expensive enough to notice at that
  /// rate. The offset is captured by the caller and refreshed on a time-zone
  /// change; across a DST transition the boundary moves by an hour, and every
  /// instant still lands in exactly one day.
  static func day(forSecondsSince1970 seconds: Double, secondsFromGMT: Int) -> DayNumber {
    DayNumber(((seconds + Double(secondsFromGMT)) / 86_400).rounded(.down))
  }

  static func day(for date: Date, secondsFromGMT: Int) -> DayNumber {
    day(forSecondsSince1970: date.timeIntervalSince1970, secondsFromGMT: secondsFromGMT)
  }

  /// Local midnight opening that day, which is what a chart plots against.
  static func startOfDay(_ day: DayNumber, secondsFromGMT: Int) -> Date {
    Date(timeIntervalSince1970: Double(day) * 86_400 - Double(secondsFromGMT))
  }

  // MARK: - Rows

  struct CallRow: Codable, Sendable {
    var profile: String
    var server: String
    /// A tool name, or a method name for everything that is not `tools/call`.
    var label: String
    /// Kept beside the label so a tool called `search` and a method called
    /// `search` can never merge into one row.
    var isTool: Bool
    var bucket: Bucket

    enum CodingKeys: String, CodingKey {
      case profile = "p"
      case server = "s"
      case label = "l"
      case isTool = "t"
      case bucket = "k"
    }
  }

  /// Traffic per client, without the tool dimension.
  ///
  /// A separate table rather than a fourth key on `CallRow`, because adding the
  /// client there multiplies the fine table by the number of clients, and the
  /// question `ClientDetail` actually asks is how much traffic a client drives —
  /// not which tool it reached for.
  struct ClientRow: Codable, Sendable {
    var client: String
    var profile: String
    var server: String
    var bucket: Bucket

    enum CodingKeys: String, CodingKey {
      case client = "c"
      case profile = "p"
      case server = "s"
      case bucket = "k"
    }
  }

  /// Reliability, and what the write gate and the facade kept out of a context.
  struct LifeRow: Codable, Sendable {
    var profile: String
    var server: String
    var starts = 0
    var restarts = 0
    var exits = 0
    /// Bytes the write gate removed from a `tools/list`, measured.
    var savedByGate = 0
    /// Bytes the facade removed from a `tools/list`, measured.
    var savedByFacade = 0

    enum CodingKeys: String, CodingKey {
      case profile = "p"
      case server = "s"
      case starts = "st"
      case restarts = "rs"
      case exits = "ex"
      case savedByGate = "gate"
      case savedByFacade = "fac"
    }

    mutating func merge(_ other: LifeRow) {
      starts += other.starts
      restarts += other.restarts
      exits += other.exits
      savedByGate += other.savedByGate
      savedByFacade += other.savedByFacade
    }
  }

  struct Day: Codable, Sendable {
    var day: DayNumber
    var rows: [CallRow] = []
    var clients: [ClientRow] = []
    var life: [LifeRow] = []

    enum CodingKeys: String, CodingKey {
      case day = "d"
      case rows
      case clients = "c"
      case life = "l"
    }
  }

  struct File: Codable, Sendable {
    var version: Int = CallStatsRollup.version
    var days: [Day] = []

    enum CodingKeys: String, CodingKey {
      case version = "v"
      case days = "d"
    }
  }

  // MARK: - The cardinality guard

  /// How many distinct labels one server may mint in one day.
  static let maxLabelsPerServer = 200

  /// Where everything past the cap goes.
  static let otherLabel = "…other"

  /// The label to record, given how many this server has already used today.
  ///
  /// Without a cap, a server with generated tool names — or a client hammering
  /// `resources/read` — grows the file without bound, and "a few kilobytes a
  /// day" stops being true silently. Totals stay exact because the overflow is
  /// still counted; only the breakdown truncates, which is a declared
  /// truncation rather than a partial one.
  static func label(_ requested: String, existingLabels: Int) -> String {
    existingLabels >= maxLabelsPerServer ? otherLabel : requested
  }

  // MARK: - Retention

  /// How long a day is kept, unless the ceiling takes it first.
  static let defaultMaxDays = 90

  /// The hard ceiling, and the number the privacy claim is written against.
  ///
  /// Sized by measurement rather than by feel: `make unit` encodes ninety days
  /// of a deliberately busy machine — five servers, thirty distinct tools called
  /// on each of them every single day — and that comes to just under two
  /// megabytes. Four leaves the ninety-day promise intact for a population
  /// nobody realistically exceeds, which is what makes the ceiling a guard
  /// against pathological cardinality rather than something an ordinary busy
  /// user quietly runs into.
  static let defaultMaxBytes = 4 * 1_024 * 1_024

  /// What survives, oldest dropped first.
  ///
  /// Two bounds for the reason `LogStore` has two: the day count stopped being a
  /// bound once one day could hold hundreds of rows. Whole days are dropped and
  /// never trimmed, which is `AuditLog.prune`'s shape and the same argument —
  /// a truncation a reader can see beats a total that quietly stopped being one.
  static func prune(_ days: [Day], today: DayNumber, maxDays: Int, maxBytes: Int) -> [Day] {
    let oldest = today - DayNumber(Swift.max(1, maxDays)) + 1
    var kept = days.filter { $0.day >= oldest && $0.day <= today }.sorted { $0.day < $1.day }
    guard maxBytes > 0 else { return kept }
    while kept.count > 1, encodedSize(of: kept) > maxBytes {
      kept.removeFirst()
    }
    return kept
  }

  /// What these days occupy on disk, in the encoding `CallStats` writes.
  static func encodedSize(of days: [Day]) -> Int {
    (try? encoder().encode(File(days: days)).count) ?? 0
  }

  // MARK: - The file

  /// Compact, not pretty.
  ///
  /// This file is machine-read and is measured in kilobytes a day. Pretty
  /// printing roughly doubles it for no reader, which is the opposite trade
  /// `ToolCostStore` makes, and for the opposite reason: that one is small and
  /// gets opened by hand.
  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  /// What came back off disk.
  enum Outcome: Sendable {
    case loaded(File)
    /// Written by a newer build. Nothing is loaded and nothing may be written:
    /// a Sparkle rollback must not silently truncate a history it cannot read.
    /// This deliberately diverges from `ToolCostStore`, which just resets — a
    /// cache that regenerates in seconds can afford that, and this cannot.
    case refused(version: Int)
    /// Unreadable. The caller renames it aside rather than deleting it, so
    /// "my stats vanished" becomes a file somebody can hand over.
    case corrupt
  }

  static func decode(_ data: Data) -> Outcome {
    guard let file = try? JSONDecoder().decode(File.self, from: data) else { return .corrupt }
    guard file.version <= version else { return .refused(version: file.version) }
    return .loaded(file)
  }
}
