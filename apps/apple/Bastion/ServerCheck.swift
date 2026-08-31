import Foundation
import Observation

/// One entry from a live `tools/list`.
///
/// Held as `Data` rather than a dictionary because it crosses a thread
/// boundary: the check runs on its own thread and hands its result back to the
/// main actor, and `[String: Any]` cannot make that trip.
///
/// Nothing else in the app has ever held one of these. `servers.json` describes
/// a *package*, and its schema is `additionalProperties: false` with no place
/// to put tools — so what a server actually exposes is knowable only by asking
/// it, which is most of the point of this file.
nonisolated struct MCPTool: Identifiable, Sendable {
  let name: String
  let summary: String
  /// The server's own JSON Schema for this tool's arguments, as it arrived.
  let schema: Data
  /// `annotations.readOnlyHint`, and `nil` when the server did not say.
  ///
  /// The absence is meaningful and is never read as "no": a server that
  /// declares nothing is treated as though every tool writes.
  let readOnlyHint: Bool?

  var id: String { name }

  init?(json: [String: Any]) {
    guard let name = json["name"] as? String else { return nil }
    self.name = name
    let annotations = json["annotations"] as? [String: Any]
    summary =
      json["description"] as? String
      ?? annotations?["title"] as? String
      ?? json["title"] as? String
      ?? ""
    let raw = json["inputSchema"] as? [String: Any] ?? [:]
    schema = (try? JSONSerialization.data(withJSONObject: raw)) ?? Data("{}".utf8)
    readOnlyHint = annotations?["readOnlyHint"] as? Bool
  }
}

/// Proof that a profile can actually start its server.
///
/// `ProfileRow` used to end on "ready — starts on the first request that needs
/// it". That was a claim about a code path nothing in the app had ever walked.
/// The first thing that tested it was somebody else's editor reporting
/// "Connection closed" with the child's stderr swallowed — the precise failure
/// `ProfileEnvironment.missing` exists to pre-empt, surfacing in the one place
/// Bastion cannot say a sentence about it.
///
/// None of the machinery here is new. `Supervisor.call` already spawns the
/// child, takes the handshake once and speaks JSON-RPC; the child's stderr
/// already lands in `LogStore` tagged with this profile's id. What was missing
/// was a caller, and somewhere to show what came back.
///
/// **Not licence-gated, deliberately.** The gate at `Gateway.swift:278` gates
/// the *relay* — a client using Bastion to reach a server. A self-check is not
/// a relay: the frames are Bastion's own, the user picks neither the method nor
/// the arguments, and refusing to tell an unlicensed user why their server will
/// not start would make the licence look like the cause.
@Observable
final class ServerCheck {
  static let shared = ServerCheck()

  /// The name these calls are attributed to in the Activity window.
  ///
  /// Its own identity rather than a borrowed one. A check is Bastion talking to
  /// itself, and letting it authenticate as a real client would put calls
  /// nobody made into the window whose whole job is saying who made them.
  nonisolated static let client = "Bastion (self-check)"

  enum Kind: String, CaseIterable, Sendable {
    case configured, handshake, tools, discover

    var label: String {
      switch self {
      case .configured: "Profile is configured"
      case .handshake: "Server starts and completes the handshake"
      case .tools: "Server lists its tools"
      case .discover: "Bastion can answer server/discover"
      }
    }
  }

  enum Outcome: Sendable {
    case pending
    case running
    case passed(String)
    /// It worked, and something about it should still be said out loud.
    case warned(String, why: String)
    case failed(String)
    case skipped(String)

    var isFailure: Bool {
      if case .failed = self { return true }
      return false
    }
  }

  struct Step: Identifiable, Sendable {
    let kind: Kind
    var outcome: Outcome = .pending
    var seconds: TimeInterval?

    var id: String { kind.rawValue }
  }

