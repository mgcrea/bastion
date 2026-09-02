import Foundation
import FoundationModels
import os

/// The deep check: let the on-device model actually call a tool.
///
/// A `tools/list` proves a server answers. It does not prove a tool *works* —
/// that a credential is accepted upstream, that a query is well-formed, that
/// what comes back is data rather than an error object with a 200 on it. The
/// only way to know is to call one, and calling one means inventing arguments
/// for a schema nobody wrote down in advance. That is the whole reason a model
/// is here: not to judge the server, but to fill in a form.
///
/// Which is also why the model's prose is the least trustworthy thing this
/// produces, and why `Result` carries every call it made, with arguments and
/// output, as the evidence. The prose is a footnote on that, never a substitute.
///
/// Nothing leaves the machine. `SystemLanguageModel.default` is on-device, and
/// the tool outputs it sees are the same bytes the server just sent Bastion.
enum ToolProbe {

  // MARK: - Can we run at all

  enum Availability: Sendable {
    case ready
    case unavailable(String)
  }

  static var availability: Availability {
    // Otherwise the `chat` plate is a photograph of the feature being ABSENT on
    // whichever Mac took it. `ChatPane` swaps its whole body for the
    // `sparkles.slash` state on an Intel machine, on a CI runner, or on a Mac
    // with Apple Intelligence switched off — so this is not merely wrong, it is
    // machine-dependent, which is worse.
    if DemoSeed.isEnabled { return .ready }
    switch SystemLanguageModel.default.availability {
    case .available:
      return .ready
    case .unavailable(.appleIntelligenceNotEnabled):
      return .unavailable("Apple Intelligence is turned off in System Settings")
    case .unavailable(.deviceNotEligible):
      return .unavailable("this Mac does not support Apple Intelligence")
    case .unavailable(.modelNotReady):
      return .unavailable("the on-device model is still downloading")
    case .unavailable:
      return .unavailable("the on-device model is unavailable")
    }
  }

  /// The same question without the reason, for callers deciding whether to
  /// offer a control at all rather than what to say when they cannot.
  static var isAvailable: Bool {
    if case .ready = availability { return true }
    return false
  }

  // MARK: - What it is allowed to touch

  /// Three independent facts, strongest first.
  ///
  /// The probe reuses the *live supervised child*, which is the point: it
  /// inherits that child's spawn environment, so the write gate is a property
  /// of the running process rather than a promise made in Swift.
  enum Eligibility: Sendable {
    /// The server has no write path at all, or this profile's gate is off. The
    /// child physically cannot write, so any tool is safe to call.
    case anyTool(because: String)
    /// A gate exists and this profile has it open. Nothing structural is
    /// protecting the server now, so only tools that say `readOnlyHint` are
    /// offered — and, because that hint is advisory, only after a confirmation.
    case readOnlyHintsOnly(because: String)

    var needsConfirmation: Bool {
      if case .readOnlyHintsOnly = self { return true }
      return false
    }
  }

  static func eligibility(server: BastionServer, profile: Profile) -> Eligibility {
    // The catalog saying this server has no write path at all — shopify's entry
    // spells it out: "No write gate because there is no write path: every tool
    // is a read."
    //
    // `hasWritePath` rather than `writeGate == nil`, and the difference is not
    // cosmetic here: a remote server carries no gate variable, so the old test
    // called Stripe read-only and handed the model every tool it could see
    // WITHOUT confirmation — including, with writes on, `stripe_api_write` and
    // `create_refund`. A remote server is never read-only by declaration.
    if !server.hasWritePath {
      return .anyTool(because: "this server has no write path — every tool is a read")
    }
    // `ProfileEnvironment.build` writes the gate unconditionally in both
    // directions, and forces every bypass variable to "0" after it.
    //
    // And the servers do not merely refuse a write when that flag is off —
    // they never register the tool. `mcp-appstore-connect` guards twelve of its
    // tool files with a bare `if (!allowWrites) return;`, and `mcp-x` says
    // it outright: "Registered only when both flags are on, so with the
    // defaults these tools do not exist at all." So the model is not declined a
    // destructive tool; there is no such tool in the child's dispatch table for
    // it to name.
    if !profile.allowWrites {
      // Both transports are safe here, for different mechanisms, so the reason
      // has to say which one: a child never registers the tool, and a remote
      // server's write tools are filtered out by `RemoteInstance` before the
      // list ever reaches this process.
      if let gate = server.writeGate {
        return .anyTool(
          because: "writes are off for this profile, so \(gate) is set to 0")
      }
      return .anyTool(
        because:
          "writes are off for this profile, so Bastion is not forwarding this server's write tools")
    }
    return .readOnlyHintsOnly(
      because: "this profile has writes enabled, so only tools marked read-only are offered")
  }

