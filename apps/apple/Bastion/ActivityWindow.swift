import SwiftUI

/// The Activity window.
///
/// Two halves, and the split is the argument. The top says what is running and
/// who is attached to it — the state that simply does not exist when every
/// client spawns its own copy. The bottom says what was actually asked for.
///
/// The limit of the claim is on screen, not only in the docs: Bastion sees the
/// JSON-RPC frames crossing the gateway and nothing a server then does over the
/// network or on disk. A window that implied otherwise would be the exact
/// overclaim `apps/website/CLAUDE.md` exists to stop.
struct ActivityWindow: View {
  var body: some View {
    VStack(spacing: 0) {
      GatewayHeader()
      Divider()
      RunningServers()
      Divider()
      ActivityFeed()
    }
    .frame(minWidth: 720, minHeight: 460)
  }
}

// MARK: - Header

private struct GatewayHeader: View {
  var body: some View {
    let activity = Activity.shared
    HStack(spacing: 12) {
      Image(systemName: Gateway.shared.startupError == nil ? "shield.lefthalf.filled" : "shield.slash")
        .font(.title2)
        .foregroundStyle(Gateway.shared.startupError == nil ? Color.accentColor : .red)

      VStack(alignment: .leading, spacing: 2) {
        if let error = Gateway.shared.startupError {
          Text("Not serving").font(.headline)
          Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        } else {
          Text("http://127.0.0.1:\(String(Gateway.shared.port))")
            .font(.system(.headline, design: .monospaced))
          Text("Loopback only. Bastion \(AppInfo.version)\(AppInfo.isDebugBuild ? " (debug)" : "")")
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      Spacer()

      // The headline number for the whole idea. With one process per connection
      // these two were the same by construction, so there was nothing to say.
      Tally(value: "\(activity.attachedClients.count)", label: "clients")
      Tally(value: "\(activity.runningCount)", label: "processes")
      Tally(value: "\(activity.totalCalls)", label: "calls")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

private struct Tally: View {
  let value: String
  let label: String
  var body: some View {
    VStack(spacing: 1) {
      Text(value).font(.system(.title3, design: .rounded)).monospacedDigit()
      Text(label).font(.caption2).foregroundStyle(.secondary)
    }
    .frame(minWidth: 58)
  }
}

// MARK: - Running

private struct RunningServers: View {
  var body: some View {
    let instances = Activity.shared.instances
    VStack(alignment: .leading, spacing: 0) {
      SectionLabel("Supervised servers")
      if instances.isEmpty {
        Text("Nothing running. A server starts on the first request that needs it.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.horizontal, 16).padding(.bottom, 12)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(instances) { instance in
              InstanceRow(instance: instance)
              Divider().padding(.leading, 16)
            }
          }
        }
        .frame(minHeight: 90, maxHeight: 200)
      }
    }
  }
}

private struct InstanceRow: View {
  let instance: Activity.Instance

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Circle()
        .fill(instance.pid > 0 ? Color.green : Color.secondary)
        .frame(width: 7, height: 7)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(instance.displayName).font(.system(.body, design: .monospaced)).bold()
          if instance.allowWrites {
            // Loud on purpose. This is the switch that lets a tool call place a
            // brokerage order, and it is set per profile — so the window has to
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
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  private var subtitle: String {
    if instance.pid <= 0 {
      return instance.lastExit.map { "stopped — \($0)" } ?? "stopped"
    }
    var parts = ["pid \(instance.pid)", uptime]
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

private struct Badge: View {
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

// MARK: - Feed

private struct ActivityFeed: View {
  @State private var callsOnly = false

  var body: some View {
    let entries = LogStore.shared.entries
    let shown = (callsOnly ? entries.filter { $0.level == .call } : entries).reversed()

    VStack(alignment: .leading, spacing: 0) {
      HStack {
        SectionLabel("Activity")
        Spacer()
        Toggle("Tool calls only", isOn: $callsOnly)
          .toggleStyle(.checkbox).font(.caption)
        Button("Clear") { LogStore.shared.clear() }
          .font(.caption).buttonStyle(.borderless)
      }
      .padding(.trailing, 16)

      if shown.isEmpty {
        Text(callsOnly ? "No tool calls yet." : "Nothing yet.")
          .font(.callout).foregroundStyle(.secondary)
          .padding(.horizontal, 16).padding(.bottom, 12)
        Spacer()
      } else {
        // Newest first, so the interesting end is the one you are already
        // looking at. A feed that appends downward makes every reader scroll
        // before it says anything.
        List(Array(shown)) { entry in
          FeedRow(entry: entry)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
      }

      Divider()
      Text(
        "Bastion records the JSON-RPC frames crossing the gateway — which profile, which tool. "
          + "It does not see what a server then does over the network or on disk."
      )
      .font(.caption2).foregroundStyle(.secondary)
      .padding(.horizontal, 16).padding(.vertical, 8)
    }
  }
}

private struct FeedRow: View {
  let entry: LogStore.Entry

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(entry.at, format: .dateTime.hour().minute().second())
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
      Circle().fill(tint).frame(width: 6, height: 6)
      Text(entry.origin)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(minWidth: 130, alignment: .leading)
      Text(entry.text)
        .font(.system(.caption, design: entry.level == .call ? .monospaced : .default))
        .textSelection(.enabled)
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

private struct SectionLabel: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View {
    Text(text.uppercased())
      .font(.caption2).bold().foregroundStyle(.secondary)
      .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
  }
}
