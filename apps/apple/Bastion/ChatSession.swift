import Foundation
import FoundationModels
import Observation
import os

/// A conversation with the on-device model, holding one profile's MCP tools.
///
/// The deep check in `ToolProbe` asks the model one question and reports the
/// answer. This is the same machinery with the lid off: you pick the tools, you
/// ask the questions, and every call the model makes is shown as it happens.
///
/// **The context window is the design.** `SystemLanguageModel.contextSize` is
/// 4096 tokens, and that budget covers the instructions, every tool schema, the
/// whole conversation and the reply. Measured against the real catalogue, one
/// server does not fit: `appstore-connect` with writes off exposes 47 tools
/// whose schemas come to roughly 12,300 tokens, three times the entire window;
/// `x-api` needs 4,900. At about 260 tokens each, a workable set is seven or
/// eight tools.
///
/// So "load all the tools" is not a thing that can be built — not a hard thing,
/// an impossible one — and the honest response is to show the arithmetic rather
/// than hide it. Hence a budget, a per-tool cost, and a list where the tools
/// that did not fit stay visible with the reason.
@Observable
final class ChatSession {

  /// Tokens of tool schema the conversation is allowed to carry.
  ///
  /// Deliberately well under `contextSize`: what is left has to hold the
  /// instructions, the questions, the answers, and one tool result, which is
  /// itself capped at 2000 characters by `ToolProbe.invoke`.
  static let budget = 1800

  enum Role: Sendable { case you, model }

