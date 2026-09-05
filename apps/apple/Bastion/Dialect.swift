import Foundation

/// Translation between the **modern** (2026-07-28) protocol Bastion fronts
/// clients with and the **legacy** (2025-11-25 and earlier) protocol its
/// children actually speak.
///
/// The 2026-07-28 spec calls this a **dual-era server**, and sanctions exactly
/// what Bastion does: "A dual-era server selects its behavior from how the
/// client opens: a request carrying modern per-request `_meta` is served
/// statelessly according to this revision; an `initialize` request selects
/// legacy semantics." Bastion is a dual-era server in front of legacy children.
///
/// ## Why this is what makes the whole design possible
///
/// The three things that made a shared-instance gateway a hack a year ago were
/// per-client session state, server→client requests, and per-project roots. The
/// modern revision designs all three out: there is no handshake, so no session;
/// server-initiated interactions become `InputRequiredResult` embedded in a
/// result; and roots are deprecated. That is why the front is modern even
/// though every child is legacy — the front is where "any request can land on
/// any instance" has to be true.
///
/// ## Measured, not assumed
///
/// Every server in the manifest runs `@modelcontextprotocol/sdk` 1.29 or 1.30,
/// whose `LATEST_PROTOCOL_VERSION` is `2025-11-25`, and `server/discover`
/// against one returns `-32601` — the exact signal the spec names for
/// identifying a legacy server. So the back half of this file has one job and
/// will have it for about a year.
nonisolated enum Dialect {
  /// What Bastion advertises to clients, newest first.
  ///
  /// Legacy versions are listed because Bastion answers `initialize` too, and
  /// a client that opens that way is served legacy semantics per the spec's
  /// compatibility matrix. Today every real MCP client does exactly that.
  static let supportedVersions: [BastionServer.Dialect] = [
    .v2026_07_28, .v2025_11_25, .v2025_06_18,
  ]

  static var latest: BastionServer.Dialect { .v2026_07_28 }

  // MARK: - `_meta` keys
  //
  // Namespaced exactly as the spec writes them. These are not names Bastion
  // chose and must not be "tidied": an intermediary that reads
  // `protocolVersion` instead of `io.modelcontextprotocol/protocolVersion`
  // silently sees no version on every request and treats every modern client
  // as legacy.

  static let metaKey = "_meta"
  static let versionKey = "io.modelcontextprotocol/protocolVersion"
  static let clientInfoKey = "io.modelcontextprotocol/clientInfo"
  static let clientCapabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
  static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

  // MARK: - Protocol error codes
  //
  // From the spec's reserved sub-range. Named rather than written inline,
  // because a client's fallback logic branches on these exact numbers: a
  // recognised modern error tells it "this server is modern, retry properly"
  // and anything else tells it "fall back to initialize".

  /// `HeaderMismatch` — the HTTP headers disagree with the body, or a required
  /// header is missing. Always `400`.
  static let headerMismatch = -32020
  /// `UnsupportedProtocolVersionError` — carries `data.supported`. Always `400`.
  static let unsupportedVersion = -32022
  /// `Method not found`. On the modern transport this is `404`, not `500`.
  static let methodNotFound = -32601

  // MARK: - List cache annotation
  //
  // The modern revision has every list result say how long it may be cached and
  // by whom, and a client that does not find both fields rejects the result
  // outright — Claude Code 2.1.251 reports exactly this as "Invalid result for
  // tools/list: ttlMs expected number, received undefined". So a list without
  // them is not an under-annotated list, it is no list at all, and the server
  // comes up with zero tools.

  /// Methods whose results carry the annotation. `tools/call` is deliberately
  /// not here: the spec puts the annotation on listings, and adding it to a call
  /// result would be inventing a field.
  static let listMethods: Set<String> = [
    "tools/list", "prompts/list", "resources/list", "resources/templates/list",
  ]

  /// `private`, because a Bastion listing is per-PROFILE rather than per-server:
  /// `allowWrites` decides which tools are returned, so two profiles on one
  /// server legitimately see different lists. A shared cache would be free to
  /// serve the read-only profile's answer to the writing one, or the reverse.
  static let listCacheScope = "private"

  /// Sixty seconds. This is a real interval and not a hint, because Bastion
  /// cannot send `list_changed` — see `frontableCapabilities` — which makes the
  /// TTL the only way a client ever notices a child that restarted with a
  /// different tool set. Too long and a server upgraded under a running Bastion
  /// stays invisible; too short and every call re-lists first.
  static let listCacheTTLMs = 60_000

  /// Attach the cache annotation to a modern list result.
  ///
  /// An annotation the child already supplied is left alone. That is not
  /// defensiveness: a remote child proxied by `RemoteInstance` may be a genuine
  /// modern server that answered with its own TTL, and overwriting it would
  /// replace something true with something guessed.
  static func annotateList(result frame: [String: Any], method: String) -> [String: Any] {
    guard listMethods.contains(method), var result = frame["result"] as? [String: Any] else {
      return frame
    }
    if result["ttlMs"] == nil { result["ttlMs"] = listCacheTTLMs }
    if result["cacheScope"] == nil { result["cacheScope"] = listCacheScope }
    var out = frame
    out["result"] = result
    return out
  }

  // MARK: - Era detection

  /// Which era one client frame is written in.
  enum Era {
    /// Per-request `_meta`, no session. Carries the version it declared.
    case modern(BastionServer.Dialect)
    /// An `initialize` handshake, or anything sent after one.
    case legacy
    /// Modern-shaped, but naming a version Bastion does not implement. Held as
    /// a distinct case rather than folded into an error because the reply has
    /// to name what the client asked for.
    case unsupported(String)
  }

  /// Read the era from the frame's `_meta`.
  ///
  /// Absence of a modern `_meta` version means legacy. That is the spec's own
  /// rule and not a guess: a legacy client has no fall-forward mechanism, so
  /// the ambiguous case must resolve to the era that can still be served.
  static func era(of frame: [String: Any]) -> Era {
    guard let params = frame["params"] as? [String: Any],
      let meta = params[metaKey] as? [String: Any],
      let declared = meta[versionKey] as? String
    else { return .legacy }

    guard let version = BastionServer.Dialect(rawValue: declared),
      supportedVersions.contains(version)
    else { return .unsupported(declared) }

    return .modern(version)
  }

  /// The client's self-reported name, from whichever era it is speaking.
  ///
  /// For display and logging only. The spec is explicit that this is
  /// self-reported, unverified, and must not drive a security decision — which
  /// in Bastion it does not: the bearer token identifies the client, and this
  /// only labels a row in the Activity window.
  static func clientName(of frame: [String: Any]) -> String? {
    guard let params = frame["params"] as? [String: Any] else { return nil }
    if let meta = params[metaKey] as? [String: Any],
      let info = meta[clientInfoKey] as? [String: Any],
      let name = info["name"] as? String
    {
      return name
    }
    // Legacy: `initialize` is the only place a client says who it is.
    if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String {
      return name
    }
    return nil
  }

  // MARK: - Modern → legacy

  /// Strip modern metadata before a frame goes to a legacy child.
  ///
  /// Only the three namespaced keys, and only those — `_meta` is an open
  /// extension field in the legacy revisions too, and it is where a progress
  /// token lives. Dropping the whole object would silently disable progress
  /// reporting on every modern request, which is the kind of bug that presents
  /// as "the new protocol feels slower".
  ///
  /// That precaution is now load-bearing rather than defensive: the token this
  /// preserves is what `Supervisor.awaitReply` rewrites, and it is what lets a
  /// child's `notifications/progress` be routed back to the one client that
  /// asked for it. See `requestedProgressToken` below.
  ///
  /// `_meta` itself is removed only when nothing else was in it, so a legacy
  /// server never sees an empty object where it expected none.
  static func stripModernMeta(from frame: [String: Any]) -> [String: Any] {
    guard var params = frame["params"] as? [String: Any],
      var meta = params[metaKey] as? [String: Any]
    else { return frame }

    for key in [versionKey, clientInfoKey, clientCapabilitiesKey] {
      meta.removeValue(forKey: key)
    }

    var out = frame
    if meta.isEmpty {
      params.removeValue(forKey: metaKey)
    } else {
      params[metaKey] = meta
    }
    out["params"] = params
    return out
  }

  // MARK: - Progress tokens

  /// Where a REQUEST asks for progress: `params._meta.progressToken`.
  ///
  /// Deliberately not the same function as `notifiedProgressToken`. A request
  /// carries the token inside `_meta`; a notification carries it at the top
  /// level of `params`. One "find the token" helper looking in both places
  /// would pass every test and quietly match the wrong field on real traffic,
  /// which is the bug this split exists to prevent.
  static func requestedProgressToken(in frame: [String: Any]) -> Any? {
    guard let params = frame["params"] as? [String: Any],
      let meta = params[metaKey] as? [String: Any]
    else { return nil }
    let token = meta["progressToken"]
    return token is NSNull ? nil : token
  }

  /// Where a NOTIFICATION carries one: `params.progressToken`, top level.
  static func notifiedProgressToken(in frame: [String: Any]) -> Any? {
    guard let params = frame["params"] as? [String: Any] else { return nil }
    let token = params["progressToken"]
    return token is NSNull ? nil : token
  }

  /// Which of the two places a token is being written to.
  enum TokenLocation {
    case requestMeta
    case notificationParams
  }

  /// Replace the progress token, leaving the rest of the frame alone.
  static func rewriting(
    progressToken token: Any, in frame: [String: Any], at location: TokenLocation
  ) -> [String: Any] {
    var out = frame
    var params = frame["params"] as? [String: Any] ?? [:]
    switch location {
    case .requestMeta:
      var meta = params[metaKey] as? [String: Any] ?? [:]
      meta["progressToken"] = token
      params[metaKey] = meta
    case .notificationParams:
      params["progressToken"] = token
    }
    out["params"] = params
    return out
  }

  /// The prefix on a token Bastion minted for a client that used a string one.
  static let mintedTokenPrefix = "bastion-"

  /// The token to send upstream for an internal id, keeping the client's type.
  ///
  /// A server that declared its token a string would choke on an integer, so
  /// the type survives the trip. The prefix on the string form is also what
  /// stops a child's own unrelated token being mistaken for one of Bastion's.
  static func mintedProgressToken(for internalID: Int, like clientToken: Any) -> Any {
    clientToken is String ? "\(mintedTokenPrefix)\(internalID)" : internalID
  }

  /// The internal request id behind a token Bastion minted, or nil for one it
  /// did not. The inverse of `mintedProgressToken`.
  static func internalID(fromProgressToken token: Any) -> Int? {
    if let number = token as? Int { return number }
    if let text = token as? String, text.hasPrefix(mintedTokenPrefix) {
      return Int(text.dropFirst(mintedTokenPrefix.count))
    }
    return nil
  }

  // MARK: - Legacy → modern

  /// Add the modern result discriminator to a legacy child's result.
  ///
  /// Every modern result carries `resultType`. `"complete"` is the ordinary
  /// value; the other one that matters is `"input_required"`, which a legacy
  /// child can never produce — see `Supervisor.received`.
  ///
  /// An error response is passed through untouched: `resultType` lives on
  /// results, and a JSON-RPC frame has one or the other, never both.
  static func modernise(result frame: [String: Any]) -> [String: Any] {
    guard var result = frame["result"] as? [String: Any] else { return frame }
    if result["resultType"] == nil { result["resultType"] = "complete" }
    var out = frame
    out["result"] = result
    return out
  }

  /// Synthesise a `server/discover` result from a legacy child's `initialize`.
  ///
  /// This is the heart of the translation. `server/discover` is mandatory in
  /// the modern revision and no legacy child implements it — asking one
  /// returns `-32601`, which is exactly how the spec says to detect a legacy
  /// server. Bastion already holds the child's handshake, taken once at spawn,
  /// and that handshake carries the same three things discovery returns:
  /// capabilities, server identity and a version.
  ///
  /// `supportedVersions` is what BASTION supports, not what the child does.
  /// That is the correct answer and not a convenient one: the client is talking
  /// to Bastion, and Bastion is what will translate. Reporting the child's
  /// `2025-11-25` would tell a modern client to downgrade to a handshake era it
  /// has no reason to enter.
  ///
  /// `instructions` is passed through when the child sent any, because it is
  /// guidance written for the model and Bastion is not in a position to improve
  /// it.
  static func discoverResult(fromHandshake handshake: [String: Any], serverID: String)
    -> [String: Any]
  {
    var result: [String: Any] = [
      "resultType": "complete",
      "supportedVersions": supportedVersions.map(\.rawValue),
      "capabilities": frontableCapabilities(handshake["capabilities"] as? [String: Any] ?? [:]),
    ]

    if let instructions = handshake["instructions"] as? String, !instructions.isEmpty {
      result["instructions"] = instructions
    }

    // The child's own name and version, not Bastion's. A person reading this in
    // a client is trying to find out what is behind the endpoint, and "bastion"
    // would answer a question nobody asked. The spec marks this display-only
    // and unverified, which is exactly how it is used.
    let info = handshake["serverInfo"] as? [String: Any] ?? ["name": serverID]
    result[metaKey] = [serverInfoKey: info]

    // No `ttlMs` and no `cacheScope`. Discovery is cacheable, but what it
    // describes here is a supervised child that can restart with a different
    // tool set — a server upgraded under a running Bastion is the normal case
    // in a dogfooding repo. Offering a TTL Bastion cannot honour would be
    // worse than offering none.
    return result
  }

  /// The child's capabilities, minus the ones Bastion cannot deliver on.
  ///
  /// A legacy child's handshake routinely advertises `listChanged: true`, and
  /// passing that through is not a small inaccuracy. A modern client reads it,
  /// opens `subscriptions/listen`, and gets `-32601` — whereupon it drops the
  /// whole connection rather than just that one subscription, and the server
  /// registers no tools at all. An honest `false` costs a notification nobody
  /// was going to receive; a hopeful `true` costs every tool on the server.
  ///
  /// It could never have been honoured anyway. `Supervisor.received` drops a
  /// child's notifications on purpose: one supervised instance serves several
  /// clients, so there is no single client a `list_changed` belongs to.
  /// `resources.subscribe` is dropped for the same reason.
  ///
  /// Streaming a POST reply does NOT change this, and the distinction is worth
  /// stating because this is where it will be re-litigated. A
  /// `notifications/progress` is CORRELATED: it carries a token naming one
  /// in-flight request from one client, so there is exactly one place to send
  /// it. A `list_changed` is UNCORRELATED — a fact about the child, addressed
  /// to everyone. What an SSE reply gives Bastion is a PER-REQUEST channel, not
  /// a per-client one: a `list_changed` arriving while nobody is calling still
  /// has nowhere to go, and delivering it to whichever calls happen to be open
  /// would reach some clients and not others, at random. `subscriptions/listen`
  /// needs a channel outliving a request, which is the GET stream, still a 405.
  ///
  /// What stands in for it is the TTL on list results — see `listCacheTTLMs`.
  /// The client re-lists on its own schedule instead of being told when to.
  static func frontableCapabilities(_ capabilities: [String: Any]) -> [String: Any] {
    var out = capabilities
    for key in ["tools", "prompts", "resources"] {
      guard var group = out[key] as? [String: Any] else { continue }
      group["listChanged"] = false
      if key == "resources" { group.removeValue(forKey: "subscribe") }
      out[key] = group
    }
    return out
  }

  // MARK: - Header validation

  /// Decode the spec's Base64 sentinel, `=?base64?…?=`.
  ///
  /// A plain value comes back unchanged. `nil` means the sentinel was present
  /// but the payload was not decodable, which is a malformed header rather than
  /// a mismatched one — both are rejected, so the caller does not distinguish.
  ///
  /// The markers are case-sensitive and lowercase, per the spec. Comparing them
  /// case-insensitively would let `=?BASE64?` through as a literal value that
  /// happens to look like a sentinel, which is the ambiguity the spec closes by
  /// requiring clients to encode any literal matching the pattern.
  static func decodeHeaderValue(_ raw: String) -> String? {
    let prefix = "=?base64?"
    let suffix = "?="
    guard raw.hasPrefix(prefix), raw.hasSuffix(suffix), raw.count > prefix.count + suffix.count
    else { return raw }
    let inner = String(raw.dropFirst(prefix.count).dropLast(suffix.count))
    guard let data = Data(base64Encoded: inner) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// The value `Mcp-Name` must carry for this frame, or `nil` if the method
  /// does not require one.
  static func expectedName(for frame: [String: Any]) -> String? {
    guard let method = frame["method"] as? String,
      let params = frame["params"] as? [String: Any]
    else { return nil }
    switch method {
    case "tools/call", "prompts/get": return params["name"] as? String
    case "resources/read": return params["uri"] as? String
    default: return nil
    }
  }

  /// Validate the mirrored headers against the body, per the spec's Server
  /// Validation rules. Returns a JSON-RPC error object, or `nil` when they
  /// agree.
  ///
  /// The point is not tidiness. The spec says it outright: different components
  /// in a network rely on different sources of truth, so a load balancer that
  /// routes on `Mcp-Name` while the server executes `params.name` is a way to
  /// send one tool call through the policy checks written for another. Bastion
  /// is precisely such an intermediary — it logs and will gate on these — so it
  /// is on the wrong side of that hazard if it does not check.
  ///
  /// Notifications are exempt: the spec states that header requirements for
  /// notification POSTs are not defined by this revision, and inventing them
  /// would reject conforming clients.
  static func validateHeaders(request: HTTPRequest, frame: [String: Any], declaredVersion: String)
    -> [String: Any]?
  {
    guard frame["id"] != nil else { return nil }

    guard let header = request.header("mcp-protocol-version") else {
      return headerMismatchError("the MCP-Protocol-Version header is required")
    }
    guard header == declaredVersion else {
      return headerMismatchError(
        "MCP-Protocol-Version header '\(header)' does not match the body value '\(declaredVersion)'"
      )
    }

    guard let method = frame["method"] as? String else {
      return headerMismatchError("the request has no method")
    }
    guard let methodHeader = request.header("mcp-method") else {
      return headerMismatchError("the Mcp-Method header is required")
    }
    guard methodHeader == method else {
      return headerMismatchError(
        "Mcp-Method header '\(methodHeader)' does not match the body value '\(method)'")
    }

    if let expected = expectedName(for: frame) {
      guard let raw = request.header("mcp-name") else {
        return headerMismatchError("the Mcp-Name header is required for \(method)")
      }
      guard let decoded = decodeHeaderValue(raw) else {
        return headerMismatchError("the Mcp-Name header is not valid Base64")
      }
      guard decoded == expected else {
        return headerMismatchError(
          "Mcp-Name header '\(decoded)' does not match the body value '\(expected)'")
      }
    }

    // NOT validated: `Mcp-Param-*`. Doing it correctly means reading the tool's
    // `inputSchema` for `x-mcp-header` annotations, which means Bastion holding
    // a tool list per profile and invalidating it when a child restarts with a
    // different one. None of the ten servers in the manifest annotates a
    // parameter, so this is a real gap that cannot currently be reached rather
    // than one being papered over — and an unrecognised `Mcp-Param-*` header is
    // forwarded and ignored, which is what the spec requires of an
    // intermediary that does not recognise it.
    return nil
  }

  // MARK: - Errors

  static func unsupportedVersionError(requested: String) -> [String: Any] {
    [
      "code": unsupportedVersion,
      "message": "Unsupported protocol version",
      "data": [
        "supported": supportedVersions.map(\.rawValue),
        "requested": requested,
      ],
    ]
  }

  static func headerMismatchError(_ detail: String) -> [String: Any] {
    ["code": headerMismatch, "message": "Header mismatch: \(detail)"]
  }

  static func methodNotFoundError(_ method: String) -> [String: Any] {
    ["code": methodNotFound, "message": "Method not found: \(method)"]
  }
}
