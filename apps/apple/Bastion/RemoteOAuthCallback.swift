import Darwin
import Foundation
import os

/// A one-shot loopback listener that catches the OAuth redirect.
///
/// ## Why this exists instead of a custom scheme
///
/// The first version used `ASWebAuthenticationSession` with a private-use URI
/// scheme (`io.mgcrea.bastion:/oauth/callback`), which RFC 8252 §7.1 endorses
/// and which Stripe's dynamic registration **accepts**. It still did not work,
/// and the reason is worth writing down because registration succeeding made it
/// look fine right up until a person clicked Allow:
///
///     [safe-links] redirect (io.mgcrea.bastion.debug:/oauth/callback?code=…)
///     blocked. URL has invalid protocol
///
/// Stripe's consent page runs a link guard that refuses to navigate anywhere
/// that is not http or https. The authorization succeeds, the page says so, and
/// the browser then declines to hand the code back — so the app waits forever
/// for a callback that was generated and thrown away. A registration endpoint
/// accepting a redirect URI says nothing about whether the *page* will navigate
/// to it, and only a real consent click can tell you.
///
/// So: `http://127.0.0.1:<port>/oauth/callback`, RFC 8252 §7.3, which is http
/// and therefore survives the guard.
///
/// ## Why not the gateway
///
/// Bastion already has a loopback listener, and this is deliberately not it.
/// `Gateway.route` checks `Host`, then `Origin`, then the bearer token *before*
/// dispatching, and `scripts/audit-listener.sh` asserts that order. A redirect
/// arrives with no bearer token, so putting this route there would mean a
/// carve-out ahead of the exact check the audit exists to protect. A separate
/// socket that exists for one request and then closes has no such cost.
///
/// ## What it is careful about
///
/// - Binds `127.0.0.1` explicitly, never `0.0.0.0` — the same rule as the
///   gateway, and `audit-listener.sh` greps the whole source for the mistake.
/// - Port 0, so the kernel picks a free one. A fixed port is one already-taken
///   port away from failing, and the redirect URI is registered dynamically
///   anyway, so nothing needs to know it in advance.
/// - Lives for one request or the timeout, whichever comes first, then closes.
///   An OAuth callback listener that outlives its flow is a hole with no job.
/// - Hands back the URL and nothing else. Every decision about it — the state
///   check above all — belongs to `RemoteOAuth`, which is where it can be
///   tested.
nonisolated final class RemoteOAuthCallback {
  enum CallbackError: LocalizedError {
    case cannotListen(String)
    case timedOut(seconds: Int)

    var errorDescription: String? {
      switch self {
      case .cannotListen(let detail):
        return "could not open a local port to receive the authorization: \(detail)"
      case .timedOut(let seconds):
        return
          "no answer from the browser within \(seconds / 60) minutes — the window was probably "
          + "closed before authorizing"
      }
    }
  }

  private let socket: Int32
  let port: UInt16

  /// The redirect URI to register and to send the browser to.
  var redirectURI: String { "http://127.0.0.1:\(port)/oauth/callback" }

  init() throws {
    // A local, not `self.socket`, until every stored property is set: the
    // `withUnsafePointer` closures below would otherwise capture a half-built
    // `self`, which Swift refuses outright.
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CallbackError.cannotListen("socket: \(errno)") }
    socket = fd

    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    // Loopback, explicitly, and port 0 so the kernel assigns a free one.
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = 0

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      close(fd)
      throw CallbackError.cannotListen("bind: \(errno)")
    }
    guard Darwin.listen(fd, 1) == 0 else {
      close(fd)
      throw CallbackError.cannotListen("listen: \(errno)")
    }

    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &actual) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(fd, $0, &length)
      }
    }
    guard named == 0 else {
      close(fd)
      throw CallbackError.cannotListen("getsockname: \(errno)")
    }
    port = UInt16(bigEndian: actual.sin_port)
  }

  deinit { close(socket) }

  /// Wait for the browser, and hand back the URL it asked for.
  ///
  /// Blocking, on whatever thread calls it — the caller runs this off the main
  /// actor precisely so a person taking two minutes to click Allow does not
  /// freeze the window that started it.
  ///
  /// Keeps accepting until it sees a request for the callback path, so a
  /// favicon fetch or a stray probe does not end the flow. The state check that
  /// makes this safe is `RemoteOAuth.code(fromCallback:expecting:)`, above.
  func waitForCallback(timeout: TimeInterval) throws -> URL {
    let deadline = Date().addingTimeInterval(timeout)

    while Date() < deadline {
      var poller = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else { break }
      let ready = poll(&poller, 1, Int32(min(remaining, 1) * 1000))
      if ready <= 0 { continue }

      let client = accept(socket, nil, nil)
      guard client >= 0 else { continue }
      defer { close(client) }

      guard let line = Self.readRequestLine(client) else { continue }
      // `GET /oauth/callback?code=…&state=… HTTP/1.1`
      let parts = line.split(separator: " ")
      guard parts.count >= 2 else { continue }
      let target = String(parts[1])
      guard target.hasPrefix("/oauth/callback") else {
        Self.respond(client, status: "404 Not Found", body: "<p>Nothing here.</p>")
        continue
      }

      Self.respond(
        client, status: "200 OK",
        body: """
          <h1>Authorized</h1>
          <p>Bastion has the token. You can close this window.</p>
          """)
      guard let url = URL(string: "http://127.0.0.1:\(port)\(target)") else { continue }
      return url
    }
    throw CallbackError.timedOut(seconds: Int(timeout))
  }

  // MARK: - The smallest HTTP that will do

  /// Just the request line. The headers and body of a redirect are of no
  /// interest, and reading a whole request would mean caring how long it is.
  private static func readRequestLine(_ client: Int32) -> String? {
    var buffer = [UInt8]()
    var byte: UInt8 = 0
    // A request line long enough to hold a code and a state, and no longer:
    // this reads from a socket anyone local can connect to, so it needs a
    // ceiling that does not depend on the sender being reasonable.
    while buffer.count < 8192 {
      let read = recv(client, &byte, 1, 0)
      if read <= 0 { break }
      if byte == UInt8(ascii: "\n") { break }
      if byte != UInt8(ascii: "\r") { buffer.append(byte) }
    }
    guard !buffer.isEmpty else { return nil }
    return String(bytes: buffer, encoding: .utf8)
  }

  private static func respond(_ client: Int32, status: String, body: String) {
    let page = """
      <!doctype html><meta charset="utf-8">
      <title>Bastion</title>
      <style>
        body { font: 16px/1.5 -apple-system, system-ui, sans-serif; color: #151617;
               background: #faf9f7; display: grid; place-items: center; height: 100vh;
               margin: 0; text-align: center; }
        h1 { font-size: 20px; margin: 0 0 8px; }
        p { margin: 0; color: rgba(21,22,23,.6); }
        @media (prefers-color-scheme: dark) {
          body { background: #151617; color: #f4f2ef; }
          p { color: rgba(244,242,239,.6); }
        }
      </style>
      <div>\(body)</div>
      """
    let response = """
      HTTP/1.1 \(status)\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(page.utf8.count)\r
      Connection: close\r
      \r
      \(page)
      """
    _ = response.withCString { send(client, $0, strlen($0), 0) }
  }
}
