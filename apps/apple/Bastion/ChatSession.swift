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
/// **The context window is the design.** `SystemLanguageModel.contextSize`
/// covers the instructions, every tool schema, the whole conversation and the
/// reply. It reads 4096 on the model this pane was built against, and measured
/// against the real catalogue one server does not fit at that size:
/// `appstore-connect` with writes off exposes 47 tools whose schemas come to
/// roughly 12,300 tokens, three times the entire window; `x` needs 4,900.
/// At about 260 tokens each, a workable set is seven or eight tools.
///
/// So at 4096 "load all the tools" is not a thing that can be built — not a
/// hard thing, an impossible one — and the honest response is to show the
/// arithmetic rather than hide it. Hence a budget, a per-tool cost, and a list
/// where the tools that did not fit stay visible with the reason.
///
/// That number is no longer a constant, which is why nothing here hardcodes it
/// any more: `contextSize` is a property of the model, and a later one reports
/// a larger window. Everything below scales off whatever it reads, so the pane
/// widens on its own rather than continuing to quote a figure that has stopped
/// being true.
@Observable
final class ChatSession {

  /// The whole window the model holds, in tokens.
  ///
  /// No `#available` guard: `contextSize` is declared `macOS 26.0` and carries
  /// `@backDeployed(before: macOS 26.4)`, so the compiler emits a fallback that
  /// runs on 26.0–26.3 and this is safe at the deployment target.
  ///
  /// Fixed under a capture, and that is the same argument
  /// `ToolProbe.availability` makes for short-circuiting there: a screenshot
  /// whose budget line is read off whichever Mac took it is machine-dependent,
  /// and this one has to keep working on a runner with no Apple Intelligence at
  /// all — where there is no model to ask.
  static var contextSize: Int {
    DemoSeed.isEnabled ? 4096 : measuredContextSize
  }

  /// Asked once. The model cannot change mid-launch, and this is read twice per
  /// header render — which, before the header was a view of its own, meant
  /// twice per streamed token.
  private static let measuredContextSize = SystemLanguageModel.default.contextSize

  /// Tokens of tool schema the conversation is allowed to carry.
  ///
  /// Deliberately well under `contextSize`: what is left has to hold the
  /// instructions, the questions, the answers, and one tool result, which is
  /// itself capped at 2000 characters by `ToolProbe.invoke`.
  ///
  /// Written as the ratio the pane shipped with rather than a percentage, so it
  /// is exactly 1800 at 4096 and scales from there — 3600 at 8192. A rounded
  /// 44% would come to 1802 and quietly move which tools fit.
  static var budget: Int { contextSize * 1800 / 4096 }

  enum Role: Sendable, Equatable { case you, model }

  struct Message: Identifiable, Equatable {
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

  /// The tool a reply is currently waiting on, for the composer to name. A call
  /// can block for `Supervisor.callTimeout` — three minutes — and a spinner
  /// that does not say what it is waiting for is indistinguishable from a hang.
  private(set) var activeTool: String?

  /// One counter the transcript watches, and the only thing deciding how often
  /// it scrolls.
  ///
  /// Three separate mutations mean "there is more to see" — a token, a recorded
  /// call, a new message — and the pane watched two of them, so a tool call
  /// arriving mid-answer scrolled nothing at all. Watching all three separately
  /// would be the same bug with more edges.
  ///
  /// Throttled here rather than in the view, because the view cannot throttle
  /// what it is not told about: all it can do is animate less per token, which
  /// is the pile of overlapping animations this replaces.
  private(set) var revision = 0
  private var lastPulse = ContinuousClock.now

  private func pulse(force: Bool = false) {
    let now = ContinuousClock.now
    guard force || now - lastPulse >= .milliseconds(100) else { return }
    lastPulse = now
    revision &+= 1
  }

  /// Whether there is a conversation to lose.
  ///
  /// A stored `Bool` rather than `messages.isEmpty` at the call site: reading
  /// `messages` from the header would subscribe the header — profile picker,
  /// budget line, banners — to every token of every reply, and the picker's
  /// list is a flatMap over every server crossed with every profile.
  private(set) var hasTranscript = false

  // MARK: - What belongs to the conversation rather than to the pane

  /// The question being typed.
  ///
  /// Here and not in the pane for two reasons: a half-typed question should
  /// survive a look at the Log, and `send` refuses on a condition the pane
  /// cannot test, so the pane is the wrong place to decide whether the field
  /// may be cleared. See `submit()`.
  var draft = ""

