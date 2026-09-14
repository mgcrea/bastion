import AppKit
import SwiftUI

/// The two Activity panes, and the small pieces the rest of the window shares.
///
/// This was the Activity window: a header, a running list capped at 200pt, and
/// a feed, stacked in one column because there was nowhere else for any of them
/// to go. The header is now the sidebar footer — it was never about one pane —
/// and the other two are destinations, which is what removes the cap.
///
/// The limit of the claim stays on screen rather than only in the docs: Bastion
/// sees the JSON-RPC frames crossing the gateway and nothing a server then does
/// over the network or on disk.

// MARK: - Running

struct RunningPane: View {
  var body: some View {
    let instances = Activity.shared.instances

    VStack(alignment: .leading, spacing: 0) {
      Text("Running")
        .font(.title2).bold()
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

      if instances.isEmpty {
        ContentUnavailableView {
          Label("Nothing running", systemImage: "moon.zzz")
        } description: {
          Text("A server starts on the first request that needs it.")
        }
      } else {
        List(instances) { instance in
          InstanceRow(instance: instance)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct InstanceRow: View {
  let instance: Activity.Instance

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Circle()
        .fill(instance.isLive ? Color.green : Color.secondary)
        .frame(width: 7, height: 7)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(instance.displayName).font(.system(.body, design: .monospaced)).bold()
          if instance.allowWrites {
            // Loud on purpose. This is the switch that lets a tool call place a
            // brokerage order, and it is set per profile — so the row has to
            // say which profile has it on, not merely that the feature exists.
            Badge("writes", tint: .orange)
          }
          if let dialect = instance.dialect { Badge(dialect, tint: .secondary) }
          if instance.restarts > 0 {
            Badge("restarted ×\(instance.restarts)", tint: .red)
          }
        }
        // A clock, so it has to be driven by one. Without this the uptime is
        // whatever it was when the row was last built for some other reason —
        // which, for a window nobody is interacting with, is "up 0s" forever.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 3) {
        Text("\(instance.calls)").font(.system(.body, design: .rounded)).monospacedDigit()
        Text(instance.calls == 1 ? "call" : "calls").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var subtitle: String {
    guard instance.isLive else {
      return instance.lastExit.map { "stopped — \($0)" } ?? "stopped"
    }
    // A remote server has no pid to show, and the host is the fact that
    // belongs in its place: it is what the credential is being sent to.
    var parts = [instance.pid.map { "pid \($0)" } ?? instance.remoteHost ?? "in-process", uptime]
    if instance.clients.isEmpty {
      parts.append("no client yet")
    } else {
      // The token identity first, because that is the authenticated one; the
      // self-reported `clientInfo` name in parentheses, because the interesting
      // case is when the two disagree.
      parts.append(
        instance.clients
          .map { client in
            let reported = client.reportedName.map { " (\($0))" } ?? ""
            return "\(client.id)\(reported) ×\(client.calls)"
          }
          .joined(separator: ", "))
    }
    return parts.joined(separator: " · ")
  }

  private var uptime: String {
    let seconds = Int(Date().timeIntervalSince(instance.startedAt))
    if seconds < 60 { return "up \(seconds)s" }
    if seconds < 3600 { return "up \(seconds / 60)m" }
    return "up \(seconds / 3600)h \((seconds % 3600) / 60)m"
  }
}

// MARK: - Log

struct LogPane: View {
  @State private var callsOnly = false
  @State private var following = true
  @State private var exported: String?
  @State private var query = ""

  private var entries: [LogStore.Entry] {
    let all = LogStore.shared.entries
    let byLevel = callsOnly ? all.filter { $0.level == .call } : all
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return byLevel }
    return byLevel.filter { $0.matches(needle) }
  }

  var body: some View {
    let shown = entries

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Text("Log").font(.title2).bold()

        // Over the payloads too, not just the tool name — "which call touched
        // order 992" is the question a log this size is opened for, and the
        // answer is in the arguments.
        HStack(spacing: 4) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.tertiary)
            .font(.caption)
          TextField("Search", text: $query)
            .textFieldStyle(.plain)
            .frame(minWidth: 90, idealWidth: 150)
          if !query.isEmpty {
            Button {
              query = ""
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Clear the search")
          }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 6))
        .frame(maxWidth: 220)

        Spacer()
        Toggle("Tool calls only", isOn: $callsOnly)
          .toggleStyle(.checkbox)
        Spacer()
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
          Text("\(shown.count) of \(LogStore.shared.entries.count)")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(shown.map(line).joined(separator: "\n"), forType: .string)
        }
        .disabled(shown.isEmpty)
        .help("Copy what is shown — the search and the filter both narrow it.")
        Button("Clear") { LogStore.shared.clear() }
          .disabled(LogStore.shared.entries.isEmpty)
        // The same panel the settings pane opens, not a route to it: a button
        // labelled "Export…" that produced a settings window was a button that
        // lied. `AuditExport` is the one copy of it.
        Button("Export…") { exported = AuditExport.run()?.note }
          .disabled(!AuditLog.isEnabled)
          .help(
            AuditLog.isEnabled ? "Save the audit log and its manifest." : AuditExport.unavailable)
      }
      .controlSize(.small)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      // Oldest first with the tail followed, rather than the reversed list this
      // used to be. A feed in a window this size shows enough rows that the
      // newest-first trick stops paying for itself, and reading a conversation
      // backwards is what it costs.
      //
      // A `List`, and not a `ScrollView` + `LazyVStack`. The stack was tried
      // and breaks the whole window: a log line is arbitrarily long, so the
      // stack's ideal width is the longest line's, a `ScrollView` propagates
      // that up as the detail column's width, and `NavigationSplitView` then
      // lays out against a width nothing on screen can satisfy — the sidebar
      // loses every row but the selected one and the footer disappears. A List
      // takes the width it is given and scrolls its rows inside it, which is
      // the behaviour this needs and the reason the original window used one.
      ScrollViewReader { proxy in
        List {
          ForEach(shown) { entry in
            FeedRow(entry: entry, highlight: query.trimmingCharacters(in: .whitespaces))
              .id(entry.id)
              .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
              .listRowSeparator(.hidden)
          }
          // An empty anchor, so following the tail does not depend on the last
          // entry still passing the filter.
          Color.clear
            .frame(height: 1)
            .id(Self.tailAnchor)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        // Take the space available, never the space wanted. A `List` in a
        // `VStack` reports an ideal height built from its rows, and the feed
        // holds up to 2000 of them — so the detail column adopted that height,
        // `NavigationSplitView` laid out both columns against it, and the
        // window showed the top-left corner of something several screens tall:
        // a sidebar scrolled to its selection with no footer, and a detail pane
        // whose content began below the bottom of the window. Flexing here is
        // what keeps the split view sized to the window instead.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .textSelection(.enabled)
        .onChange(of: LogStore.shared.entries.count) {
          guard following else { return }
          withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.tailAnchor, anchor: .bottom) }
        }
        .overlay(alignment: .center) {
          if shown.isEmpty {
            Text(emptyReason)
              .foregroundStyle(.secondary)
          }
        }
        // `safeAreaInset`, not another row in the enclosing `VStack`.
        //
        // As a sibling in the stack this footer broke the entire window. Its
        // long sentence wants `fixedSize(vertical:)` so that it wraps rather
        // than truncates, and a wrapping `Text` in an `HStack` still reports the
        // whole sentence as its *ideal* width — which the detail column adopts,
        // and `NavigationSplitView` then lays both columns out against a width
        // no window here can satisfy. What that looked like: a sidebar scrolled
        // to its selected row with every other row and the sidebar footer gone,
        // and a detail pane drawing nothing at all. Capping the text's width was
        // tried and was not enough; the stack still consulted the ideal.
        //
        // An inset is laid out against a size that has already been decided, so
        // it cannot feed back into it. The sidebar's own footer is attached this
        // way for the same reason.
        .safeAreaInset(edge: .bottom, spacing: 0) { disclaimer }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// The limit of the claim, and the Follow switch.
  ///
  /// The sentence is on its own line with no `fixedSize`, and both halves of
  /// that are load-bearing.
  ///
  /// `fixedSize(horizontal: false, vertical: true)` is the usual way to stop a
  /// caption being truncated, and here it broke the entire window: it makes the
  /// text answer "how tall are you?" only after being told a width, and in a
  /// `NavigationSplitView` detail column that width is not settled yet. The
  /// layout resolved against the unwrapped sentence instead — and the result
  /// was not a wide window but a broken one: a sidebar scrolled to its selected
  /// row with every other row and the sidebar footer gone, and a detail pane
  /// that drew nothing at all.
  ///
  /// Bisected to this one string: swapping it for a short one fixed it
  /// outright. `.frame(maxWidth:)`, `.frame(idealWidth:)` and moving the whole
  /// footer into a `safeAreaInset` were each tried and each still broke, so the
  /// cap is not the answer — not asking the question is.
  ///
  /// In a `VStack` with no `fixedSize` the width arrives first and the text
  /// simply wraps into it, which is all this ever needed.
  private var disclaimer: some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      HStack(alignment: .firstTextBaseline) {
        // Load-bearing, not decoration. Keeping this sentence true is a
        // constraint on anything ever added to the feed — including the
        // payloads, which is why it says where they stop rather than dropping
        // the claim now that there are some.
        // Conditional now, because the answer to "does any of this outlive the
        // app" is a setting. A footer that says "nothing is written to disk"
        // while an audit log is running would be the one sentence on screen
        // that is false.
        // Narrowed to arguments and results once `CallStats` began keeping a
        // usage rollup on disk by default. The unqualified sentence was about
        // this feed and was read as being about the app, which is the same
        // drift the website and the EULA were corrected for.
        Text(
          "Bastion records the JSON-RPC frames crossing the gateway — which profile, which tool, "
            + "and what it was called with. Credentials are never recorded. "
            + (AuditLog.isEnabled
              ? "An audit log is being kept on disk — see Settings › Activity. "
              : "No arguments or results are written to disk. ")
            + "It does not see what a server then does over the network or on disk."
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
        Spacer(minLength: 12)
        // What the export did, where the export happened. A result reported in
        // a window the user is no longer looking at is a result nobody reads.
        if let exported {
          Text(exported)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(exported)
        }
        Toggle("Follow", isOn: $following)
          .toggleStyle(.checkbox)
          .font(.caption)
          .fixedSize()
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 8)
    }
    .background(.bar)
  }

  /// Why the feed is empty, which is three different facts.
  ///
  /// "Nothing matches this filter" in front of a log that has never had a line
  /// in it sends someone looking for a filter to clear.
  private var emptyReason: String {
    if LogStore.shared.entries.isEmpty { return "Nothing yet." }
    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
      return "Nothing matches \u{201C}\(query)\u{201D}."
    }
    return "Nothing matches this filter."
  }

  private static let tailAnchor = "activity-tail"

  private func line(_ entry: LogStore.Entry) -> String {
    var out =
      "\(Self.clock.string(from: entry.at))  \(entry.origin)  \(entry.level.rawValue)  \(entry.text)"
    if let arguments = entry.arguments { out += "\n    args   \(arguments)" }
    if let result = entry.result { out += "\n    result \(result)" }
    return out
  }

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}

