import AppKit
import SwiftUI

/// Talk to the on-device model with one profile's MCP tools loaded.
///
/// The point of this pane is to make a tool call something you can *try* rather
/// than something you infer from a log line. The deep check in the server sheet
/// asks one question and reports; here you ask, and every call the model makes
/// appears inline with the arguments it invented.
///
/// A pane rather than a window: `MainPane` already carries the sidebar, the
/// `@AppStorage` selection and the `--pane=` deep link, so this costs four small
/// edits in `MainWindow` and no window plumbing at all.
struct ChatPane: View {
  @State private var chat = DemoSeed.isEnabled ? DemoSeed.chatSession() : ChatSession()
  @State private var draft = ""
  @State private var showingTools = false
  @State private var acknowledged = false
  @State private var pendingSwitch: Pick?

  /// A profile and the server it belongs to. Both, because a profile only names
  /// its server by id and every use here needs the entry itself.
  private struct Pick: Identifiable, Hashable {
    let profile: Profile
    let server: BastionServer
    var id: String { profile.id }
  }

  private var picks: [Pick] {
    ServerStore.shared.servers
      .flatMap { server in
        ProfileStore.shared.profiles
          .filter { $0.serverID == server.id }
          .map { Pick(profile: $0, server: server) }
      }
      .sorted { $0.id < $1.id }
  }

  var body: some View {
    Group {
      if case .unavailable(let why) = ToolProbe.availability {
        unavailable(why)
      } else {
        transcript
      }
    }
    .safeAreaInset(edge: .top) { header }
    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
    // Somebody arrived here from a profile row rather than from the sidebar.
    // Both hooks are needed and neither is redundant: `onAppear` catches the
    // request that was set while this pane did not exist, and `onChange`
    // catches one set while it is already on screen — which is the ordinary
    // case, since `MainWindowController.show(_:)` reaches an open window.
    .onAppear { adopt(ChatRequest.shared.take()) }
    .onChange(of: ChatRequest.shared.pending) { adopt(ChatRequest.shared.take()) }
    #if DEBUG
      // `--chat-profile=prod/appstore-connect`, alongside `--pane=chat`.
      // Selecting a profile is the one step that cannot be reached without a
      // click, and driving a click from a script means synthetic input that
      // lands in whatever happens to be frontmost. This is the honest way.
      .onAppear {
        guard chat.profile == nil,
          let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--chat-profile=") })
        else { return }
        let wanted = String(raw.dropFirst("--chat-profile=".count))
        if let pick = picks.first(where: { $0.id == wanted }) { load(pick) }
      }
    #endif
    .confirmationDialog(
      "Switch to '\(pendingSwitch?.id ?? "")'?",
      isPresented: Binding(get: { pendingSwitch != nil }, set: { if !$0 { pendingSwitch = nil } }),
      titleVisibility: .visible
    ) {
      Button("Switch and start over") {
        if let pick = pendingSwitch { load(pick) }
        pendingSwitch = nil
      }
      Button("Cancel", role: .cancel) { pendingSwitch = nil }
    } message: {
      Text(
        "A conversation is tied to the tools it was started with, so changing profile ends this "
          + "one. Nothing on the server is affected.")
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Picker("Profile", selection: profileBinding) {
          Text("Choose a profile…").tag(nil as String?)
          ForEach(picks) { pick in
            Text("\(pick.profile.name) / \(pick.server.id)").tag(pick.id as String?)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 260)

        if chat.isLoading { ProgressView().controlSize(.small) }

        Spacer()

        if chat.isReady {
          Button {
            showingTools = true
          } label: {
            // The budget, always on screen. It is the constraint the whole pane
            // is shaped by, and hiding it behind a disclosure would make every
            // "why didn't it use tool X" question unanswerable at a glance.
            HStack(spacing: 6) {
              Text("\(chat.selected.count) of \(chat.tools.count) tools")
              Text(
                "\(chat.used.formatted(.number.grouping(.never)))/"
                  + "\(ChatSession.budget.formatted(.number.grouping(.never)))"
              )
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(chat.isOverBudget ? .orange : .secondary)
            }
          }
          .popover(isPresented: $showingTools, arrowEdge: .bottom) { toolPicker }

          Button("Clear") { chat.clear() }
            .disabled(chat.messages.isEmpty || chat.isResponding)
        }
      }
      .controlSize(.small)
      .padding(.horizontal, 12).padding(.vertical, 8)

      if let failure = chat.loadFailure {
        banner(failure, tint: .red, symbol: "xmark.circle.fill")
      } else if let eligibility = chat.eligibility, eligibility.needsConfirmation, !acknowledged,
        chat.isReady
      {
        writesBanner(eligibility)
      } else if chat.trims > 0 {
        banner(
          "The conversation outgrew the model's \(ChatSession.contextSize)-token window, so the "
            + "earliest \(chat.trims == 1 ? "exchange was" : "\(chat.trims) exchanges were") "
            + "dropped. Anything said there has been forgotten.",
          tint: .orange, symbol: "scissors")
      }

      Divider()
    }
    .background(.bar)
  }

