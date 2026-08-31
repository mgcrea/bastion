import Darwin
import Foundation

/// The rule that keeps "add a remote server" from becoming "fetch anything".
///
/// The catalog's KEPT rule says a caller selects a server by *name*, never by a
/// path or a command line, because a component that runs whatever it is handed
/// is a way for anything reaching the gateway to execute code with the user's
/// credentials already in the environment. A remote server replaces the command
/// line with a URL, so the same rule has to hold for URLs — and it does, by the
/// same mechanism: `/s/<profile>/<server>` resolves an id against the list the
/// *user* installed, and nothing arriving over the wire can name an endpoint.
///
/// What is genuinely new is the second half. A URL in that list is a
/// `fetch(whatever_you_typed)` primitive pointed at whatever it resolves to,
/// and the interesting targets are all on the inside:
///
/// - `169.254.169.254`, the cloud metadata address, which hands out credentials
///   to anything that asks.
/// - The user's own LAN — a router's admin page, a NAS, a printer.
/// - **Bastion's own gateway on `127.0.0.1:8720`**, which is the sharpest one.
///   A client's bearer token is minted for the gateway, and a "remote server"
///   pointed back at it would be a way to replay that token against every other
///   profile in the app, from inside the one component allowed to hold it.
///
/// This file is the whole answer, in one readable place on purpose:
/// `scripts/audit-remote.sh` asserts it against a running build, and an
/// assertion is only worth as much as the reader's ability to check what it
/// asserts.
///
/// ## What this cannot promise
///
/// A name that passes here can resolve somewhere else a moment later — the
/// DNS-rebinding shape the gateway's own `Host` check exists for, pointed the
/// other way. `preflight` therefore resolves the name and judges the addresses,
/// and `RemoteTransport` re-checks the address the connection actually landed
/// on afterwards. The residual race is a rebind between those two points; what
/// closes it is that the second check runs before any response is handed back,
/// so a rebound request fails rather than returning attacker-chosen content.
/// The credential can still have been sent, which is why `preflight` runs
/// first rather than only the check afterwards.
nonisolated enum RemoteEndpoint {
  enum EndpointError: LocalizedError, Equatable {
    case notHTTPS(String)
    case noHost
    case privateAddress(host: String, address: String)
    case bastionItself(String)
    case unresolvable(host: String, detail: String)
    case crossOriginRedirect(from: String, to: String)

    var errorDescription: String? {
      switch self {
      case .notHTTPS(let scheme):
        return
          "a remote server must be https, not \(scheme.isEmpty ? "a bare host" : scheme) — the "
          + "credential for it leaves this machine on every call"
      case .noHost:
        return "that URL has no host"
      case .privateAddress(let host, let address):
        return
          "\(host) resolves to \(address), which is on this machine or this network — a remote "
          + "server has to be somewhere else, or 'add a server' becomes a way to reach anything "
          + "you can reach"
      case .bastionItself(let host):
        return
          "\(host) is Bastion's own gateway. Pointing a server at it would let one profile's "
          + "token be replayed against every other profile"
      case .unresolvable(let host, let detail):
        return "cannot resolve \(host): \(detail)"
      case .crossOriginRedirect(let from, let to):
        return
          "\(from) redirected to \(to), and following it would have sent this profile's "
          + "credential there. Refused rather than followed without it: a cross-origin redirect "
          + "on an MCP endpoint has no legitimate reading"
      }
    }
  }

  /// Shape only: scheme and host. Cheap, synchronous, and safe to call while
  /// someone is still typing — `ServerEditor` uses it to enable its Save
  /// button, so it must not touch the network.
  static func validateShape(_ url: URL) throws {
    guard url.scheme?.lowercased() == "https" else {
      throw EndpointError.notHTTPS(url.scheme ?? "")
    }
    guard let host = url.host(), !host.isEmpty else { throw EndpointError.noHost }

    // Named forms, before anything is resolved. `localhost` and `*.local` are
    // refused by name because a resolver that is down, lying or simply absent
    // must not turn a refusal into an allow.
    let lowered = host.lowercased()
    if lowered == "localhost" || lowered.hasSuffix(".localhost") || lowered.hasSuffix(".local") {
      throw EndpointError.privateAddress(host: host, address: lowered)
    }
    // A literal address needs no resolver, and judging it here means the same
    // sentence appears whether or not the machine is online.
    if let judgement = judge(literal: lowered) { throw judgement.error(host: host) }
  }

  /// Shape, then what the name actually resolves to.
  ///
  /// Blocking, because everything on the supervisor's path is: it runs on the
  /// connection's own dedicated thread, which exists so that waiting costs a
  /// thread rather than a slot in a bounded pool.
  static func preflight(_ url: URL) throws {
    try validateShape(url)
    guard let host = url.host() else { throw EndpointError.noHost }

    for address in try resolve(host) {
      if let judgement = judge(literal: address) { throw judgement.error(host: host) }
    }
  }

  /// The check after the fact, against the address the connection landed on.
  ///
  /// `URLSessionTaskTransactionMetrics.remoteAddress` is the only place the
  /// resolved peer is observable, and it arrives once the exchange is over —
  /// too late to stop the request, in time to refuse the answer.
  static func verify(connectedTo address: String?, host: String) throws {
    guard let address, !address.isEmpty else { return }
    if let judgement = judge(literal: address.lowercased()) { throw judgement.error(host: host) }
  }

  // MARK: - Judging one address

  private enum Judgement {
    case privateAddress(String)
    case bastion

    func error(host: String) -> EndpointError {
      switch self {
      case .privateAddress(let address): .privateAddress(host: host, address: address)
      case .bastion: .bastionItself(host)
      }
    }
  }

  /// `nil` means "nothing wrong with this one".
  ///
  /// Everything not routable on the public internet is refused, rather than a
  /// denylist of the addresses somebody remembered. The metadata address is
  /// inside link-local and needs no line of its own; it is named in the doc
  /// comment because it is *why*, not because it is a special case.
  private static func judge(literal: String) -> Judgement? {
    if let v4 = IPv4(literal) {
      if v4.isLoopback { return .bastion }
      if v4.isPrivate || v4.isLinkLocal || v4.isUnspecified || v4.isMulticast
        || v4.isCarrierGrade || v4.isBenchmark || v4.isReserved
      {
        return .privateAddress(literal)
      }
      return nil
    }
    if let v6 = IPv6(literal) {
      if v6.isLoopback { return .bastion }
      if v6.isPrivate || v6.isLinkLocal || v6.isUnspecified { return .privateAddress(literal) }
      // An IPv4-mapped address is an IPv4 address wearing a hat, and judging it
      // as opaque would let `::ffff:127.0.0.1` through the loopback rule.
      if let mapped = v6.mappedIPv4 { return judge(literal: mapped) }
      return nil
    }
    return nil
  }

  // MARK: - Resolution

  private static func resolve(_ host: String) throws -> [String] {
    var hints = addrinfo(
      ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)
    guard status == 0, let head = result else {
      throw EndpointError.unresolvable(
        host: host, detail: String(cString: gai_strerror(status)))
    }
    defer { freeaddrinfo(head) }

    var out: [String] = []
    var node: UnsafeMutablePointer<addrinfo>? = head
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    while let current = node {
      if let sa = current.pointee.ai_addr {
        if getnameinfo(
          sa, socklen_t(current.pointee.ai_addrlen), &buffer, socklen_t(buffer.count), nil, 0,
          NI_NUMERICHOST) == 0
        {
          out.append(String(cString: buffer).lowercased())
        }
      }
      node = current.pointee.ai_next
    }
    // An empty answer is not an all-clear. Nothing was judged, so nothing was
    // cleared, and letting the request proceed would make a resolver that
    // returns nothing the way around every rule above.
    guard !out.isEmpty else {
      throw EndpointError.unresolvable(host: host, detail: "no addresses")
    }
    return out
  }

  // MARK: - Address parsing

  private struct IPv4 {
    let octets: [UInt8]

    init?(_ text: String) {
      var address = in_addr()
      guard text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
      let raw = address.s_addr.bigEndian
      octets = [
        UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
        UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF),
      ]
    }

    var isLoopback: Bool { octets[0] == 127 }
    var isUnspecified: Bool { octets == [0, 0, 0, 0] }
    var isLinkLocal: Bool { octets[0] == 169 && octets[1] == 254 }
    var isMulticast: Bool { octets[0] >= 224 }
    var isCarrierGrade: Bool { octets[0] == 100 && (64...127).contains(octets[1]) }
    var isBenchmark: Bool { octets[0] == 198 && (18...19).contains(octets[1]) }
    var isReserved: Bool { octets[0] == 192 && octets[1] == 0 && octets[2] == 0 }
    var isPrivate: Bool {
      octets[0] == 10
        || (octets[0] == 172 && (16...31).contains(octets[1]))
        || (octets[0] == 192 && octets[1] == 168)
    }
  }

  private struct IPv6 {
    let bytes: [UInt8]

    init?(_ text: String) {
      // A scoped literal (`fe80::1%en0`) is still a literal, and the scope is
      // exactly the sign it is link-local.
      let bare = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
      var address = in6_addr()
      guard bare.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
      bytes = withUnsafeBytes(of: &address) { Array($0) }
    }

    var isLoopback: Bool { bytes == Array(repeating: 0, count: 15) + [1] }
    var isUnspecified: Bool { bytes.allSatisfy { $0 == 0 } }
    var isLinkLocal: Bool { bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 }
    /// Unique local, `fc00::/7` — IPv6's answer to `10.0.0.0/8`.
    var isPrivate: Bool { (bytes[0] & 0xFE) == 0xFC }

    /// `::ffff:a.b.c.d`, as dotted quad.
    var mappedIPv4: String? {
      guard bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF
      else { return nil }
      return "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
    }
  }
}