  /// The tools that may be offered, and why each of the others was left out.
  static func select(from tools: [MCPTool], under eligibility: Eligibility)
    -> (offered: [MCPTool], skipped: [(tool: String, reason: String)])
  {
    switch eligibility {
    case .anyTool:
      return (tools, [])
    case .readOnlyHintsOnly:
      var offered: [MCPTool] = []
      var skipped: [(tool: String, reason: String)] = []
      for tool in tools {
        if tool.readOnlyHint == true {
          offered.append(tool)
        } else {
          // A missing hint is never read as "no side effects". A server that
          // declares nothing is treated as though every tool writes.
          skipped.append(
            (
              tool.name,
              tool.readOnlyHint == false
                ? "the server marks it as writing" : "the server does not mark it read-only"
            ))
        }
      }
      return (offered, skipped)
    }
  }

  // MARK: - What came of it

  struct Call: Identifiable, Sendable {
    let id = UUID()
    let tool: String
    /// The arguments the model invented, as JSON.
    let arguments: String
    let output: String
    let failed: Bool
    let seconds: TimeInterval
  }

  /// What the model concluded, as a shape rather than as prose.
  ///
  /// Asked for free text, the on-device model reliably answers "X is working.
  /// Here are the details:" and stops — it wants to enumerate, and a sentence
  /// cap turns that into a truncated colon. A schema removes the option.
  @Generable
  nonisolated struct Verdict {
    @Guide(description: "true only if a tool call returned real data from a working server")
    let working: Bool
    @Guide(
      description:
        "One plain sentence on what happened, naming the tool. No lists, no colons, no offers to help."
    )
    let sentence: String
  }

  struct Result: Sendable {
    /// The model's own reading of what happened. A footnote on `calls`.
    var summary: String
    /// The model's verdict, when it produced one.
    var working: Bool?
    var calls: [Call]
    var offered: Int
    var skipped: [String]
    var failure: String?
  }

  enum ProbeError: LocalizedError {
    case noEligibleTools
    case noSchemaSurvived

    var errorDescription: String? {
      switch self {
      case .noEligibleTools:
        return "no tool on this server declares itself read-only, so none was called"
      case .noSchemaSurvived:
        return "none of this server's tools has an argument schema the probe can express"
      }
    }
  }

  // MARK: - Running it

