// bastion-bridge — what a stdio-only MCP host actually spawns.
//
// ## Why this exists
//
// Bastion speaks Streamable HTTP on loopback, and a client that can be told a
// URL needs nothing else. Claude Desktop cannot: every one of the seven entries
// in its config is a `command`, and there is no `type: http` among them. So for
// those hosts something has to stand where a server would stand, speak stdio to
// the host, and speak HTTP to the gateway.
//
// That is all this does. It holds no credential of its own beyond the bearer
// token it is handed, opens no protected path, and makes exactly one kind of
// network call: a POST to 127.0.0.1. Everything that matters — the supervised
// child, the Keychain, the audit record — is on the other side of that POST.
//
// ## Not a byte pump
//
// cupertino-bridge relays bytes in both directions between one stdio pair and
// one unix socket, and never looks at them. This cannot: HTTP is
// request/response, so each JSON-RPC frame has to be recognised, sent as its
// own POST, and matched back to a reply. That difference is why this reads
// frames rather than chunks, and why it has to know what a notification is.
//
// stdout is the JSON-RPC channel. Every diagnostic goes to stderr.

import Foundation

// Both things this writes to — its own stdout and stderr — belong to a process
// that can exit first. SIGPIPE's default action would kill the bridge outright,
// so the write failures below could never be reported. Every write here checks
// its own return value.
_ = signal(SIGPIPE, SIG_IGN)

// `write(2)`, not `FileHandle.write`, and this is the same argument as the
// SIGPIPE line above applied to the diagnostic stream.
//
// `-[NSFileHandle writeData:]` reports a failed write by RAISING an
// Objective-C exception, which Swift cannot catch. The moment stderr went away
// with the host, the diagnostic path became the crash path: something noticed a
// write had failed, called `warn` to say so, and `warn` aborted the process on
// the way out. Measured in cupertino as a SIGABRT in the wild, with
// `objc_exception_throw` -> `abort` sitting directly above `warn`.
//
// An MCP host that exits closes all its pipes at once, so the run that most
// needs to report something is exactly the run where reporting it would kill
// the relay. A raw write cannot throw, and a failed one is ignored on purpose:
// there is nowhere left to report that the reporting failed.
func warn(_ message: String) {
  writeAll(STDERR_FILENO, Array("[bastion-bridge] \(message)\n".utf8))
}

@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
  var offset = 0
  while offset < bytes.count {
    let written = bytes.withUnsafeBufferPointer {
      write(fd, $0.baseAddress! + offset, bytes.count - offset)
    }
    if written <= 0 {
      if errno == EINTR { continue }
      return false
    }
    offset += written
  }
  return true
}

func die(_ message: String, code: Int32 = 1) -> Never {
  warn(message)
  exit(code)
}

// MARK: - Arguments

var profile: String?
var server: String?
var port = 8720

for argument in CommandLine.arguments.dropFirst() {
  if argument.hasPrefix("--profile=") {
    profile = String(argument.dropFirst("--profile=".count))
  } else if argument.hasPrefix("--server=") {
    server = String(argument.dropFirst("--server=".count))
  } else if argument.hasPrefix("--port=") {
    port = Int(argument.dropFirst("--port=".count)) ?? port
  }
}

guard let profile, let server else {
  die("usage: bastion-bridge --profile=<name> --server=<id> [--port=8720]", code: 2)
}

// Deliberately NOT validated against a list of server ids here.
//
// cupertino-bridge checks its argument against a generated table, because there
// the bridge's argument selects which privileged thing gets spawned. Here it
// selects a URL path, and the gateway resolves it against the closed table and
// 404s on a miss. Duplicating the list would mean a second copy to keep in step
// with `servers.json` for no security benefit — the check that matters happens
// where the spawn happens.

// The token identifies which CLIENT this is, not who the user is. It is meant
// to travel in a config file; the credential it stands in for never leaves the
// Keychain. That split is the whole point — a config that leaks costs a
// revocable loopback token instead of a brokerage refresh token.
guard let token = ProcessInfo.processInfo.environment["BASTION_TOKEN"], !token.isEmpty else {
  die(
    """
    BASTION_TOKEN is not set.
    Bastion mints one token per client; put it in this server's `env` block in \
    your MCP client configuration.
    """, code: 2)
}

// The gateway resolves both names against its closed table, so nothing here
// validates them — but a name with a space or a control character in it does
// not even form a URL, and that deserves the same sentence every other bad
// argument gets rather than a trap.
guard let endpoint = URL(string: "http://127.0.0.1:\(port)/s/\(profile)/\(server)") else {
  die(
    "--profile=\(profile) --server=\(server) does not form a URL. "
      + "Profile and server names are lower-case letters, digits and hyphens.", code: 2)
}

