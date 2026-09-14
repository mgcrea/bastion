import SwiftUI

/// Which window the counts are read over.
///
/// Three, and no "All". "All" is a promise about retention the view cannot
/// keep — history is capped by days and by bytes — so it would silently mean
/// something different next month.
enum StatsRange: String, CaseIterable, Sendable {
  case week, month, quarter

  static let defaultsKey = "statsRange"

  var days: Int {
    switch self {
    case .week: 7
    case .month: 30
    case .quarter: 90
    }
  }

  var label: String { "\(days) days" }

  /// The clause every sentence on this pane uses, so no copy hardcodes a number
  /// the picker can change underneath it.
  var phrase: String { "the last \(days) days" }

  /// Days between axis labels, so ninety days does not print ninety of them.
  var stride: Int {
    switch self {
    case .week: 1
    case .month: 7
    case .quarter: 14
    }
  }

  var window: CallStats.Window { CallStats.Window(days: days) }
}

/// What every connect costs, and what happened after.
///
/// **Two groups, with the control between them rather than in the header.** The
/// context bill is a standing property of a tool list: it is true on every
/// connect whether or not anybody called anything, so a time range over it would
/// be meaningless. Everything below the picker is an event count and means
/// nothing without one. A single picker in the pane header would appear to
/// govern the card it does not touch.
///
/// The first screenful is the context ranking and the per-client bill, which is
/// deliberate: those are the two facts nothing else in the app can state, and
/// the time series is the less distinctive half.
struct StatsPane: View {
  /// Survives the pane, which is one arm of a switch in `MainWindow` and is
  /// destroyed on every selection change. `@AppStorage` for the reason
  /// `MainPane.defaultsKey` is — a `@State` copy would reset the range on every
  /// trip to the Log, and this is a preference rather than a gesture.
  ///
  /// Shared with the card on `ServerDetail`, so changing it in one place changes
  /// it in both and there is one truth about what "the last 30 days" means.
  @AppStorage(StatsRange.defaultsKey) private var stored = StatsRange.month.rawValue

  /// A chart selection deliberately does NOT live here. It should die on
  /// navigation: a highlighted day that survived a trip to the Log would be
  /// pointing at a bar the reader can no longer see.
  @State private var snapshot: CallStats.Snapshot?

