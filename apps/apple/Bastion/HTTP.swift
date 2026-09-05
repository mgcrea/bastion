import Foundation
import os

/// Just enough HTTP/1.1 to serve JSON-RPC over loopback.
///
/// Hand-written rather than `Network.framework` or a package, for two reasons
/// that are really one: the security rules in `Gateway` are checks on specific
/// headers in a specific order, and a dependency that parses those headers for
/// you is a dependency that decides what they mean. A vendored HTTP stack would
/// also be the largest attack surface in an app whose whole claim is a small
/// one — `scripts/audit-listener.sh` can assert what this file does because
/// everything it does is here.
///
/// What it deliberately does not do: keep-alive, chunked bodies, pipelining,
/// compression. Every response closes the connection. That costs a TCP setup
/// per request on loopback, which is measured in microseconds, and buys a
/// request lifecycle with no state to get wrong.
nonisolated struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data

  /// A body larger than this is refused before it is read.
  ///
  /// Tool results can be genuinely large — an analytics report, a screenshot
  /// upload — so this is generous. It is finite because an unbounded read on a
  /// socket anything on the machine can connect to is a way to exhaust memory
  /// without ever presenting a token.
  static let maxBody = 32 << 20

  /// Headers are matched lower-cased. HTTP field names are case-insensitive and
  /// clients disagree in practice: `Origin`, `origin` and `ORIGIN` are the same
  /// header, and a security check that missed one because of capitalisation
  /// would fail open.
  func header(_ name: String) -> String? { headers[name.lowercased()] }

  var pathComponents: [String] {
    path.split(separator: "?").first.map(String.init).map { raw in
      raw.split(separator: "/").map(String.init)
    } ?? []
  }

  var bearerToken: String? {
    guard let value = header("authorization") else { return nil }
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
    return parts[1].trimmingCharacters(in: .whitespaces)
  }

  /// Whether `Accept` names a media type, matched as a whole token rather than
  /// as a substring.
  ///
  /// `*/*` does NOT count, and neither does an absent header. A wildcard means
  /// "I will take anything", not "I asked for a stream", and the risk here is
  /// asymmetric: answering JSON to a client that would have read a stream is
  /// always safe, while answering a stream to one that cannot parse it breaks
  /// the call. `curl` sends `*/*` by default, and someone piping this to `jq`
  /// should keep getting one JSON object.
  ///
  /// q-values are cut off and ignored, so `;q=0` reads as "accepted" — wrong by
  /// the letter of RFC 9110, and with no caller that can reach it: no MCP client
  /// sends one, and every client that matters sends the media type outright.
  func accepts(_ mediaType: String) -> Bool {
    guard let value = header("accept") else { return false }
    return value.split(separator: ",").contains { part in
      let token = part.split(separator: ";", maxSplits: 1).first ?? part
      return token.trimmingCharacters(in: .whitespaces).lowercased() == mediaType
    }
  }

  /// Whether the caller said it can read an SSE stream.
  ///
  /// One half of the two conditions that turn a reply into a stream; the other
  /// is a `progressToken` on the request. See `Gateway.handleRPC`.
  var acceptsEventStream: Bool { accepts("text/event-stream") }

  /// The `id` of a JSON-RPC frame, so an error can be returned against it.
  ///
  /// A JSON-RPC error with the wrong id is worse than no error: the client
  /// matches it to nothing and waits out its own timeout on a request that has
  /// already failed.
  static func jsonRPCID(of body: Data) -> Any? {
    guard let frame = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      return nil
    }
    return frame["id"]
  }

  /// Whether a `Host` header names this machine's loopback, with or without a
  /// port.
  ///
  /// `127.0.0.1` and `localhost`, and nothing else. The listener is `AF_INET`,
  /// so no request can arrive over `::1`; a `Host: [::1]` on an IPv4 connection
  /// is a misconfigured client or a probe, and either deserves the refusal.
  /// Bastion itself only ever writes `127.0.0.1` into a client config, so the
  /// list is the list of names it hands out.
  static func isLoopbackHost(_ host: String) -> Bool {
    let name =
      host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(
        String.init) ?? host
    return ["127.0.0.1", "localhost"].contains(name.lowercased())
  }

  /// Read one request, or give up after `timeout` seconds in total.
  ///
  /// The deadline covers the whole request — headers and body — and nothing
  /// after it: the time spent waiting on a child is the operation, not a
  /// stall, and it is bounded elsewhere. `nil` means wait forever, which is
  /// what the unit checks want and what the gateway never passes.
  static func read(from fd: Int32, timeout: TimeInterval? = nil) -> HTTPRequest? {
    let deadline = timeout.map { DispatchTime.now() + $0 }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)

    // Headers first, up to the blank line.
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
      guard awaitReadable(fd, until: deadline) else { return nil }
      let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
      if n < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if n == 0 { return nil }
      buffer.append(contentsOf: chunk[0..<n])
      headerEnd = buffer.firstRange(of: Data("\r\n\r\n".utf8))
      // A header block this long is not a request anyone meant to send. Refuse
      // rather than keep reading: this runs before any authentication, so it is
      // the one place an unauthenticated peer controls how much is allocated.
      if headerEnd == nil && buffer.count > 64 * 1024 { return nil }
    }
    guard let headerEnd else { return nil }

    let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }

    let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
    guard requestLine.count >= 2 else { return nil }

    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
      let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }

    var body = Data(buffer[headerEnd.upperBound...])
    let declared = Int(headers["content-length"] ?? "0") ?? 0
    guard declared <= maxBody else { return nil }
    while body.count < declared {
      guard awaitReadable(fd, until: deadline) else { return nil }
      let n = chunk.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
      if n < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if n == 0 { break }
      body.append(contentsOf: chunk[0..<n])
    }
    // A body that arrived short is a truncated request, not a small one.
    // Serving it would mean handing the supervisor half a JSON frame.
    guard body.count >= declared else { return nil }

    return HTTPRequest(
      method: requestLine[0].uppercased(), path: requestLine[1], headers: headers,
      body: body.prefix(declared))
  }

  /// Block until `fd` has something to read, or the deadline passes.
  ///
  /// `poll` rather than `SO_RCVTIMEO`, and the difference is the whole point:
  /// that option bounds one `read`, so a peer trickling a byte every few
  /// seconds stays under it for as long as it likes. A deadline on the request
  /// bounds time the way the 64 KB cap bounds size. `POLLHUP` and `POLLERR`
  /// count as readable — the `read` that follows returns 0 or -1, which the
  /// caller already handles.
  private static func awaitReadable(_ fd: Int32, until deadline: DispatchTime?) -> Bool {
    guard let deadline else { return true }
    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      let end = deadline.uptimeNanoseconds
      guard end > now else { return false }
      let remaining = Int32(min((end - now) / 1_000_000 + 1, UInt64(Int32.max)))
      var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&descriptor, 1, remaining)
      if ready > 0 { return true }
      if ready == 0 { return false }
      if errno == EINTR { continue }
      return false
    }
  }
}