// MARK: - Reaching the gateway

/// The `.app` this binary is embedded in.
///
/// `Contents/Helpers/bastion-bridge` -> `Bastion.app`, or nil when running the
/// bare executable out of a build directory.
func containingApp() -> URL? {
  guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
  let app =
    executable  // …/Bastion.app/Contents/Helpers/bastion-bridge
    .deletingLastPathComponent()  // …/Contents/Helpers
    .deletingLastPathComponent()  // …/Contents
    .deletingLastPathComponent()  // …/Bastion.app
  return app.pathExtension == "app" ? app : nil
}

/// Is anything listening?
///
/// A bare TCP connect, not a request: this runs before the app may exist, and
/// the question at this point is only whether to launch it.
func gatewayIsUp() -> Bool {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = UInt16(port).bigEndian
  address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  return withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
    }
  }
}

/// Start Bastion, then wait for it to listen.
///
/// **By path, not by bundle identifier.** `open -b io.mgcrea.bastion` asks
/// LaunchServices to pick among every registered copy, and in cupertino it
/// picked a stale one out of Xcode's DerivedData during development — so the
/// bridge waited on a socket a different build was never going to open.
/// Launching the app this binary shipped inside is unambiguous, and it means a
/// bridge copied elsewhere cannot be talked into starting some other app that
/// claims the identifier.
///
/// `-g` keeps it from stealing focus: this runs while someone is typing at an
/// AI assistant, not while they are looking at the screen.
///
/// This is also, for now, how Bastion gets started at all. There is no login
/// item yet, so a stdio client launching its bridge is the one path that brings
/// the gateway up on demand. A client configured with a plain `type: http` URL
/// has no such path and needs Bastion already running.
func launchApp() {
  let open = Process()
  open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  if let app = containingApp() {
    open.arguments = ["-g", app.path]
  } else {
    warn("not running from inside Bastion.app; falling back to the bundle identifier")
    open.arguments = ["-g", "-b", "io.mgcrea.bastion"]
  }
  do {
    try open.run()
    open.waitUntilExit()
  } catch {
    warn("could not launch Bastion: \(error.localizedDescription)")
  }
}

if !gatewayIsUp() {
  warn("Bastion is not running; launching it")
  launchApp()
  // Cold start of a signed app is well under a second; ten is for a machine
  // that is busy, or a first launch that has to clear Gatekeeper.
  let deadline = Date().addingTimeInterval(10)
  while !gatewayIsUp(), Date() < deadline {
    usleep(150_000)
  }
}
guard gatewayIsUp() else {
  die(
    """
    could not reach Bastion on 127.0.0.1:\(port).
    Tried to launch \(containingApp()?.path ?? "io.mgcrea.bastion").
    Open Bastion once by hand, then retry.
    """)
}

// MARK: - stdout, one frame at a time

/// Responses arrive on URLSession's queue, in whatever order the gateway
/// answers — which for a client that pipelines is not the order they were sent.
/// That is fine and expected for JSON-RPC, whose ids carry the correlation, but
/// two frames must never interleave *within* a line.
let stdoutLock = NSLock()

func emit(_ data: Data) {
  var bytes = Array(data)
  bytes.append(UInt8(ascii: "\n"))
  stdoutLock.lock()
  defer { stdoutLock.unlock() }
  writeAll(STDOUT_FILENO, bytes)
}

/// Answer the host ourselves when the gateway cannot be reached or refuses.
///
/// A bridge that stayed silent here would present in the client as a request
/// that never returns, and every one of these servers has a comment about that
/// exact failure mode: a dead MCP server shows up as a bare "Connection
/// closed", with stderr swallowed, so the one message that would have explained
/// the problem never reaches anyone.
func emitError(id: Any?, _ message: String) {
  let frame: [String: Any] = [
    "jsonrpc": "2.0",
    "id": id ?? NSNull(),
    "error": ["code": -32603, "message": "bastion-bridge: \(message)"],
  ]
  guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
  emit(data)
}

// MARK: - One frame

let session = URLSession(configuration: .ephemeral)
let inFlight = DispatchGroup()

/// The `_meta` version, when the client is speaking the modern protocol.
///
/// The bridge is otherwise dialect-agnostic — it forwards whatever the host
/// sent and lets the gateway's dual-era handling decide. But Streamable HTTP
/// requires the version, method and name to be MIRRORED INTO HEADERS on a
/// modern request, and the gateway validates them: a modern frame posted
/// without them comes back 400 with a HeaderMismatch. The host cannot add them,
/// because it thinks it is talking to a stdio server. So this does.
func modernVersion(of frame: [String: Any]) -> String? {
  guard let params = frame["params"] as? [String: Any],
    let meta = params["_meta"] as? [String: Any]
  else { return nil }
  return meta["io.modelcontextprotocol/protocolVersion"] as? String
}

