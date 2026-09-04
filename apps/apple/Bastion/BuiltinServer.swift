import Foundation

/// Bastion, as one of its own servers.
///
/// Every other entry in the list is an npm package Bastion downloads, spawns
/// and relays to. This one is the app: it answers MCP in-process, spawns
/// nothing, and holds no credentials of its own. It exists because the app's
/// users live in an agent, and until now every change — installing a server,
/// creating a profile, putting a credential in the Keychain, wiring a client —
/// meant leaving that agent and opening a window.
///
/// ## What makes this safe to ship
///
/// Three rules, and they hold whatever the profile's write gate says:
///
/// 1. **No tool ever returns a secret.** `set_credential` has no counterpart,
///    and `list_profiles` reports *which* variables are set, never what to.
///    A management server that could read the Keychain back out would undo the
///    single property the whole app is built to provide.
/// 2. **`disable_server` refuses this server.** An agent that switched off its
///    own control plane would lock itself out of switching it back on. The
///    window can do it; the server cannot.
/// 3. **`remove_server` refuses this server.** `ServerStore.remove` enforces
///    that on its own; it is restated here so the caller gets a sentence rather
///    than a caught exception.
///
/// ## Why it is off by default
///
/// It is a control plane for a daemon holding every credential you own.
/// Present in the list from the first launch so it can be found, and inert
/// until someone turns it on, gives it a profile and wires a client — three
/// deliberate acts, none of which happen by accident.
nonisolated enum BuiltinServer {
  /// Reserved. `ServerStore` refuses a custom server that tries to take it,
  /// because a shadowing row would silently replace the control plane.
  static let id = "bastion"

  /// Named for the UI's benefit, and set on no process ever.
  ///
  /// There is no child here, so nothing receives this variable. It is declared
  /// because `ProfileEditor` renders the "Allow writes" toggle only for a
  /// server that names a gate, and because `ServerDetail` would otherwise stamp
  /// the green `read-only` badge on the one server that can change everything.
  /// The dispatcher reads `profile.allowWrites` directly.
  static let writeGate = "BASTION_ALLOW_WRITES"

  /// The definition, hand-written rather than generated.
  ///
  /// Deliberately not in `servers.json`: that file generates the catalog, the
  /// website and `docs/servers.md`, and every entry in it is either a package
  /// to install or an endpoint to reach. This is neither. It runs in this
  /// process, so there is no `npmName` for the manifest to carry and no
  /// `transport` shape that would be honest about it.
  static let definition = BastionServer(
    id: id,
    displayName: "Bastion",
    summary: "Bastion itself: servers, profiles, credentials, clients, and what is running.",
    // Not an empty package name pretending to be one. There is nothing to
    // install and nothing to spawn, and saying that in the type means an
    // installer path that slips past its guard cannot go looking for
    // `@mgcrea/mcp-bastion` on the registry — `server.package` is nil.
    transport: .inProcess,
    docsURL: URL(string: "https://github.com/mgcrea/bastion"),
    // The only modern server in the list, because it is the only one Bastion
    // wrote. Nothing in `Dialect` has to translate for it.
    dialect: .v2026_07_28,
    writeGate: writeGate,
    writeTools: [],
    gateBypass: [],
    authModes: [],
    stateEnv: [],
    callbackEnv: [],
    // No environment at all. Its "credentials" are the app's own state, which
    // it already has.
    env: [],
    origin: .builtin,
    isEnabled: false)

  /// What a client is told this server is for.
  static let instructions = """
    Bastion supervises MCP servers for this machine: one process per server \
    instead of one per editor, credentials in the Keychain, and every tool call \
    recorded. These tools manage Bastion itself — the servers it runs, the \
    profiles that give them credentials, and the clients wired to reach them.

    A profile is a named credential set for one server (`prod/shopify`, \
    `rgis/keycloak`); clients reach it at /s/<profile>/<server>. Adding a \
    server to the list and installing its code are separate steps, so a failed \
    download leaves something to retry.

    Secrets are write-only here: you can set a credential, and nothing can read \
    one back.
    """

  // MARK: - One request

  /// Handle one client frame, returning the response or `nil` for a
  /// notification.
  ///
  /// Shaped to match `Supervisor.Instance.handle` so the gateway above does not
  /// have to know which kind of server answered: same signature, same `nil`
  /// convention, same era handling. What it does not do is any of the things
  /// that exist for a child — no id remapping, no waiter, no timeout, no
  /// restart — because there is no process on the other side to be out of step
  /// with.
  static func handle(_ frame: [String: Any], era: Dialect.Era, profile: Profile, client: String)
    throws -> Data?
  {
    guard let method = frame["method"] as? String else {
      throw Supervisor.SupervisorError.malformedRequest("no method")
    }
    let key = "\(profile.name)/\(id)"
    let clientID = frame["id"]

    if case .modern = era {
      // Answered from the definition rather than from a handshake: there is no
      // child to have taken one with.
      if method == "server/discover" {
        guard let clientID else {
          throw Supervisor.SupervisorError.malformedRequest("server/discover without id")
        }
        hostLog(key, .info, "server/discover")
        return try encode(["jsonrpc": "2.0", "id": clientID, "result": discoverResult()])
      }
      // A modern frame naming a legacy method — the same refusal a supervised
      // child gets, and for the same reason: the modern era has no handshake,
      // so asking for one is a method this era does not have.
      if method == "initialize" || method == "notifications/initialized" {
        guard let clientID else { return nil }
        return try encode([
          "jsonrpc": "2.0", "id": clientID, "error": Dialect.methodNotFoundError(method),
        ])
      }
    } else {
      if method == "initialize" {
        guard let clientID else {
          throw Supervisor.SupervisorError.malformedRequest("initialize without id")
        }
        return try encode([
          "jsonrpc": "2.0", "id": clientID, "result": handshakeResult(for: frame),
        ])
      }
      if method == "notifications/initialized" { return nil }
    }

    // The same audit line every other server produces, through the same
    // helper: a tool call here is a tool call, and leaving it out of the
    // Activity log would make the one server that can change everything the
    // one server that leaves no trace.
    // Bastion's own tools are recorded like anyone else's, and the one that
    // takes a credential as an argument is the reason `CallCapture` has a
    // never-capture list rather than a setting.
    let logID = LogStore.record(
      origin: key, frame: frame, mode: profile.capture,
      secretKeys: Set(BuiltinTools.secretArgumentNames))

    guard let clientID else {
      // A notification naming something else. Nothing to correlate and nothing
      // to forward — there is no child.
      return nil
    }

    switch method {
    case "ping":
      return try encode(["jsonrpc": "2.0", "id": clientID, "result": [:] as [String: Any]])

    case "tools/list":
      let tools = onMain { BuiltinTools.declarations(allowWrites: profile.allowWrites) }
      return try encode([
        "jsonrpc": "2.0", "id": clientID, "result": ["tools": tools],
      ])

    case "tools/call":
      let params = frame["params"] as? [String: Any] ?? [:]
      let result = callTool(params, profile: profile, key: key)
      if let logID {
        let answer: [String: Any] = ["result": result]
        hostCallResult(
          logID,
          CallCapture.result(
            answer, mode: profile.capture, secretKeys: Set(BuiltinTools.secretArgumentNames),
            tool: params["name"] as? String),
          failed: CallCapture.isFailure(answer))
      }
      return try encode(["jsonrpc": "2.0", "id": clientID, "result": result])

    default:
      return try encode([
        "jsonrpc": "2.0", "id": clientID, "error": Dialect.methodNotFoundError(method),
      ])
    }
  }

  /// Run one tool and shape the result the way MCP asks for.
  ///
  /// A failure comes back as `isError: true` with the sentence in the content,
  /// not as a JSON-RPC error. That is the spec's distinction and it matters
  /// here: a JSON-RPC error is a protocol fault the client handles, while a
  /// tool that refused is something the *model* needs to read and act on —
  /// "'shopify' already exists in your list" is a fact it can use, and a
  /// transport error is not.
  private static func callTool(_ params: [String: Any], profile: Profile, key: String)
    -> [String: Any]
  {
    guard let name = params["name"] as? String else {
      return errorResult("tools/call needs a tool name")
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]

    do {
      let value = try onMain {
        try BuiltinTools.invoke(
          name: name, arguments: arguments, allowWrites: profile.allowWrites, caller: key)
      }
      let text: String
      if let string = value as? String {
        text = string
      } else {
        // Compact, not pretty-printed. A model does not need the indentation,
        // and Swift's pretty printer is unusually expensive: it writes
        // `"key" : "value"` with a space on BOTH sides of the colon and renders
        // an empty array over three lines. Measured at ~20% of every response
        // this server sends. `sortedKeys` stays — deterministic key order keeps
        // the payload stable for prompt caching and for builtin-check's
        // substring assertions.
        let data = try JSONSerialization.data(
          withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        text = String(decoding: data, as: UTF8.self)
      }
      return ["content": [["type": "text", "text": text]]]
    } catch {
      let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
      hostLog(key, .error, "\(name): \(detail)")
      return errorResult(detail)
    }
  }

  private static func errorResult(_ text: String) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": true]
  }

  // MARK: - Handshakes

  /// A legacy `initialize` result.
  ///
  /// The version echoed is the client's own when Bastion implements it. There
  /// is no child whose negotiation has to be replayed, so the ordinary rule
  /// applies: answer in the version you were asked in, and fall back to the
  /// newest legacy revision when the request named one that is not implemented.
  private static func handshakeResult(for request: [String: Any]) -> [String: Any] {
    let asked = (request["params"] as? [String: Any])?["protocolVersion"] as? String
    let version =
      asked.flatMap(BastionServer.Dialect.init(rawValue:)).flatMap {
        Dialect.supportedVersions.contains($0) ? $0 : nil
      } ?? .v2025_11_25

    return [
      "protocolVersion": version.rawValue,
      "capabilities": ["tools": ["listChanged": false]],
      "serverInfo": ["name": id, "version": AppInfo.version],
      "instructions": instructions,
    ]
  }

  /// A modern `server/discover` result.
  ///
  /// Built directly rather than through `Dialect.discoverResult`, which
  /// synthesises one from a legacy child's handshake — there is no child and no
  /// handshake here, so the fields are simply stated.
  private static func discoverResult() -> [String: Any] {
    [
      "resultType": "complete",
      "supportedVersions": Dialect.supportedVersions.map(\.rawValue),
      "capabilities": ["tools": ["listChanged": false]],
      "instructions": instructions,
      Dialect.metaKey: [
        Dialect.serverInfoKey: ["name": id, "version": AppInfo.version]
      ],
    ]
  }

  // MARK: - Plumbing

  private static func encode(_ frame: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: frame)
  }

  /// Run a body on the main actor from the connection's own thread.
  ///
  /// `ServerStore` and `ProfileStore` keep lock-guarded snapshots precisely so
  /// the gateway never has to do this — but that is about the *hot path*, where
  /// a main-thread round trip per relayed call would put the menu's draw loop
  /// in front of every tool invocation. A management call is not that: it
  /// happens when a person asks their agent to change something, and it needs
  /// the authoritative state rather than a projection of it.
  ///
  /// Safe to block on: connection threads are dedicated (`onDedicatedThread`)
  /// and are never the main thread, and nothing on the main thread ever waits
  /// on one.
  private static func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread {
      return try MainActor.assumeIsolated(body)
    }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
  }
}
