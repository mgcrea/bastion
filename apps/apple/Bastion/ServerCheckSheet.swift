import AppKit
import SwiftUI

/// What a check found, while it is still finding it.
///
/// A sheet rather than an expanded row: the useful half of this is the server's
/// own log, which needs vertical room, and `profilesCard` is a compact list
/// where one row growing to a page would push the others out of view and fight
/// the five-second `TimelineView` redraw behind it.
struct ServerCheckSheet: View {
  let server: BastionServer
  let profile: Profile

  @Environment(\.dismiss) private var dismiss
  @State private var probing = false
  @State private var confirmingProbe = false
  @State private var showingEverything = false

  private var run: ServerCheck.Run? { ServerCheck.shared.run(for: profile) }
  private var probe: ToolProbe.Result? { ServerCheck.shared.probes[profile.id] }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          stepsCard
          if let run, !run.tools.isEmpty { costCard(run: run) }
          if let run, !run.tools.isEmpty { deepCard(run: run) }
        }
        .padding(14)
      }
      Divider()
      logs
      Divider()
      footer
    }
    .frame(width: 660, height: 680)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(profile.name) / \(server.id)")
          .font(.system(.title3, design: .monospaced)).bold()
        Text(headline)
          .font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if run?.isRunning == true { ProgressView().controlSize(.small) }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }

  private var headline: String {
    guard let run else { return server.displayName }
    if run.isRunning { return "Checking…" }
    if run.failed { return "The check found a problem." }
    // Said explicitly, because it is the difference between having measured a
    // cold start and having measured a dictionary read.
    return run.wasWarm
      ? "Everything passed. The server was already running when the check began."
      : "Everything passed. The server was started by this check."
  }

  // MARK: - Steps

  private var stepsCard: some View {
    Card(title: "Checks") {
      VStack(alignment: .leading, spacing: 8) {
        if let run {
          ForEach(run.steps) { step in
            StepRow(step: step)
          }
        }
        if let live = Activity.shared.instances.first(where: { $0.id == profile.id }) {
          Divider()
          HStack(spacing: 10) {
            if let pid = live.pid, pid > 0 {
              Label("pid \(pid)", systemImage: "cpu")
            } else if let host = live.remoteHost {
              Label(host, systemImage: "network")
            }
            if let dialect = live.dialect { Label(dialect, systemImage: "number") }
            Label(
              "\(live.clients.count) client\(live.clients.count == 1 ? "" : "s")",
              systemImage: "person.2")
            // A restart count is the number that turns "it feels flaky" into a
            // fact, so it is only shown when there is a fact to report.
            if live.restarts > 0 {
              Label(
                "\(live.restarts) restart\(live.restarts == 1 ? "" : "s")",
                systemImage: "arrow.clockwise"
              )
              .foregroundStyle(.orange)
            }
            Spacer()
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .labelStyle(.titleAndIcon)
        }
      }
    }
  }

  // MARK: - Context cost

  /// What this profile's tool list costs every client that connects to it.
  ///
  /// The one number a supervisor is placed to report and an editor is not: the
  /// list is fetched here once, for a profile, with its write gate already
  /// applied, so this is what a client would have been sent.
  ///
  /// Five tools rather than the whole table. What a reader can act on is which
  /// few tools carry the largest schemas — on `appstore-connect` the heaviest
  /// costs twelve times the lightest — and a list of eighty-five buries that.
  /// A full table would also be the Chat pane's tool picker with a different
  /// number in the same column, which is the confusion the caption below exists
  /// to prevent.
  @ViewBuilder
  private func costCard(run: ServerCheck.Run) -> some View {
    let bytes = run.tools.reduce(0) { $0 + $1.wireBytes }
    let count = run.tools.count
    let heaviest = run.tools.sorted { $0.wireBytes > $1.wireBytes }.prefix(5)
    let gate = profile.allowWrites ? "on" : "off"

    Card(title: "Context cost") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Every editor that connects to this profile receives all \(count) tool "
            + "definition\(count == 1 ? "" : "s") before it can call one. That is "
            + "\(ToolCost.phrase(bytes: bytes, partial: run.listIsPartial)) of its context "
            + "window, held for the whole conversation."
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "Counted from what this check received, with writes \(gate), at four bytes to the "
            + "token. Editors reshape tool definitions into their own prompt "
            + "format, so read it as an order of magnitude rather than a bill."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if run.listIsPartial {
          Label(
            "The list is paginated and this check read only the first page, so the real figure "
              + "is higher.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }

        Text(
          "The Chat pane counts a smaller number for the same tools. It measures what Bastion "
            + "hands the on-device model after trimming each description, not what the server "
            + "puts on the wire."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        if count > 5 {
          Divider()
          SectionLabel("Heaviest tools")
          VStack(alignment: .leading, spacing: 2) {
            ForEach(heaviest) { tool in
              HStack(spacing: 6) {
                Text(tool.name).font(.system(.caption, design: .monospaced))
                Spacer(minLength: 8)
                Text(ToolCost.short(ToolCost.tokens(bytes: tool.wireBytes)))
                  .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
              }
            }
            Text("and \(count - 5) more")
              .font(.caption2).foregroundStyle(.tertiary)
          }
        }
      }
    }
  }

  // MARK: - Deep check

  @ViewBuilder
  private func deepCard(run: ServerCheck.Run) -> some View {
    let eligibility = ToolProbe.eligibility(server: server, profile: profile)
    let availability = ToolProbe.availability

    Card(title: "Deep check") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Calls one tool for real, using Apple's on-device model to invent the arguments. "
            + "Nothing leaves this Mac."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        switch eligibility {
        case .anyTool(let because):
          Label(because, systemImage: "lock.open")
            .font(.caption).foregroundStyle(.secondary)
        case .readOnlyHintsOnly(let because):
          Label(because, systemImage: "exclamationmark.triangle.fill")
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }

        if case .unavailable(let why) = availability {
          Label(why, systemImage: "sparkles.slash")
            .font(.caption).foregroundStyle(.secondary)
        }

        HStack(spacing: 8) {
          Button(probe == nil ? "Run deep check" : "Run again") {
            if eligibility.needsConfirmation {
              confirmingProbe = true
            } else {
              startProbe()
            }
          }
          .disabled(probing || run.isRunning || availability.isUnavailable)
          if probing {
            ProgressView().controlSize(.small)
            Text("The model is choosing a tool…")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }

        if let probe { ProbeReport(result: probe) }
      }
    }
    .confirmationDialog(
      "Let the model call a tool on '\(profile.name)'?",
      isPresented: $confirmingProbe, titleVisibility: .visible
    ) {
      Button("Call a read-only tool") { startProbe() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This profile has writes enabled, so the server's destructive tools are registered and "
          + "reachable. Only tools the server marks read-only will be offered, but that mark is "
          + "the server's own claim about itself — it is not something Bastion can verify.")
    }
  }

  private func startProbe() {
    guard let tools = run?.tools, !tools.isEmpty else { return }
    probing = true
    Task {
      let result = await ToolProbe.run(profile: profile, server: server, tools: tools)
      ServerCheck.shared.setProbe(result, for: profile.id)
      probing = false
    }
  }

  // MARK: - The server's own log

  private var logs: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        SectionLabel("Log")
        Spacer()
        Toggle("Everything for this profile", isOn: $showingEverything)
          .toggleStyle(.checkbox)
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(
            entries.map { "\($0.origin)  \($0.level.rawValue)  \($0.text)" }
              .joined(separator: "\n"), forType: .string)
        }
        .disabled(entries.isEmpty)
      }
      .controlSize(.small)
      .padding(.horizontal, 14).padding(.vertical, 6)

      // A `List`, for the reason `LogPane` gives: a log line is arbitrarily
      // long, and a lazy stack breaks the whole window when one arrives.
      List(entries) { entry in
        FeedRow(entry: entry)
          .listRowSeparator(.hidden)
          .listRowInsets(.init(top: 1, leading: 6, bottom: 1, trailing: 6))
      }
      .listStyle(.plain)
      .frame(height: 180)
      .overlay {
        if entries.isEmpty {
          Text(
            showingEverything
              ? "This profile has logged nothing." : "Nothing logged since the check began."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  /// The child's stderr, which `drainStderr` already routes into `LogStore`
  /// under this profile's id — so "see its logs" is a filter, not new plumbing.
  private var entries: [LogStore.Entry] {
    let since = run?.startedAt ?? .distantPast
    return LogStore.shared.entries.filter {
      $0.origin == profile.id && (showingEverything || $0.at >= since)
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Button("Check again") { ServerCheck.shared.start(profile: profile, server: server) }
        .disabled(run?.isRunning == true || probing)
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }
}

// MARK: - One step

private struct StepRow: View {
  let step: ServerCheck.Step

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      glyph
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(step.kind.label).font(.callout)
          Spacer()
          if let seconds = step.seconds {
            Text(Self.duration(seconds))
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.tertiary)
          }
        }
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(tint == .primary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        if case .warned(_, let why) = step.outcome {
          Text(why)
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private var glyph: some View {
    switch step.outcome {
    case .pending: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
    case .running: ProgressView().controlSize(.small).scaleEffect(0.6)
    case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    case .warned: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
    case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
    case .skipped: Image(systemName: "minus.circle").foregroundStyle(.tertiary)
    }
  }

  private var detail: String? {
    switch step.outcome {
    case .pending, .running: nil
    case .passed(let text), .warned(let text, _), .failed(let text), .skipped(let text): text
    }
  }

  private var tint: Color {
    switch step.outcome {
    case .warned: .orange
    case .failed: .red
    default: .primary
    }
  }

  /// Milliseconds under a second, seconds above. A cold node start is 800–2500ms
  /// and reading "1.9s" next to "already running" is most of the point.
  static func duration(_ seconds: TimeInterval) -> String {
    seconds < 1
      ? "\(Int((seconds * 1000).rounded()))ms"
      : String(format: "%.1fs", seconds)
  }
}

// MARK: - What the model did

private struct ProbeReport: View {
  let result: ToolProbe.Result

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()

      if let failure = result.failure {
        Label(failure, systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      // The calls first, and the prose after: the transcript is the evidence,
      // and a small on-device model's summary of it is a footnote.
      ForEach(result.calls) { call in
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Image(systemName: call.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
              .foregroundStyle(call.failed ? .red : .green)
            Text(call.tool).font(.system(.caption, design: .monospaced)).bold()
            Spacer()
            Text(StepRow.duration(call.seconds))
              .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
          }
          // The arguments the model invented are the most interesting artefact
          // here: they are a readable statement of what it understood the
          // tool's schema to mean, which is a direct read on how well the
          // server describes itself.
          Text(call.arguments)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
          Text(call.output.prefix(400))
            .font(.caption2)
            .foregroundStyle(call.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(6)
        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
      }

      if !result.summary.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            SectionLabel("What the on-device model made of it")
            if let working = result.working {
              Badge(working ? "looks alive" : "looks wrong", tint: working ? .green : .orange)
            }
          }
          Text(result.summary)
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !result.skipped.isEmpty {
        DisclosureGroup("\(result.skipped.count) tool(s) were not offered") {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(result.skipped, id: \.self) { line in
              Text("• \(line)")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(.top, 3)
        }
        .font(.caption)
      }
    }
  }
}

extension ToolProbe.Availability {
  var isUnavailable: Bool {
    if case .unavailable = self { return true }
    return false
  }
}
