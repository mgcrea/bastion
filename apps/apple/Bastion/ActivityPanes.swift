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

  private var entries: [LogStore.Entry] {
    let all = LogStore.shared.entries
    return callsOnly ? all.filter { $0.level == .call } : all
  }

  var body: some View {
    let shown = entries

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Text("Log").font(.title2).bold()
        Spacer()
        Toggle("Tool calls only", isOn: $callsOnly)
          .toggleStyle(.checkbox)
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(shown.map(line).joined(separator: "\n"), forType: .string)
        }
        .disabled(shown.isEmpty)
        Button("Clear") { LogStore.shared.clear() }
          .disabled(LogStore.shared.entries.isEmpty)
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
            FeedRow(entry: entry)
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
            Text(LogStore.shared.entries.isEmpty ? "Nothing yet." : "Nothing matches this filter.")
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
        // Load-bearing, not decoration. Bastion records the method and the name
        // of whatever a request reached for and stops there; keeping this
        // sentence true is a constraint on anything ever added to the feed.
        Text(
          "Bastion records the JSON-RPC frames crossing the gateway — which profile, which tool. "
            + "It does not see what a server then does over the network or on disk.")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer(minLength: 12)
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

  private static let tailAnchor = "activity-tail"

  private func line(_ entry: LogStore.Entry) -> String {
    "\(Self.clock.string(from: entry.at))  \(entry.origin)  \(entry.level.rawValue)  \(entry.text)"
  }

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}

struct FeedRow: View {
  let entry: LogStore.Entry

  var body: some View {
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
      Spacer(minLength: 0)
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

struct Badge: View {
  let text: String
  let tint: Color

  init(_ text: String, tint: Color) {
    self.text = text
    self.tint = tint
  }

  var body: some View {
    Text(text)
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
struct Card<Content: View>: View {
  let title: String
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      SectionLabel(title)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
  }
}