struct FeedRow: View {
  let entry: LogStore.Entry
  /// The active search, so a row can open itself when the reason it matched is
  /// past the preview. Empty when nothing is being searched for.
  var highlight: String = ""
  @State private var expanded = false

  /// How much of a payload shows before the row has been opened.
  static let preview = 160

  /// Open either because the reader asked, or because the match is out of
  /// sight and a row listed for no visible reason reads as a bug.
  private var isOpen: Bool {
    expanded || entry.matchIsHidden(highlight, preview: Self.preview)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(entry.at, format: .dateTime.hour().minute().second())
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.tertiary)
        Circle().fill(tint).frame(width: 6, height: 6)
        Text(entry.origin)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(width: 130, alignment: .leading)
        Text(entry.text)
          .font(.system(.caption, design: entry.level == .call ? .monospaced : .default))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if entry.failed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2).foregroundStyle(.red)
        }
        Spacer(minLength: 0)
      }
      // No `fixedSize(horizontal:vertical:)` anywhere below, deliberately —
      // see the comment on `disclaimer`. A payload is the longest text this
      // window has ever held and it is exactly the shape that broke the split
      // view's layout before.
      if let arguments = entry.arguments {
        payload("args", arguments, tint: .secondary)
      }
      if let result = entry.result {
        payload("result", result, tint: entry.failed ? .red : .secondary)
      }
      if longest > Self.preview {
        Button(isOpen ? "Show less" : "Show all \(longest) characters") { expanded.toggle() }
          .buttonStyle(.link).font(.caption2)
          .padding(.leading, 152)
      }
    }
  }

  private var longest: Int {
    max(entry.arguments?.count ?? 0, entry.result?.count ?? 0)
  }

  private func payload(_ label: String, _ text: String, tint: Color) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(label)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: 144, alignment: .trailing)
      Text(isOpen ? text : String(text.prefix(Self.preview)))
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(tint)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var tint: Color {
    switch entry.level {
    case .call: .accentColor
    case .error: .red
    case .info: .secondary.opacity(0.5)
    }
  }
}

