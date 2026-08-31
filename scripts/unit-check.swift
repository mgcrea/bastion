import Darwin
import Foundation

/// Unit checks for the two files that had none and could have.
///
/// `Dialect` is the dual-era translation — the thing that makes "one handshake,
/// N clients" true — and `HTTP` is a hand-written parser sitting on a listening
/// socket. Both were covered only end to end, and end to end is where they are
/// hardest to cover: `make dialect` needs a running app *and* an installed
/// catalog server, so on a machine that has not installed one it does not run
/// at all, and `audit-listener.sh` only ever sends the parser well-formed
/// requests. Malformed input against a hand-rolled parser that runs *before*
/// authentication is exactly the case worth having.
///
/// A standalone `swiftc` binary, for the reason `wiring-check.swift` gives: the
/// Xcode project has no test target, and adding one means hand-editing
/// project.pbxproj — a bigger and riskier diff than the code under test. These
/// two files compile alone, so nothing had to be moved to make this possible.
///
/// Run with `make unit`.
@main
struct UnitCheck {
  static var failures = 0
  static var checks = 0

  static func check(_ label: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() {
      print("  ok   \(label)")
    } else {
      print("  FAIL \(label)")
      failures += 1
    }
  }

  // MARK: - Feeding the real parser real bytes

  /// Runs `HTTPRequest.read(from:)` against a socket carrying `raw`.
  ///
  /// A socketpair rather than a fixture, so the code under test is the code
  /// that runs in production — including the read loop, which is where the
  /// interesting failures are. Written from another thread because a header
  /// block deliberately larger than the socket buffer would otherwise deadlock
  /// the writer against a reader that has not started.
  static func parse(_ raw: String) -> HTTPRequest? {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return nil }
    let write = fds[1], read = fds[0]
    let data = Data(raw.utf8)
    let writer = Thread {
      data.withUnsafeBytes { buffer in
        var sent = 0
        while sent < buffer.count {
          let n = Darwin.write(write, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
          if n <= 0 { break }
          sent += n
        }
      }
      // EOF, so a read loop waiting on a declared length terminates instead of
      // hanging — which is also how a truncated request presents in the wild.
      close(write)
    }
    writer.start()
    defer { close(read) }
    return HTTPRequest.read(from: read)
  }

  static func request(_ headers: [String: String], method: String = "tools/call") -> HTTPRequest {
    HTTPRequest(method: "POST", path: "/s/p/s", headers: headers, body: Data())
  }