  struct Message: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    /// Calls the model made while producing this message, in order.
    var calls: [ToolProbe.Call] = []
    var failure: String?
  }

  // MARK: - Selection

  private(set) var profile: Profile?
  private(set) var server: BastionServer?
  /// Every tool this profile is allowed to offer, cheapest first.
  private(set) var tools: [MCPTool] = []
  /// Why each of the others was withheld — the safety gate's own words.
  private(set) var withheld: [String] = []
  /// Tools whose schema `ToolProbe.node` cannot express.
  private(set) var unusable: [String] = []
  private(set) var selected: Set<String> = []

  private(set) var messages: [Message] = []
  private(set) var isResponding = false
  private(set) var isLoading = false
  private(set) var loadFailure: String?
  /// How many times the transcript has been trimmed to fit. Surfaced, because a
  /// model that has quietly forgotten the start of the conversation is
  /// otherwise indistinguishable from one that is being obtuse.
  private(set) var trims = 0

  private var session: LanguageModelSession?
  private var bound: [any Tool] = []
  private nonisolated let callIDs = OSAllocatedUnfairLock<Int>(initialState: 1000)

  var isReady: Bool { session != nil }

  var eligibility: ToolProbe.Eligibility? {
    guard let server, let profile else { return nil }
    return ToolProbe.eligibility(server: server, profile: profile)
  }

  // MARK: - The budget

  /// Estimated, not measured. `LanguageModelSession.tokenCount(for:)` is exact
  /// but needs macOS 26.4 and a session that already exists, and this has to be
  /// right as a checkbox is ticked, before there is a session at all.
  nonisolated static func cost(of tool: MCPTool) -> Int {
    (tool.name.count + ToolProbe.summary(of: tool).count + tool.schema.count) / 4
  }

  /// How many arguments a tool insists on.
  ///
  /// The ordering key that matters more than size. A tool with no required
  /// arguments can be called cold; one that wants an id cannot be called until
  /// something else has produced that id, so loading a dozen of those and none
  /// of the tools that list things gives the model a set it cannot start from.
  /// Measured, not theorised: cheapest-first alone loaded fourteen `get_*`
  /// tools on `appstore-connect` and left `list_apps` out.
  nonisolated static func required(of tool: MCPTool) -> Int {
    guard let root = try? JSONSerialization.jsonObject(with: tool.schema) as? [String: Any],
      let names = root["required"] as? [String]
    else { return 0 }
    return names.count
  }

  /// Callable-cold first, then cheapest.
  nonisolated static func before(_ a: MCPTool, _ b: MCPTool) -> Bool {
    let (ra, rb) = (required(of: a) == 0, required(of: b) == 0)
    if ra != rb { return ra }
    return cost(of: a) < cost(of: b)
  }

  var used: Int {
    tools.filter { selected.contains($0.name) }.reduce(0) { $0 + Self.cost(of: $1) }
  }

  var isOverBudget: Bool { used > Self.budget }

  // MARK: - Loading a profile's tools

  func load(profile: Profile, server: BastionServer) {
    guard !isLoading else { return }
    self.profile = profile
    self.server = server
    tools = []
    withheld = []
    unusable = []
    selected = []
    messages = []
    session = nil
    bound = []
    trims = 0
    loadFailure = nil
    isLoading = true

    // `ServerCheck.call` blocks by contract, so it gets a thread rather than a
    // slot in the cooperative pool — the same bargain every other caller makes.
    onDedicatedThread("bastion.chat.tools") { [self] in
      let outcome: Result<[MCPTool], Error>
      do {
        let reply = try ServerCheck.call(
          profile: profile, server: server, era: .legacy, method: "tools/list",
          params: [:], id: 1)
        let listed = reply["tools"] as? [[String: Any]] ?? []
        outcome = .success(listed.compactMap(MCPTool.init(json:)))
      } catch {
        outcome = .failure(error)
      }
      Task { @MainActor in self.finishLoading(outcome) }
    }
  }

  private func finishLoading(_ outcome: Result<[MCPTool], Error>) {
    isLoading = false
    guard let server, let profile else { return }
    switch outcome {
    case .failure(let error):
      loadFailure = error.localizedDescription
    case .success(let listed):
      // The identical gate the deep check uses. Writes off means the server
      // never registered its destructive tools; writes on means only the ones
      // it marks read-only, and a missing mark is never read as a yes.
      let (allowed, excluded) = ToolProbe.select(
        from: listed, under: ToolProbe.eligibility(server: server, profile: profile))
      tools = allowed.sorted(by: Self.before)
      withheld = excluded.map { "\($0.tool) — \($0.reason)" }
      // Greedy over that ordering: fill up with tools the model can actually
      // open with, then spend what is left on the cheapest of the rest.
      var running = 0
      for tool in tools where running + Self.cost(of: tool) <= Self.budget {
        selected.insert(tool.name)
        running += Self.cost(of: tool)
      }
      rebuild()
    }
  }

  // MARK: - The session

  func toggle(_ tool: MCPTool) {
    if selected.contains(tool.name) { selected.remove(tool.name) } else { selected.insert(tool.name) }
    rebuild()
  }

  /// Rebuild from the current selection, discarding the conversation.
  ///
  /// A session's tools are fixed when it is constructed, so changing the
  /// selection cannot be done in place. The transcript goes with it, which is
  /// why the pane says so before calling this.
  func rebuild() {
    guard let profile, let server else { return }
    var built: [any Tool] = []
    var dropped: [String] = []
    for tool in tools where selected.contains(tool.name) {
      do {
        built.append(
          try ToolProbe.bridgeTool(for: tool) { [self] json in
            let call = ToolProbe.invoke(
              tool: tool, argumentsJSON: json, profile: profile, server: server,
              id: callIDs.withLock { $0 += 1; return $0 })
            Task { @MainActor in self.record(call) }
            return call.output
          })
      } catch {
        dropped.append("\(tool.name) — \(error.localizedDescription)")
      }
    }
    unusable = dropped
    bound = built
    messages = []
    trims = 0
    session = LanguageModelSession(tools: built) { Self.instructions }
  }

  private static let instructions = """
    You are helping someone try out the tools on one MCP server, through Bastion.

    Use a tool whenever it can answer the question, and prefer small arguments — \
    if a tool takes a limit or a count, ask for a few rather than many. If no \
    tool fits, say so plainly instead of guessing an answer.

    Keep replies short. Report what a tool returned rather than describing what \
    you are about to do, and if a call fails, say what the error was.
    """

  // MARK: - Talking

  func send(_ text: String) {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, session != nil, !isResponding else { return }
    messages.append(Message(role: .you, text: prompt))
    messages.append(Message(role: .model, text: ""))
    isResponding = true
    Task {
      await respond(to: prompt, at: messages.count - 1, retrying: false)
      isResponding = false
    }
  }

  private func respond(to prompt: String, at index: Int, retrying: Bool) async {
    guard let session, messages.indices.contains(index) else { return }
    do {
      for try await snapshot in session.streamResponse(
        to: prompt, options: GenerationOptions(sampling: .greedy))
      {
        guard messages.indices.contains(index) else { return }
        messages[index].text = snapshot.content
      }
    } catch let error as LanguageModelSession.GenerationError {
      // Overflow is the expected end of a long conversation here, not a fault:
      // 1800 tokens of tools leaves around 2000 for everything else, and one
      // fat tool result spends a good part of it. Drop the oldest turns and try
      // once more; a second failure is a real one.
      if case .exceededContextWindowSize = error, !retrying, trimTranscript() {
        await respond(to: prompt, at: index, retrying: true)
        return
      }
      messages[index].failure = error.localizedDescription
    } catch {
      messages[index].failure = error.localizedDescription
    }
  }

  private func record(_ call: ToolProbe.Call) {
    guard let index = messages.indices.last else { return }
    messages[index].calls.append(call)
  }

  /// Drop the oldest exchange, keeping the instructions, and rebuild.
  private func trimTranscript() -> Bool {
    guard let session else { return false }
    var entries = Array(session.transcript)
    let instructions = entries.filter { if case .instructions = $0 { true } else { false } }
    entries.removeAll { if case .instructions = $0 { true } else { false } }
    guard entries.count > 2 else { return false }
    entries.removeFirst(2)
    trims += 1
    self.session = LanguageModelSession(
      tools: bound, transcript: Transcript(entries: instructions + entries))
    return true
  }

  func clear() {
    guard session != nil else { return }
    rebuild()
  }
}