// MARK: - Shared pieces

/// A number and what it counts. Used by the sidebar footer, which is the only
/// place in the app that reports on everything at once.
struct Tally: View {
  let value: String
  let label: String

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(value).font(.system(.callout, design: .rounded)).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
  }
}

/// A line of `Tally`s, so the panes that report several numbers at once agree
/// about the gap between them.
///
/// The sidebar footer drew exactly this by hand for as long as it was the only
/// caller. There are three now, and hand-rolling it again is how they end up
/// with three different spacings — the argument `Card` already makes one level
/// up.
struct MetricRow<Content: View>: View {
  @ViewBuilder let content: () -> Content

  var body: some View {
    // Ten, because that is what the sidebar footer already used and the footer
    // is the established look. Picking a new number here would have moved the
    // one caller that exists in a shipped screenshot, to settle nothing.
    HStack(spacing: 10) {
      content()
      Spacer(minLength: 0)
    }
  }
}

/// One row of a ranking: a name, a proportional rule, and the figure.
///
/// **The fraction is of the largest row, never of the total.** This ranks; it
/// does not divide a whole. A bar drawn as a share of the sum would be a claim
/// about the size of a context window, and the size of a context window is a
/// number Bastion cannot see — it belongs to whatever model the editor runs.
///
/// Drawn with shapes rather than with Swift Charts, deliberately. A ranked list
/// is a table with a rule in each row: it needs a label column, a right-aligned
/// figure, a badge slot, a partial marker and per-row help, and a chart fights
/// every one of those. The time series in `StatsCharts` is the case that is
/// genuinely a chart.
struct RankedBar: View {
  let label: String
  /// Of the largest row. Clamped, so a caller that divides by zero draws
  /// nothing rather than a bar of infinite width.
  let fraction: Double
  let value: String
  var caption: String? = nil
  var badge: String? = nil
  var tint: Color = .accentColor
  /// The listing was read one page at a time, so the figure is a floor. The bar
  /// fades out instead of ending, and the figure takes the `+` that
  /// `ProfileRow.cost` already puts on a partial badge.
  var partial: Bool = false
  /// The hedged sentence, for the tooltip. A capture never photographs it,
  /// which is also why nothing load-bearing may live only here.
  var help: String? = nil