  /// The stage decides under a capture, exactly as `MainView.current` does and
  /// for the same reason: `@AppStorage` reads the developer's real preference
  /// domain, so an unpinned range photographs whatever they last clicked.
  private var range: StatsRange {
    if DemoSeed.isEnabled { return DemoSeed.statsRange }
    return StatsRange(rawValue: stored) ?? .month
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        contextCard
        overTimeHeader
        if let snapshot, !snapshot.isEmpty {
          // First under the picker, because it is the measured answer to the
          // forecast above it — and it is under the picker rather than beside
          // that forecast because it covers a window, and the card above it
          // covers none.
          if let saved = measuredSavings() {
            Card(title: "Kept out of context") {
              Text(saved)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          callsCard(snapshot)
          clientsCard
          toolsCard(snapshot)
          latencyCard(snapshot)
          reliabilityCard(snapshot)
        } else {
          Card(title: "Calls") {
            Text(waitingLine)
              .font(.callout).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        footnote
      }
      .padding(16)
    }
    .accessibilityIdentifier("stats.pane")
    // The counters move while the pane is open, and nothing publishes them: the
    // authority is a lock-protected nonisolated type that no `body` may read.
    // A poll only while this is on screen, rather than a timer that runs with no
    // pane to update — and keyed on the range so changing it reads immediately
    // rather than at the next tick.
    .task(id: range) {
      refresh()
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        refresh()
      }
    }
  }

  private func refresh() {
    snapshot = CallStats.shared.snapshot(window: range.window)
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Stats").font(.title2).bold()
      Text("What each server costs a client before it asks anything, and what happened after.")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - The context bill

  private var contextCard: some View {
    let rows = ContextBill.perServer()
    let heaviest = rows.map(\.sentBytes).max() ?? 0
    let measured = rows.count
    let wired = Set(ProfileStore.shared.profiles.map(\.serverID)).count

    return Card(title: "Context on every connect") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Every client wired to a profile is sent that server's whole tool list before it can "
            + "call one tool, and holds it for the rest of the conversation. This is what each "
            + "one costs."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if rows.isEmpty {
          Text(
            "Nothing has been measured yet. A figure appears here once something lists a "
              + "profile's tools, which happens on the first connect or when you press Test."
          )
          .font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
              let profiles = ContextBill.measuredProfiles(ofServer: row.serverID)
              RankedBar(
                label: row.displayName,
                // Of the largest row, never of the total. See `RankedBar`.
                fraction: heaviest > 0 ? Double(row.sentBytes) / Double(heaviest) : 0,
                value: ToolCost.short(ToolCost.tokens(bytes: row.sentBytes)),
                caption: row.isFronted
                  ? "\(ToolFacade.names.count) tools instead of \(row.toolCount)"
                  : "\(row.toolCount) tools",
                badge: profiles > 1 ? "\(profiles) profiles wired" : nil,
                partial: row.partial,
                help: ToolCost.phrase(bytes: row.sentBytes, partial: row.partial))
            }
          }

          Divider()
          Text(scopeLine(measured: measured, wired: wired))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Text(facadeLine(rows))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          // Said once, not on every row, and said plainly. `ToolCost` exists
          // because an exact count with the wrong tokenizer reads as
          // authoritative while being no better than the ratio.
          Text(
            "Counted as bytes over four rather than with a tokenizer, so every figure here is "
              + "approximate. The context being spent belongs to whatever model your editor "
              + "runs, not to Bastion."
          )
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private func scopeLine(measured: Int, wired: Int) -> String {
    let scope =
      measured == wired
      ? "Measured for all \(measured) server\(measured == 1 ? "" : "s") you have wired."
      : "Measured for \(measured) of \(wired) servers you have wired."
    // The non-obvious half of the feature, and worth saying: a server nobody
    // calls still costs this much, every time something connects to it.
    return scope + " A server nobody has listed yet is not in this ranking, and one nobody calls "
      + "still costs what it says here."
  }

  /// What the write gate and the facade actually kept out, in this window.
  ///
  /// Every other figure on this card is a forecast from a stored listing. This
  /// one is the difference between two buffers that both existed, counted as
  /// they passed, which is why it is worth a line of its own and why it names
  /// the window it covers.
  private func measuredSavings() -> String? {
    guard let snapshot else { return nil }
    let gate = snapshot.savedByGate
    let facade = snapshot.savedByFacade
    guard gate + facade > 0 else { return nil }
    let clause: String
    switch (gate > 0, facade > 0) {
    case (true, true):
      clause =
        "the write gate and loading on demand together kept about "
        + "\(ToolCost.short(ToolCost.tokens(bytes: gate + facade))) tokens"
    case (true, false):
      clause =
        "the write gate kept about \(ToolCost.short(ToolCost.tokens(bytes: gate))) tokens"
    default:
      clause =
        "loading on demand kept about \(ToolCost.short(ToolCost.tokens(bytes: facade))) tokens"
    }
    return
      "Over \(windowClause(snapshot)), \(clause) out of client contexts. Measured as it passed, "
      + "rather than worked out from a stored listing."
  }

  private func facadeLine(_ rows: [ContextBill.Row]) -> String {
    let fronted = rows.filter(\.isFronted)
    guard !fronted.isEmpty else {
      return
        "None of these load their tools on demand. Turning it on for a large listing replaces "
        + "it with \(ToolFacade.names.count) Bastion tools, and the schemas are fetched when the "
        + "model reaches for one."
    }
    let saved = fronted.reduce(0) { $0 + $1.savedBytes }
    let names = fronted.map(\.displayName).sorted()
    let subject =
      names.count == 1
      ? names[0] : "\(names.count) of these"
    return
      "\(subject) load\(names.count == 1 ? "s" : "") on demand, which keeps about "
      + "\(ToolCost.short(ToolCost.tokens(bytes: saved))) tokens out of a client's context on "
      + "every connect. Everything stays reachable through Bastion's own tools."
  }

  // MARK: - What each client actually used

  /// A measurement, deliberately, where the card above it is a forecast.
  ///
  /// It began as a second context bill and was wrong twice over: it would have
  /// restated what `ClientDetail` already says better, and it could not honestly
  /// scope itself to one client's config file without re-reading every client's
  /// config on a five-second timer. What this pane can add is the other half of
  /// the sentence — not what a client is sent, but what it went on to pull
  /// through. The two are never added together.
  private var clientsCard: some View {
    let rows = CallStats.shared.clients(window: range.window)
    let heaviest = rows.map(\.calls).max() ?? 0
    return Card(title: "Which client did the work") {
      VStack(alignment: .leading, spacing: 8) {
        if rows.isEmpty {
          Text("No client has called anything in \(range.phrase).")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(rows, id: \.client) { row in
            RankedBar(
              label: displayName(ofClient: row.client),
              fraction: heaviest > 0 ? Double(row.calls) / Double(heaviest) : 0,
              value: "\(row.calls)",
              caption: "\(row.profilesCalled) profile\(row.profilesCalled == 1 ? "" : "s"), "
                + "about \(ToolCost.short(ToolCost.tokens(bytes: row.responseBytes))) tokens "
                + "of results",
              badge: row.failures > 0 ? "\(row.failures) failed" : nil,
              tint: row.failures > 0 ? StatTint.warn : StatTint.primary,
              help: row.latency.p95Phrase.map { "95th percentile \($0)" })
          }
          Text(
            "What each client pulled through, which is a different fact from what it is sent on "
              + "connect. The two are never added together."
          )
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  /// The client's own name where Bastion knows it, and the token identity
  /// otherwise — a client wired by hand is still traffic and still gets a row.
  private func displayName(ofClient id: String) -> String {
    ClientWiring.all.first { $0.id == id }?.displayName ?? id
  }

  // MARK: - Over time

  private var overTimeHeader: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("Over time").font(.headline)
      Spacer()
      Picker(
        "Time range",
        selection: Binding(
          get: { range.rawValue },
          // Swallowed under a capture, which must never write a defaults key.
          set: { if !DemoSeed.isEnabled { stored = $0 } })
      ) {
        ForEach(StatsRange.allCases, id: \.rawValue) { option in
          Text(option.label).tag(option.rawValue)
        }
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .fixedSize()
      .accessibilityIdentifier("stats.range")
      .accessibilityLabel("Time range")
    }
    .padding(.top, 4)
  }

  /// What the window says when the history is shorter than it.
  private func windowClause(_ snapshot: CallStats.Snapshot) -> String {
    guard snapshot.isPartialWindow, snapshot.daysCovered > 0 else { return range.phrase }
    return "the \(snapshot.daysCovered) day\(snapshot.daysCovered == 1 ? "" : "s") measured so far"
  }

  private func callsCard(_ snapshot: CallStats.Snapshot) -> some View {
    Card(title: "Calls") {
      VStack(alignment: .leading, spacing: 10) {
        MetricRow {
          Tally(value: "\(snapshot.calls)", label: "calls")
          Tally(value: "\(snapshot.failures)", label: "failed")
          // Profiles, not servers: a row here is a profile/server pair, so two
          // profiles of one server are two rows. The ranking above counts
          // servers, and labelling both "servers" put two different numbers for
          // two different things under one word on one screen.
          Tally(value: "\(snapshot.servers.count)", label: "profiles")
          Tally(value: "\(snapshot.tools.count)", label: "tools")
        }
        if snapshot.series.count > 1 {
          DayBars(days: snapshot.series, stride: range.stride)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calls per day")
            .accessibilityValue(callsSummary(snapshot))
          Text("Successful calls, with failures stacked on top.")
            .font(.caption2).foregroundStyle(.secondary)
        }
        Text(
          "Counted from the frames crossing the gateway. What a server then does over the "
            + "network or on disk is not in here."
        )
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// One string, read by the chart's accessibility value and nothing else, so
  /// the picture and the spoken version cannot disagree.
  private func callsSummary(_ snapshot: CallStats.Snapshot) -> String {
    let busiest = snapshot.series.map(\.calls).max() ?? 0
    return
      "\(snapshot.calls) calls over \(windowClause(snapshot)), \(snapshot.failures) of them "
      + "failed. Busiest day \(busiest)."
  }

  private func toolsCard(_ snapshot: CallStats.Snapshot) -> some View {
    let rows = Array(snapshot.tools.prefix(8))
    let heaviest = rows.map(\.calls).max() ?? 0
    return Card(title: "Busiest tools") {
      VStack(alignment: .leading, spacing: 8) {
        if rows.isEmpty {
          Text("No tool has been called in \(range.phrase).")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(rows) { row in
            RankedBar(
              label: row.label,
              fraction: heaviest > 0 ? Double(row.calls) / Double(heaviest) : 0,
              value: "\(row.calls)",
              caption: "\(row.profile) / \(row.server)",
              tint: row.failures > 0 ? StatTint.warn : StatTint.primary,
              help: row.failures > 0 ? "\(row.failures) failed" : nil)
          }
        }
      }
    }
  }

  private func latencyCard(_ snapshot: CallStats.Snapshot) -> some View {
    // Off the merged distribution, not off the per-server figures: a median of
    // medians is not a median, and the largest server's 95th is not the 95th.
    let median = snapshot.latency.p50
    let tail = snapshot.latency.p95
    return Card(title: "Response time") {
      VStack(alignment: .leading, spacing: 10) {
        if median == nil {
          Text("Nothing to time in \(range.phrase).")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          MetricRow {
            Tally(
              value: CallStatsRollup.duration(milliseconds: median ?? 0),
              label: snapshot.latency.p50IsFloor ? "median, at least" : "median")
            if let tail {
              Tally(
                value: CallStatsRollup.duration(milliseconds: tail),
                label: snapshot.latency.p95IsFloor ? "95th, at least" : "95th")
            }
            if let worst = snapshot.latency.max {
              Tally(value: CallStatsRollup.duration(milliseconds: worst), label: "slowest")
            }
          }
          if snapshot.series.count > 1 {
            LatencyBand(days: snapshot.series, stride: range.stride)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel("Response time per day")
              .accessibilityValue(
                "Median \(CallStatsRollup.duration(milliseconds: median ?? 0)) over "
                  + windowClause(snapshot))
            Text("The band is the median to the 95th. The line is the median.")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
        Text(
          "Measured at the gateway, from a request leaving Bastion to the reply coming back. It "
            + "includes the server's own work and anything it waited on, so it is not a measure "
            + "of Bastion."
        )
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func reliabilityCard(_ snapshot: CallStats.Snapshot) -> some View {
    let troubled = snapshot.servers.filter { $0.restarts > 0 || $0.exits > 0 }
    return Card(title: "Restarts and exits") {
      VStack(alignment: .leading, spacing: 8) {
        if troubled.isEmpty {
          Text("Nothing restarted in \(range.phrase).")
            .font(.callout).foregroundStyle(.secondary)
        } else {
          ForEach(troubled) { row in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(row.id).font(.callout)
              if row.restarts > 0 {
                Badge("restarted ×\(row.restarts)", tint: .red)
                  .accessibilityLabel("restarted \(row.restarts) times")
              }
              if row.exits > 0 {
                Badge("\(row.exits) exit\(row.exits == 1 ? "" : "s")", tint: .orange)
              }
              Spacer(minLength: 0)
            }
          }
        }
        Text(
          "Only servers Bastion starts. A remote server runs on somebody else's machine, so "
            + "there is nothing here to restart."
        )
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var waitingLine: String {
    "Nothing measured yet. Calls are counted from now on, and a day of traffic fills this in."
  }

  /// Branches on what the store actually does, the way `LogPane`'s disclaimer
  /// branches on `AuditLog.isEnabled`. A pane claiming nothing is written while
  /// a file is being written would be the one sentence on screen that is false,
  /// which is exactly what the EULA and the website were corrected for.
  private var footnote: some View {
    Text(
      CallStats.isEnabled
        ? "These counts are kept under Application Support, and only the counts: no arguments, "
          + "no results, no credentials. Settings › Activity turns it off and deletes it."
        : "Counting is off, so nothing here is being recorded or written. Settings › Activity "
          + "turns it back on."
    )
    .font(.caption2).foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }
}
