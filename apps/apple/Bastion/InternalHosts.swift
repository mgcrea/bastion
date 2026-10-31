import Darwin
import Foundation

/// A host on the user's own network that a remote server may live on.
///
/// `RemoteEndpoint` refuses every address that is not on the public internet,
/// because a URL in the installed list is a `fetch(whatever_you_typed)`
/// primitive and the interesting targets are all on the inside. That also
/// refuses the one thing a company VPN is for: an MCP server on an internal
/// name, such as `workers.example.dev` resolving to `10.240.20.35`. This is the
/// way through, kept as narrow as the loopback exception beside it.
///
/// An entry is an exact host name plus the private networks it may resolve
/// to. Both halves matter. The name alone would let a DNS change, or a
/// hijacked record, land the credential on any private address the Mac can
/// reach — the router, the NAS — and still pass. The networks alone would let
/// any name that happens to resolve there through.
///
/// What a listing never allows, whatever it says:
/// - plain http — the credential still crosses the network, VPN or not;
/// - loopback, and so Bastion's own gateway;
/// - link-local, which is where the cloud metadata address lives;
/// - anything outside the RFC 1918 ranges and IPv6 unique-local space;
/// - the names `localhost`, `*.localhost` and `*.local`, which `RemoteEndpoint`
///   refuses by name before anything is resolved.
///
/// **Only a person changes this list**, in Settings. No tool of Bastion's own
/// MCP server reads or writes it, and no field of a server definition carries
/// it. Otherwise one agent that read the wrong web page could list the router
/// and then add a "server" pointing at it, which is exactly the hole
/// `RemoteEndpoint` exists to close. The list is kept in the Keychain rather
/// than a file, so an agent with a shell cannot widen it by editing JSON
/// either — it would have to manipulate a Keychain item Bastion owns, and
/// deleting that item empties the list. What this does not claim: a local
/// process free to rewrite the user's login keychain is out of reach of any
/// rule here, as it is for the credentials beside it.
///
/// An entry covers every port on the host. A server definition, including one
/// an agent adds, can reach any TLS port there, so a listing is a statement
/// about the machine, not about one service on it.
///
/// Its own file, Foundation and Darwin only, so `make remote-check` compiles it
/// beside `RemoteEndpoint` and asserts the rule without the app.
nonisolated struct InternalHost: Codable, Hashable, Sendable, Identifiable {
  /// Lowercased, with no trailing dot and no brackets. See `InternalHosts.normalize`.
  var host: String
  /// CIDR, canonical form (`10.240.20.35/32`), each inside a private range.
  var networks: [String]
  /// When it was listed. Shown in Settings, so an entry nobody remembers adding
  /// at least says when it happened.
  var addedAt: Date?

  var id: String { host }

  /// Whether `address` — a resolved or connected peer, as text — is inside one
  /// of this entry's networks. An IPv4-mapped IPv6 address is judged as the
  /// IPv4 address it carries, as `RemoteEndpoint` judges it.
  ///
  /// Also requires the address itself to be private, whatever the networks say.
  /// `InternalHosts.validated` already keeps every network inside a private
  /// range, but this is the check the guard leans on, and a list that reached
  /// it some other way — a test, a future caller — must not be able to waive a
  /// link-local or loopback answer by naming it.
  func permits(address: String) -> Bool {
    guard let parsed = InternalHosts.Address(address), InternalHosts.isPrivate(parsed) else {
      return false
    }
    return networks.contains { InternalHosts.Network($0)?.contains(parsed) == true }
  }
}

