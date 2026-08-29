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
      "capabilities": handshake["capabilities"] as? [String: Any] ?? [:],
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
    let prefix = "=?base64?", suffix = "?="
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