#if DEBUG
  extension ChatSession {
    /// Hold one exchange from the command line and print what happened.
    ///
    /// `Bastion --chat=prod/appstore-connect --ask="which apps do I have?"`.
    ///
    /// Same argument as `ServerCheck.runHeadless`: the pane cannot be clicked by
    /// a script, and everything interesting here — which tools survive the
    /// budget, whether their schemas convert, whether the model actually reaches
    /// the server — is invisible from outside the window.
    static func runHeadless(_ argument: String, asking question: String?) {
      let parts = argument.split(separator: "/", maxSplits: 1).map(String.init)
      guard parts.count == 2,
        let server = ServerStore.lookup(parts[1]),
        let profile = ProfileStore.lookup(name: parts[0], server: parts[1])
      else {
        FileHandle.standardError.write(
          Data("no profile '\(argument)' — expected <profile>/<server>\n".utf8))
        exit(2)
      }

      let chat = ChatSession()
      Task { @MainActor in
        if case .unavailable(let why) = ToolProbe.availability {
          print("the on-device model is unavailable: \(why)")
          leave(1)
        }

        chat.load(profile: profile, server: server)
        while chat.isLoading { try? await Task.sleep(for: .milliseconds(100)) }
        if let failure = chat.loadFailure {
          print("could not load tools: \(failure)")
          leave(1)
        }

        let total = chat.tools.count
        print("\n\(argument) — \(total) eligible tool(s), budget \(ChatSession.budget) tokens")
        print("  loaded \(chat.selected.count), costing \(chat.used):")
        for tool in chat.tools where chat.selected.contains(tool.name) {
          print("    \(String(format: "%5d", cost(of: tool)))  \(tool.name)")
        }
        let unloaded = chat.tools.filter { !chat.selected.contains($0.name) }
        if !unloaded.isEmpty {
          print("  did not fit (\(unloaded.count)):")
          for tool in unloaded.prefix(5) {
            print("    \(String(format: "%5d", cost(of: tool)))  \(tool.name)")
          }
          if unloaded.count > 5 { print("    … and \(unloaded.count - 5) more") }
        }
        if !chat.withheld.isEmpty { print("  withheld by the write gate: \(chat.withheld.count)") }
        for line in chat.unusable { print("  unusable schema: \(line)") }

        guard let question else { leave(0) }
        print("\n> \(question)")
        chat.send(question)
        while chat.isResponding { try? await Task.sleep(for: .milliseconds(100)) }

        for message in chat.messages where message.role == .model {
          for call in message.calls {
            print(
              "  \(call.failed ? "FAIL" : "OK  ") \(call.tool) \(call.arguments)"
                + String(format: "  (%.2fs)", call.seconds))
            print("       \(call.output.prefix(160).replacingOccurrences(of: "\n", with: " "))")
          }
          if let failure = message.failure { print("  ! \(failure)") }
          if !message.text.isEmpty { print("\n  model: \(message.text)") }
        }
        if chat.trims > 0 { print("\n  (transcript trimmed \(chat.trims)x to fit)") }
        leave(0)
      }
    }

    /// Stop the children before going: `exit` unwinds nothing.
    private static func leave(_ code: Int32) -> Never {
      Supervisor.shared.stopAll()
      exit(code)
    }
  }
#endif