  struct Run: Sendable {
    let profileID: String
    /// When the button was pressed. The log pane shows only what came after, so
    /// a check reads as an account of itself rather than of the whole day.
    let startedAt: Date
    var steps: [Step]
    var finishedAt: Date?
    /// The live `tools/list`. Kept because the deep check needs it and because
    /// nothing else in the app caches one.
    var tools: [MCPTool] = []
    /// Whether the child was already up when the check began. The difference
    /// between "started in 1.9s" and "already running" is most of what the
    /// handshake timing means.
    var wasWarm = false

    var isRunning: Bool { finishedAt == nil }
    var failed: Bool { steps.contains { $0.outcome.isFailure } }

    subscript(kind: Kind) -> Step? { steps.first { $0.kind == kind } }
  }

  /// Keyed by `profile.id`, and kept after the sheet closes so the row can go
  /// on reporting what was measured instead of what was assumed.
  ///
  /// Never persisted. A check result written to disk becomes a confident claim
  /// about a machine state that has since moved on, which is the same argument
  /// `ServerInstaller.installedVersion` makes for reading rather than
  /// remembering.
  private(set) var runs: [String: Run] = [:]
  private(set) var probes: [String: ToolProbe.Result] = [:]

  func run(for profile: Profile) -> Run? { runs[profile.id] }
  func isRunning(_ profile: Profile) -> Bool { runs[profile.id]?.isRunning == true }

  func setProbe(_ probe: ToolProbe.Result?, for profileID: String) {
    probes[profileID] = probe
  }

  // MARK: - Driving a check

  func start(profile: Profile, server: BastionServer) {
    guard !isRunning(profile) else { return }

    // `server/discover` is Bastion's to answer only on the modern era. Asking a
    // legacy child for it earns a -32601 that says nothing about the server.
    var kinds: [Kind] = [.configured, .handshake, .tools]
    if server.dialect.isModern { kinds.append(.discover) }

    probes[profile.id] = nil
    runs[profile.id] = Run(
      profileID: profile.id, startedAt: Date(),
      steps: kinds.map { Step(kind: $0) },
      wasWarm: Supervisor.shared.running.contains { $0.id == profile.id })

    // A dedicated thread, not `Task.detached`. `Supervisor.call` blocks by
    // contract — its own comment says so — and a detached task still spends a
    // slot in the cooperative pool, which is exactly what `onDedicatedThread`
    // was written to keep blocking work out of.
    onDedicatedThread("bastion.check") {
      Self.perform(profile: profile, server: server)
    }
  }

  // MARK: - The check itself, off the main actor