  /// Whether the writes-enabled warning has been acknowledged for this profile.
  ///
  /// Reset by `load`, and only by `load`. It used to live in the pane, so it
  /// reset on every navigation — and since it also gates sending, the orange
  /// banner came back and blocked the composer every time somebody glanced at
  /// another pane and returned.
  var acknowledgedWrites = false

  /// A profile the user has asked to switch to, waiting on the confirmation
  /// that the current conversation may be discarded.
  var pendingSwitch: ChatRequest.Pending?

  private var session: LanguageModelSession?
  private var bound: [any Tool] = []

  private struct TurnState {
    /// Which conversation a write belongs to. Bumped by everything that
    /// replaces `messages` wholesale, which is what makes a write from an
    /// abandoned turn *detectable* rather than merely unlikely.
    var era = 0
    /// Tool calls made by the turn in progress.
    var calls = 0
    var nextID = 1000
  }

  /// The era, the per-turn call count and the call id, under one lock.
  ///
  /// One lock rather than three because they are read from the same place: the
  /// bridged tools' `perform` closures run on a dedicated thread and cannot
  /// touch main-actor state. The id counter was already here for exactly that
  /// reason; the other two join it.
  private nonisolated let turnState = OSAllocatedUnfairLock(initialState: TurnState())

  private nonisolated var era: Int { turnState.withLock { $0.era } }

  /// Everything the running turn has not written yet is now stale.
  private func endEra() {
    turnState.withLock {
      $0.era += 1
      $0.calls = 0
    }
  }

  /// Take a slot for one tool call, or refuse. Off the main actor, because the
  /// bridged closures are.
  private nonisolated func claim() -> (era: Int, id: Int)? {
    turnState.withLock { state in
      guard state.calls < Self.callsPerTurn else { return nil }
      state.calls += 1
      state.nextID += 1
      return (state.era, state.nextID)
    }
  }

  /// The task following the current turn, so it can be let go of. Held here and
  /// not in the pane: the pane is the thing that gets destroyed.
  private var turn: Task<Void, Never>?

  /// Tool calls one question may make.
  ///
  /// Every call's output can be 2000 characters (`ToolProbe.render`), so a
  /// handful of them is the rest of the context. And a model looping on a
  /// failing tool could spend six times `Supervisor.callTimeout` — three
  /// minutes each — before anybody could type again.
  ///
  /// `nonisolated`, because the two places that enforce it — `claim()` and the
  /// bridged closure that calls it — both run off the main actor. Left
  /// main-actor isolated by the project's default, reading it from there is a
  /// warning today and an error under Swift 6.
  nonisolated static let callsPerTurn = 6

  /// What a stopped row says.
  ///
  /// It has to say something, because `reseat()` drops the stopped question
  /// from what the model remembers while its row stays on screen. Unexplained,
  /// that divergence reads as a model with amnesia.
  static let stopped = "Stopped. This question was dropped from what the model remembers."

  /// The cap the deep check has always had (`ToolProbe.run`, 300 tokens) and
  /// chat never did. Without one, a model that starts enumerating spends the
  /// rest of the window on it and then throws `exceededContextWindowSize` —
  /// which the trim path dutifully absorbs, so the only symptom is a
  /// conversation that has forgotten its own opening for no visible reason. The
  /// instructions already ask for short replies; this is the same request the
  /// model cannot talk itself out of.
  private static let options = GenerationOptions(
    sampling: .greedy, maximumResponseTokens: 400)

  /// Set by `DemoSeed.chat()` only.
  ///
  /// A demo session cannot have a real one: `LanguageModelSession` is
  /// unconstructible on a Mac without Apple Intelligence, which is exactly the
  /// machine this has to keep working on. So readiness is widened by one flag
  /// rather than faked with an object — `send` still guards on `session != nil`
  /// and does nothing, which is correct: nothing types into this pane under a
  /// capture.
  private var demoReady = false

  var isReady: Bool { session != nil || demoReady }

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

  /// A session with a completed exchange in it, for `DemoSeed` only.
  ///
  /// It fills the same fields `load` and `finishLoading` do, in the same order,
  /// and stops short of `rebuild()` — which is the one step that needs a model.
  /// `used` is deliberately NOT set: it is computed off `cost(of:)` against the
  /// fixture schemas, so the budget line in the header is a claim the fixture
  /// has to satisfy rather than a number typed into a screenshot.
  func adoptDemo(
    profile: Profile, server: BastionServer, tools: [MCPTool], selected: Set<String>,
    withheld: [String], messages: [Message]
  ) {
    self.profile = profile
    self.server = server
    self.tools = tools.sorted(by: Self.before)
    self.selected = selected
    self.withheld = withheld
    self.messages = messages
    hasTranscript = !messages.isEmpty
    demoReady = true
  }

