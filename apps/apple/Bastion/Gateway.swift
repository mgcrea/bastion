import Foundation
import os

/// The loopback HTTP front.
///
/// This replaces cupertino's `ServerHost`, and the change of transport is the
/// change of threat model. A unix socket with 0600 permissions is reachable
/// only by processes that can open a path; an HTTP listener is reachable by
/// anything that can make a request, **including a web page the user is
/// visiting**. That is not a hypothetical: CVE-2025-49596 is Anthropic's own
/// MCP Inspector, where a listener plus no CSRF protection meant a visited page
/// could reach it and execute code, and the rust-sdk and FastMCP DNS-rebinding
/// advisories share one root cause — no rebinding protection by default,
/// because "it is only localhost".
///
/// Bastion holds every credential the user owns. The five rules below are
/// therefore in the first commit that opens a socket, not a hardening pass
/// afterwards:
///
/// 1. Bind `127.0.0.1` explicitly. Never `0.0.0.0`, never configurable.
/// 2. Validate `Origin` on every request.
/// 3. Validate `Host` on every request — this is the anti-rebinding rule.
/// 4. A per-client bearer token, minted at wiring time, kept in the Keychain.
/// 5. Secrets never written to any config file. The token goes in the client
///    config; the credential stays in the Keychain.
///
/// `scripts/audit-listener.sh` asserts 1, 2 and 3 against the built bundle, in
/// the same spirit as cupertino's `audit-network.sh`: a marketing claim CI can
/// check. Opening a listening socket cost Bastion that script's original claim,
/// so it had to be replaced by one of the same kind rather than dropped.
nonisolated final class Gateway: @unchecked Sendable {
  static let shared = Gateway()

  /// Default port. Deliberately not near the ones the servers themselves use
  /// for their OAuth callbacks — reddit is on 8724 and x-api on 8723, and a
  /// gateway that collided with the thing it supervises would be a bad first
  /// impression.
  static let defaultPort: UInt16 = 8720

  private var listenFD: Int32 = -1
  /// Held for the lifetime of the process. `flock` releases on close, and on
  /// death — which is why it can replace a check-then-act probe. Two copies of
  /// Bastion serving different profiles on one port is exactly the eviction
  /// bug cupertino spent 3½ hours on, and the lesson transfers unchanged.
  private var lockFD: Int32 = -1
  private let queue = DispatchQueue(label: "io.mgcrea.bastion.gateway", qos: .userInitiated)

  private(set) var port: UInt16 = Gateway.defaultPort
  /// Why the listener never came up, if it did not. Kept rather than only
  /// logged: a gateway that failed to bind is the one state where nothing will
  /// ever work, and stderr is invisible to someone who launched from Finder.
  private(set) var startupError: String?

  enum GatewayError: LocalizedError {
    case socketFailed(String)
    case portInUse(UInt16)
    case lockHeld(by: String?)

    var errorDescription: String? {
      switch self {
      case .socketFailed(let detail): return "could not listen: \(detail)"
      case .portInUse(let port):
        return
          "port \(port) is already in use — something else is listening on it, or a previous Bastion has not exited"
      case .lockHeld(let holder):
        let who = holder.map { "\n\nIt is: \($0)" } ?? ""
        return
          "another copy of Bastion is already running. Quit it before starting this one.\(who)"
      }
    }
  }

  // MARK: - Lifecycle

  func start() throws {
    // SIGPIPE's default action is to kill the process, and this app writes to
    // descriptors whose far end routinely disappears: a client socket whose
    // editor window closed, or a child's stdin after the child crashed.
    // Unhandled, one client quitting mid-request took the whole gateway down —
    // and with a shared instance that is now every other client's session too.
    _ = signal(SIGPIPE, SIG_IGN)

    port = UInt16(UserDefaults.standard.integer(forKey: "gatewayPort"))
    if port == 0 { port = Self.defaultPort }

    do {
      try claimLock()
      try openSocket()
      startupError = nil
    } catch {
      startupError = error.localizedDescription
      throw error
    }
  }

  func stop() {
    if listenFD >= 0 { close(listenFD); listenFD = -1 }
    // Closing releases the flock. The file itself stays: unlinking a lock file
    // is how two processes end up locking two different inodes and both winning.
    if lockFD >= 0 { close(lockFD); lockFD = -1 }
  }

  private var lockPath: String {
    AppSupport.ensureDirectory().appendingPathComponent("bastion.lock").path
  }

  /// Take the single-instance lock, or fail saying who has it.
  ///
  /// `flock` rather than a probe: check-then-act is not an exclusion mechanism,
  /// and the kernel releases this on death, which is the case a heuristic
  /// cannot get right. `closeOnExec` matters as much as the lock — without it
  /// every spawned server inherits the descriptor and a wedged child would hold
  /// the lock after Bastion quit, locking out the next launch with no process
  /// anyone could see.
  private func claimLock() throws {
    let path = lockPath
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw GatewayError.socketFailed("could not open \(path): \(errnoText())") }
    closeOnExec(fd)

    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let holder = lockHolder()
      close(fd)
      throw GatewayError.lockHeld(by: holder)
    }

    ftruncate(fd, 0)
    lseek(fd, 0, SEEK_SET)
    _ = writeAll(fd, Data("\(getpid())\t\(Bundle.main.bundlePath)\n".utf8))
    lockFD = fd
  }

  private func lockHolder() -> String? {
    guard let data = FileManager.default.contents(atPath: lockPath),
      let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first
    else { return nil }
    let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    return "\(parts[1]) (pid \(parts[0]))"
  }

  /// Rule 1, and the only place it can be got wrong.
  ///
  /// `INADDR_LOOPBACK`, hardcoded. There is no setting for this and there must
  /// not be: "bind address" as a preference is how `0.0.0.0` ends up in a
  /// support thread as a workaround for something else, and this process holds
  /// a brokerage refresh token.
  private func openSocket() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GatewayError.socketFailed(errnoText()) }

    // SO_REUSEADDR only, never SO_REUSEPORT: reuseaddr lets a restart reclaim a
    // port still in TIME_WAIT, while reuseport would let a SECOND process bind
    // the same port and silently take half the traffic — which, for a listener
    // that authenticates clients and holds credentials, is an attacker's
    // preferred way in.
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      let failure = errno
      close(fd)
      throw failure == EADDRINUSE ? GatewayError.portInUse(port) : .socketFailed(errnoText())
    }

    guard listen(fd, 32) == 0 else {
      let detail = errnoText()
      close(fd)
      throw GatewayError.socketFailed(detail)
    }

    // Every spawned server would otherwise inherit the listening socket, so a
    // wedged child would keep the port bound after Bastion quit and later
    // connections would hang against a listener nobody is accepting on.
    closeOnExec(fd)

    listenFD = fd
    hostLog("gateway", .info, "listening on http://127.0.0.1:\(port)")
    queue.async { [weak self] in self?.acceptLoop(fd) }
  }

  /// Accept forever, and treat "forever" literally.
  ///
  /// Returning from here retires the listener for the lifetime of the app: the
  /// port stays bound, so `connect` still succeeds and every client hangs
  /// waiting on a response that will never come. Every transient reason
  /// `accept` can fail is therefore recovered from rather than fatal.
  private func acceptLoop(_ fd: Int32) {
    while true {
      let client = accept(fd, nil, nil)
      if client < 0 {
        let failure = errno
        if listenFD < 0 { return }  // stopped deliberately
        switch failure {
        case EINTR, ECONNABORTED:
          continue
        case EMFILE, ENFILE, ENOMEM, ENOBUFS:
          hostLog("gateway", .error, "accept deferred: \(String(cString: strerror(failure)))")
          usleep(100_000)
          continue
        default:
          hostLog("gateway", .error, "accept failed: \(String(cString: strerror(failure)))")
          return
        }
      }
      closeOnExec(client)
      onDedicatedThread("bastion.connection") { [weak self] in
        self?.serve(client)
      }
    }
  }

  // MARK: - One connection

  private func serve(_ client: Int32) {
    defer { close(client) }
    guard let request = HTTPRequest.read(from: client) else {
      respond(client, HTTPResponse(status: 400, message: "malformed request"))
      return
    }
    respond(client, route(request))
  }

  /// Rules 2, 3 and 4, in that order, before anything else happens.
  ///
  /// The ORDER is deliberate and is what `scripts/audit-listener.sh` asserts. A
  /// foreign `Origin` or `Host` must be refused with 403 *before* the token is
  /// looked at, so that a rebinding attempt gets the same answer whether or not
  /// it also guessed a token — and so that the audit can check the refusal
  /// without holding a valid token at all.
  private func route(_ request: HTTPRequest) -> HTTPResponse {
    if let refusal = checkHost(request) { return refusal }
    if let refusal = checkOrigin(request) { return refusal }

    guard let presented = request.bearerToken, let client = GatewayToken.identify(presented) else {
      // No detail. "Unknown token" and "no token" are the same sentence on
      // purpose: an error that distinguishes them is an oracle.
      return HTTPResponse(
        status: 401, message: "unauthorized",
        headers: ["WWW-Authenticate": "Bearer realm=\"bastion\""])
    }

    switch (request.method, request.pathComponents) {
    case ("GET", ["health"]):
      return HTTPResponse(
        json: [
          "ok": true, "version": AppInfo.version,
          "protocolVersions": Dialect.supportedVersions.map(\.rawValue),
          "servers": ServerStore.installedIDs(),
        ])

    case ("POST", let path) where path.count == 3 && path[0] == "s":
      // The licence gate, and the only one in the app.
      //
      // Here rather than deeper in: this is the last point where nothing has
      // been spawned. Past it the supervisor may start a child, and refusing
      // after that would leave a process running for a request that was never
      // served.
      //
      // What is gated is the RELAY — the supervised, credential-holding,
      // audited gateway, which is the thing being sold. Write gates are NOT
      // gated and must not be: that would make the free tier the safe one and
      // the paid tier the dangerous one.
      //
      // Refusing every request is immediate in a way cupertino's equivalent
      // could not be. There, an MCP host opened one stdio connection when the
      // editor started and held it for days, so a gate on new connections was
      // not a gate at all. Here every request is its own POST.
      switch Entitlement.current {
      case .licensed:
        break
      case .trial:
        break
      // Bastion's own server is exempt, and this is the gate's own rule rather
      // than a hole in it: what is sold is the RELAY — the supervised,
      // credential-holding, audited path to somebody else's server. The
      // built-in server relays nothing, spawns nothing and holds no credential;
      // it is the app's own configuration, and charging for read access to your
      // own setup would be charging for the window.
      //
      // It also buys the best possible trial: an unlicensed user can have their
      // agent install servers, set credentials and wire clients, and the first
      // thing they hit afterwards is the sentence explaining what a licence is
      // for — at the point they have something to lose by not having one.
      case .refused where path[2] == BuiltinServer.id:
        break
      case .refused(let reason):
        hostLog("licence", .error, "refused \(path[1])/\(path[2]): \(reason)")
        return HTTPResponse(
          status: 200,
          json: rpcFrame(
            id: HTTPRequest.jsonRPCID(of: request.body),
            error: [
              "code": -32603,
              "message":
                "Bastion is not licensed: \(reason). Open Bastion to enter a key, or to start a "
                + "\(Int(Trial.duration / 60))-minute trial.",
            ]))
      }
      return handleRPC(profile: path[1], server: path[2], request: request, client: client)

    // 2026-07-28 removed the GET stream endpoint and protocol-level sessions.
    // The spec names the answer for a client still speaking an earlier
    // Streamable HTTP revision — "HTTP GET or DELETE to the MCP endpoint:
    // respond with 405 Method Not Allowed" — and says why 405 rather than 404:
    // a 404 sends an old client hunting for the deprecated HTTP+SSE endpoint,
    // and it would keep trying.
    case ("GET", let path) where path.count == 3 && path[0] == "s",
      ("DELETE", let path) where path.count == 3 && path[0] == "s":
      return HTTPResponse(
        status: 405,
        message:
          "Bastion speaks Streamable HTTP (2026-07-28) on POST only: there is no GET stream and no session to DELETE"
      )

    default:
      return HTTPResponse(status: 404, message: "no route for \(request.method) \(request.path)")
    }
  }

  /// Rule 3 — the anti-DNS-rebinding check.
  ///
  /// A page on `evil.example` can make its own name resolve to `127.0.0.1` and
  /// then reach this listener from JavaScript with the same-origin rules
  /// satisfied. What it cannot change is the `Host` header it sends: it will
  /// say `evil.example`, because that is the name the browser was asked for.
  /// Refusing any `Host` that is not a loopback literal is what closes it, and
  /// it is the one check that a correct `Origin` policy does not already cover.
  private func checkHost(_ request: HTTPRequest) -> HTTPResponse? {
    guard let host = request.header("host") else {
      return HTTPResponse(status: 400, message: "no Host header")
    }
    let name = host.split(separator: ":").first.map(String.init) ?? host
    let allowed = ["127.0.0.1", "localhost", "[::1]", "::1"]
    guard allowed.contains(name.lowercased()) else {
      hostLog("gateway", .error, "refused a request with Host: \(host)")
      return HTTPResponse(status: 403, message: "forbidden host")
    }
    return nil
  }

  /// Rule 2 — the anti-CSRF check.
  ///
  /// A missing `Origin` is allowed, and that is not a hole: a browser always
  /// sends one and a page cannot suppress it, so "no Origin" means the caller
  /// is not a web page. An MCP client — Claude Code, VS Code, a CLI — sends
  /// none, which is exactly the traffic this is meant to admit.
  ///
  /// A PRESENT `Origin` must be one of Bastion's own. Nothing else is on the
  /// list and nothing else should be: an allowlist that grows to accommodate a
  /// tool is how the check stops meaning anything.
  private func checkOrigin(_ request: HTTPRequest) -> HTTPResponse? {
    guard let origin = request.header("origin") else { return nil }
    let mine = [
      "http://127.0.0.1:\(port)", "http://localhost:\(port)",
    ]
    guard mine.contains(origin.lowercased()) else {
      hostLog("gateway", .error, "refused a request with Origin: \(origin)")
      return HTTPResponse(status: 403, message: "forbidden origin")
    }
    return nil
  }

  /// One JSON-RPC frame, in whichever era the client wrote it.
  ///
  /// Everything era-specific happens here, before the supervisor is reached:
  /// the supervisor talks to a legacy child and should not have to know which
  /// kind of client is on the other end.
  private func handleRPC(profile: String, server: String, request: HTTPRequest, client: String)
    -> HTTPResponse
  {
    guard !request.body.isEmpty else {
      return HTTPResponse(status: 400, message: "empty body")
    }
    guard let frame = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
      return HTTPResponse(status: 400, message: "the body is not a JSON object")
    }

    // `Mcp-Session-Id` and `Last-Event-ID` are deliberately not read anywhere.
    // The spec's instruction for a server on this revision is to ignore both
    // and never mint or echo a session id — and for Bastion that is not merely
    // compliance. A session id is per-client state on a shared instance, which
    // is the thing the stateless revision removed and the thing that made this
    // architecture possible.

    let era = Dialect.era(of: frame)

    switch era {
    case .unsupported(let requested):
      // 400 with a RECOGNISED modern error. That combination is load-bearing:
      // a dual-era client inspects the body of a 400 to decide whether it has
      // found a modern server to retry against or a legacy one to fall back
      // to. A bare 400 would send it back to `initialize`.
      hostLog("gateway", .info, "\(client) asked for protocol \(requested), which Bastion does not implement")
      return HTTPResponse(
        status: 400,
        json: rpcFrame(id: frame["id"], error: Dialect.unsupportedVersionError(requested: requested)))

    case .modern(let version):
      if let mismatch = Dialect.validateHeaders(
        request: request, frame: frame, declaredVersion: version.rawValue)
      {
        return HTTPResponse(status: 400, json: rpcFrame(id: frame["id"], error: mismatch))
      }

    case .legacy:
      break
    }

    // Called straight through on this connection's own thread. The supervisor
    // blocks — waiting on a child's response is the whole operation — and
    // `onDedicatedThread` exists so that blocking costs a thread rather than a
    // slot in a bounded pool. This used to hop through a `Task` and a
    // semaphore, which moved the blocking onto Swift's cooperative pool and
    // bought nothing for it.
    do {
      guard
        let data = try Supervisor.shared.call(
          profile: profile, server: server, frame: frame, era: era, client: client)
      else {
        // A notification. The spec is exact here: "the server MUST return HTTP
        // status code 202 Accepted with no body." An empty body, not a JSON
        // acknowledgement — which is what this returned before, and which a
        // strict client is entitled to reject.
        return HTTPResponse(status: 202, body: Data(), contentType: "application/json")
      }
      return modernise(data, era: era, method: frame["method"] as? String)
    } catch {
      return rpcError(error, profile: profile, server: server, client: client, request: request)
    }
  }

  /// Shape a child's reply for the era the client is speaking.
  ///
  /// Three things happen only for a modern client: every result gains
  /// `resultType`, a list result gains its cache annotation, and an unknown
  /// method becomes `404`. That last one is not cosmetic — the spec gives
  /// `404` + `-32601` a specific job, distinguishing a modern server that does
  /// not implement a method from a legacy HTTP+SSE server that does not host
  /// the endpoint at all.
  ///
  /// `method` is the one the CLIENT asked for, read from the request rather
  /// than the reply, because a JSON-RPC response does not carry it. Without it
  /// there is no way to tell a `tools/list` result from a `tools/call` result,
  /// and only the first takes an annotation.
  private func modernise(_ data: Data, era: Dialect.Era, method: String?) -> HTTPResponse {
    guard case .modern = era,
      let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return HTTPResponse(status: 200, body: data, contentType: "application/json")
    }

    if let error = frame["error"] as? [String: Any],
      let code = error["code"] as? Int, code == Dialect.methodNotFound
    {
      return HTTPResponse(status: 404, json: frame)
    }
    var result = Dialect.modernise(result: frame)
    if let method { result = Dialect.annotateList(result: result, method: method) }
    return HTTPResponse(status: 200, json: result)
  }

  /// A JSON-RPC error frame. `id` is `null` when the request had none, which
  /// the spec explicitly permits for a transport-level refusal.
  private func rpcFrame(id: Any?, error: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": error]
  }

  private func rpcError(
    _ error: Error, profile: String, server: String, client: String, request: HTTPRequest
  ) -> HTTPResponse {
    let detail = (error as? LocalizedError)?.errorDescription ?? "the request could not be served"
    hostLog("\(profile)/\(server)", .error, "\(client): \(detail)")
    // A JSON-RPC error, not a bare HTTP status. The caller is an MCP client
    // and a 500 with a text body reaches its user as "connection failed", which
    // is the least informative possible rendering of a sentence that says
    // exactly what to fix.
    return HTTPResponse(
      status: 200,
      json: [
        "jsonrpc": "2.0",
        "id": HTTPRequest.jsonRPCID(of: request.body) ?? NSNull(),
        "error": ["code": -32603, "message": detail],
      ])
  }

  private func respond(_ fd: Int32, _ response: HTTPResponse) {
    _ = writeAll(fd, response.wireFormat)
  }
}
