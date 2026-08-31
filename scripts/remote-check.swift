import Foundation

/// Asserts the rules `RemoteEndpoint` promises about where a remote server may
/// live, and the SSE collapse `RemoteInstance` depends on.
///
/// A standalone `swiftc` binary rather than an XCTest bundle, for the reason
/// `wiring-check.swift` gives: the Xcode project has two synchronized-group
/// targets and no test target, so adding one means hand-editing
/// project.pbxproj — a bigger and riskier diff than the code under test.
///
/// **Why this exists at all.** The catalog's KEPT rule is that nothing arriving
/// over the wire can name a package, a path or an argv. A remote server
/// replaces the command line with a URL, and a URL in the installed list is a
/// `fetch(whatever_you_typed)` primitive. `RemoteEndpoint` is the whole answer,
/// and an answer nobody checks is a comment. This is the check.
///
/// Run with `make remote-check`.
@main
struct RemoteCheck {
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

  /// Shape-only, so these never touch the network and never depend on DNS.
  static func refusesShape(_ text: String) -> Bool {
    guard let url = URL(string: text) else { return true }
    do {
      try RemoteEndpoint.validateShape(url)
      return false
    } catch {
      return true
    }
  }

  static func acceptsShape(_ text: String) -> Bool {
    guard let url = URL(string: text) else { return false }
    do {
      try RemoteEndpoint.validateShape(url)
      return true
    } catch {
      return false
    }
  }

  /// The post-connection check, against an address rather than a name.
  static func refusesAddress(_ address: String) -> Bool {
    do {
      try RemoteEndpoint.verify(connectedTo: address, host: "example.com")
      return false
    } catch {
      return true
    }
  }

