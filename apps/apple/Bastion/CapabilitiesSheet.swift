import AppKit
import SwiftUI

/// What one profile actually exposes: every tool, every prompt, every resource,
/// read from the running server.
///
/// The question this answers had no home. `ServerCheckSheet` reports the five
/// heaviest tools and says so — a full table there would be the Chat pane's
/// picker with a different number in the same column — and the Chat pane's
/// picker is a budget control that shows only the tools the on-device model may
/// be offered, with everything the write gate touches dropped into `withheld`.
/// Neither has ever shown a prompt or a resource, because nothing in the app
/// asked for one.
///
/// A sheet rather than a card in `ServerDetail`: eighty-five tools with their
/// schemas is a page, and `profilesCard` is a compact list where one row growing
/// to a page pushes the others out of view — the argument `ServerCheckSheet`
/// already makes for being a sheet, one size larger.
struct CapabilitiesSheet: View {
  let server: BastionServer
  let profile: Profile

  @Environment(\.dismiss) private var dismiss
  @State private var surface: CapabilityStore.Surface = .tools
  @State private var query = ""

  private var snapshot: CapabilityStore.Snapshot? {
    CapabilityStore.shared.snapshot(for: profile, server: server)
  }

  private var isLoading: Bool { CapabilityStore.shared.isLoading(profile) }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      controls
      Divider()
      list(for: surface)
      Divider()
      notes
      Divider()
      footer
    }
    .frame(width: 700, height: 700)
    // On appear rather than on a button, because the sheet has one subject and
    // opening it is the request. Only when there is nothing current: a snapshot
    // ages out on the version and the gate, so what survives is what still
    // describes this profile.
    .onAppear {
      if snapshot == nil, !isLoading {
        CapabilityStore.shared.load(profile: profile, server: server)
      }
    }
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(profile.name) / \(server.id)")
          .font(.system(.title3, design: .monospaced)).bold()
        Text(headline)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      if isLoading { ProgressView().controlSize(.small) }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }

  private var headline: String {
    if isLoading { return "Asking the server what it exposes…" }
    guard let snapshot else { return server.displayName }
    let when = snapshot.takenAt.formatted(.relative(presentation: .numeric))
    let who = snapshot.identity ?? server.displayName
    return "\(who) · read \(when)"
  }

  // MARK: - Picker and search

  private var controls: some View {
    HStack(spacing: 10) {
      Picker("", selection: $surface) {
        ForEach(CapabilityStore.Surface.allCases) { surface in
          Text(label(for: surface)).tag(surface)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()

      TextField("Filter", text: $query)
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 220)

      Spacer()

      Button("Copy names") { copyNames() }
        .disabled(snapshot == nil)
    }
    .controlSize(.small)
    .padding(.horizontal, 14).padding(.vertical, 8)
  }

  /// The count belongs on the tab. It is the first thing anybody opening this
  /// wants — "does this server even have prompts" is answered before a click.
  private func label(for surface: CapabilityStore.Surface) -> String {
    guard let snapshot else { return surface.label }
    guard snapshot.declared.contains(surface) else { return "\(surface.label) —" }
    let count = snapshot.count(of: surface)
    return "\(surface.label) \(count)\(snapshot.truncated.contains(surface) ? "+" : "")"
  }

  // MARK: - The lists

  @ViewBuilder
  private func list(for surface: CapabilityStore.Surface) -> some View {
    if let snapshot {
      // A `List`, for the reason `LogPane` gives and `ServerCheckSheet` repeats:
      // a description is arbitrarily long, and a lazy stack breaks the window
      // when one arrives.
      List {
        if let failure = snapshot.failures[surface] {
          Label(failure, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(.orange)
            .listRowSeparator(.hidden)
        }
        switch surface {
        case .tools:
          ForEach(tools(in: snapshot)) { tool in
            ToolRow(tool: tool, writes: snapshot.writeTools.contains(tool.name))
              .listRowSeparator(.hidden)
          }
          // Named rather than merely counted. These are the tools this profile
          // would have had with its gate on, and the difference between "this
          // server has none" and "you cannot see them from here" is the whole
          // point of saying it.
          ForEach(snapshot.hiddenWriteTools.filter { matches($0) }, id: \.self) { name in
            HStack(spacing: 6) {
              Text(name)
                .font(.system(.caption, design: .monospaced))
                .strikethrough()
                .foregroundStyle(.tertiary)
              Badge("hidden by the write gate", tint: .orange)
              Spacer()
            }
            .listRowSeparator(.hidden)
          }
        case .prompts:
          ForEach(prompts(in: snapshot)) { prompt in
            PromptRow(prompt: prompt).listRowSeparator(.hidden)
          }
        case .resources:
          ForEach(resources(in: snapshot)) { resource in
            ResourceRow(resource: resource).listRowSeparator(.hidden)
          }
        }
      }
      .listStyle(.plain)
      .frame(maxHeight: .infinity)
      .overlay { emptyState(snapshot) }
    } else {
      VStack(spacing: 8) {
        if !isLoading {
          Text("Nothing read yet.")
            .font(.callout).foregroundStyle(.secondary)
          Button("Read this profile") {
            CapabilityStore.shared.load(profile: profile, server: server)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func emptyState(_ snapshot: CapabilityStore.Snapshot) -> some View {
    if snapshot.count(of: surface) == 0, snapshot.failures[surface] == nil {
      // Three different facts, and collapsing them into "none" would be the
      // sheet guessing. A server that never declared the capability was never
      // asked; one that declared it and returned nothing has nothing.
      Text(
        snapshot.declared.contains(surface)
          ? "This server declares \(surface.rawValue) and returned an empty list."
          : "This server's handshake declares no \(surface.rawValue), so Bastion did not ask for "
            + "a list. Asking anyway would earn a refusal that says nothing about the server."
      )
      .font(.callout).foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 40)
    } else if !query.isEmpty, visibleCount(snapshot) == 0 {
      Text("Nothing matches '\(query)'.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  // MARK: - Filtering

  private func matches(_ text: String...) -> Bool {
    guard !query.isEmpty else { return true }
    return text.contains { $0.localizedCaseInsensitiveContains(query) }
  }

  private func tools(in snapshot: CapabilityStore.Snapshot) -> [MCPTool] {
    snapshot.tools.filter { matches($0.name, $0.summary) }
  }

  private func prompts(in snapshot: CapabilityStore.Snapshot) -> [MCPPrompt] {
    snapshot.prompts.filter { matches($0.name, $0.summary) }
  }

  private func resources(in snapshot: CapabilityStore.Snapshot) -> [MCPResource] {
    snapshot.resources.filter { matches($0.name, $0.summary, $0.uri) }
  }

  private func visibleCount(_ snapshot: CapabilityStore.Snapshot) -> Int {
    switch surface {
    case .tools: tools(in: snapshot).count + snapshot.hiddenWriteTools.filter { matches($0) }.count
    case .prompts: prompts(in: snapshot).count
    case .resources: resources(in: snapshot).count
    }
  }

  // MARK: - What this listing is, and is not

  /// The caveats, all of them, under the list they qualify.
  ///
  /// Every one of these exists because a number here can honestly disagree with
  /// a number somewhere else in the app, and an unexplained disagreement is how
  /// a person stops trusting both.
  private var notes: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(gateNote)
      if let facadeNote { Text(facadeNote) }
      if let snapshot, snapshot.truncated.contains(surface) {
        Text(
          "The server would not stop paginating, so this list stopped at 20 pages and is a floor "
            + "rather than a total."
        )
        .foregroundStyle(.orange)
      }
      if surface == .tools, let snapshot, !snapshot.tools.isEmpty {
        Text(
          "The whole listing is "
            + ToolCost.phrase(
              bytes: snapshot.toolBytes, partial: snapshot.truncated.contains(.tools))
            + " of a client's context window, held for the whole conversation. The Chat pane "
            + "counts a smaller number for the same tools: it measures what Bastion hands the "
            + "on-device model after trimming, not what the server puts on the wire."
        )
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 14).padding(.vertical, 8)
  }

  /// Which of the two possible listings this is.
  ///
  /// The distinction the sheet cannot leave implicit: a writes-off listing is
  /// short for one of two quite different reasons, and only one of them is
  /// Bastion's doing.
  private var gateNote: String {
    if profile.allowWrites {
      return
        "Read with this profile's write gate ON, so this is the full listing, destructive tools "
        + "included."
    }
    if let snapshot, !snapshot.hiddenWriteTools.isEmpty {
      let count = snapshot.hiddenWriteTools.count
      return
        "Read with the write gate OFF. Bastion removed \(count) tool\(count == 1 ? "" : "s") the "
        + "catalog marks as writes, struck through below; it also removes any the server itself "
        + "annotates as mutating, and those it cannot name here because they never arrived."
    }
    if server.writeGate != nil {
      return
        "Read with the write gate OFF. This server switches its own destructive tools off at "
        + "startup, so they were never registered — they are absent from this list rather than "
        + "hidden from it, and Bastion cannot say what they were."
    }
    return
      server.hasWritePath
      ? "Read with the write gate OFF."
      : "This server has no write path, so there is one listing and this is it."
  }

  /// What a client is sent in place of this, when it is sent something else.
  ///
  /// `Supervisor.handle` exempts `ServerCheck.client` from the facade by name,
  /// so this sheet always sees the server's real listing. That is the right
  /// thing to show and the wrong thing to leave unexplained: with the switch on
  /// and the floor cleared, an editor is sent three declarations and would
  /// report three tools.
  private var facadeNote: String? {
    guard server.loadsToolsOnDemand, let snapshot, !snapshot.tools.isEmpty else { return nil }
    let hasWriteDispatcher = !snapshot.writeTools.isEmpty
    let count = ToolFacade.declarationCount(hasWriteDispatcher: hasWriteDispatcher)
    guard
      ToolFacade.worthFronting(
        listingBytes: snapshot.toolBytes, listingCount: snapshot.tools.count,
        facadeBytes: ToolFacade.declarationBytes(
          displayName: server.displayName, summary: server.summary,
          toolCount: snapshot.tools.count, hasWriteDispatcher: hasWriteDispatcher),
        facadeCount: count)
    else { return nil }
    return
      "Loading on demand is on, so a client that does not defer schemas itself is sent \(count) "
      + "declarations — search, describe and call — instead of this list. These are the tools "
      + "standing behind them, which is what Bastion searches."
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Button("Read again") { CapabilityStore.shared.load(profile: profile, server: server) }
        .disabled(isLoading)
      Spacer()
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
  }

  /// The names, one per line, in the order they are on screen.
  ///
  /// Names and not the whole objects: this is for pasting into an allowlist, a
  /// ticket or a prompt, and a schema dump would make the common case worse to
  /// serve the rare one. The schemas are one disclosure away, with their own
  /// copy.
  private func copyNames() {
    guard let snapshot else { return }
    let lines: [String]
    switch surface {
    case .tools: lines = tools(in: snapshot).map(\.name)
    case .prompts: lines = prompts(in: snapshot).map(\.name)
    case .resources: lines = resources(in: snapshot).map(\.uri)
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
  }
}

// MARK: - One tool

private struct ToolRow: View {
  let tool: MCPTool
  /// Whether Bastion has positive evidence this one changes something — the
  /// manifest's list or the server's own annotations. Passed in rather than
  /// read off `readOnlyHint`, which is only half of what the gate looks at.
  let writes: Bool

  @State private var showingSchema = false

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(tool.name)
          .font(.system(.callout, design: .monospaced)).bold()
          .textSelection(.enabled)
        if writes {
          Badge("writes", tint: .orange)
        } else if tool.readOnlyHint == true {
          Badge("read-only", tint: .green)
        }
        Spacer(minLength: 8)
        Text("\(ToolCost.short(ToolCost.tokens(bytes: tool.wireBytes))) tokens")
          .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
      }
      if !tool.summary.isEmpty {
        Text(tool.summary)
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(showingSchema ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
      }
      // The schema is the largest thing on the row and the least often wanted,
      // which is exactly the shape a disclosure is for. It is also the answer
      // to "what does this tool actually take", which nothing else in the app
      // will show you.
      //
      // A button and a chevron rather than a `DisclosureGroup`: inside a `List`
      // row that style draws no triangle, so the label reads as a stray line of
      // text under every tool rather than as something to press.
      Button {
        showingSchema.toggle()
      } label: {
        Label(
          "Input schema", systemImage: showingSchema ? "chevron.down" : "chevron.right"
        )
        .font(.caption2).foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      if showingSchema { SchemaBlock(json: tool.schema) }
    }
    .padding(.vertical, 3)
  }
}

// MARK: - One prompt

private struct PromptRow: View {
  let prompt: MCPPrompt

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(prompt.name)
          .font(.system(.callout, design: .monospaced)).bold()
          .textSelection(.enabled)
        Spacer(minLength: 8)
        if !prompt.arguments.isEmpty {
          let required = prompt.arguments.filter(\.required).count
          Text(
            "\(prompt.arguments.count) argument\(prompt.arguments.count == 1 ? "" : "s")"
              + (required > 0 ? ", \(required) required" : "")
          )
          .font(.caption2).foregroundStyle(.tertiary)
        }
      }
      if !prompt.summary.isEmpty {
        Text(prompt.summary)
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      ForEach(prompt.arguments) { argument in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(argument.name)
            .font(.system(.caption2, design: .monospaced))
          if argument.required { Badge("required", tint: .secondary) }
          if !argument.summary.isEmpty {
            Text(argument.summary)
              .font(.caption2).foregroundStyle(.tertiary)
              .lineLimit(1)
          }
          Spacer()
        }
      }
    }
    .padding(.vertical, 3)
  }
}

// MARK: - One resource

private struct ResourceRow: View {
  let resource: MCPResource

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(resource.name)
          .font(.callout).bold()
        if resource.isTemplate {
          // Worth a badge: a template is not something you can read, it is a
          // shape you fill in first, and the two look identical in a list.
          Badge("template", tint: .purple)
        }
        if let mimeType = resource.mimeType { Badge(mimeType, tint: .secondary) }
        Spacer()
      }
      Text(resource.uri)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(1).truncationMode(.middle)
      if !resource.summary.isEmpty {
        Text(resource.summary)
          .font(.caption).foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 3)
  }
}

// MARK: - A schema, as it arrived

private struct SchemaBlock: View {
  let json: Data

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(pretty)
        .font(.system(.caption2, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 6))
      Button("Copy schema") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pretty, forType: .string)
      }
      .buttonStyle(.borderless)
      .font(.caption2)
    }
  }

  /// Sorted keys, so two readings of the same schema are the same text and a
  /// diff between two versions of a server is a diff about the server.
  private var pretty: String {
    guard let object = try? JSONSerialization.jsonObject(with: json),
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
  }
}