  private var width: Double { min(1, max(0, fraction.isFinite ? fraction : 0)) }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(label).font(.callout)
        if let badge { Badge(badge, tint: .secondary) }
        Spacer(minLength: 8)
        Text(partial ? "\(value)+" : value)
          .font(.system(.callout, design: .rounded)).monospacedDigit()
      }
      // A GeometryReader is the safe primitive here: it takes the width it is
      // proposed and reports nothing back up, which is more than can be said
      // for a Text. See the note in `LogPane` about what a view with a large
      // ideal width does to a NavigationSplitView.
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(.quaternary.opacity(0.5))
          Capsule()
            .fill(
              partial
                ? AnyShapeStyle(
                  LinearGradient(
                    stops: [
                      .init(color: tint, location: 0),
                      .init(color: tint, location: 0.8),
                      .init(color: tint.opacity(0), location: 1),
                    ], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(tint)
            )
            .frame(width: max(2, proxy.size.width * width))
        }
      }
      .frame(height: 6)
      if let caption {
        Text(caption).font(.caption2).foregroundStyle(.secondary)
      }
    }
    .help(help ?? "")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
    .accessibilityValue(help ?? value)
  }
}

struct Badge: View {
  let text: String
  /// An SF Symbol drawn before the text, or nil for the plain pill every other
  /// badge is. Optional and defaulted rather than a second view, because a
  /// handful of badges are claims worth a glance of visual weight — provenance
  /// among them — and the rest are not, and should not have to say so.
  let systemImage: String?
  let tint: Color

  init(_ text: String, systemImage: String? = nil, tint: Color) {
    self.text = text
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
      }
      Text(text)
    }
    .font(.caption2)
    .padding(.horizontal, 6).padding(.vertical, 1)
    .background(tint.opacity(0.15), in: Capsule())
    .foregroundStyle(tint)
  }
}

/// The heading above a card's contents. Uppercased and tracked, which is the
/// macOS convention for a group label that is not a window title.
struct SectionLabel: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(.caption2).bold()
      .foregroundStyle(.secondary)
  }
}

/// A titled group in a detail pane.
///
/// Every detail pane in this window is a stack of these, which is what keeps
/// three separately-written screens looking like one app. Doing it by hand is
/// how they end up with three different paddings and two different corner radii.
struct Card<Content: View, Accessory: View>: View {
  let title: String
  @ViewBuilder let accessory: () -> Accessory
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // The title line doubles as the card's toolbar. A card whose one action
      // lives at the bottom, under whatever the card happens to say last, makes
      // the reader work out for themselves which block that button belongs to.
      HStack(spacing: 8) {
        SectionLabel(title)
        Spacer()
        accessory()
      }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
  }
}

extension Card where Accessory == EmptyView {
  init(title: String, @ViewBuilder content: @escaping () -> Content) {
    self.init(title: title, accessory: { EmptyView() }, content: content)
  }
}