/// How many connections may be in flight at once, counted before any header
/// is read.
///
/// Every connection costs a dedicated thread with its own stack, and the accept
/// loop hands one out before it knows whether the peer will ever send a byte.
/// Without a bound, a local process can hold as many as it can open, and needs
/// no token to do it — the token is in the headers it never sends. The bound
/// keeps Bastion's own footprint finite. It is not a defence against a same-uid
/// attacker, who could as easily `kill -9` the process; it is what stops an
/// honest client's bug, or a stray port scan, from costing a thread per attempt
/// forever.
nonisolated final class ConnectionBudget: Sendable {
  let limit: Int
  private let count = OSAllocatedUnfairLock(initialState: 0)

  init(limit: Int) { self.limit = limit }

  /// Take a slot. `false` means refuse, and do not serve.
  func acquire() -> Bool {
    count.withLock { taken in
      guard taken < limit else { return false }
      taken += 1
      return true
    }
  }

  func release() {
    count.withLock { $0 = max(0, $0 - 1) }
  }

  var inFlight: Int { count.withLock { $0 } }
}

nonisolated struct HTTPResponse {
  let status: Int
  let body: Data
  let contentType: String
  var headers: [String: String] = [:]

  init(status: Int, body: Data, contentType: String, headers: [String: String] = [:]) {
    self.status = status
    self.body = body
    self.contentType = contentType
    self.headers = headers
  }

  /// A plain refusal or acknowledgement, as JSON so a client never has to guess
  /// at the content type it is being handed.
  init(status: Int, message: String, headers: [String: String] = [:]) {
    self.init(
      status: status,
      body: (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data(),
      contentType: "application/json", headers: headers)
  }

  init(status: Int = 200, json: [String: Any]) {
    self.init(
      status: status,
      body: (try? JSONSerialization.data(withJSONObject: json)) ?? Data(),
      contentType: "application/json")
  }

  var wireFormat: Data {
    var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    // Every response closes. See the note on HTTPRequest.
    head += "Connection: close\r\n"
    // Nothing here is meant for a browser, and the headers say so. A response
    // that a page can neither read cross-origin nor be talked into rendering as
    // HTML is one less thing for the Origin check to be the only defence
    // against.
    head += "X-Content-Type-Options: nosniff\r\n"
    head += "Cache-Control: no-store\r\n"
    for (name, value) in headers { head += "\(name): \(value)\r\n" }
    head += "\r\n"
    return Data(head.utf8) + body
  }

  private static func reason(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 202: return "Accepted"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 500: return "Internal Server Error"
    case 503: return "Service Unavailable"
    default: return "Status"
    }
  }
}