  nonisolated private static func perform(profile: Profile, server: BastionServer) {
    let id = profile.id

    // 1 — configured. Cheap, local, and worth doing first: a profile missing a
    // credential cannot pass anything below, and spawning it anyway would only
    // feed the circuit breaker a failure whose cause the user already knows.
    post(id, .configured, .running)
    let missing = ProfileEnvironment.missing(for: profile, server: server)
    guard missing.isEmpty else {
      post(id, .configured, .failed("missing \(missing.joined(separator: ", "))"))
      let reason = "the profile is not configured"
      post(id, .handshake, .skipped(reason))
      post(id, .tools, .skipped(reason))
      post(id, .discover, .skipped(reason))
      finish(id)
      return
    }
    post(id, .configured, .passed("every required variable is set"))

    // 2 — spawn and handshake, as one timed step.
    //
    // A legacy `initialize`, because `handshakeReply` opens with
    // `ensureRunning()`: the frame spawns the child and runs the real handshake
    // before it is answered from the cache. So this is not a proxy for the
    // handshake, it is the handshake, taken through the same seam every real
    // MCP client uses today.
    post(id, .handshake, .running)
    let began = Date()
    let handshake: [String: Any]
    do {
      handshake = try call(
        profile: profile, server: server, era: .legacy, method: "initialize",
        params: [
          "protocolVersion": Dialect.latest.rawValue,
          "capabilities": [:],
          "clientInfo": ["name": "bastion-check", "version": AppInfo.version],
        ], id: 1)
    } catch {
      post(id, .handshake, .failed(describe(error)), seconds: Date().timeIntervalSince(began))
      post(id, .tools, .skipped("the server never completed its handshake"))
      post(id, .discover, .skipped("the server never completed its handshake"))
      finish(id)
      return
    }
    let handshakeSeconds = Date().timeIntervalSince(began)

    let info = handshake["serverInfo"] as? [String: Any]
    let negotiated = handshake["protocolVersion"] as? String
    // A remote server has no binary to fall back to, so it falls back to the
    // host it answers on — which is the useful thing to see anyway.
    var identity =
      (info?["name"] as? String) ?? server.package?.binName ?? server.endpoint?.host() ?? server.id
    if let version = info?["version"] as? String { identity += " \(version)" }
    if let pid = livePID(id) { identity += " · pid \(pid)" }

    // The one line in this sheet most likely to teach somebody something.
    // `Supervisor` already logs this drift to stderr and nowhere else — the
    // manifest said 2025-06-18 for every server until a live handshake showed
    // they all negotiate 2025-11-25. A warning, never a failure: the server is
    // working, the catalog is simply describing it wrongly.
    if let negotiated, negotiated != server.dialect.rawValue {
      post(
        id, .handshake,
        .warned(
          "\(identity) · negotiated \(negotiated)",
          why:
            "servers.json says this server speaks \(server.dialect.rawValue), but it negotiated "
            + "\(negotiated). Bastion is using \(negotiated); the manifest is out of date."),
        seconds: handshakeSeconds)
    } else {
      post(
        id, .handshake,
        .passed(identity + (negotiated.map { " · protocol \($0)" } ?? "")),
        seconds: handshakeSeconds)
    }

    // 3 — what it actually exposes.
    post(id, .tools, .running)
    let listBegan = Date()
    let listed: [String: Any]
    do {
      listed = try call(
        profile: profile, server: server, era: .legacy, method: "tools/list", params: [:], id: 2)
    } catch {
      post(id, .tools, .failed(describe(error)), seconds: Date().timeIntervalSince(listBegan))
      post(id, .discover, .skipped("the tool list could not be read"))
      finish(id)
      return
    }
    let listSeconds = Date().timeIntervalSince(listBegan)

    guard let entries = listed["tools"] as? [[String: Any]] else {
      post(id, .tools, .failed("the reply had no 'tools' array"), seconds: listSeconds)
      post(id, .discover, .skipped("the tool list could not be read"))
      finish(id)
      return
    }
    let tools = entries.compactMap(MCPTool.init(json:))
    let readable = tools.filter { $0.readOnlyHint == true }.count
    var summary = "\(tools.count) tool\(tools.count == 1 ? "" : "s")"
    if readable > 0 { summary += ", \(readable) marked read-only" }
    Task { @MainActor in ServerCheck.shared.runs[id]?.tools = tools }

    // Said rather than silently under-reported: a paginated list means the
    // count above is a floor, and a count presented as a total would be wrong.
    if listed["nextCursor"] != nil {
      post(
        id, .tools,
        .warned(
          summary,
          why: "the list is paginated and the check reads only the first page, so there are more."),
        seconds: listSeconds)
    } else {
      post(id, .tools, .passed(summary), seconds: listSeconds)
    }

    // 4 — modern servers only. Bastion answers this one itself, out of the
    // handshake it cached at spawn, so a failure here means that cache is gone
    // — a different and more alarming thing than a server declining a method.
    guard server.dialect.isModern else {
      finish(id)
      return
    }
    post(id, .discover, .running)
    let discoverBegan = Date()
    do {
      let discovered = try call(
        profile: profile, server: server, era: .modern(server.dialect),
        method: "server/discover", params: [:], id: 3)
      let versions = (discovered["supportedVersions"] as? [String]) ?? []
      post(
        id, .discover,
        .passed(
          versions.isEmpty
            ? "answered from the cached handshake"
            : "answered · offers \(versions.joined(separator: ", "))"),
        seconds: Date().timeIntervalSince(discoverBegan))
    } catch {
      post(
        id, .discover, .failed(describe(error)),
        seconds: Date().timeIntervalSince(discoverBegan))
    }
    finish(id)
  }

