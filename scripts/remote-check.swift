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

    print("\nA server on this machine")
    // The one exception: a typed loopback literal, where a credential never
    // leaves the machine. Narrow on purpose, so each neighbour is asserted too.
    check("http://127.0.0.1 is accepted", acceptsShape("http://127.0.0.1:8788/mcp"))
    check("https://127.0.0.1 is accepted", acceptsShape("https://127.0.0.1:8788/mcp"))
    check("http://[::1] is accepted", acceptsShape("http://[::1]:8788/mcp"))
    check("http://localhost is still refused", refusesShape("http://localhost:8788/mcp"))
    check("http://127.0.0.2 is still refused", refusesShape("http://127.0.0.2:8788/mcp"))
    check(
      "http to an IPv4-mapped loopback is still refused",
      refusesShape("http://[::ffff:127.0.0.1]:8788/mcp"))
    check("http to a private address is still refused", refusesShape("http://192.168.1.1:8788"))
    check("ws://127.0.0.1 is still refused", refusesShape("ws://127.0.0.1:8788"))
    check("the gateway port over http is refused", refusesShape("http://127.0.0.1:8720/s/p/x"))

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

    print("\nThe stored gateway port")
    // Settings' port field is a bare integer with no range, and `UInt16(_:)`
    // traps outside one, so a typed 87200 crashed every launch after it.
    check("unset is the default", RemoteEndpoint.gatewayPort(stored: 0) == 8720)
    check("a valid port is kept", RemoteEndpoint.gatewayPort(stored: 8799) == 8799)
    check("65535 is kept", RemoteEndpoint.gatewayPort(stored: 65535) == 65535)
    check("past 65535 is the default", RemoteEndpoint.gatewayPort(stored: 87200) == 8720)
    check("a negative port is the default", RemoteEndpoint.gatewayPort(stored: -1) == 8720)

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
    func landed(_ address: String, typed host: String) -> Bool {
      (try? RemoteEndpoint.verify(connectedTo: address, host: host)) != nil
    }
    check("a typed 127.0.0.1 may land on loopback", landed("127.0.0.1", typed: "127.0.0.1"))
    check("a typed ::1 may land on loopback", landed("::1", typed: "::1"))
    check("a typed 127.0.0.1 may not land elsewhere", !landed("192.168.1.10", typed: "127.0.0.1"))
    // Nothing observed used to pass, on the reasoning that `preflight` had
    // judged the name. But `preflight` is the resolution BEFORE the request,
    // and a rebinding answer is exactly a second resolution that differs —
    // so an exchange whose peer was never seen (its metrics arrived late, or
    // not at all) is one the check cannot vouch for.
    func refusesPeers(_ addresses: [String]?) -> Bool {
      (try? RemoteEndpoint.verify(connectedTo: addresses, host: "example.com")) == nil
    }
    check("an exchange whose peer was never observed is refused", refusesPeers(nil))
    check("and one that observed no address at all", refusesPeers([]))
    check("a public peer on every hop is accepted", !refusesPeers(["93.184.216.34"]))
    check(
      "one private hop among public ones is refused",
      refusesPeers(["93.184.216.34", "10.0.0.5"]))

    print("\nAn internal host the user listed")
    // The second exception: an exact name, landing inside the private networks
    // it was listed with, over https. Each neighbour is asserted, because the
    // ways this goes wrong are all "a little wider than intended".
    let listed = [InternalHost(host: "workers.corp.example", networks: ["10.240.20.35/32"])]
    let literal = [InternalHost(host: "10.240.20.40", networks: ["10.240.20.0/24"])]
    func lands(_ address: String, on host: String, _ list: [InternalHost]) -> Bool {
      (try? RemoteEndpoint.verify(connectedTo: address, host: host, internalHosts: list)) != nil
    }
    func shapeOK(_ text: String, _ list: [InternalHost]) -> Bool {
      guard let url = URL(string: text) else { return false }
      return (try? RemoteEndpoint.validateShape(url, internalHosts: list)) != nil
    }
    check(
      "a listed host may land inside its network",
      lands("10.240.20.35", on: "workers.corp.example", listed))
    check(
      "the match ignores case and a trailing dot",
      lands("10.240.20.35", on: "Workers.Corp.Example.", listed))
    check(
      "an unlisted host landing there is refused",
      !lands("10.240.20.35", on: "other.corp.example", listed))
    check(
      "a subdomain of a listed host is a different host",
      !lands("10.240.20.35", on: "evil.workers.corp.example", listed))
    check(
      "a listed host landing elsewhere on the network is refused",
      !lands("10.240.20.36", on: "workers.corp.example", listed))
    check(
      "a listed host landing on the router is refused",
      !lands("192.168.1.1", on: "workers.corp.example", listed))
    check(
      "a listed host landing on loopback is refused",
      !lands("127.0.0.1", on: "workers.corp.example", listed))
    check(
      "a listed host landing on the metadata address is refused",
      !lands("169.254.169.254", on: "workers.corp.example", listed))
    check(
      "an IPv4-mapped form of its address is judged as that address",
      lands("::ffff:10.240.20.35", on: "workers.corp.example", listed))
    check(
      "one hop outside its network among inside ones is refused",
      (try? RemoteEndpoint.verify(
        connectedTo: ["10.240.20.35", "10.0.0.9"], host: "workers.corp.example",
        internalHosts: listed)) == nil)
    check(
      "the refusal names the networks it was listed for",
      {
        do {
          try RemoteEndpoint.verify(
            connectedTo: "10.9.9.9", host: "workers.corp.example", internalHosts: listed)
          return false
        } catch {
          return error.localizedDescription.contains("10.240.20.35/32")
        }
      }())
    // The guard must not lean on validation alone. These lists never pass
    // `InternalHosts.validated`, and that is the point: a list that reached the
    // guard some other way still cannot open loopback or link-local.
    let unvalidatedLoopback = [
      InternalHost(host: "workers.corp.example", networks: ["127.0.0.0/8"])
    ]
    let unvalidatedMetadata = [
      InternalHost(host: "workers.corp.example", networks: ["169.254.0.0/16"])
    ]
    let unvalidatedPublic = [
      InternalHost(host: "workers.corp.example", networks: ["93.184.216.0/24"])
    ]
    check(
      "an unvalidated loopback network still cannot open loopback",
      !lands("127.0.0.1", on: "workers.corp.example", unvalidatedLoopback))
    check(
      "an unvalidated link-local network still cannot open the metadata address",
      !lands("169.254.169.254", on: "workers.corp.example", unvalidatedMetadata))
    check(
      "and a public network in a list changes nothing for public addresses",
      lands("93.184.216.34", on: "workers.corp.example", unvalidatedPublic))
    check("a listed private literal is accepted", shapeOK("https://10.240.20.40/mcp", literal))
    check("http to a listed host is still refused", !shapeOK("http://10.240.20.40/mcp", literal))
    check(
      "a literal outside its own network is refused",
      !shapeOK(
        "https://10.240.21.1/mcp", [InternalHost(host: "10.240.21.1", networks: ["10.240.20.0/24"])]
      ))
    check(
      "an empty list changes nothing",
      !shapeOK("https://10.240.20.40/mcp", []) && refusesShape("https://10.240.20.40/mcp"))
    check(
      "the unlisted refusal says how to list a host",
      {
        guard let url = URL(string: "https://10.1.1.1") else { return false }
        do {
          try RemoteEndpoint.validateShape(url, internalHosts: [])
          return false
        } catch {
          return error.localizedDescription.contains("Internal hosts")
        }
      }())

    print("\nWhat a listing may hold")
    // Validated on every add and every load, so a hand-edited file cannot
    // widen the rule past what Settings would accept.
    func valid(_ host: String, _ networks: [String]) -> Bool {
      (try? InternalHosts.validated(InternalHost(host: host, networks: networks))) != nil
    }
    check("a name with a /32 is accepted", valid("workers.corp.example", ["10.240.20.35/32"]))
    check("172.16/12 is accepted", valid("a.corp.example", ["172.20.0.0/16"]))
    check("192.168/16 is accepted", valid("a.corp.example", ["192.168.4.0/24"]))
    check("unique-local IPv6 is accepted", valid("a.corp.example", ["fd12:3456::/48"]))
    check("loopback is never listable", !valid("a.corp.example", ["127.0.0.1/32"]))
    check("link-local is never listable", !valid("a.corp.example", ["169.254.169.254/32"]))
    check("a public network is never listable", !valid("a.corp.example", ["93.184.216.0/24"]))
    check("CGNAT is never listable", !valid("a.corp.example", ["100.64.0.0/10"]))
    check("0.0.0.0/0 is never listable", !valid("a.corp.example", ["0.0.0.0/0"]))
    check("a network wider than its range is refused", !valid("a.corp.example", ["10.0.0.0/7"]))
    check("172.32 is not private", !valid("a.corp.example", ["172.32.0.0/16"]))
    check("IPv6 link-local is never listable", !valid("a.corp.example", ["fe80::/10"]))
    check("a bare address with no prefix is refused", !valid("a.corp.example", ["10.0.0.1"]))
    check("no network at all is refused", !valid("a.corp.example", []))
    check("localhost is refused by name", !valid("localhost", ["10.0.0.1/32"]))
    check("a .local name is refused", !valid("nas.local", ["192.168.1.0/24"]))
    check("a host with a scheme is refused", !valid("https://a.corp.example", ["10.0.0.1/32"]))
    check("a host with a port is refused", !valid("a.corp.example:443", ["10.0.0.1/32"]))
    check("a wildcard is refused", !valid("*.corp.example", ["10.0.0.0/8"]))
    check("a single-label name is refused", !valid("intranet", ["10.0.0.1/32"]))
    check("a host led by a scope sign is refused", !valid("%10.0.0.1", ["10.0.0.0/8"]))
    check("a scope sign never leads an address", InternalHosts.Address("%10.0.0.1") == nil)
    check(
      "a network is stored canonical",
      (try? InternalHosts.validated(
        InternalHost(host: "a.corp.example", networks: ["10.240.20.99/24"])))?
        .networks == ["10.240.20.0/24"])
    check(
      "Look Up suggests only private addresses, as single hosts",
      InternalHosts.suggestedNetworks(for: ["10.240.20.35", "93.184.216.34", "127.0.0.1"])
        == ["10.240.20.35/32"])

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

    print("\nReading a stream as it arrives")
    // The buffered reader above treats the end of its input as the end of an
    // event, which is right for a complete body and wrong for one still
    // arriving: fed half a frame it would dispatch half a frame. `Parser` holds
    // the tail back until a blank line proves the event ended.
    func incremental(_ text: String, chunk size: Int) -> [String] {
      var parser = ServerSentEvents.Parser()
      var out: [Data] = []
      let bytes = Array(text.utf8)
      var index = 0
      while index < bytes.count {
        let end = min(index + size, bytes.count)
        out += parser.feed(Data(bytes[index..<end]))
        index = end
      }
      out += parser.finish()
      return out.map { String(decoding: $0, as: UTF8.self) }
    }
    // The property worth having, and the reason this is testable at all: for
    // ANY chunking of ANY body, reading it incrementally is the same as reading
    // it whole. A byte at a time is the worst case and the one a real socket
    // eventually produces.
    let bodies = [
      "data: {\"id\":1}\n\n",
      "data: {\"id\":1}\r\n\r\n",
      "data: one\n\ndata: two\n\ndata: three\n\n",
      "data: {\ndata: \"id\":1}\n\n",
      ": ping\n\ndata: {\"id\":1}\n\n",
      "event: message\ndata: a\n\ndata: b",
      "data: trailing-no-blank-line",
      "",
    ]
    var equivalent = true
    for body in bodies {
      for size in [1, 2, 3, 7, 64, 4096] where !(incremental(body, chunk: size) == payloads(body)) {
        equivalent = false
        print("       \(size)-byte chunks disagree on: \(body.debugDescription)")
      }
    }
    check("any chunking reads the same as the whole body", equivalent)

    // The half-frame case, stated on its own because it is the bug the type
    // exists to prevent rather than a property of it.
    var partial = ServerSentEvents.Parser()
    check(
      "a frame with no terminator yet yields nothing",
      partial.feed(Data("data: {\"id\"".utf8)).isEmpty)
    check(
      "and arrives whole once the blank line does",
      partial.feed(Data(":1}\n\n".utf8)).map { String(decoding: $0, as: UTF8.self) }
        == ["{\"id\":1}"])
    var straddling = ServerSentEvents.Parser()
    // A CRLF terminator split down the middle: the \r arrives in one read and
    // the \n in the next, so a boundary search that ran per-chunk would miss it.
    check(
      "a terminator split across reads yields nothing yet",
      straddling.feed(Data("data: a\r\n\r".utf8)).isEmpty)
    check(
      "and is found when the rest lands",
      straddling.feed(Data("\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["a"])
    var complete = ServerSentEvents.Parser()
    check(
      "two whole events and a partial third yield exactly two",
      complete.feed(Data("data: a\n\ndata: b\n\ndata: c".utf8)).count == 2)
    check(
      "and the third on finish",
      complete.finish().map { String(decoding: $0, as: UTF8.self) } == ["c"])

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
    // RFC 7235 §2.1: the auth-scheme is case-insensitive.
    check(
      "the scheme is read in any case",
      meta("bearer resource_metadata=https://x.example/m") == "https://x.example/m"
        && meta("BEARER resource_metadata=https://x.example/m") == "https://x.example/m")
    // A comma inside a quoted value is legal and used to cut the header in half,
    // truncating the URL and sending discovery to the well-known path against a
    // server that had just named its metadata.
    check(
      "a comma inside a quoted value does not split the challenge",
      meta("Bearer resource_metadata=\"https://x.example/m,n\"") == "https://x.example/m,n")
    check(
      "and it is still found after a quoted parameter carrying one",
      meta("Bearer error=\"bad, very bad\", resource_metadata=https://x.example/m")
        == "https://x.example/m")

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
    check(
      "nothing needs URL-escaping",
      {
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
    check(
      "an error response is refused", code("error=access_denied&state=xyz", state: "xyz") == nil)
    // State is checked BEFORE error, which is what the doc comment always
    // claimed. Otherwise anything that could reach the ephemeral callback port —
    // any local process — could abort an authorization in flight, and the user
    // would read the refusal as coming from the provider.
    check(
      "an error carrying the wrong state is a state mismatch, not a denial",
      {
        do {
          _ = try RemoteOAuth.code(
            fromCallback: URL(
              string: "http://127.0.0.1:53682/oauth/callback?error=access_denied&state=nope")!,
            expecting: "xyz")
          return false
        } catch RemoteOAuth.OAuthError.stateMismatch {
          return true
        } catch {
          return false
        }
      }())

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
    // RFC 6749 says a number. Some providers send "3600", and read as no expiry
    // at all the token was only ever refreshed after it had already failed.
    let quoted = try? RemoteOAuth.tokenSet(
      from: ["access_token": "a", "expires_in": "3600"], clientID: "cid",
      issuer: URL(string: "https://as.example")!, previous: nil)
    check("an expires_in sent as a string still sets the expiry", quoted?.expiresAt != nil)
    // The refresh token goes to whichever authorization server the resource
    // names NOW. A set from another issuer is somebody else's, and sending it
    // there hands a long-lived credential to a server that never issued it.
    check("a set is from its own issuer", previous.isFrom(URL(string: "https://as.example")!))
    check(
      "a trailing slash is the same issuer",
      previous.isFrom(URL(string: "https://as.example/")!))
    check(
      "and another issuer is not",
      !previous.isFrom(URL(string: "https://evil.example")!))
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

      // Listening first, then each request in turn, waiting for its answer:
      // sent before anything accepts, they sit in a backlog of one and the
      // ordering under test is not the ordering that happens.
      final class Box: @unchecked Sendable {
        var url: URL?
        var error: Error?
      }
      let box = Box()
      let finished = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        do { box.url = try callback.waitForCallback(timeout: 15, expecting: "st4te") } catch {
          box.error = error
        }
        finished.signal()
      }
      let session = URLSession(configuration: .ephemeral)
      func get(_ path: String) -> Int? {
        let done = DispatchSemaphore(value: 0)
        var status: Int?
        session.dataTask(with: URL(string: "http://127.0.0.1:\(callback.port)\(path)")!) {
          _, response, _ in
          status = (response as? HTTPURLResponse)?.statusCode
          done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return status
      }
      // A stray request first. A favicon fetch or a probe must not end the
      // flow, or an abandoned tab could cancel somebody's authorization.
      check("a stray path is answered 404", get("/favicon.ico") == 404)
      // The callback path with the wrong state: any local process, or a page
      // probing ports, can send one. It used to end the flow — the state was
      // only checked after the listener had stopped — so the authorization
      // somebody was in the middle of was aborted.
      check(
        "a callback with the wrong state is refused",
        get("/oauth/callback?code=evil&state=wrong") == 400)
      check("the real one is accepted", get("/oauth/callback?code=oac_x&state=st4te") == 200)
      _ = finished.wait(timeout: .now() + 10)
      guard let received = box.url else { throw box.error ?? URLError(.timedOut) }
      check(
        "neither ended the flow, and the real callback is what it returns",
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

    // Browsers open speculative connections and send nothing on them. Each one
    // used to be read until the FLOW's deadline, so one accepted ahead of the
    // real redirect held it in the backlog until the authorization timed out.
    do {
      let callback = try RemoteOAuthCallback()
      final class Box: @unchecked Sendable { var url: URL? }
      let box = Box()
      let finished = DispatchSemaphore(value: 0)
      Thread.detachNewThread {
        box.url = try? callback.waitForCallback(timeout: 30, expecting: "st4te")
        finished.signal()
      }
      let idle = socket(AF_INET, SOCK_STREAM, 0)
      var address = sockaddr_in()
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = in_port_t(callback.port).bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          connect(idle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
      check("an idle connection is open", connected == 0)
      Thread.sleep(forTimeInterval: 0.2)
      let redirect = "http://127.0.0.1:\(callback.port)/oauth/callback?code=oac_y&state=st4te"
      URLSession(configuration: .ephemeral).dataTask(with: URL(string: redirect)!).resume()
      _ = finished.wait(timeout: .now() + 12)
      close(idle)
      check(
        "an idle connection does not hold up the redirect behind it",
        box.url?.absoluteString.contains("code=oac_y") == true)
    } catch {
      check("the second listener works — \(error.localizedDescription)", false)
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

    print("\nThe write gate: a fresh instance, before any list has passed through")
    // An instance learns annotations from a `tools/list` that passes through.
    // A new one — after the toggle, a profile edit, a relaunch — has learned
    // nothing, while a client still holds the list it was served before. The
    // call it then makes must be judged against the catalog, not against the
    // empty set.
    let fresh = [tool("look", readOnly: true), tool("wipe", destructive: true), tool("plain")]
    var catalogReads = 0
    let readCatalog: () throws -> [[String: Any]] = {
      catalogReads += 1
      return fresh
    }
    let wipe = WriteGate.gatesCall(
      "wipe", declared: [], annotated: [], catalog: readCatalog)
    check("an annotated write tool is refused on a fresh instance", wipe.refused)
    check("and what the catalog said is learned for the next call", wipe.learned == ["wipe"])
    check(
      "a read tool on a fresh instance is forwarded",
      !WriteGate.gatesCall("look", declared: [], annotated: [], catalog: readCatalog).refused)
    catalogReads = 0
    check(
      "a declared write tool is refused without reading the catalog",
      WriteGate.gatesCall(
        "stripe_api_write", declared: declared, annotated: [], catalog: readCatalog
      )
      .refused && catalogReads == 0)
    check(
      "a write tool already learned is refused without reading the catalog",
      WriteGate.gatesCall("wipe", declared: [], annotated: ["wipe"], catalog: readCatalog).refused
        && catalogReads == 0)
    struct Unreadable: Error {}
    check(
      "a catalog that cannot be read refuses: a gate that cannot tell does not forward",
      WriteGate.gatesCall("look", declared: [], annotated: [], catalog: { throw Unreadable() })
        .refused)

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