nonisolated enum InternalHosts {
  enum Problem: LocalizedError, Equatable {
    case badHost(String)
    case refusedName(String)
    case noNetworks
    case badNetwork(String)
    case notPrivate(String)
    case duplicate(String)

    var errorDescription: String? {
      switch self {
      case .badHost(let host):
        return "'\(host)' is not a host name. Type the name alone, with no scheme, port or path."
      case .refusedName(let host):
        return
          "\(host) is refused by name whatever it resolves to, so listing it would change "
          + "nothing. For a server on this Mac, use http://127.0.0.1 in the server's URL."
      case .noNetworks:
        return "Name at least one network the host may resolve to, such as 10.240.20.35/32."
      case .badNetwork(let text):
        return "'\(text)' is not a network. Write an address with a prefix, such as 10.0.0.0/8."
      case .notPrivate(let text):
        return
          "\(text) is not inside a private range. Only 10.0.0.0/8, 172.16.0.0/12, "
          + "192.168.0.0/16 and fc00::/7 can be listed: loopback, link-local and public "
          + "addresses never can."
      case .duplicate(let host):
        return "\(host) is already listed. Remove it first to change its networks."
      }
    }
  }

  // MARK: - The list the guard reads

  /// What `RemoteEndpoint` consults on every request, off the main thread.
  ///
  /// A copy behind a lock rather than a read of the store, because the store is
  /// `@MainActor` and the guard runs on a connection's own dedicated thread,
  /// where hopping to the main actor would put waiting back on a bounded pool.
  /// `InternalHostStore` publishes here on load and after every change, and is
  /// the only writer.
  static var current: [InternalHost] {
    lock.lock()
    defer { lock.unlock() }
    return published
  }

  static func publish(_ list: [InternalHost]) {
    lock.lock()
    published = list
    lock.unlock()
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var published: [InternalHost] = []

  /// The entry for `host`, matched exactly after normalising. No wildcards and
  /// no suffix matching: `evil.workers.example.dev` is a different host.
  static func entry(for host: String, in list: [InternalHost]) -> InternalHost? {
    let key = normalize(host)
    return list.first { $0.host == key }
  }

  // MARK: - Validation

  /// Lowercased, brackets off an IPv6 literal, trailing dot dropped.
  static func normalize(_ host: String) -> String {
    var text = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
    while text.hasSuffix(".") { text.removeLast() }
    return text
  }

  /// A valid entry with its host normalised and its networks in canonical form,
  /// or the first thing wrong with it. The store calls this on every add, and
  /// on every entry it loads, so a hand-edited file cannot widen the rule.
  static func validated(_ entry: InternalHost) throws -> InternalHost {
    let host = normalize(entry.host)
    let isLiteral = Address(host) != nil
    if !isLiteral {
      let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
      let labels = host.split(separator: ".", omittingEmptySubsequences: false)
      // At least two labels: a single label (`intranet`) is expanded through
      // the resolver's search domains, so the name listed would not be the
      // name that was looked up.
      guard !host.isEmpty, host.count <= 253, host.allSatisfy(allowed.contains),
        labels.count >= 2,
        labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") })
      else {
        throw Problem.badHost(entry.host)
      }
    }
    if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
      throw Problem.refusedName(host)
    }

    var networks: [String] = []
    for text in entry.networks {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      guard let network = Network(trimmed) else { throw Problem.badNetwork(trimmed) }
      guard network.isInsidePrivateRange else { throw Problem.notPrivate(trimmed) }
      if !networks.contains(network.description) { networks.append(network.description) }
    }
    guard !networks.isEmpty else { throw Problem.noNetworks }

    return InternalHost(host: host, networks: networks, addedAt: entry.addedAt)
  }

  /// Parses a comma- or space-separated field into network texts, unvalidated.
  static func networkTexts(from field: String) -> [String] {
    field.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
  }

  /// What a host resolves to now, as single-address networks, keeping only the
  /// private ones a listing could hold. Settings pre-fills its field with this,
  /// so the default is the narrowest entry that works today.
  static func suggestedNetworks(for addresses: [String]) -> [String] {
    var out: [String] = []
    for text in addresses {
      guard let address = Address(text) else { continue }
      let network = Network(address: address, prefix: address.bytes.count * 8)
      if network.isInsidePrivateRange, !out.contains(network.description) {
        out.append(network.description)
      }
    }
    return out
  }

  /// Inside 10/8, 172.16/12, 192.168/16 or fc00::/7 — the only space a listing
  /// may ever open.
  static func isPrivate(_ address: Address) -> Bool {
    Network.privateRanges.contains { $0.contains(address) }
  }

  // MARK: - Addresses and networks

  struct Address: Equatable {
    /// 4 bytes for IPv4 (including an IPv4-mapped IPv6 address), 16 for IPv6.
    let bytes: [UInt8]

    init?(_ text: String) {
      // Empty pieces kept, so `%10.0.0.1` is not read as `10.0.0.1`: a scope
      // follows an address, it never precedes one.
      let bare = String(
        InternalHosts.normalize(text)
          .split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0])
      var v4 = in_addr()
      if bare.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
        bytes = withUnsafeBytes(of: &v4) { Array($0) }
        return
      }
      var v6 = in6_addr()
      guard bare.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
      let raw = withUnsafeBytes(of: &v6) { Array($0) }
      // `::ffff:a.b.c.d` is an IPv4 address, and judging it as IPv6 would let
      // it slip past a network written as IPv4.
      if raw.prefix(10).allSatisfy({ $0 == 0 }), raw[10] == 0xFF, raw[11] == 0xFF {
        bytes = Array(raw[12...])
      } else {
        bytes = raw
      }
    }

    init(bytes: [UInt8]) { self.bytes = bytes }
  }

  struct Network: CustomStringConvertible {
    let address: Address
    let prefix: Int

    init(address: Address, prefix: Int) {
      self.address = Network.masked(address, prefix: prefix)
      self.prefix = prefix
    }

    /// `a.b.c.d/n` or `x::y/n`. A bare address is not a network here: the
    /// prefix is the decision, and defaulting it would make it for the user.
    init?(_ text: String) {
      let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
      guard parts.count == 2, let address = Address(parts[0]), let prefix = Int(parts[1]),
        (0...(address.bytes.count * 8)).contains(prefix)
      else { return nil }
      self.init(address: address, prefix: prefix)
    }

    func contains(_ other: Address) -> Bool {
      guard other.bytes.count == address.bytes.count else { return false }
      return Network.masked(other, prefix: prefix) == address
    }

    /// Wholly inside 10/8, 172.16/12, 192.168/16 or fc00::/7.
    var isInsidePrivateRange: Bool {
      Network.privateRanges.contains { range in
        range.address.bytes.count == address.bytes.count && range.prefix <= prefix
          && range.contains(address)
      }
    }

    var description: String {
      if address.bytes.count == 4 {
        return address.bytes.map(String.init).joined(separator: ".") + "/\(prefix)"
      }
      var raw = in6_addr()
      withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: address.bytes) }
      var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count))
      return String(cString: buffer) + "/\(prefix)"
    }

    fileprivate static let privateRanges: [Network] = [
      Network("10.0.0.0/8")!, Network("172.16.0.0/12")!, Network("192.168.0.0/16")!,
      Network("fc00::/7")!,
    ]

    private static func masked(_ address: Address, prefix: Int) -> Address {
      var bytes = address.bytes
      for index in bytes.indices {
        let bitsBefore = index * 8
        if prefix >= bitsBefore + 8 { continue }
        let keep = max(0, prefix - bitsBefore)
        bytes[index] &= keep == 0 ? 0 : UInt8(truncatingIfNeeded: 0xFF << (8 - keep))
      }
      return Address(bytes: bytes)
    }
  }
}