  static func main() {
    print("\nHTTP: a well-formed request")
    let ok = parse(
      "POST /s/prod/stripe?x=1 HTTP/1.1\r\nHost: 127.0.0.1:8720\r\nORIGIN: http://a\r\n"
        + "Content-Length: 7\r\n\r\n{\"a\":1}")
    check("the method is upper-cased", ok?.method == "POST")
    check("the path survives intact", ok?.path == "/s/prod/stripe?x=1")
    check("the body is exactly content-length", ok?.body == Data("{\"a\":1}".utf8))
    // A security check that missed a header because of capitalisation would
    // fail open, and clients genuinely disagree about case.
    check("headers are matched case-insensitively", ok?.header("origin") == "http://a")
    check("and the stored keys are lower-cased", ok?.headers["origin"] == "http://a")
    check("the query is not part of pathComponents", ok?.pathComponents == ["s", "prod", "stripe"])

    print("\nHTTP: malformed input, which nothing else exercises")
    check("no request line at all is refused", parse("") == nil)
    check("a one-word request line is refused", parse("GET\r\n\r\n") == nil)
    check("headers with no terminator are refused", parse("GET / HTTP/1.1\r\nHost: x\r\n") == nil)
    // The one place an unauthenticated peer controls an allocation: this runs
    // before the bearer token is looked at.
    check(
      "a header block over 64KB is refused rather than buffered",
      parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000)) == nil)
    check(
      "a content-length over the cap is refused before the body is read",
      parse("POST / HTTP/1.1\r\nContent-Length: \(HTTPRequest.maxBody + 1)\r\n\r\n") == nil)
    // A short body is a truncated request, not a small one; serving it would
    // hand the supervisor half a JSON frame.
    check(
      "a body shorter than content-length is refused",
      parse("POST / HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort") == nil)
    check(
      "a body longer than content-length is trimmed to it",
      parse("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nabcdefgh")?.body == Data("abc".utf8))
    check(
      "a header line with no colon is skipped, not fatal",
      parse("GET / HTTP/1.1\r\ngarbage\r\nHost: x\r\n\r\n")?.header("host") == "x")
    check(
      "a non-numeric content-length reads as zero rather than throwing",
      parse("POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n")?.body.isEmpty == true)

    print("\nHTTP: the bearer token")
    func bearer(_ value: String) -> String? {
      request(["authorization": value]).bearerToken
    }
    check("a normal header yields the token", bearer("Bearer abc123") == "abc123")
    check("the scheme is case-insensitive", bearer("bearer abc123") == "abc123")
    check("another scheme yields nothing", bearer("Basic abc123") == nil)
    check("a scheme with no token yields nothing", bearer("Bearer") == nil)
    check("no header at all yields nothing", request([:]).bearerToken == nil)
    // A token with spaces would otherwise be truncated at the first one, and
    // the failure would look like a wrong token rather than a parsing bug.
    check("only the first space splits", bearer("Bearer a b") == "a b")

    print("\nHTTP: the JSON-RPC id, which an error is returned against")
    // An error carrying the wrong id is worse than no error: the client matches
    // it to nothing and waits out its own timeout on a request already failed.
    check("a numeric id is found", HTTPRequest.jsonRPCID(of: Data("{\"id\":7}".utf8)) as? Int == 7)
    check(
      "a string id is found",
      HTTPRequest.jsonRPCID(of: Data("{\"id\":\"x\"}".utf8)) as? String == "x")
    check("a notification has none", HTTPRequest.jsonRPCID(of: Data("{\"a\":1}".utf8)) == nil)
    check("garbage yields none rather than throwing", HTTPRequest.jsonRPCID(of: Data("{{{".utf8)) == nil)

    print("\nHTTP: the response on the wire")
    let wire = String(decoding: HTTPResponse(status: 403, message: "no").wireFormat, as: UTF8.self)
    check("the status line carries a reason", wire.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
    check("every response closes the connection", wire.contains("Connection: close\r\n"))
    // Nothing here is meant for a browser, and the headers say so.
    check("nosniff is always set", wire.contains("X-Content-Type-Options: nosniff\r\n"))
    check("responses are never cached", wire.contains("Cache-Control: no-store\r\n"))
    check("content-length matches the body", wire.contains("Content-Length: \(("{\"error\":\"no\"}").utf8.count)\r\n"))
    check(
      "extra headers are emitted",
      String(
        decoding: HTTPResponse(status: 401, message: "x", headers: ["WWW-Authenticate": "Bearer"])
          .wireFormat, as: UTF8.self
      ).contains("WWW-Authenticate: Bearer\r\n"))

    print("\nDialect: which era a frame is speaking")
    func era(_ frame: [String: Any]) -> Dialect.Era { Dialect.era(of: frame) }
    func isLegacy(_ e: Dialect.Era) -> Bool { if case .legacy = e { true } else { false } }
    func isModern(_ e: Dialect.Era) -> Bool { if case .modern = e { true } else { false } }
    func isUnsupported(_ e: Dialect.Era) -> Bool { if case .unsupported = e { true } else { false } }

    // The ambiguous case must resolve to the era that can still be served: a
    // legacy client has no fall-forward mechanism.
    check("no params at all is legacy", isLegacy(era(["method": "tools/list"])))
    check("params with no _meta is legacy", isLegacy(era(["params": ["a": 1]])))
    check(
      "a declared modern version is modern",
      isModern(
        era([
          "params": [Dialect.metaKey: [Dialect.versionKey: Dialect.latest.rawValue]]
        ])))
    check(
      "a version nobody speaks is unsupported, not legacy",
      isUnsupported(era(["params": [Dialect.metaKey: [Dialect.versionKey: "1999-01-01"]]])))

    print("\nDialect: the client's self-reported name")
    check(
      "a modern client is read from _meta",
      Dialect.clientName(of: [
        "params": [Dialect.metaKey: [Dialect.clientInfoKey: ["name": "modern"]]]
      ]) == "modern")
    check(
      "a legacy client is read from clientInfo",
      Dialect.clientName(of: ["params": ["clientInfo": ["name": "legacy"]]]) == "legacy")
    check("an anonymous frame yields nothing", Dialect.clientName(of: ["params": [:]]) == nil)

    print("\nDialect: stripping modern metadata for a legacy child")
    // Dropping the whole object would silently disable progress reporting on
    // every modern request — a bug that presents as "the new protocol feels
    // slower" rather than as a failure.
    let mixed: [String: Any] = [
      "method": "tools/call",
      "params": [
        "name": "t",
        Dialect.metaKey: [
          Dialect.versionKey: "2026-07-28",
          Dialect.clientInfoKey: ["name": "x"],
          Dialect.clientCapabilitiesKey: [:],
          "progressToken": 42,
        ],
      ],
    ]
    let stripped = Dialect.stripModernMeta(from: mixed)
    let strippedMeta = (stripped["params"] as? [String: Any])?[Dialect.metaKey] as? [String: Any]
    check("the version key is removed", strippedMeta?[Dialect.versionKey] == nil)
    check("the client info key is removed", strippedMeta?[Dialect.clientInfoKey] == nil)
    check("the capabilities key is removed", strippedMeta?[Dialect.clientCapabilitiesKey] == nil)
    check("a progress token survives", strippedMeta?["progressToken"] as? Int == 42)
    check("other params are untouched", (stripped["params"] as? [String: Any])?["name"] as? String == "t")

    // A legacy server must never see an empty object where it expected none.
    let onlyModern: [String: Any] = [
      "params": ["a": 1, Dialect.metaKey: [Dialect.versionKey: "2026-07-28"]]
    ]
    let emptied = Dialect.stripModernMeta(from: onlyModern)
    check(
      "_meta is removed entirely when nothing else was in it",
      (emptied["params"] as? [String: Any])?[Dialect.metaKey] == nil)
    check("a frame with no params is returned unchanged", Dialect.stripModernMeta(from: ["method": "x"])["method"] as? String == "x")

    print("\nDialect: the Base64 header sentinel")
    // Case-sensitive and lowercase, per the spec. Comparing case-insensitively
    // would let `=?BASE64?` through as a literal that happens to look like a
    // sentinel — the exact ambiguity the spec closes.
    check("a plain value passes through", Dialect.decodeHeaderValue("plain") == "plain")
    check(
      "a sentinel is decoded",
      Dialect.decodeHeaderValue("=?base64?" + Data("héllo".utf8).base64EncodedString() + "?=")
        == "héllo")
    check("an upper-case marker is NOT a sentinel", Dialect.decodeHeaderValue("=?BASE64?aGk=?=") == "=?BASE64?aGk=?=")
    check("invalid base64 inside a sentinel is refused", Dialect.decodeHeaderValue("=?base64?!!!?=") == nil)
    check("an empty sentinel is not treated as one", Dialect.decodeHeaderValue("=?base64??=") == "=?base64??=")

    print("\nDialect: which methods must mirror a name")
    check(
      "tools/call mirrors params.name",
      Dialect.expectedName(for: ["method": "tools/call", "params": ["name": "t"]]) == "t")
    check(
      "resources/read mirrors params.uri",
      Dialect.expectedName(for: ["method": "resources/read", "params": ["uri": "u"]]) == "u")
    check(
      "tools/list mirrors nothing",
      Dialect.expectedName(for: ["method": "tools/list", "params": [:]]) == nil)

    print("\nDialect: header/body agreement")
    // Not tidiness. A load balancer routing on Mcp-Name while the server
    // executes params.name is a way to send one tool call through the policy
    // checks written for another — and Bastion is exactly such an intermediary.
    let version = Dialect.latest.rawValue
    let call: [String: Any] = ["id": 1, "method": "tools/call", "params": ["name": "refund"]]
    // A plain name is sent literally. Base64 is a SENTINEL form — `=?base64?…?=`
    // — not "always encode", and encoding without the markers produces a header
    // that compares as the literal base64 text and fails. Worth asserting both,
    // because getting this wrong looks exactly like a header-mismatch attack.
    check(
      "a literal Mcp-Name matching the body passes",
      Dialect.validateHeaders(
        request: request([
          "mcp-protocol-version": version, "mcp-method": "tools/call", "mcp-name": "refund",
        ]), frame: call, declaredVersion: version) == nil)
    check(
      "a Base64-sentinel Mcp-Name is decoded before comparing",
      Dialect.validateHeaders(
        request: request([
          "mcp-protocol-version": version, "mcp-method": "tools/call",
          "mcp-name": "=?base64?" + Data("refund".utf8).base64EncodedString() + "?=",
        ]), frame: call, declaredVersion: version) == nil)
    check(
      "base64 WITHOUT the sentinel markers is compared literally, and refused",
      Dialect.validateHeaders(
        request: request([
          "mcp-protocol-version": version, "mcp-method": "tools/call",
          "mcp-name": Data("refund".utf8).base64EncodedString(),
        ]), frame: call, declaredVersion: version) != nil)
    // The spec leaves notification headers undefined; inventing rules would
    // reject conforming clients.
    check(
      "a notification is exempt",
      Dialect.validateHeaders(
        request: request([:]), frame: ["method": "tools/call", "params": [:]],
        declaredVersion: version) == nil)
    check(
      "a missing version header is refused",
      Dialect.validateHeaders(
        request: request(["mcp-method": "tools/call"]), frame: call, declaredVersion: version)
        != nil)
    check(
      "a version header disagreeing with the body is refused",
      Dialect.validateHeaders(
        request: request(["mcp-protocol-version": "1999-01-01", "mcp-method": "tools/call"]),
        frame: call, declaredVersion: version) != nil)
    check(
      "a method header disagreeing with the body is refused",
      Dialect.validateHeaders(
        request: request(["mcp-protocol-version": version, "mcp-method": "tools/list"]),
        frame: call, declaredVersion: version) != nil)
    check(
      "a missing Mcp-Name on tools/call is refused",
      Dialect.validateHeaders(
        request: request(["mcp-protocol-version": version, "mcp-method": "tools/call"]),
        frame: call, declaredVersion: version) != nil)
    // The one that matters most: the header names a different tool than the
    // body executes.
    check(
      "an Mcp-Name naming a different tool is refused",
      Dialect.validateHeaders(
        request: request([
          "mcp-protocol-version": version, "mcp-method": "tools/call",
          "mcp-name": "read_only",
        ]), frame: call, declaredVersion: version) != nil)

    print("\nDialect: error shapes")
    check(
      "method-not-found uses the JSON-RPC code",
      Dialect.methodNotFoundError("x")["code"] as? Int == Dialect.methodNotFound)
    check(
      "a header mismatch has its own code",
      Dialect.headerMismatchError("x")["code"] as? Int == Dialect.headerMismatch)
    check(
      "an unsupported version has its own code, and names what was asked for",
      Dialect.unsupportedVersionError(requested: "1999-01-01")["code"] as? Int
        == Dialect.unsupportedVersion)

    print("\nWhich servers have a write path")
    // The rule six places used to spell out for themselves, each from
    // `writeGate != nil`. A remote server has no gate variable, so all six
    // decided Stripe was read-only: no toggle in the profile editor, a green
    // "read-only" badge, and — the one that mattered — the chat pane offering
    // a model every tool with no confirmation.
    func server(
      writeGate: String? = nil, writeTools: [String] = [],
      transport: BastionServer.Transport = .child(
        .init(npmName: "@a/b", binName: "b", distribution: .npm, localPath: "b"))
    ) -> BastionServer {
      BastionServer(
        id: "x", displayName: "X", summary: "", transport: transport, docsURL: nil,
        dialect: .v2025_11_25, writeGate: writeGate, writeTools: writeTools, gateBypass: [],
        authModes: [], stateEnv: [], callbackEnv: [], env: [])
    }
    let remote = BastionServer.Transport.remote(endpoint: URL(string: "https://mcp.example.com")!)

    check("a child with a gate has a write path", server(writeGate: "A_ALLOW_WRITES").hasWritePath)
    check("a child with no gate does not", !server().hasWritePath)
    check(
      "a remote server has one even with no writeTools",
      server(transport: remote).hasWritePath)
    check(
      "a remote server with writeTools has one",
      server(writeTools: ["w"], transport: remote).hasWritePath)
    check("Bastion's own server has one", server(writeGate: "BASTION_ALLOW_WRITES").hasWritePath)
    // The regression, named: this is what the profile editor asks before it
    // draws the toggle, and what the chat pane asks before it decides a tool
    // needs no confirmation.
    check(
      "the catalog's stripe entry has a write path",
      ServerCatalog.all.first { $0.id == "stripe" }?.hasWritePath == true)
    check(
      "and shopify, which really is read-only, does not",
      ServerCatalog.all.first { $0.id == "shopify" }?.hasWritePath == false)

    // MARK: - Call capture
    //
    // The two things this file exists to stop, both of which are silent when
    // they go wrong: a credential reaching the log, and an unbounded payload
    // reaching a 2000-entry ring buffer.

    print("\nCall capture: what is never recorded")

    let secretKeys: Set<String> = ["SHOPIFY_TOKEN"]
    func params(_ tool: String, _ args: [String: Any]) -> [String: Any] {
      ["name": tool, "arguments": args]
    }

    // The headline. `set_credential`'s `value` is documented to models as
    // "never written to disk", and recording it would make that false.
    check(
      "set_credential's arguments are never captured",
      CallCapture.arguments(
        tool: "set_credential",
        params: params("set_credential", ["profile": "prod", "value": "s3cr3t-canary"]),
        mode: .argumentsAndResults, secretKeys: secretKeys) == nil)
    check(
      "and not at .arguments either",
      CallCapture.arguments(
        tool: "set_credential", params: params("set_credential", ["value": "s3cr3t-canary"]),
        mode: .arguments) == nil)

    let manifest = CallCapture.arguments(
      tool: "shopify_get_order",
      params: params("shopify_get_order", ["SHOPIFY_TOKEN": "s3cr3t-canary", "id": "992"]),
      mode: .arguments, secretKeys: secretKeys)
    check("a manifest secret is redacted", manifest?.contains("s3cr3t-canary") == false)
    check("and the rest of the call survives", manifest?.contains("992") == true)

    let nested = CallCapture.arguments(
      tool: "t",
      params: params("t", ["outer": ["inner": ["api_key": "s3cr3t-canary"]]]),
      mode: .arguments)
    check("a secret nested two levels down is redacted", nested?.contains("s3cr3t-canary") == false)

    let inArray = CallCapture.arguments(
      tool: "t", params: params("t", ["rows": [["password": "s3cr3t-canary"]]]), mode: .arguments)
    check("and one inside an array", inArray?.contains("s3cr3t-canary") == false)

    check("Api-Key matches api_key", CallCapture.isSecretKey("Api-Key", []))
    check("apiKey does too", CallCapture.isSecretKey("apiKey", []))
    check("orderId does not", !CallCapture.isSecretKey("orderId", []))

    print("\nCall capture: what each mode records")

    check(
      "off records no arguments",
      CallCapture.arguments(tool: "t", params: params("t", ["a": 1]), mode: .off) == nil)
    check(
      "arguments records arguments",
      CallCapture.arguments(tool: "t", params: params("t", ["a": 1]), mode: .arguments) != nil)
    check(
      "arguments records no result",
      CallCapture.result(["result": ["ok": true]], mode: .arguments) == nil)
    check(
      "argumentsAndResults records one",
      CallCapture.result(["result": ["ok": true]], mode: .argumentsAndResults) != nil)
    check(
      "an error frame is kept",
      CallCapture.result(["error": ["message": "no"]], mode: .argumentsAndResults) != nil)
    check("an error frame is a failure", CallCapture.isFailure(["error": ["message": "no"]]))
    check(
      "an isError result is a failure",
      CallCapture.isFailure(["result": ["isError": true]]))
    check("a plain result is not", !CallCapture.isFailure(["result": ["ok": true]]))

    print("\nCall capture: malformed input")

    check(
      "no params yields nil", CallCapture.arguments(tool: "t", params: nil, mode: .arguments) == nil)
    check(
      "no arguments key yields nil",
      CallCapture.arguments(tool: "t", params: ["name": "t"], mode: .arguments) == nil)
    check(
      "empty arguments yield nil",
      CallCapture.arguments(tool: "t", params: params("t", [:]), mode: .arguments) == nil)
    check("no frame yields nil", CallCapture.result(nil, mode: .argumentsAndResults) == nil)
    check(
      "a frame with neither result nor error yields nil",
      CallCapture.result(["jsonrpc": "2.0"], mode: .argumentsAndResults) == nil)

    print("\nCall capture: the size cap")

    let long = String(repeating: "a", count: 10_000)
    let capped = CallCapture.truncate(long, to: 4096)
    check("truncation bounds the byte count", capped.utf8.count < 4200)
    check("and says how much went", capped.contains("+5904 bytes"))
    check("short text is untouched", CallCapture.truncate("hi", to: 4096) == "hi")

    // A cut landing mid-scalar would produce something that is not a String.
    // é is two UTF-8 bytes, so a cap of 3 must stop after the first one.
    let multibyte = String(repeating: "é", count: 100)
    let cut = CallCapture.truncate(multibyte, to: 3)
    check("a cut lands on a character boundary", cut.hasPrefix("é") && !cut.hasPrefix("éé"))
    check("multibyte truncation still reports bytes", cut.contains("bytes"))

    let big = CallCapture.arguments(
      tool: "t", params: params("t", ["body": long]), mode: .arguments)
    check("a captured argument is capped", (big?.utf8.count ?? 0) < 4200)

    // MARK: - The catalog's auth kinds
    //
    // The generator refuses these at build time, which is the real guard. They
    // are asserted here too because the generator only runs when somebody edits
    // `servers.json`, and a hand-edit to the generated Swift would sail past
    // it — while `make unit` runs on every change.

    // MARK: - Decoding what a child says about its own login

    print("\nTool replies: the isError-in-a-result trap")

    // The exact envelope mcp-reddit's `ok()` produces.
    func reply(_ text: String, isError: Bool? = nil) -> [String: Any] {
      var out: [String: Any] = ["content": [["type": "text", "text": text]]]
      if let isError { out["isError"] = isError }
      return out
    }

    let status = try? ToolReply.decode(reply(#"{"signedIn": true, "mode": "user"}"#))
    check("a signed-in status decodes", status?["signedIn"] as? Bool == true)

    let out = try? ToolReply.decode(reply(#"{"signedIn": false}"#))
    check("a signed-out status decodes", out?["signedIn"] as? Bool == false)

    // The whole reason this is a separate type. A failed tool answers 200 with
    // a *result*, so anything reading only the JSON-RPC layer calls this a
    // success — and a refused login would be reported as a completed one.
    var refusedMessage: String?
    do {
      _ = try ToolReply.decode(reply(#"{"error": "no client id"}"#, isError: true))
      check("an isError result throws", false)
    } catch {
      refusedMessage = error.localizedDescription
      check("an isError result throws", true)
    }
    check("and carries the tool's own reason", refusedMessage == "no client id")

    // `isError` with no `error` key still has to throw, or a refusal with an
    // unexpected body reads as a success.
    do {
      _ = try ToolReply.decode(reply(#"{"detail": "nope"}"#, isError: true))
      check("an isError result with no error key still throws", false)
    } catch {
      check("an isError result with no error key still throws", true)
    }

    check(
      "isError:false is not a refusal",
      (try? ToolReply.decode(reply(#"{"signedIn": true}"#, isError: false))) != nil)

    // Text split across blocks is one JSON document, not two.
    let split: [String: Any] = [
      "content": [
        ["type": "text", "text": #"{"signedIn":"#], ["type": "text", "text": " true}"],
      ]
    ]
    check(
      "text split across content blocks is joined",
      (try? ToolReply.decode(split))?["signedIn"] as? Bool == true)

    for (label, bad) in [
      ("no content", [String: Any]()),
      ("content is not a list", ["content": "hi"] as [String: Any]),
      ("text is not JSON", reply("not json at all")),
      ("payload is a JSON array", reply("[1, 2, 3]")),
    ] {
      check("malformed throws: \(label)", (try? ToolReply.decode(bad)) == nil)
    }

    print("\nThe catalog: auth kinds")
    let catalog = ServerCatalog.all

    for server in catalog {
      let isChild: Bool
      switch server.transport {
      case .child: isChild = true
      default: isChild = false
      }
      for mode in server.authModes {
        switch mode.kind {
        case .env:
          check(
            "\(server.id)/\(mode.id): an env mode names variables", !mode.env.isEmpty)
        case .oauth:
          // Bastion is the client here, and it discovers against an endpoint.
          check("\(server.id)/\(mode.id): an oauth mode is remote", !isChild)
          check("\(server.id)/\(mode.id): an oauth mode names no variables", mode.env.isEmpty)
        case .childOAuth:
          // The mirror image: there has to be a child to call the tools on.
          check("\(server.id)/\(mode.id): a childOAuth mode is a child", isChild)
          check("\(server.id)/\(mode.id): a childOAuth mode names no variables", mode.env.isEmpty)
          // A missing name is a button that fails at -32601 on click, which is
          // the failure this whole feature exists to avoid.
          check(
            "\(server.id)/\(mode.id): a childOAuth mode names its three tools",
            !(mode.loginTool ?? "").isEmpty && !(mode.statusTool ?? "").isEmpty
              && !(mode.logoutTool ?? "").isEmpty)
        }
        check(
          "\(server.id)/\(mode.id): only childOAuth carries tool names",
          mode.kind == .childOAuth
            || (mode.loginTool == nil && mode.statusTool == nil && mode.logoutTool == nil))
      }
    }

    let reddit = catalog.first { $0.id == "reddit" }
    check("reddit offers a sign-in", reddit?.authModes.contains { $0.isInteractive } == true)

    print("\nThe catalog: per-profile callbacks")
    for server in catalog {
      let named = Set(server.env.map(\.name))
      for callback in server.callbackEnv {
        check("\(server.id): \(callback.name) is a real variable", named.contains(callback.name))
        // Without {port} the template is a constant, which is the collision
        // the field exists to remove.
        check(
          "\(server.id): \(callback.name) is templated on the port",
          callback.format.contains("{port}"))
        let url = callback.url(port: 51234)
        check("\(server.id): \(callback.name) substitutes the port", url.contains("51234"))
        check(
          "\(server.id): \(callback.name) leaves no placeholder", !url.contains("{port}"))
        // A callback that is not loopback would send an authorization code to
        // somebody else's machine.
        check(
          "\(server.id): \(callback.name) stays on loopback",
          url.hasPrefix("http://127.0.0.1:"))
      }
    }

    // MARK: - The audit chain
    //
    // Everything here is invisible when it goes wrong: a chain that verifies a
    // forged log, or one that cries tamper over a log nobody touched, both look
    // exactly like a chain that works until somebody depends on the answer.

    func record(_ seq: Int, _ text: String, prev: String, args: String? = nil)
      -> AuditChain.Record
    {
      AuditChain.seal(
        AuditChain.Record(
          seq: seq, at: Date(timeIntervalSince1970: 1_756_000_000 + Double(seq)),
          origin: "prod/shopify", kind: .call, text: text, args: args, prev: prev))
    }

    /// A sealed run of `count` records, each linked to the one before.
    func chain(_ count: Int, from: String = AuditChain.genesis) -> [AuditChain.Record] {
      var out: [AuditChain.Record] = []
      var prev = from
      for seq in 1...count {
        let sealed = record(seq, "tool_\(seq)", prev: prev)
        out.append(sealed)
        prev = sealed.hash
      }
      return out
    }

    print("\nAudit chain: a sequence nobody touched")

    let clean = chain(5)
    let cleanLines = clean.map { AuditChain.line($0) }
    let cleanReport = AuditChain.verify(lines: cleanLines)
    check("five records verify", cleanReport.isIntact)
    check("and are all counted", cleanReport.records == 5)
    check("the head is the last hash", cleanReport.head == clean[4].hash)
    check("a blank line is skipped, not failed", AuditChain.verify(lines: cleanLines + [""]).isIntact)
    check("an empty log verifies as genesis", AuditChain.verify(lines: []).head == AuditChain.genesis)

    print("\nAudit chain: tampering")

    // An edited field. The record still parses and still links; only its own
    // hash stops matching, which is the whole point of hashing the fields.
    var edited = cleanLines
    edited[2] = edited[2].replacingOccurrences(of: "tool_3", with: "tool_X")
    let editedReport = AuditChain.verify(lines: edited)
    check("an edited field is caught", !editedReport.isIntact)
    check("and is named by its seq", editedReport.failures.contains(.brokenHash(seq: 3)))

    // A deleted middle record. Nothing is edited, so every hash still matches
    // its own body — the break is the LINK, which is the reason `prev` exists.
    var deleted = cleanLines
    deleted.remove(at: 2)
    let deletedReport = AuditChain.verify(lines: deleted)
    check("a deleted middle record is caught", !deletedReport.isIntact)
    check("as a broken link on the record after it", deletedReport.failures.contains(.brokenLink(seq: 4)))
    check("and as a gap in the sequence", deletedReport.failures.contains(.outOfOrder(seq: 4)))

    // Reordering. Hashes still match their bodies; the links do not.
    var swapped = cleanLines
    swapped.swapAt(1, 2)
    check("a reordered pair is caught", !AuditChain.verify(lines: swapped).isIntact)

    // THE ONE A CHAIN CANNOT CATCH, and the reason the manifest carries a
    // count. Lopping off the tail leaves a shorter, perfectly valid chain.
    let truncated = Array(cleanLines.prefix(3))
    let truncatedReport = AuditChain.verify(lines: truncated)
    check("a truncated tail still verifies", truncatedReport.isIntact)
    check("but the count is lower", truncatedReport.records == 3)
    check("and the head has moved back", truncatedReport.head == clean[2].hash)

    check(
      "a corrupt line is reported by line number",
      AuditChain.verify(lines: ["{not json"]).failures == [.unreadable(line: 1)])
    check(
      "a record from a future format is refused rather than hashed",
      AuditChain.verify(lines: [cleanLines[0].replacingOccurrences(of: "\"v\":1", with: "\"v\":9")])
        .failures.contains(.unknownVersion(line: 1, version: 9)))

    print("\nAudit chain: segments")

    // Retention prunes whole segments, so a segment must link to the one
    // before it. Verified against the right head it is intact; against genesis
    // it is a broken link on its first record, which is what stops a dropped
    // segment from passing as a complete log.
    let second = chain(3, from: clean[4].hash).map { AuditChain.line($0) }
    check("a segment verifies from the previous head", AuditChain.verify(lines: second, from: clean[4].hash).isIntact)
    check(
      "and fails from genesis",
      AuditChain.verify(lines: second).failures.contains(.brokenLink(seq: 1)))

    print("\nAudit chain: the export manifest")

    // These bytes are what a signature is taken over, so a change to them is a
    // change to what "signed" means. The export path is otherwise reachable
    // only through a save panel, which no check can click.
    let described = [
      AuditChain.SegmentEntry(name: "audit-0001.jsonl", records: 5, sha256: "aa"),
      AuditChain.SegmentEntry(name: "audit-0002.jsonl", records: 3, sha256: "bb"),
    ]
    let card = AuditChain.manifest(
      app: "Bastion 1.1.0", exportedAt: Date(timeIntervalSince1970: 1_756_000_000),
      records: 8, segments: described, head: "c17b", intact: true)

    check("the manifest parses as JSON", (try? JSONSerialization.jsonObject(with: Data(card.utf8))) != nil)
    let decoded =
      (try? JSONSerialization.jsonObject(with: Data(card.utf8))) as? [String: Any] ?? [:]
    check("it names the format", decoded["format"] as? String == "bastion-audit")
    check("and the version", decoded["version"] as? Int == AuditChain.version)
    // The count is the only thing that makes a truncated export visible, since
    // a shortened chain still verifies.
    check("it carries the record count", decoded["records"] as? Int == 8)
    check("and the chain head", decoded["head"] as? String == "c17b")
    check("and every segment", (decoded["segments"] as? [Any])?.count == 2)
    check("with each segment's digest", card.contains("\"sha256\":\"aa\""))
    // Pinned to the exact instant, not just the shape: a formatter that
    // followed the machine's calendar or zone would write a manifest that
    // verifies where it was made and nowhere else, and a loose check would
    // never notice.
    check("the timestamp is that instant in UTC", card.contains("2025-08-24T01:46:40.000Z"))

    // Deterministic for fixed inputs, or a signature could not be checked twice.
    let again = AuditChain.manifest(
      app: "Bastion 1.1.0", exportedAt: Date(timeIntervalSince1970: 1_756_000_000),
      records: 8, segments: described, head: "c17b", intact: true)
    check("building it twice gives the same bytes", again == card)
    check(
      "and a different head gives different bytes",
      AuditChain.manifest(
        app: "Bastion 1.1.0", exportedAt: Date(timeIntervalSince1970: 1_756_000_000),
        records: 8, segments: described, head: "dead", intact: true) != card)
    check(
      "a failed verification is recorded rather than hidden",
      AuditChain.manifest(
        app: "Bastion 1.1.0", exportedAt: Date(timeIntervalSince1970: 1_756_000_000),
        records: 8, segments: described, head: "c17b", intact: false).contains("\"intact\":false"))

    print("\nAudit chain: the canonical form")

    // The hash is taken over bytes a verifier must be able to rebuild. These
    // are the inputs most likely to make two implementations disagree.
    let quoted = record(1, "tool", prev: AuditChain.genesis, args: #"{"q":"he said \"hi\""}"#)
    check("quotes survive a round trip", AuditChain.verify(lines: [AuditChain.line(quoted)]).isIntact)
    let newline = record(1, "tool", prev: AuditChain.genesis, args: "line1\nline2\ttab")
    check("newlines and tabs do", AuditChain.verify(lines: [AuditChain.line(newline)]).isIntact)
    let unicode = record(1, "tool", prev: AuditChain.genesis, args: #"{"note":"café 🔒 日本"}"#)
    check("multibyte text does", AuditChain.verify(lines: [AuditChain.line(unicode)]).isIntact)
    let control = record(1, "tool", prev: AuditChain.genesis, args: "bell\u{07}null-ish\u{01}")
    check("control characters do", AuditChain.verify(lines: [AuditChain.line(control)]).isIntact)

    // Sealing twice must not change anything, or a record re-read and re-sealed
    // would look edited.
    check("sealing is deterministic", AuditChain.seal(quoted).hash == quoted.hash)
    // And an omitted optional must not be written as null: a writer and a
    // verifier that disagree about that produce different bytes.
    check(
      "an absent argument is omitted, not nulled",
      !AuditChain.canonical(record(1, "t", prev: AuditChain.genesis)).contains("args"))

    // MARK: - Searching the log

    print("\nLog search: what a query matches")

    func row(_ text: String, origin: String = "prod/shopify", args: String? = nil,
             result: String? = nil) -> LogStore.Entry {
      LogStore.Entry(
        at: Date(), origin: origin, level: .call, text: text, arguments: args, result: result)
    }

    let order = row(
      "shopify_get_order", args: #"{"id":"gid://shopify/Order/992"}"#,
      result: #"{"total":"48.20"}"#)

    check("the tool name matches", order.matches("get_order"))
    check("the profile matches", order.matches("prod"))
    // The reason to search a log at all: the identifier is in the arguments,
    // not in the tool name.
    check("an argument matches", order.matches("992"))
    check("a result matches", order.matches("48.20"))
    check("something absent does not", !order.matches("keycloak"))

    check("case is ignored", order.matches("SHOPIFY_GET_ORDER"))
    check("in payloads too", order.matches("ORDER/992"))
    check("accents are ignored", row("café_tool").matches("cafe"))
    check("a row with no payload still matches its name", row("ping").matches("ping"))
    check("and does not match a payload it does not have", !row("ping").matches("992"))

    print("\nLog search: a match the row would not show")

    // A payload is previewed at a fixed length, so a match past that point
    // lists a row with no visible reason for being there — which reads as a
    // bug rather than as a truncation. `FeedRow` opens such a row itself.
    let buried = row("tool", args: String(repeating: "x", count: 300) + "needle")
    check("a match past the preview is flagged", buried.matchIsHidden("needle", preview: 160))
    check(
      "a match inside the preview is not",
      !row("tool", args: "needle" + String(repeating: "x", count: 300))
        .matchIsHidden("needle", preview: 160))
    check("a match in the tool name is not", !order.matchIsHidden("get_order", preview: 160))
    check("a match in the origin is not", !order.matchIsHidden("prod", preview: 160))
    check("a row that does not match at all is not", !order.matchIsHidden("absent", preview: 160))
    check("an empty query flags nothing", !buried.matchIsHidden("", preview: 160))

    print("\n\(checks - failures)/\(checks) passed")
    if failures > 0 {
      print("\(failures) failed")
      exit(1)
    }
  }
}