  // MARK: - Talking to the supervisor

  /// One request/response against the real supervised child.
  ///
  /// Deliberately the same path a client takes, rather than a private throwaway
  /// process: a check that spawned its own child would prove something about a
  /// server Bastion is not running, which is not the question anybody is asking.
  ///
  /// `era` is the *client's* dialect, not the server's — it selects which front
  /// `Instance.handle` applies. `initialize` must go through the legacy front
  /// or it is answered with -32601 instead of a handshake.
  nonisolated static func call(
    profile: Profile, server: BastionServer, era: Dialect.Era, method: String,
    params: [String: Any]? = nil, id: Int
  ) throws -> [String: Any] {
    var frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    if let params { frame["params"] = params }

    guard
      let data = try Supervisor.shared.call(
        profile: profile.name, server: server.id, frame: frame, era: era, client: client)
    else {
      throw CheckError.noReply(method)
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw CheckError.malformedReply(method)
    }
    if let failure = object["error"] as? [String: Any] {
      throw CheckError.rpc(
        method: method,
        code: failure["code"] as? Int,
        message: failure["message"] as? String ?? "no message")
    }
    guard let result = object["result"] as? [String: Any] else {
      throw CheckError.malformedReply(method)
    }
    return result
  }

  enum CheckError: LocalizedError {
    case noReply(String)
    case malformedReply(String)
    case rpc(method: String, code: Int?, message: String)

    var errorDescription: String? {
      switch self {
      case .noReply(let method):
        return "the server answered '\(method)' with nothing at all"
      case .malformedReply(let method):
        return "the server's reply to '\(method)' was not JSON-RPC"
      case .rpc(let method, let code, let message):
        let number = code.map { " (\($0))" } ?? ""
        return "'\(method)' was refused\(number): \(message)"
      }
    }
  }

  /// The sentence to show for a thrown error.
  ///
  /// `SupervisorError` already writes user-facing prose, so it is used as-is —
  /// except where the check knows something a client would not.
  nonisolated private static func describe(_ error: Error) -> String {
    guard let supervisor = error as? Supervisor.SupervisorError else {
      return error.localizedDescription
    }
    let sentence = supervisor.localizedDescription
    switch supervisor {
    case .circuitOpen:
      // Without this it reads as a fresh diagnosis and sends somebody looking
      // for a problem that already happened.
      return sentence + " — this is an earlier failure being remembered, not a new one"
    case .startFailed(let detail) where detail.contains("initialize"):
      // stdout is the JSON-RPC channel and `drainStderr` says so: a child that
      // runs but never answers is nearly always one that printed to stdout.
      return sentence
        + " — the process started but never spoke MCP, which usually means it wrote something "
        + "to stdout that is not a JSON-RPC frame"
    case .childDied:
      return sentence + " — its stderr is in the log below"
    default:
      return sentence
    }
  }

  /// The pid of the child right now, straight from the supervisor's own lock.
  ///
  /// Not `Activity`: that projection is posted asynchronously and is only
  /// eventually true, which is fine for a window somebody is reading and wrong
  /// for a decision being made a microsecond after the call returned.
  nonisolated private static func livePID(_ profileID: String) -> Int32? {
    Supervisor.shared.running.first { $0.id == profileID }.map(\.pid)
  }

  // MARK: - Back to the main actor

  nonisolated private static func post(
    _ profileID: String, _ kind: Kind, _ outcome: Outcome, seconds: TimeInterval? = nil
  ) {
    Task { @MainActor in
      ServerCheck.shared.apply(profileID, kind, outcome, seconds: seconds)
    }
  }

  nonisolated private static func finish(_ profileID: String) {
    Task { @MainActor in
      ServerCheck.shared.runs[profileID]?.finishedAt = Date()
    }
  }