func mirroredName(of frame: [String: Any]) -> String? {
  guard let method = frame["method"] as? String,
    let params = frame["params"] as? [String: Any]
  else { return nil }
  switch method {
  case "tools/call", "prompts/get": return params["name"] as? String
  case "resources/read": return params["uri"] as? String
  default: return nil
  }
}

/// Header-safe, or the spec's Base64 sentinel.
///
/// Tool and prompt names are only SHOULD-constrained to header-safe characters,
/// so a name outside the safe set has to be encoded rather than dropped — and a
/// dropped `Mcp-Name` is a 400, not a warning.
func headerValue(_ raw: String) -> String {
  let safe = raw.allSatisfy { character in
    guard let ascii = character.asciiValue else { return false }
    return ascii >= 0x21 && ascii <= 0x7E
  }
  if safe && !raw.hasPrefix("=?base64?") { return raw }
  return "=?base64?\(Data(raw.utf8).base64EncodedString())?="
}

func forward(_ line: Data) {
  guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
    warn("ignoring a line that is not a JSON object")
    return
  }
  let id = frame["id"]

  var request = URLRequest(url: endpoint)
  request.httpMethod = "POST"
  request.httpBody = line
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  // JSON only, and deliberately narrower than the spec allows a client to be.
  //
  // The gateway now streams to a client that says it reads one, and `forward`
  // below buffers the whole body and emits it as a single stdout line — so a
  // stream would reach a stdio host as a raw SSE body where a JSON-RPC frame
  // should be, and it would fail to parse with nothing in the diff to blame.
  // Asking for JSON is what makes that unreachable. Widen this again in the
  // same change that teaches `forward` to read a stream, not before.
  request.setValue("application/json", forHTTPHeaderField: "Accept")
  request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

  if let version = modernVersion(of: frame) {
    request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
    if let method = frame["method"] as? String {
      request.setValue(method, forHTTPHeaderField: "Mcp-Method")
    }
    if let name = mirroredName(of: frame) {
      request.setValue(headerValue(name), forHTTPHeaderField: "Mcp-Name")
    }
  }

  inFlight.enter()
  session.dataTask(with: request) { data, response, error in
    defer { inFlight.leave() }

    if let error {
      // A notification has no id, so there is nobody to tell. Log it and move
      // on rather than emitting an error frame with a null id, which a host has
      // no way to match to anything.
      if id == nil {
        warn("a notification could not be delivered: \(error.localizedDescription)")
      } else {
        emitError(id: id, error.localizedDescription)
      }
      return
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    // 202 with an empty body is the spec's answer to a notification. There is
    // nothing to write, and writing anything would be a response the host never
    // asked for.
    if status == 202 { return }

    guard let data, !data.isEmpty else {
      if id != nil { emitError(id: id, "Bastion returned \(status) with no body") }
      return
    }
    emit(data)
  }.resume()
}

// MARK: - stdin

warn("relaying \(profile)/\(server) to \(endpoint.absoluteString)")

var pending = Data()
var buffer = [UInt8](repeating: 0, count: 64 * 1024)

while true {
  let n = buffer.withUnsafeMutableBufferPointer { read(STDIN_FILENO, $0.baseAddress, $0.count) }
  if n < 0 {
    if errno == EINTR { continue }
    warn("stdin failed: \(String(cString: strerror(errno)))")
    break
  }
  if n == 0 { break }  // the host closed its end
  pending.append(contentsOf: buffer[0..<n])

  // Split on the LAST newline, not each chunk on its own. Reads come back with
  // no regard for line boundaries, so a frame straddling two chunks would
  // otherwise be dropped — and a large tool result is exactly the size that
  // hits this.
  guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else {
    // A line this long is not MCP framing. Stop buffering rather than grow
    // without bound on a host that never sends a newline.
    if pending.count > 32 << 20 {
      warn("discarding an oversized partial frame")
      pending.removeAll(keepingCapacity: false)
    }
    continue
  }
  let complete = pending[..<last]
  pending = Data(pending[pending.index(after: last)...])
  for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
    forward(Data(line))
  }
}

// Let anything already sent come back before going. The host has closed stdin,
// but a tool call it made a moment earlier may still be running, and exiting
// here would turn a completed call into a lost one.
//
// Bounded, because the alternative is the failure cupertino measured: 67 bridge
// processes parented to launchd, each still holding descriptors, because
// nothing ever told them to stop waiting.
_ = inFlight.wait(timeout: .now() + 30)
