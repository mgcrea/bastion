import Foundation
import os

/// One remote server, and everyone talking to it.
///
/// The sibling of `Supervisor.Instance`, and deliberately the same shape from
/// the outside: `handle(_:era:client:)` in, a JSON-RPC frame out. Everything
/// that made the child case interesting is either absent or different here, and
/// each difference is worth saying out loud rather than discovering later.
///
/// ## What is gone
///
/// **The process.** There is nothing to spawn, so there is no pid, no backoff,
/// no restart count and no idle stop. The headline claim — one process, N
/// clients — does not apply to a server that was never Bastion's process. What
/// still applies is the other three quarters of the reason to put a gateway in
/// front of a server: the credential lives in the Keychain instead of in every
/// client's config file, each profile is its own identity, and every call
/// leaves a line in the Activity window.
///
/// **The id remapping.** The child case rewrites every client's request id into
/// the supervisor's own numbering, because one stdio pipe carries every
/// client's traffic and two clients using id `1` would otherwise be able to
/// receive each other's answers. Here each request is its own HTTP exchange and
/// its response comes back on that exchange, so ids cannot cross and rewriting
/// them would be ceremony with no hazard behind it.
///
/// ## What is new
///
/// **The rate limit is shared.** With one process per client each client spent
/// its own budget against the upstream API. Behind one profile they spend one,
/// so a client in a loop can now exhaust a limit for every other client of the
/// same profile. This is the genuine cost of sharing an identity, it has no fix
/// at this layer, and the UI says so rather than letting it be discovered.
///
/// **The endpoint is attacker-relevant.** See `RemoteEndpoint` — a URL in the
/// installed list is the analogue of a command line, and the checks that keep
/// it from becoming one run on every request rather than once at add time.
/// `nonisolated` for the same reason `Supervisor.Instance` is, and it is not a
/// formality: every method here runs on the connection's own dedicated thread,
/// and inheriting the project's default main-actor isolation would put a hop to
/// the main thread — the one drawing the menu — in the path of every request.
nonisolated final class RemoteInstance: @unchecked Sendable {
  let key: String
  private let profile: Profile
  private let server: BastionServer
  private let endpoint: URL

  /// The manifest variables this server marks secret — the argument names
  /// Bastion can be certain are credentials. See `CallCapture`.
  private var secretKeys: Set<String> {
    Set(server.env.filter(\.isSecret).map(\.name))
  }

  /// How long one call may take. The same generous-but-finite number the child
  /// case uses, and for the same reason: these are real API calls and a report
  /// is slow, but a request with no ceiling is a client hung forever with
  /// nothing to show.
  private static let callTimeout: TimeInterval = 180

  private struct State {
    /// The one handshake, replayed to every client — the remote analogue of
    /// "the handshake happens once, at spawn".
    var handshake: [String: Any]?
    /// `Mcp-Session-Id`, if the server issued one. A server that does not is
    /// stateless and needs none.
    var session: String?
    /// The tool names the server itself annotates as not read-only, learned
    /// from a `tools/list` that passed through. The manifest's `writeTools` is
    /// a denylist somebody wrote down; this is the server's own answer, and it
    /// covers a mutating tool added after the list was written.
    var annotatedWriteTools: Set<String> = []
    var calls = 0
    /// Requests sent upstream and not yet answered.
    ///
    /// The same number `Supervisor.Instance` tracks, and for the same reason:
    /// it is what says whether replacing this process would turn somebody's
    /// pending call into a dropped connection. A remote request is if anything
    /// more likely to be slow, since it is a real API call over somebody
    /// else's network.
    var inFlight = 0
    /// Every tool upstream exposes, or nil for "not asked yet". `ToolFacade`
    /// cannot search a list it does not hold; `Supervisor.Instance.toolCatalog`
    /// says the rest, including why it is never written to disk.
    var toolCatalog: [[String: Any]]?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())
  /// One handshake at a time per profile. Two concurrent first requests is the
  /// normal case — an editor and a CLI starting together — and without this
  /// both would open their own session and one would be orphaned upstream.
  private let handshakeGate = DispatchSemaphore(value: 1)
  /// The same one-at-a-time bargain for the catalog walk, and for the same
  /// reason: two clients connecting together would otherwise each walk it.
  private let catalogGate = DispatchSemaphore(value: 1)
  /// A server that returns the same cursor forever is a hang, not a big list.
  private static let catalogPageLimit = 20
  private let session: URLSession

  init(profile: Profile, server: BastionServer) throws {
    guard let endpoint = server.endpoint else {
      throw Supervisor.SupervisorError.startFailed("\(server.id) is not a remote server")
    }
    self.profile = profile
    self.server = server
    self.endpoint = endpoint
    self.key = profile.id

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = Self.callTimeout
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    // Bastion adds every header itself, and an implicit one is a header nobody
    // reviewed.
    configuration.httpAdditionalHeaders = [:]
    self.session = URLSession(configuration: configuration)

    // Before anything is sent, and before Activity claims this is running.
    try RemoteEndpoint.preflight(endpoint)

    let id = key
    let host = endpoint.host() ?? endpoint.absoluteString
    Task(priority: Activity.priority) { @MainActor in
      Activity.shared.started(
        id: id, profile: profile.name, server: server.id, pid: 0,
        allowWrites: profile.allowWrites, remoteHost: host)
    }
  }

  var clientCount: Int { state.withLock { $0.calls > 0 ? 1 : 0 } }

  /// Requests sent upstream and not yet answered.
  var pendingCount: Int { state.withLock { $0.inFlight } }

  func stop(reason: String) {
    session.invalidateAndCancel()
    let id = key
    Task(priority: Activity.priority) { @MainActor in Activity.shared.stopped(id: id) }
    hostLog(key, .info, "remote session closed: \(reason)")
  }

  // MARK: - The one entry point

  func handle(_ incoming: [String: Any], era: Dialect.Era, client: String) throws -> Data? {
    var frame = incoming
    guard let method = frame["method"] as? String else {
      throw Supervisor.SupervisorError.malformedRequest("no method")
    }
    let clientID = frame["id"]
    let reported = Dialect.clientName(of: frame)

    let id = key
    let counts = clientID != nil
    Task(priority: Activity.priority) { @MainActor in
      Activity.shared.called(id: id, client: client, reported: reported, counts: counts)
    }

    // Era translation is identical to the child case, and for the identical
    // reason: whatever the client speaks, upstream took exactly one handshake
    // and every client is answered from it.
    if case .modern = era {
      if method == "server/discover" {
        guard let clientID else {
          throw Supervisor.SupervisorError.malformedRequest("server/discover without id")
        }
        let handshake = try ensureHandshake()
        return try encode([
          "jsonrpc": "2.0", "id": clientID,
          "result": Dialect.discoverResult(fromHandshake: handshake, serverID: server.id),
        ])
      }
      if method == "initialize" || method == "notifications/initialized" {
        guard let clientID else { return nil }
        return try encode([
          "jsonrpc": "2.0", "id": clientID, "error": Dialect.methodNotFoundError(method),
        ])
      }
      frame = Dialect.stripModernMeta(from: frame)
    } else {
      if method == "initialize" {
        guard let clientID else {
          throw Supervisor.SupervisorError.malformedRequest("initialize without id")
        }
        let handshake = try ensureHandshake()
        return try encode(["jsonrpc": "2.0", "id": clientID, "result": handshake])
      }
      if method == "notifications/initialized" { return nil }
    }

    // The facade. Identical in shape to `Supervisor.Instance`, deliberately, and
    // the rule itself is in `ToolFacade` so there is one of it rather than two —
    // the bargain the write gate above already makes. Before the log row and the
    // gate on purpose: `bastion_call_tool` is rewritten into the `tools/call` it
    // stood for, so the audit row, `CallCapture` and the write gate all name the
    // real tool. Never for Bastion's own callers, which budget and report over
    // the real list.
    var facadeAnswer: [String: Any]?
    if profile.loadsToolsOnDemand, client != ServerCheck.client,
      ToolFacade.handles(method: method, params: frame["params"] as? [String: Any])
    {
      _ = try ensureHandshake()
      switch ToolFacade.route(
        method: method, params: frame["params"] as? [String: Any], catalog: try facadeCatalog(),
        displayName: server.displayName, summary: server.summary)
      {
      case .answer(let result): facadeAnswer = result
      case .rewrite(let params): frame["params"] = params
      case .passThrough: break
      }
    }

    let logID = LogStore.record(
      origin: key, frame: frame, mode: profile.capture, secretKeys: secretKeys)

    // Answered here, so the record is completed here — nothing is going upstream
    // to come back and complete it.
    if let facadeAnswer {
      guard let clientID else { return nil }
      let reply: [String: Any] = ["jsonrpc": "2.0", "id": clientID, "result": facadeAnswer]
      if let logID {
        hostCallResult(
          logID, CallCapture.result(reply, mode: profile.capture, secretKeys: secretKeys),
          failed: CallCapture.isFailure(reply))
      }
      return try encode(reply)
    }

    _ = try ensureHandshake()

    // The write gate, before anything leaves the machine. A refused call is a
    // call the upstream API never sees, which is the only enforcement Bastion
    // can actually perform on a server it does not run.
    if !profile.allowWrites, method == "tools/call",
      let params = frame["params"] as? [String: Any],
      let name = params["name"] as? String, isWriteTool(name)
    {
      // A gated notification is simply dropped: there is no id to answer.
      guard clientID != nil else { return nil }
      hostLog(key, .info, "refused \(name): writes are off for this profile")
      return try encode([
        "jsonrpc": "2.0", "id": clientID as Any,
        "error": [
          "code": -32601,
          "message":
            "'\(name)' changes things and writes are off for the \(profile.name) profile. Turn "
            + "'Allow writes' on in Bastion if that is what you want.",
        ],
      ])
    }

    guard clientID != nil else {
      // A notification. Sent and forgotten; there is nothing to correlate.
      _ = try? post(frame)
      return nil
    }
    // Nothing rebinds the id from here on, and that is the point: the frame
    // goes out carrying the client's own id and the answer comes back on the
    // same exchange carrying it still. The child case has to remap because one
    // pipe carries every client; one HTTP exchange carries one.

    state.withLock {
      $0.calls += 1
      $0.inFlight += 1
    }
    defer { state.withLock { $0.inFlight -= 1 } }
    var response = try post(frame)

    // A 401 on an OAuth profile is the ordinary end of a token's life, not a
    // failure. Refresh and retry exactly once: twice would be a loop against a
    // server that answers 401 to everything, and the second answer is the one
    // worth showing the user.
    if response.status == 401,
      let known = CredentialStore.readTokens(profile: profile.name, server: server.id)
    {
      hostLog(key, .info, "upstream 401 — refreshing the token and retrying once")
      _ = try RemoteOAuthSession.shared.refresh(profile: profile, server: server, known: known)
      response = try post(frame, hasRetriedAuth: true)
    }

    // A stale session is the one upstream failure with an unambiguous recovery,
    // and the spec names it: 404 to a request carrying `Mcp-Session-Id` means
    // start a new session. Once, never in a loop — a server answering 404 to
    // everything would otherwise turn one request into an infinite handshake.
    if response.status == 404, state.withLock({ $0.session != nil }) {
      hostLog(key, .info, "session expired upstream, handshaking again")
      state.withLock {
        $0.session = nil
        $0.handshake = nil
        // Beside the handshake, for the child case's reason: a new session may
        // be a different tool surface, and a stale catalog would deny a tool
        // that now exists.
        $0.toolCatalog = nil
      }
      _ = try ensureHandshake()
      response = try post(frame)
    }

    guard let object = try response.jsonRPC() else {
      throw Supervisor.SupervisorError.childDied("no response")
    }

    // No correlation table needed here: one HTTP exchange carries one request,
    // so the answer is in hand at the point the call was recorded.
    if let logID {
      hostCallResult(
        logID,
        CallCapture.result(object, mode: profile.capture, secretKeys: secretKeys),
        failed: CallCapture.isFailure(object))
    }

    // The upstream id is Bastion's own only for the handshake; for a relayed
    // request it is the client's, sent as-is and returned as-is.
    return try encode(filteredForWriteGate(object, method: method))
  }

  // MARK: - The facade

  /// Every tool upstream exposes, fetched once and held for the session.
  ///
  /// The whole list, following `nextCursor`: under a facade a client reaches a
  /// tool only through `bastion_call_tool`, so a catalog missing page two is a
  /// set of tools that have silently ceased to exist.
  ///
  /// This is also the only chance to measure what a remote profile costs when
  /// the facade is on. `filteredForWriteGate` takes that figure off a client's
  /// own `tools/list` as it passes, and with the facade in front of it no such
  /// reply ever passes — so without this the detail pane would go blank for
  /// exactly the profiles where the number is most worth reading.
  private func ensureCatalog() throws -> [[String: Any]] {
    if let held = state.withLock({ $0.toolCatalog }) { return held }
    catalogGate.wait()
    defer { catalogGate.signal() }
    if let held = state.withLock({ $0.toolCatalog }) { return held }

    var collected: [[String: Any]] = []
    var cursor: String?
    var pages = 0
    repeat {
      var params: [String: Any] = [:]
      if let cursor { params["cursor"] = cursor }
      let request: [String: Any] = [
        "jsonrpc": "2.0", "id": "bastion-catalog-\(pages)", "method": "tools/list",
        "params": params,
      ]
      guard let object = try post(request).jsonRPC(),
        let payload = object["result"] as? [String: Any],
        let entries = payload["tools"] as? [[String: Any]]
      else {
        throw Supervisor.SupervisorError.startFailed("the server would not list its tools")
      }
      collected += entries
      cursor = payload["nextCursor"] as? String
      pages += 1
    } while cursor != nil && pages < Self.catalogPageLimit

    if cursor != nil {
      hostLog(
        key, .error,
        "stopped listing tools after \(pages) pages — the server keeps asking for another")
    }
    let catalog = collected
    state.withLock { $0.toolCatalog = catalog }
    hostLog(key, .info, "catalog: \(catalog.count) tool(s) behind the facade")
    return catalog
  }

  /// The catalog as this profile is allowed to see it, and the measurement of
  /// it.
  ///
  /// After the gate rather than before, which is the rule
  /// `filteredForWriteGate` already states: the figure has to be the list this
  /// profile's gate produces, not the one upstream sent.
  private func facadeCatalog() throws -> [[String: Any]] {
    let catalog = try ensureCatalog()
    let learned = WriteGate.annotatedWriteTools(in: catalog)
    if !learned.isEmpty { state.withLock { $0.annotatedWriteTools.formUnion(learned) } }
    let visible = WriteGate.visibleTools(
      in: catalog, declared: server.writeTools,
      annotated: state.withLock { $0.annotatedWriteTools }, allowWrites: profile.allowWrites)

    let bytes = visible.reduce(0) { $0 + ToolCost.bytes(of: $1) }
    let profileID = profile.id
    let allowWrites = profile.allowWrites
    let count = visible.count
    Task { @MainActor in
      ToolCostStore.shared.record(
        profileID: profileID, bytes: bytes, toolCount: count, partial: false, version: nil,
        allowWrites: allowWrites)
    }
    return visible
  }

  // MARK: - The handshake, once

  private func ensureHandshake() throws -> [String: Any] {
    if let existing = state.withLock({ $0.handshake }) { return existing }

    handshakeGate.wait()
    defer { handshakeGate.signal() }
    if let existing = state.withLock({ $0.handshake }) { return existing }

    let request: [String: Any] = [
      "jsonrpc": "2.0", "id": "bastion-init", "method": "initialize",
      "params": [
        // The dialect the SERVER speaks, from the manifest — never whatever a
        // client asked for. `Dialect` translates between the two, and
        // conflating them here is how a server is handed a version it has
        // never heard of.
        "protocolVersion": server.dialect.rawValue,
        "capabilities": [:],
        "clientInfo": ["name": "bastion", "version": AppInfo.version],
      ],
    ]

    let response = try post(request, isHandshake: true)
    guard let object = try response.jsonRPC() else {
      throw Supervisor.SupervisorError.startFailed("the server did not answer initialize")
    }
    if let error = object["error"] as? [String: Any] {
      let message = (error["message"] as? String) ?? "\(error)"
      throw Supervisor.SupervisorError.startFailed("initialize was refused: \(message)")
    }
    guard let result = object["result"] as? [String: Any] else {
      throw Supervisor.SupervisorError.startFailed("initialize returned no result")
    }

    state.withLock {
      $0.handshake = result
      if let issued = response.sessionID { $0.session = issued }
    }

    // The same drift line the child case logs, and the same reason to want it:
    // the manifest said 2025-06-18 for every server until a live handshake
    // proved otherwise. This entry's dialect is unmeasured, so this is the
    // first thing that has ever measured it.
    let negotiated = (result["protocolVersion"] as? String) ?? "unknown"
    if negotiated != server.dialect.rawValue {
      hostLog(
        key, .info,
        "dialect drift: manifest says \(server.dialect.rawValue), \(server.id) negotiated "
          + "\(negotiated)")
    }
    let id = key
    Task(priority: Activity.priority) { @MainActor in
      Activity.shared.negotiated(id: id, dialect: negotiated)
    }

    // The notification the spec asks for after a legacy handshake. Best effort:
    // a server that does not want it answers 202 or 405 and neither is a
    // reason to fail a handshake that already succeeded.
    _ = try? post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    return result
  }

  // MARK: - The write gate

  private func isWriteTool(_ name: String) -> Bool {
    WriteGate.isWriteTool(
      name, declared: server.writeTools,
      annotated: state.withLock { $0.annotatedWriteTools })
  }

  /// Hide the gated tools from `tools/list`, and learn the server's own
  /// annotations while passing them.
  ///
  /// The rule itself lives in `WriteGate`, which is a pure function and has a
  /// test. What stays here is the only part that is not: the per-profile state
  /// the annotations accumulate into, and the log line.
  private func filteredForWriteGate(_ object: [String: Any], method: String) -> [String: Any] {
    let declared = server.writeTools
    let annotated = state.withLock { $0.annotatedWriteTools }
    let (response, learned) = WriteGate.filter(
      object, method: method, declared: declared, annotated: annotated,
      allowWrites: profile.allowWrites)

    if !learned.isEmpty {
      state.withLock { $0.annotatedWriteTools.formUnion(learned) }
    }
    if let before = (object["result"] as? [String: Any])?["tools"] as? [[String: Any]],
      let after = (response["result"] as? [String: Any])?["tools"] as? [[String: Any]],
      after.count != before.count
    {
      hostLog(key, .info, "write gate hid \(before.count - after.count) tool(s) from tools/list")
    }

    // What this client is about to receive, recorded for the detail pane. A
    // remote server has no spawn to hang a measurement off, so a reply on its
    // way past is the only chance to take one. After the filter rather than
    // before: the figure has to be the list this profile's gate produces, not
    // the one upstream sent.
    if method == "tools/list", let result = response["result"] as? [String: Any],
      let entries = result["tools"] as? [[String: Any]]
    {
      let bytes = entries.reduce(0) { $0 + ToolCost.bytes(of: $1) }
      let partial = result["nextCursor"] != nil
      let profileID = profile.id
      let allowWrites = profile.allowWrites
      Task { @MainActor in
        ToolCostStore.shared.record(
          profileID: profileID, bytes: bytes, toolCount: entries.count, partial: partial,
          version: nil, allowWrites: allowWrites)
      }
    }
    return response
  }

  // MARK: - HTTP

  private struct Response {
    let status: Int
    let body: Data
    let contentType: String
    let sessionID: String?

    /// One JSON-RPC object, however it arrived.
    ///
    /// A Streamable HTTP server may answer a single request with an SSE stream,
    /// and Bastion's own front door emits a single JSON object and never a
    /// stream — a limitation the README already states for the child case and
    /// which reaches a second transport here rather than becoming a new one.
    /// So the stream is read to its end and collapsed to the one response that
    /// answers the request; notifications and progress events on the way are
    /// dropped, because there is nowhere to forward them to.
    func jsonRPC() throws -> [String: Any]? {
      if contentType.contains("text/event-stream") {
        for payload in ServerSentEvents.dataPayloads(in: body) {
          guard
            let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
          else { continue }
          // The answer is the frame carrying an id; everything else on the
          // stream is a notification with no client to receive it.
          if object["id"] != nil, object["result"] != nil || object["error"] != nil {
            return object
          }
        }
        return nil
      }
      guard !body.isEmpty else { return nil }
      return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

  }

  /// One request, sent and waited for on this thread.
  ///
  /// Blocking on purpose. `Supervisor.call` runs on the connection's own
  /// dedicated thread precisely so that waiting costs a thread rather than a
  /// slot in a bounded pool, and an async hop here would put this back on the
  /// cooperative pool the child case was moved off.
  private func post(_ frame: [String: Any], isHandshake: Bool = false, hasRetriedAuth: Bool = false)
    throws -> Response
  {
    // Every request, not just the first. A name that passed at add time can
    // resolve somewhere else now, which is the rebinding shape the gateway's
    // own Host check exists for, pointed outward.
    try RemoteEndpoint.preflight(endpoint)

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = Self.callTimeout
    request.httpBody = try JSONSerialization.data(withJSONObject: frame)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue(server.dialect.rawValue, forHTTPHeaderField: "MCP-Protocol-Version")
    if let session = state.withLock({ $0.session }) {
      request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
    }
    // The profile's own headers last, so a manifest sink always wins over a
    // default set above it — and never the other way round, which would let a
    // default silently replace a credential.
    for (name, value) in ProfileEnvironment.headers(for: profile, server: server) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    // And OAuth last of all, because an authorized profile is authorized: a
    // stale typed key left in the Keychain must not quietly win over a token
    // the user granted more recently, which would show as "I authorized this
    // and it still says my credential is wrong". The profile editor says which
    // one is in force, and signing out is what hands the key back its job.
    //
    // Refreshes inline if it is due. That needs no human, unlike authorizing.
    if let bearer = try RemoteOAuthSession.shared.authorizationHeader(
      profile: profile, server: server)
    {
      request.setValue(bearer, forHTTPHeaderField: "Authorization")
    }

    let semaphore = DispatchSemaphore(value: 0)
    let outcome = OSAllocatedUnfairLock<Result<Response, Error>?>(initialState: nil)
    let host = endpoint.host() ?? ""
    let collector = MetricsCollector()

    let task = session.dataTask(with: request) { data, response, error in
      let result: Result<Response, Error>
      defer {
        outcome.withLock { $0 = result }
        semaphore.signal()
      }
      if let error {
        result = .failure(Supervisor.SupervisorError.startFailed(error.localizedDescription))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        result = .failure(Supervisor.SupervisorError.childDied("no HTTP response"))
        return
      }
      // The address the connection actually landed on, judged before a single
      // byte of the body is handed back. Too late to stop the request — which
      // is why `preflight` runs first — in time to refuse the answer.
      // A refused redirect first: it is the more specific fact, and it would
      // otherwise surface as whatever partial response the refusal produced.
      if let refusal = collector.refusal {
        result = .failure(refusal)
        return
      }
      do {
        for address in collector.remoteAddresses {
          try RemoteEndpoint.verify(connectedTo: address, host: host)
        }
      } catch {
        result = .failure(error)
        return
      }
      result = .success(
        Response(
          status: http.statusCode,
          body: data ?? Data(),
          contentType: (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased(),
          sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id")))
    }
    task.delegate = collector
    task.resume()

    guard semaphore.wait(timeout: .now() + Self.callTimeout + 5) == .success else {
      task.cancel()
      throw Supervisor.SupervisorError.timedOut(seconds: Int(Self.callTimeout))
    }
    guard let result = outcome.withLock({ $0 }) else {
      throw Supervisor.SupervisorError.childDied("no response")
    }
    let response = try result.get()

    // 202 is the spec's answer to a notification, and it carries no body.
    if response.status == 202 { return response }
    // 404 on a session, and 401 on an OAuth profile, are both handled by the
    // caller — it is the only place that knows whether there is a session to
    // retire or a token to refresh. Returned rather than thrown so the retry
    // can happen; a second 401 comes back through here and is thrown properly.
    if response.status == 404, !isHandshake { return response }
    if response.status == 401, !isHandshake, !hasRetriedAuth,
      CredentialStore.readTokens(profile: profile.name, server: server.id) != nil
    {
      return response
    }

    guard (200..<300).contains(response.status) else {
      throw Self.upstreamError(response, server: server.id, profile: profile.name)
    }
    return response
  }

  /// The sentence a client sees when the far end refuses.
  ///
  /// Every one of these reaches the client as HTTP 200 carrying a JSON-RPC
  /// error, the same way `Supervisor.SupervisorError` already does, because a 500 renders
  /// in a client as "connection failed" — the least informative possible
  /// rendering of a sentence that says exactly what to do.
  private static func upstreamError(_ response: Response, server: String, profile: String)
    -> Supervisor.SupervisorError
  {
    switch response.status {
    case 401, 403:
      return .remoteRefused(
        "\(server) refused the \(profile) profile's credential (HTTP \(response.status)). Check "
          + "it in Bastion — for an expired or revoked key, replacing it is the whole fix.")
    case 429:
      return .remoteRefused(
        "\(server) is rate limiting the \(profile) profile. Every client sharing this profile "
          + "shares one budget upstream, so another client may be spending it.")
    case 500...599:
      return .remoteRefused(
        "\(server) returned HTTP \(response.status) — that is their end, not Bastion's")
    default:
      return .remoteRefused("\(server) returned HTTP \(response.status)")
    }
  }

  private func encode(_ frame: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: frame)
  }
}

/// Two jobs, both about where the request actually went.
///
/// **Redirects.** `URLSession` follows them by default and replays the original
/// headers while doing it, which for this request means replaying the profile's
/// credential at whatever host the redirect names. That is the ordinary way an
/// API token is stolen, so a redirect off the endpoint's own origin is refused
/// outright rather than followed without the header: a cross-origin redirect on
/// an MCP endpoint has no legitimate reading, and failing loudly beats
/// succeeding against somewhere unexpected.
///
/// **The addresses.** `URLSessionTaskTransactionMetrics.remoteAddress` is the
/// only place the resolved peer is observable, and it is populated once the
/// exchange is over — which is exactly when `RemoteEndpoint.verify` wants it.
/// Every hop is kept, not just the last: judging only the final one would miss
/// a same-origin redirect that landed somewhere it should not have.
private nonisolated final class MetricsCollector:
  NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
  private struct State {
    var addresses: [String] = []
    var refusal: Error?
  }

  private let state = OSAllocatedUnfairLock(initialState: State())

  var remoteAddresses: [String] { state.withLock { $0.addresses } }
  var refusal: Error? { state.withLock { $0.refusal } }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let from = task.originalRequest?.url
    guard let to = request.url else {
      completionHandler(nil)
      return
    }
    let sameOrigin =
      from?.scheme?.lowercased() == to.scheme?.lowercased()
      && from?.host()?.lowercased() == to.host()?.lowercased()
      && from?.port == to.port
    guard sameOrigin else {
      state.withLock {
        $0.refusal = RemoteEndpoint.EndpointError.crossOriginRedirect(
          from: from?.host() ?? "the endpoint", to: to.host() ?? to.absoluteString)
      }
      completionHandler(nil)
      return
    }
    // Same origin, so the credential is going where it was already going. The
    // address still gets judged like every other hop.
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    let seen = metrics.transactionMetrics.compactMap { $0.remoteAddress }.filter { !$0.isEmpty }
    state.withLock { $0.addresses.append(contentsOf: seen) }
  }
}