  // MARK: - Loading a profile's tools

  func load(profile: Profile, server: BastionServer) {
    guard !isLoading else { return }
    // A reply can still be arriving into the conversation this is about to
    // throw away — the confirmation dialog is answerable mid-stream.
    abandon(noting: false)
    acknowledgedWrites = false
    pendingSwitch = nil
    self.profile = profile
    self.server = server
    tools = []
    withheld = []
    unusable = []
    selected = []
    messages = []
    hasTranscript = false
    session = nil
    bound = []
    trims = 0
    loadFailure = nil
    isLoading = true
    pulse(force: true)

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
    // Rebuilding discards the conversation, and a reply in flight is writing
    // into it. The popover disables these too; that is the explanation, this is
    // the invariant.
    guard !isResponding else { return }
    if selected.contains(tool.name) {
      selected.remove(tool.name)
    } else {
      selected.insert(tool.name)
    }
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
            // The era is read here rather than captured when this closure is
            // built. `bound` outlives a Stop — `reseat()` reuses it — so a
            // build-time era would be stale for the next turn and would
            // silently drop every call that turn made.
            guard let claim = claim() else {
              return "refused: this question has already used its "
                + "\(Self.callsPerTurn) tool calls. Answer with what the "
                + "previous calls returned."
            }
            Task { @MainActor in self.note(waitingOn: tool.name, era: claim.era) }
            let call = ToolProbe.invoke(
              tool: tool, argumentsJSON: json, profile: profile, server: server, id: claim.id)
            Task { @MainActor in self.record(call, era: claim.era) }
            return call.output
          })
      } catch {
        dropped.append("\(tool.name) — \(error.localizedDescription)")
      }
    }
    unusable = dropped
    bound = built
    endEra()
    messages = []
    hasTranscript = false
    trims = 0
    session = LanguageModelSession(tools: built) { Self.instructions }
    pulse(force: true)
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

  @discardableResult
  func send(_ text: String) -> Bool {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, session != nil, !isResponding else { return false }
    messages.append(Message(role: .you, text: prompt))
    messages.append(Message(role: .model, text: ""))
    hasTranscript = true
    isResponding = true
    turnState.withLock { $0.calls = 0 }
    pulse(force: true)

    let stamp = era
    let index = messages.count - 1
    turn = Task { [self] in
      await respond(to: prompt, at: index, era: stamp, retrying: false)
      // An orphan must not unwind a turn that is no longer its own: `stop` has
      // already done that, and may have started another since.
      guard stamp == era else { return }
      isResponding = false
      activeTool = nil
      turn = nil
      pulse(force: true)
    }
    return true
  }

  /// Send what is typed, and clear the field only if it was taken.
  ///
  /// `send` refuses on three conditions and the pane's `canSend` mirrors two of
  /// them — `session != nil` is the one it cannot see, since `demoReady` makes
  /// `isReady` true with no session behind it. Clearing regardless is how a
  /// refused question used to vanish as though it had been asked.
  func submit() {
    if send(draft) { draft = "" }
  }

  /// Stream one reply into `messages[index]`.
  ///
  /// The index is an identity only for as long as the era holds, and that is
  /// enough. Within one era `messages` only ever grows, and only in `send`,
  /// which is gated on `!isResponding`; everything that replaces the array
  /// wholesale — `load`, `rebuild`, `stop` — ends the era first. So a stamp
  /// that still matches means the index still points at the same message, and
  /// no `firstIndex(where:)` per token is needed to prove it.
  private func respond(to prompt: String, at index: Int, era stamp: Int, retrying: Bool) async {
    guard let session, stamp == era, messages.indices.contains(index) else { return }
    do {
      for try await snapshot in session.streamResponse(to: prompt, options: Self.options) {
        guard stamp == era, messages.indices.contains(index) else { return }
        messages[index].text = snapshot.content
        pulse()
      }
      pulse(force: true)
    } catch let error as LanguageModelSession.GenerationError {
      // Overflow is the expected end of a long conversation here, not a fault:
      // the tool budget is a little under half the window, so what is left for
      // everything else is about the same again, and one fat tool result spends
      // a good part of it. Drop the oldest turns and try once more; a second
      // failure is a real one.
      if case .exceededContextWindowSize = error, !retrying, stamp == era, trimTranscript() {
        await respond(to: prompt, at: index, era: stamp, retrying: true)
        return
      }
      fail(error.localizedDescription, at: index, era: stamp)
    } catch {
      fail(error.localizedDescription, at: index, era: stamp)
    }
  }

  /// The one place a failure is written, so there is one place the guard has to
  /// be right. Both catch arms above used to write the subscript themselves and
  /// neither checked it — which was the whole bug, twice over.
  private func fail(_ message: String, at index: Int, era stamp: Int) {
    // A stopped turn is not a failed one, and the framework is free to report
    // cancellation as whatever error it likes — so the question asked here is
    // "is this still the current turn", never "which error is this".
    guard stamp == era, !Task.isCancelled, messages.indices.contains(index) else { return }
    messages[index].failure = message
    pulse(force: true)
  }

  private func note(waitingOn tool: String, era stamp: Int) {
    guard stamp == era else { return }
    activeTool = tool
  }

  private func record(_ call: ToolProbe.Call, era stamp: Int) {
    guard stamp == era, let index = messages.indices.last else { return }
    messages[index].calls.append(call)
    activeTool = nil
    // A recorded call changes neither `messages.count` nor the last message's
    // text, so before there was one counter to watch it scrolled nothing at all
    // and the call block grew under the fold.
    pulse(force: true)
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
    guard session != nil, !isResponding else { return }
    rebuild()
  }

  // MARK: - Letting go

  /// Stop following the current turn. It is abandoned, not cancelled.
  ///
  /// `Task.cancel()` is sent, and is honoured wherever the framework happens to
  /// be between tokens. The expensive place to be stuck is inside a tool call,
  /// and that one cannot be cancelled by anybody: `ToolProbe.MCPBridgeTool.call`
  /// parks on `withCheckedContinuation` — not `withTaskCancellationHandler` —
  /// around `Supervisor.call`, which ends in a semaphore with no local deadline.
  /// The supervisor's reaper owns that deadline and resolves it at
  /// `callTimeout`, up to three minutes from now, and waiting for that IS the
  /// dead composer this exists to remove.
  ///
  /// So nothing here waits. The era ends, the pane unwinds now, and the thread
  /// still blocked in the child finishes into a conversation with no slot left
  /// for what it produces. That costs one 512KB thread and one answer nobody
  /// reads. It cannot cost correctness, because every write that turn can still
  /// make — a token, a call, a failure — carries an era that is over.
  func stop() {
    guard isResponding else { return }
    abandon(noting: true)
    reseat()
    pulse(force: true)
  }

  /// Let go of the running turn.
  ///
  /// `noting` marks the row on screen, which `stop` wants and a wholesale reset
  /// does not — there, the row is about to go with everything else.
  private func abandon(noting: Bool) {
    turn?.cancel()
    turn = nil
    if noting, let index = messages.indices.last, messages[index].role == .model {
      messages[index].failure = Self.stopped
    }
    endEra()
    isResponding = false
    activeTool = nil
  }

  /// A session of the conversation's own, since the old one belongs to a turn
  /// that has been let go of and may still be generating into it. Asking a busy
  /// `LanguageModelSession` is an error rather than a queue, so without this the
  /// next question after a Stop would fail.
  ///
  /// Truncated at the last completed response, which drops the question that was
  /// stopped: a transcript ending in a prompt with no answer, or in tool calls
  /// with no output, is not one the model's own generator would ever have
  /// produced. It is also why the stopped row says so on screen — the row is
  /// still in the pane, and the model no longer remembers it.
  ///
  /// The same manoeuvre as `trimTranscript()`, and deliberately the same shape.
  private func reseat() {
    guard let session else { return }
    let entries = Array(session.transcript)
    let instructions = entries.filter { if case .instructions = $0 { true } else { false } }
    let body = entries.filter { if case .instructions = $0 { false } else { true } }
    let lastAnswer = body.lastIndex { if case .response = $0 { true } else { false } }
    let kept = lastAnswer.map { Array(body[...$0]) } ?? []
    self.session = LanguageModelSession(
      tools: bound, transcript: Transcript(entries: instructions + kept))
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
        print(
          "\n\(argument) — \(total) eligible tool(s), "
            + "budget \(ChatSession.budget) of \(ChatSession.contextSize) tokens")
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