  static func main() {
    print("\nScheme")
    // The credential leaves the machine on every call. Plaintext is not a
    // degraded mode, it is a different promise.
    check("http:// is refused", refusesShape("http://mcp.example.com"))
    check("ws:// is refused", refusesShape("ws://mcp.example.com"))
    check("file:// is refused", refusesShape("file:///etc/passwd"))
    check("https:// is accepted", acceptsShape("https://mcp.stripe.com"))
    check("https with a path is accepted", acceptsShape("https://mcp.example.com/v1/mcp"))

    print("\nBastion's own gateway")
    // The sharpest one. A client's bearer token is minted for the gateway, so a
    // "remote server" pointed back at it is a way to replay that token against
    // every other profile in the app.
    check("127.0.0.1 is refused", refusesShape("https://127.0.0.1:8720/s/prod/shopify"))
    check("the gateway port is refused", refusesShape("https://127.0.0.1:8720"))
    check("localhost is refused", refusesShape("https://localhost:8720"))
    check("a localhost subdomain is refused", refusesShape("https://x.localhost"))
    check("::1 is refused", refusesShape("https://[::1]:8720"))
    check("127.0.0.2 is refused", refusesShape("https://127.0.0.2"))
    check("an IPv4-mapped loopback is refused", refusesShape("https://[::ffff:127.0.0.1]"))

    print("\nThis network")
    check("10/8 is refused", refusesShape("https://10.0.0.1"))
    check("172.16/12 is refused", refusesShape("https://172.16.5.4"))
    check("172.31/12 is refused", refusesShape("https://172.31.255.254"))
    check("192.168/16 is refused", refusesShape("https://192.168.1.1"))
    check("a .local name is refused", refusesShape("https://nas.local"))
    check("unique-local IPv6 is refused", refusesShape("https://[fd00::1]"))
    check("172.32 is NOT private", acceptsShape("https://172.32.0.1"))

    print("\nLink-local and the metadata address")
    // 169.254.169.254 hands out cloud credentials to anything that asks. It
    // needs no line of its own — it is inside link-local — and that is the
    // point: a denylist of remembered addresses would have missed its
    // neighbours.
    check("the metadata address is refused", refusesShape("https://169.254.169.254"))
    check("link-local generally is refused", refusesShape("https://169.254.1.1"))
    check("IPv6 link-local is refused", refusesShape("https://[fe80::1]"))
    check("a scoped IPv6 link-local is refused", refusesShape("https://[fe80::1%25en0]"))

    print("\nOther unroutable space")
    check("0.0.0.0 is refused", refusesShape("https://0.0.0.0"))
    check("carrier-grade NAT is refused", refusesShape("https://100.64.0.1"))
    check("multicast is refused", refusesShape("https://239.0.0.1"))

    print("\nPublic addresses still work")
    check("a public IPv4 literal is accepted", acceptsShape("https://93.184.216.34"))
    check("a public IPv6 literal is accepted", acceptsShape("https://[2606:2800:220:1::1]"))

    print("\nThe check after the connection")
    // Same judgement, applied to the address the connection actually landed on
    // — which is what catches a name that resolved somewhere else.
    check("a loopback peer is refused", refusesAddress("127.0.0.1"))
    check("a private peer is refused", refusesAddress("192.168.1.10"))
    check("a metadata peer is refused", refusesAddress("169.254.169.254"))
    check("an IPv6 loopback peer is refused", refusesAddress("::1"))
    check("a public peer is accepted", !refusesAddress("93.184.216.34"))
    // Nothing observed is not the same as nothing wrong, but there is also
    // nothing to judge — `preflight` is what covers this case, and it ran
    // before the request.
    check("no observed address is not a failure", !refusesAddress(""))

    print("\nNo host at all")
    check("a bare scheme is refused", refusesShape("https://"))

    print("\nCollapsing an SSE answer")
    // A Streamable HTTP server may answer one POST with a stream. Bastion reads
    // it and hands back the one frame that answers the request; everything else
    // on the way has nowhere to go.
    func payloads(_ text: String) -> [String] {
      ServerSentEvents.dataPayloads(in: Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }
    check(
      "one event is read",
      payloads("data: {\"id\":1}\n\n") == ["{\"id\":1}"])
    check(
      "CRLF framing is read",
      payloads("data: {\"id\":1}\r\n\r\n") == ["{\"id\":1}"])
    check(
      "the event: line is ignored",
      payloads("event: message\ndata: {\"id\":1}\n\n") == ["{\"id\":1}"])
    check(
      "a keep-alive comment is ignored",
      payloads(": ping\n\ndata: {\"id\":1}\n\n") == ["{\"id\":1}"])
    check(
      "multi-line data is joined with newlines",
      payloads("data: {\ndata: \"id\":1}\n\n") == ["{\n\"id\":1}"])
    check(
      "several events keep their order",
      payloads("data: one\n\ndata: two\n\ndata: three\n\n") == ["one", "two", "three"])
    check(
      "a stream with no trailing blank line still yields its last event",
      payloads("data: {\"id\":1}") == ["{\"id\":1}"])
    check(
      "exactly one leading space is stripped, and no more",
      payloads("data:  two-spaces\n\n") == [" two-spaces"])
    check("an empty body yields nothing", payloads("").isEmpty)
    check("a body with no data lines yields nothing", payloads("event: ping\n\n").isEmpty)

    print("\nOAuth: finding the authorization server")
    // Parsed from the 401, never guessed. A server is entitled to put its
    // metadata anywhere and say so here.
    func meta(_ header: String) -> String? {
      RemoteOAuth.resourceMetadataURL(fromChallenge: header)?.absoluteString
    }
    check(
      "a bare resource_metadata is read",
      meta("Bearer resource_metadata=https://mcp.stripe.com/.well-known/oauth-protected-resource")
        == "https://mcp.stripe.com/.well-known/oauth-protected-resource")
    check(
      "a quoted one is read",
      meta("Bearer resource_metadata=\"https://x.example/m\"") == "https://x.example/m")
    check(
      "it is found after another parameter",
      meta("Bearer error=\"invalid_token\", resource_metadata=https://x.example/m")
        == "https://x.example/m")
    check("a challenge naming nothing yields nil", meta("Bearer realm=\"x\"") == nil)

    print("\nOAuth: RFC 8414 metadata locations")
    // The counter-intuitive one, and the one Stripe actually serves: the
    // well-known segment is INSERTED between host and issuer path.
    let issuer = URL(string: "https://access.stripe.com/mcp")!
    let candidates = RemoteOAuth.metadataURLs(forIssuer: issuer).map(\.absoluteString)
    check(
      "path-insertion is tried first",
      candidates.first == "https://access.stripe.com/.well-known/oauth-authorization-server/mcp")
    check(
      "the naive concatenation is tried too",
      candidates.contains("https://access.stripe.com/mcp/.well-known/oauth-authorization-server"))
    let rootIssuer = RemoteOAuth.metadataURLs(forIssuer: URL(string: "https://as.example")!)
      .map(\.absoluteString)
    check(
      "a path-less issuer gets the plain well-known",
      rootIssuer.first == "https://as.example/.well-known/oauth-authorization-server")

    print("\nOAuth: the issuer check")
    // A document fetched for one issuer that declares another is either
    // misconfigured or aimed somewhere else. Neither is worth guessing through.
    func parses(_ declared: String) -> Bool {
      let json: [String: Any] = [
        "issuer": declared,
        "authorization_endpoint": "https://as.example/auth",
        "token_endpoint": "https://as.example/token",
        "code_challenge_methods_supported": ["S256"],
      ]
      return (try? RemoteOAuth.Metadata.parse(json, expecting: URL(string: "https://as.example")!))
        != nil
    }
    check("a matching issuer parses", parses("https://as.example"))
    check("a trailing slash is not a mismatch", parses("https://as.example/"))
    check("a different issuer is refused", !parses("https://evil.example"))
    check("no issuer at all is refused", !parses(""))
    check(
      "a plaintext endpoint is refused",
      (try? RemoteOAuth.Metadata.parse(
        [
          "issuer": "https://as.example", "authorization_endpoint": "http://as.example/auth",
          "token_endpoint": "https://as.example/token",
        ], expecting: URL(string: "https://as.example")!)) == nil)

    print("\nOAuth: PKCE")
    // RFC 7636 §A's own test vector. PKCE is what makes a public client safe,
    // so a wrong challenge is the whole scheme quietly not working.
    check(
      "S256 matches the RFC test vector",
      RemoteOAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    check("no padding survives", !RemoteOAuth.PKCE().challenge.contains("="))
    check("nothing needs URL-escaping", {
      let c = RemoteOAuth.PKCE().challenge
      return !c.contains("+") && !c.contains("/")
    }())
    check(
      "two verifiers differ",
      RemoteOAuth.PKCE().verifier != RemoteOAuth.PKCE().verifier)

    print("\nOAuth: the callback")
    // A loopback redirect, not a private-use scheme. Stripe's consent page
    // blocks navigation to anything that is not http(s), so the code comes back
    // to a one-shot listener on 127.0.0.1 instead — see RemoteOAuthCallback.
    func code(_ query: String, state: String) -> String? {
      try? RemoteOAuth.code(
        fromCallback: URL(string: "http://127.0.0.1:53682/oauth/callback?\(query)")!,
        expecting: state)
    }
    check("a matching state yields the code", code("code=abc&state=xyz", state: "xyz") == "abc")
    // The one that matters: a response to a request this app never made.
    check("a mismatched state is refused", code("code=abc&state=nope", state: "xyz") == nil)
    check("a missing state is refused", code("code=abc", state: "xyz") == nil)
    check("an error response is refused", code("error=access_denied&state=xyz", state: "xyz") == nil)

    print("\nOAuth: token requests and token sets")
    // A code containing + or & is legal and would arrive truncated unencoded —
    // an intermittent failure with no visible cause.
    check(
      "form bodies percent-encode their values",
      String(decoding: RemoteOAuth.formBody([("code", "a+b&c")]), as: UTF8.self)
        == "code=a%2Bb%26c")
    let previous = RemoteOAuth.TokenSet(
      accessToken: "old", refreshToken: "keep-me", expiresAt: nil, scope: "mcp",
      clientID: "cid", issuer: "https://as.example")
    let refreshed = try? RemoteOAuth.tokenSet(
      from: ["access_token": "new", "expires_in": 3600], clientID: "cid",
      issuer: URL(string: "https://as.example")!, previous: previous)
    // A refresh response may omit the refresh token, meaning "keep yours".
    // Dropping it would make every such refresh the last one possible.
    check("an omitted refresh token is kept", refreshed?.refreshToken == "keep-me")
    check("the new access token is taken", refreshed?.accessToken == "new")
    check("expiry is derived from expires_in", refreshed?.expiresAt != nil)
    check(
      "an error response throws",
      (try? RemoteOAuth.tokenSet(
        from: ["error": "invalid_grant"], clientID: "c",
        issuer: URL(string: "https://as.example")!, previous: nil)) == nil)
    check(
      "a response with no access token throws",
      (try? RemoteOAuth.tokenSet(
        from: ["token_type": "Bearer"], clientID: "c",
        issuer: URL(string: "https://as.example")!, previous: nil)) == nil)

    // Refreshed early on purpose: a token that dies between the check and the
    // request arriving costs a round trip and a retry.
    func expiring(inSeconds: Double) -> Bool {
      RemoteOAuth.TokenSet(
        accessToken: "a", refreshToken: nil, expiresAt: Date().addingTimeInterval(inSeconds),
        scope: nil, clientID: "c", issuer: "https://as.example"
      ).isExpired()
    }
    check("a token due in 30s counts as expired", expiring(inSeconds: 30))
    check("a token good for an hour does not", !expiring(inSeconds: 3600))
    check(
      "a token with no expiry never does",
      !RemoteOAuth.TokenSet(
        accessToken: "a", refreshToken: nil, expiresAt: nil, scope: nil, clientID: "c",
        issuer: "https://as.example"
      ).isExpired())

    print("\nOAuth: the loopback callback listener")
    // This exists because the private-use scheme it replaced looked fine right
    // up until a person clicked Allow: Stripe's consent page refuses to
    // navigate to a non-http(s) protocol, so the code was minted and dropped.
    // Registration accepting a redirect URI proves nothing about that, so the
    // listener gets a real request here rather than a second consent screen.
    do {
      let callback = try RemoteOAuthCallback()
      check("it binds a port", callback.port > 0)
      check(
        "the redirect URI is loopback http",
        callback.redirectURI == "http://127.0.0.1:\(callback.port)/oauth/callback")

      let session = URLSession(configuration: .ephemeral)
      // A stray request first. A favicon fetch or a probe must not end the
      // flow, or an abandoned tab could cancel somebody's authorization.
      let stray = DispatchSemaphore(value: 0)
      session.dataTask(with: URL(string: "http://127.0.0.1:\(callback.port)/favicon.ico")!) {
        _, _, _ in stray.signal()
      }.resume()
      _ = stray.wait(timeout: .now() + 5)

      let hit = URL(
        string: "http://127.0.0.1:\(callback.port)/oauth/callback?code=oac_x&state=st4te")!
      session.dataTask(with: hit) { _, _, _ in }.resume()

      let received = try callback.waitForCallback(timeout: 10)
      check(
        "a stray path does not end the flow, and the real one is returned",
        received.absoluteString.contains("code=oac_x"))
      check(
        "the code parses out of it",
        (try? RemoteOAuth.code(fromCallback: received, expecting: "st4te")) == "oac_x")
      check(
        "and a wrong state on the same URL is still refused",
        (try? RemoteOAuth.code(fromCallback: received, expecting: "other")) == nil)
    } catch {
      check("the loopback listener works — \(error.localizedDescription)", false)
    }

    print("\nThe write gate: what a client is allowed to see")
    // The rule that decides whether `stripe_api_write` reaches a model. It had
    // no test until a bug in which the gate itself was right and every consumer
    // of "does this server write" was wrong.
    func tool(_ name: String, readOnly: Bool? = nil, destructive: Bool? = nil) -> [String: Any] {
      var out: [String: Any] = ["name": name]
      var hints: [String: Any] = [:]
      if let readOnly { hints["readOnlyHint"] = readOnly }
      if let destructive { hints["destructiveHint"] = destructive }
      if !hints.isEmpty { out["annotations"] = hints }
      return out
    }
    func names(
      _ tools: [[String: Any]], declared: [String] = [], annotated: Set<String> = [],
      allowWrites: Bool
    ) -> [String] {
      WriteGate.visibleTools(
        in: tools, declared: declared, annotated: annotated, allowWrites: allowWrites
      ).compactMap { $0["name"] as? String }
    }

    let stripe = [tool("stripe_api_read"), tool("stripe_api_write"), tool("create_refund")]
    let declared = ["stripe_api_write", "create_refund", "stripe_report"]

    check(
      "a declared write tool is hidden with writes off",
      names(stripe, declared: declared, allowWrites: false) == ["stripe_api_read"])
    check(
      "and is offered with writes on",
      names(stripe, declared: declared, allowWrites: true).count == 3)
    check(
      "a read tool survives either way",
      names(stripe, declared: declared, allowWrites: false).contains("stripe_api_read"))
    check(
      "a declared name the server does not offer changes nothing",
      names([tool("stripe_api_read")], declared: declared, allowWrites: false)
        == ["stripe_api_read"])

    // The half a denylist cannot do on its own: a mutating tool added after
    // somebody wrote the manifest list.
    let annotatedNew = [tool("stripe_api_read"), tool("brand_new_writer", readOnly: false)]
    check(
      "readOnlyHint:false is gated even though the manifest never named it",
      names(
        annotatedNew, declared: declared,
        annotated: WriteGate.annotatedWriteTools(in: annotatedNew), allowWrites: false)
        == ["stripe_api_read"])
    check(
      "destructiveHint:true is gated the same way",
      WriteGate.annotatedWriteTools(in: [tool("wipe", destructive: true)]) == ["wipe"])
    check(
      "readOnlyHint:true is not gated",
      WriteGate.annotatedWriteTools(in: [tool("look", readOnly: true)]).isEmpty)
    check(
      "a tool with no annotations at all is not gated by annotation",
      WriteGate.annotatedWriteTools(in: [tool("plain")]).isEmpty)

    print("\nThe write gate: learning, and the frames it must not touch")
    // Annotations are recorded even from a list served with writes ON, so a
    // profile that later turns them off gates what it learned.
    let learnedWithWritesOn = WriteGate.filter(
      ["result": ["tools": annotatedNew]], method: "tools/list", declared: [], annotated: [],
      allowWrites: true)
    check(
      "annotations are learned from a list served with writes on",
      learnedWithWritesOn.learned == ["brand_new_writer"])
    check(
      "and nothing is hidden from that same answer",
      ((learnedWithWritesOn.response["result"] as? [String: Any])?["tools"] as? [[String: Any]])?
        .count == 2)
    check(
      "what was learned then gates a later call",
      WriteGate.isWriteTool(
        "brand_new_writer", declared: [], annotated: learnedWithWritesOn.learned))

    let call: [String: Any] = ["result": ["content": [["type": "text", "text": "hi"]]]]
    check(
      "a tools/call result is passed through untouched",
      (WriteGate.filter(
        call, method: "tools/call", declared: declared, annotated: [], allowWrites: false
      ).response["result"] as? [String: Any])?["content"] != nil)
    check(
      "an error frame is passed through untouched",
      WriteGate.filter(
        ["error": ["code": -32601]], method: "tools/list", declared: declared, annotated: [],
        allowWrites: false
      ).response["error"] != nil)
    check(
      "a malformed tool with no name is kept rather than silently deleted",
      names([["description": "nameless"]], declared: declared, allowWrites: false).isEmpty
        && WriteGate.visibleTools(
          in: [["description": "nameless"]], declared: declared, annotated: [], allowWrites: false
        ).count == 1)

    print("\n\(checks - failures)/\(checks) passed")
    if failures > 0 {
      print("\(failures) failed")
      exit(1)
    }
  }
}