  static func run(profile: Profile, server: BastionServer, tools: [MCPTool]) async -> Result {
    let eligibility = eligibility(server: server, profile: profile)
    let (candidates, excluded) = select(from: tools, under: eligibility)
    var skipped = excluded.map { "\($0.tool) — \($0.reason)" }

    guard !candidates.isEmpty else {
      return Result(
        summary: "", working: nil, calls: [], offered: 0, skipped: skipped,
        failure: ProbeError.noEligibleTools.localizedDescription)
    }

    let recorder = Recorder()
    var offered: [any Tool] = []

    // A cap, because every tool's schema goes into the model's instructions and
    // an eighty-five-tool server would spend the whole context describing
    // itself before it could call anything. Said out loud rather than applied
    // quietly: a report that lists why twelve tools were excluded and says
    // nothing about the other thirty-five is a report that reads as complete
    // and is not.
    let capacity = 12
    if candidates.count > capacity {
      skipped.append(
        "\(candidates.count - capacity) further eligible tool(s) — the probe offers at most "
          + "\(capacity), to leave the model room to answer")
    }
    for tool in candidates.prefix(capacity) {
      do {
        offered.append(
          try bridgeTool(for: tool) { json in
            recorder.invoke(tool: tool, arguments: json, profile: profile, server: server)
          })
      } catch {
        skipped.append("\(tool.name) — \(error.localizedDescription)")
      }
    }

    guard !offered.isEmpty else {
      return Result(
        summary: "", working: nil, calls: [], offered: 0, skipped: skipped,
        failure: ProbeError.noSchemaSurvived.localizedDescription)
    }

    let session = LanguageModelSession(tools: offered) {
      """
      You are checking whether the tools on a server actually work.

      Call exactly one tool that reads or lists something, with the smallest \
      plausible arguments. If a tool takes a limit or a count, ask for a small \
      one. Never call more than two tools in total.

      Then report whether the call succeeded and whether what came back looks \
      like real data rather than an error or an empty shell. If it returned an \
      error, say what the error was.
      """
    }

    do {
      let response = try await session.respond(
        to: "Check that \(server.displayName) is working, then report what you found.",
        generating: Verdict.self,
        options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 300))
      return Result(
        summary: response.content.sentence, working: response.content.working,
        calls: recorder.calls, offered: offered.count, skipped: skipped, failure: nil)
    } catch {
      // A model failure is not a server failure, and the calls it managed to
      // make before giving up are still evidence — so they are reported either
      // way, with the reason the session ended sitting beside them.
      return Result(
        summary: "", working: nil, calls: recorder.calls, offered: offered.count,
        skipped: skipped, failure: "the on-device model stopped: \(error.localizedDescription)")
    }
  }

  // MARK: - The bridge to the supervisor

  /// Collects what actually happened, from whichever thread it happened on.
  ///
  /// The transcript could be walked for this instead, but the tool is ours and
  /// already sees the arguments, the output, the failure and the duration —
  /// reading them here is both simpler and one less thing to be wrong about.
  nonisolated private final class Recorder: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<(calls: [Call], nextID: Int)>(
      initialState: ([], 100))

    var calls: [Call] { state.withLock { $0.calls } }

    func invoke(tool: MCPTool, arguments json: String, profile: Profile, server: BastionServer)
      -> String
    {
      let id = state.withLock { current -> Int in
        current.nextID += 1
        return current.nextID
      }
      let record = ToolProbe.invoke(
        tool: tool, argumentsJSON: json, profile: profile, server: server, id: id)
      state.withLock { $0.calls.append(record) }
      return record.output
    }
  }

  /// One `tools/call` against the live supervised child, as a `Call`.
  ///
  /// Shared by the one-shot probe and the chat pane. Both need the identical
  /// thing — send the arguments the model invented, render what came back,
  /// time it, and say whether it failed — and the interesting part is that
  /// there are two distinct kinds of failure worth telling apart, which is
  /// exactly the sort of detail a second copy would get wrong.
  nonisolated static func invoke(
    tool: MCPTool, argumentsJSON json: String, profile: Profile, server: BastionServer, id: Int
  ) -> Call {
    let parsed =
      (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    let began = Date()
    let outcome: (text: String, failed: Bool)
    do {
      let result = try ServerCheck.call(
        profile: profile, server: server, era: .legacy, method: "tools/call",
        params: ["name": tool.name, "arguments": parsed], id: id)
      // `isError` is how MCP reports a tool that ran and failed, as opposed to
      // a call that never happened. Both are worth telling apart in the report.
      outcome = (render(result), result["isError"] as? Bool ?? false)
    } catch {
      outcome = (error.localizedDescription, true)
    }
    return Call(
      tool: tool.name, arguments: json, output: outcome.text, failed: outcome.failed,
      seconds: Date().timeIntervalSince(began))
  }

  /// A model-facing tool backed by one MCP tool on one supervised child.
  nonisolated struct MCPBridgeTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let perform: @Sendable (String) -> String

    func call(arguments: GeneratedContent) async throws -> String {
      let json = arguments.jsonString
      // `Supervisor.call` blocks, and this is running on the cooperative pool.
      // Hopping to a dedicated thread is the same bargain the gateway makes for
      // every connection it serves.
      return await withCheckedContinuation { continuation in
        onDedicatedThread("bastion.tool") {
          continuation.resume(returning: perform(json))
        }
      }
    }
  }

  /// An MCP result rendered as the text the model will read.
  ///
  /// Truncated hard: a `tools/list` on a busy store can return tens of
  /// kilobytes, and the model has a context window that a single unbounded
  /// product listing would fill on its own.
  nonisolated private static func render(_ result: [String: Any]) -> String {
    var text = ""
    if let content = result["content"] as? [[String: Any]] {
      text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }
    if text.isEmpty, let data = try? JSONSerialization.data(withJSONObject: result) {
      text = String(decoding: data, as: UTF8.self)
    }
    let limit = 2000
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "\n… (truncated)"
  }

  nonisolated static func summary(of tool: MCPTool) -> String {
    let text = tool.summary.isEmpty ? tool.name : tool.summary
    return text.count > 300 ? String(text.prefix(300)) : text
  }

  /// Type names in a `GenerationSchema` are identifiers, and MCP tool names are
  /// not required to be.
  nonisolated static func sanitised(_ name: String) -> String {
    let cleaned = name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
    return String(cleaned)
  }

  /// Build the model-facing tool for one MCP tool, or throw if its schema is
  /// not one `node` can express.
  nonisolated static func bridgeTool(
    for tool: MCPTool, perform: @escaping @Sendable (String) -> String
  ) throws -> MCPBridgeTool {
    MCPBridgeTool(
      name: sanitised(tool.name), description: summary(of: tool),
      parameters: try schema(for: tool), perform: perform)
  }

  // MARK: - JSON Schema to GenerationSchema

  enum SchemaError: LocalizedError {
    case unsupported(path: String, why: String)

    var errorDescription: String? {
      switch self {
      case .unsupported(let path, let why):
        return "its schema is not one the probe can express (\(path) \(why))"
      }
    }
  }

  nonisolated static func schema(for tool: MCPTool) throws -> GenerationSchema {
    let root = (try? JSONSerialization.jsonObject(with: tool.schema)) as? [String: Any] ?? [:]
    let name = sanitised(tool.name)
    // A tool with no declared arguments still needs a schema, and an object
    // with no properties is the honest one.
    let dynamic = try node(root, name: name, path: name, depth: 0)
    return try GenerationSchema(root: dynamic, dependencies: [])
  }

  /// The JSON Schema subset these servers actually emit.
  ///
  /// Anything outside it throws rather than guesses: a tool called with
  /// arguments shaped by a guess is a worse outcome than a tool reported as
  /// unprobeable, because only one of those two is honest about what happened.
  nonisolated private static func node(_ json: [String: Any], name: String, path: String, depth: Int) throws
    -> DynamicGenerationSchema
  {
    guard depth <= 4 else {
      throw SchemaError.unsupported(path: path, why: "nests deeper than the probe follows")
    }
    for construct in ["oneOf", "allOf", "anyOf", "not", "$ref"] where json[construct] != nil {
      throw SchemaError.unsupported(path: path, why: "uses \(construct)")
    }

    let description = json["description"] as? String

    if let choices = json["enum"] as? [Any] {
      let strings = choices.compactMap { $0 as? String }
      guard !strings.isEmpty, strings.count == choices.count else {
        throw SchemaError.unsupported(path: path, why: "has an enum that is not all strings")
      }
      return DynamicGenerationSchema(name: name, description: description, anyOf: strings)
    }

    let declared = json["type"] as? String ?? (json["properties"] != nil ? "object" : nil)
    switch declared {
    case "object":
      let properties = json["properties"] as? [String: Any] ?? [:]
      let required = Set(json["required"] as? [String] ?? [])
      // Sorted so the same tool produces the same schema twice running, which
      // matters the day one of these has to be compared against another.
      let members = try properties.keys.sorted().map { key -> DynamicGenerationSchema.Property in
        guard let child = properties[key] as? [String: Any] else {
          throw SchemaError.unsupported(path: "\(path).\(key)", why: "is not a schema object")
        }
        return DynamicGenerationSchema.Property(
          name: key,
          description: child["description"] as? String,
          schema: try node(
            child, name: "\(name)_\(key)", path: "\(path).\(key)", depth: depth + 1),
          isOptional: !required.contains(key))
      }
      return DynamicGenerationSchema(name: name, description: description, properties: members)

    case "array":
      guard let items = json["items"] as? [String: Any] else {
        throw SchemaError.unsupported(path: path, why: "is an array with no declared item type")
      }
      return DynamicGenerationSchema(
        arrayOf: try node(items, name: "\(name)_item", path: "\(path)[]", depth: depth + 1),
        minimumElements: json["minItems"] as? Int,
        maximumElements: json["maxItems"] as? Int)

    case "string": return DynamicGenerationSchema(type: String.self)
    case "integer": return DynamicGenerationSchema(type: Int.self)
    case "number": return DynamicGenerationSchema(type: Double.self)
    case "boolean": return DynamicGenerationSchema(type: Bool.self)
    case .some(let other):
      throw SchemaError.unsupported(path: path, why: "declares the type '\(other)'")
    case .none:
      throw SchemaError.unsupported(path: path, why: "declares no type")
    }
  }
}