  @ViewBuilder
  private func writesBanner(_ eligibility: ToolProbe.Eligibility) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
      // No `fixedSize` on this sentence, and that is load-bearing rather than an
      // oversight. `LogPane.disclaimer` documents what it costs: a wrapping
      // caption that answers its height only once given a width makes the
      // `NavigationSplitView` detail column resolve against the *unwrapped*
      // sentence, and the result is not a wide window but a blank one — sidebar
      // rows gone, detail pane drawing nothing. Without it the width arrives
      // first and the text simply wraps into it, which is all this needs.
      Text(
        "This profile has writes enabled. Only tools the server marks read-only are loaded, but "
          + "that mark is the server's own claim about itself and not something Bastion can check."
      )
      .font(.caption)
      Spacer(minLength: 8)
      Button("I understand") { acknowledged = true }
        .controlSize(.small)
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }

  private func banner(_ text: String, tint: Color, symbol: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol).foregroundStyle(tint)
      // Same reason as `writesBanner` above: no `fixedSize` in this column.
      Text(text)
        .font(.caption).foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).padding(.vertical, 6)
  }

  // MARK: - Tools

  private var toolPicker: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Tools loaded into the conversation")
        .font(.headline)
      ProgressView(
        value: Double(min(chat.used, ChatSession.budget)), total: Double(ChatSession.budget)
      )
      .tint(chat.isOverBudget ? .orange : .accentColor)
      Text(
        "The model holds \(ChatSession.contextSize) tokens in total — instructions, tools, the "
          + "conversation and its reply. Every tool spends part of that budget for the whole "
          + "conversation, so this is a choice about what to make reachable, not a preference."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(chat.tools) { tool in
            Toggle(
              isOn: Binding(
                get: { chat.selected.contains(tool.name) }, set: { _ in chat.toggle(tool) })
            ) {
              HStack(spacing: 6) {
                Text(tool.name).font(.system(.caption, design: .monospaced))
                Spacer(minLength: 8)
                Text("\(ChatSession.cost(of: tool))")
                  .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
              }
            }
            .toggleStyle(.checkbox)
          }
        }
      }
      .frame(height: 240)

      if !chat.withheld.isEmpty || !chat.unusable.isEmpty {
        Divider()
        DisclosureGroup("\(chat.withheld.count + chat.unusable.count) not offered") {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(chat.withheld + chat.unusable, id: \.self) { line in
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
    .padding(12)
    .frame(width: 420)
  }

  // MARK: - Transcript

  private static let tailAnchor = "chat-tail"

  private var transcript: some View {
    ScrollViewReader { proxy in
      List {
        if chat.messages.isEmpty { placeholder }
        ForEach(chat.messages) { message in
          MessageRow(message: message)
            .id(message.id)
            .listRowSeparator(.hidden)
        }
        // Its own anchor rather than the last message's id, so following the
        // tail does not depend on which message happens to be last.
        Color.clear
          .frame(height: 1)
          .id(Self.tailAnchor)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
      }
      .listStyle(.plain)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: chat.messages.last?.text) {
        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.tailAnchor, anchor: .bottom) }
      }
      .onChange(of: chat.messages.count) {
        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(Self.tailAnchor, anchor: .bottom) }
      }
    }
  }

  @ViewBuilder
  private var placeholder: some View {
    VStack(alignment: .leading, spacing: 6) {
      if chat.isReady {
        Text("Ask something that needs one of the loaded tools.")
          .font(.callout).foregroundStyle(.secondary)
        Text(
          "Every call runs against the real supervised server, as this profile, and shows up in "
            + "the Log pane too."
        )
        .font(.caption).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Choose a profile to load its tools.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
    .listRowSeparator(.hidden)
    .padding(.vertical, 6)
  }

  private func unavailable(_ why: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "sparkles.slash").font(.largeTitle).foregroundStyle(.tertiary)
      Text("The on-device model is not available")
        .font(.headline)
      // And here too — this one replaces the whole detail pane, so getting it
      // wrong would blank the window on exactly the machines that can least
      // afford a confusing failure.
      Text(why + ". The rest of Bastion is unaffected — this pane is the only thing that needs it.")
        .font(.caption).foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Composer

  private var composer: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(alignment: .bottom, spacing: 8) {
        // The box is what stops the composer reading as text falling off the
        // bottom of the window. `.plain` draws no border of its own, and in dark
        // mode `.bar` over the transcript is the same colour as the transcript,
        // so before this the only thing between the caret and the window edge
        // was padding — and no amount of it looked deliberate. Same fill and
        // corner as the tool-call blocks above, one step up in radius for a
        // control rather than a readout.
        TextField("Ask something…", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .lineLimit(1...6)
          .onSubmit(send)
          .disabled(!canSend)
          // 6, with `.controlSize(.large)` on the button below: that pairing is
          // what makes the two exactly 28pt, so the box and the button share a
          // top and a bottom edge instead of only meeting at the baseline.
          // Changing either one alone puts them back out of alignment.
          .padding(.horizontal, 10).padding(.vertical, 6)
          .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 1))
        Button("Send", action: send)
          .controlSize(.large)
          .keyboardShortcut(.return, modifiers: [])
          .disabled(!canSend || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if chat.isResponding { ProgressView().controlSize(.small) }
      }
      .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 14)
    }
    .background(.bar)
  }

  private var canSend: Bool {
    guard chat.isReady, !chat.isResponding else { return false }
    if let eligibility = chat.eligibility, eligibility.needsConfirmation, !acknowledged {
      return false
    }
    return true
  }

  private func send() {
    guard canSend else { return }
    chat.send(draft)
    draft = ""
  }

  // MARK: - Profile selection

  private var profileBinding: Binding<String?> {
    Binding(
      get: { chat.profile?.id },
      set: { id in
        guard let id, let pick = picks.first(where: { $0.id == id }) else { return }
        // Only worth a dialog when there is something to lose.
        if chat.messages.isEmpty {
          load(pick)
        } else {
          pendingSwitch = pick
        }
      })
  }

  private func load(_ pick: Pick) {
    acknowledged = false
    chat.load(profile: pick.profile, server: pick.server)
  }

  /// Honour an incoming request, asking first when there is something to lose.
  ///
  /// Routed through the same `pendingSwitch` dialog the picker uses rather than
  /// a second one of its own. A request that arrives mid-conversation is the
  /// identical situation — the tools are fixed at construction, so adopting it
  /// ends the conversation — and saying so twice in two different sentences is
  /// how the two drift apart.
  private func adopt(_ request: ChatRequest.Pending?) {
    guard let request else { return }
    let pick = Pick(profile: request.profile, server: request.server)
    guard pick.id != chat.profile?.id else { return }
    if chat.messages.isEmpty {
      load(pick)
    } else {
      pendingSwitch = pick
    }
  }
}