  private func apply(_ profileID: String, _ kind: Kind, _ outcome: Outcome, seconds: TimeInterval?)
  {
    guard var run = runs[profileID], let index = run.steps.firstIndex(where: { $0.kind == kind })
    else { return }
    run.steps[index].outcome = outcome
    if let seconds { run.steps[index].seconds = seconds }
    runs[profileID] = run
  }
}

#if DEBUG
  extension ServerCheck {
    /// Run one check from the command line and print what it found.
    ///
    /// `Bastion --check=prod/shopify [--probe]`.
    ///
    /// Bastion is `LSUIElement` and this feature lives behind a button in a
    /// sheet, so without a flag the one path that spawns a child, handshakes and
    /// reads its tools could only ever be exercised by hand — which is the same
    /// argument `--pane=` and `--trial` already make for themselves, and the
    /// same reason `scripts/wiring-check.swift` exists.
    static func runHeadless(_ argument: String, probing: Bool) {
      let parts = argument.split(separator: "/", maxSplits: 1).map(String.init)
      guard parts.count == 2,
        let server = ServerStore.lookup(parts[1]),
        let profile = ProfileStore.lookup(name: parts[0], server: parts[1])
      else {
        FileHandle.standardError.write(
          Data("no profile '\(argument)' — expected <profile>/<server>\n".utf8))
        exit(2)
      }

      shared.start(profile: profile, server: server)
      Task { @MainActor in
        while shared.isRunning(profile) { try? await Task.sleep(for: .milliseconds(100)) }
        guard let run = shared.run(for: profile) else { leave(3) }

        print("\n\(profile.name)/\(server.id) — \(run.wasWarm ? "already running" : "cold start")")
        for step in run.steps { print("  " + line(for: step)) }
        for tool in run.tools {
          let mark = tool.readOnlyHint == true ? "r/o" : (tool.readOnlyHint == false ? "rw " : "  ?")
          print("    \(mark)  \(tool.name)")
        }

        if probing, !run.tools.isEmpty {
          let result = await ToolProbe.run(profile: profile, server: server, tools: run.tools)
          print("\n  deep check — \(result.offered) tool(s) offered")
          if let failure = result.failure { print("    ! \(failure)") }
          for call in result.calls {
            print("    \(call.failed ? "FAIL" : "OK  ") \(call.tool) \(call.arguments)")
            print("         \(call.output.prefix(200).replacingOccurrences(of: "\n", with: " "))")
          }
          for skipped in result.skipped { print("    -    \(skipped)") }
          if !result.summary.isEmpty {
            let verdict = result.working.map { $0 ? "[alive]" : "[wrong]" } ?? "[no verdict]"
            print("\n  model \(verdict): \(result.summary)")
          }
        }
        leave(run.failed ? 1 : 0)
      }
    }

    /// Stop the children, then go.
    ///
    /// `exit` runs neither `applicationWillTerminate` nor any `defer` on the way
    /// out, so without this the child a check started outlives the process that
    /// started it — one orphaned node per run, which is the exact leak the
    /// supervisor exists to prevent.
    private static func leave(_ code: Int32) -> Never {
      Supervisor.shared.stopAll()
      exit(code)
    }

    private static func line(for step: Step) -> String {
      let verdict: String
      let detail: String
      switch step.outcome {
      case .pending: (verdict, detail) = ("....", "")
      case .running: (verdict, detail) = ("....", "still running")
      case .passed(let text): (verdict, detail) = ("PASS", text)
      case .warned(let text, let why): (verdict, detail) = ("WARN", "\(text) — \(why)")
      case .failed(let text): (verdict, detail) = ("FAIL", text)
      case .skipped(let text): (verdict, detail) = ("skip", text)
      }
      let timing = step.seconds.map { String(format: " (%.2fs)", $0) } ?? ""
      return "\(verdict)  \(step.kind.rawValue)\(timing)  \(detail)"
    }
  }
#endif