// MARK: - One message

private struct MessageRow: View {
  let message: ChatSession.Message

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(message.role == .you ? "You" : "On-device model")
        .font(.caption2).bold()
        .foregroundStyle(message.role == .you ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

      // Calls before the prose, because they are the evidence and the prose is
      // a small model's account of them.
      ForEach(message.calls) { call in
        CallRow(call: call)
      }

      if !message.text.isEmpty {
        Text(message.text)
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
      } else if message.role == .model, message.failure == nil, message.calls.isEmpty {
        Text("…").foregroundStyle(.tertiary)
      }

      if let failure = message.failure {
        Label(failure, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct CallRow: View {
  let call: ToolProbe.Call
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Image(systemName: call.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
          .foregroundStyle(call.failed ? .red : .green)
        Text(call.tool).font(.system(.caption, design: .monospaced)).bold()
        Spacer(minLength: 8)
        Text(
          call.seconds < 1
            ? "\(Int((call.seconds * 1000).rounded()))ms" : String(format: "%.1fs", call.seconds)
        )
        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
      }
      // The arguments the model invented are the most informative thing on
      // screen: they say what it understood the tool's schema to mean.
      Text(call.arguments)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Text(expanded ? call.output : String(call.output.prefix(240)))
        .font(.caption2)
        .foregroundStyle(call.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .fixedSize(horizontal: false, vertical: true)
      if call.output.count > 240 {
        Button(expanded ? "Show less" : "Show all \(call.output.count) characters") {
          expanded.toggle()
        }
        .buttonStyle(.link).font(.caption2)
      }
    }
    .padding(6)
    .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 6))
  }
}
