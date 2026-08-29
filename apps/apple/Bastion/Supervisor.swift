import Foundation
import os

/// One supervised child per `(profile, server)`, many clients per child.
///
/// This is the inversion. `cupertino/apps/apple/Cupertino/ServerHost.swift:16`
/// states the opposite design outright — one accepted connection maps to one
/// server process, "because a process per connection keeps their state, their
/// crashes and their write permissions separate" — and every one of those three
/// reasons has to be answered here rather than waved at:
///
/// - **state** — the 2026-07-28 spec went stateless-first, so a request no
///   longer depends on which instance saw the last one. For the servers still
///   on the old dialect (all ten of them today) `Dialect` fronts them with the
///   new protocol and the handshake happens once, here, not per client.
/// - **crashes** — a supervisor with backoff and a circuit breaker, and the
///   blast radius reported rather than hidden: when a child dies, every client
///   waiting on it is told, and the Activity window records how many that was.
/// - **write permissions** — per profile, not per process. Two profiles of the
///   same server can differ on their write gate, which is strictly more
///   expressive than a process boundary was.
///
/// What is genuinely lost is isolation between two clients of the *same
/// profile*. That is the trade, and it is the right one: two clients of the
/// same profile are the same identity with the same permissions, which is
/// exactly the case where a second process bought nothing but memory.
nonisolated final class Supervisor: @unchecked Sendable {
  static let shared = Supervisor()

  enum SupervisorError: LocalizedError {
    case unknownServer(String)
    case unknownProfile(profile: String, server: String)
    case notConfigured(profile: String, missing: [String])
    case startFailed(String)
    case circuitOpen(profile: String, until: Date)
    case childDied(String)
    case timedOut(seconds: Int)
    case malformedRequest(String)

    var errorDescription: String? {
      switch self {
      case .unknownServer(let id):
        return "no server '\(id)' — Bastion only runs the servers in its manifest"
      case .unknownProfile(let profile, let server):
        return "no profile '\(profile)' for \(server) — create it in Bastion"
      case .notConfigured(let profile, let missing):
        return "profile '\(profile)' is missing \(missing.joined(separator: ", "))"
      case .startFailed(let detail):
        return "could not start the server: \(detail)"
      case .circuitOpen(let profile, let until):
        let seconds = max(1, Int(until.timeIntervalSinceNow.rounded(.up)))
        return
          "\(profile) has failed to stay running and is not being restarted for another \(seconds)s"
      case .childDied(let detail):
        return "the server exited while handling this request (\(detail))"
      case .timedOut(let seconds):
        return "the server did not answer within \(seconds)s"
      case .malformedRequest(let detail):
        return "malformed JSON-RPC: \(detail)"
      }
    }
  }

  private let instances = OSAllocatedUnfairLock<[String: Instance]>(initialState: [:])
  /// One creation at a time per profile, and only per profile.
  ///
  /// Measured, on the first multi-client test: four concurrent first requests
  /// for `prod/shopify` spawned four children, three of which were immediately
  /// stopped as having lost the start race. It worked — every client got the
  /// right answer — but "works" is not the claim. The claim is one supervised
  /// instance per server, and four node processes and three SIGTERMs in the
  /// Activity window is that claim visibly failing.
  ///
  /// Per key rather than one global gate: a slow server starting must not hold
  /// up a different profile's first request.
  private let startGates = OSAllocatedUnfairLock<[String: DispatchSemaphore]>(initialState: [:])

  /// Route one client request to the right child, starting it if needed.
  ///
  /// Synchronous and blocking, called from the connection's own dedicated
  /// thread. Everything below this line blocks — a handshake waits for a child
  /// to answer, a call waits for a response — and `onDedicatedThread` exists so
  /// that blocking costs a thread rather than a slot in a bounded pool. An
  /// async version of this ran first and was worse in the way that matters: the
  /// blocking still happened, it just happened on Swift's cooperative pool,
  /// where a handful of slow server startups can starve everything else in the
  /// process.
  func call(profile profileName: String, server serverID: String, request: Data) throws -> Data? {
    guard let server = ServerCatalog.byID[serverID] else {
      throw SupervisorError.unknownServer(serverID)
    }
    guard let profile = ProfileStore.lookup(name: profileName, server: serverID) else {
      throw SupervisorError.unknownProfile(profile: profileName, server: serverID)
    }

    let instance = try instanceFor(profile: profile, server: server)
    return try instance.handle(request)
  }

  /// Stop everything. Called when the app quits.
  func stopAll() {
    let live = instances.withLock { taken -> [Instance] in
      let all = Array(taken.values)
      taken.removeAll()
      return all
    }
    for instance in live { instance.stop(reason: "Bastion is quitting") }
  }

  func stop(profile: String, server: String) {
    let key = "\(profile)/\(server)"
    let instance = instances.withLock { $0.removeValue(forKey: key) }
    instance?.stop(reason: "stopped by request")
  }

  /// What is running right now, for the Activity window.
  var running: [(id: String, pid: Int32, clients: Int)] {
    instances.withLock { $0.values.map { ($0.key, $0.pid, $0.clientCount) } }
  }

  private func instanceFor(profile: Profile, server: BastionServer) throws -> Instance {
    let key = profile.id
    if let existing = instances.withLock({ $0[key] }), existing.isAlive { return existing }

    let missing = ProfileEnvironment.missing(for: profile, server: server)
    guard missing.isEmpty else {
      throw SupervisorError.notConfigured(profile: profile.name, missing: missing)
    }

    // One creation at a time for this profile. Two concurrent first requests is
    // the normal case, not a race to worry about later — an editor and a CLI
    // starting together do exactly this.
    let gate = startGates.withLock { table -> DispatchSemaphore in
      if let existing = table[key] { return existing }
      let created = DispatchSemaphore(value: 1)
      table[key] = created
      return created
    }
    gate.wait()
    defer { gate.signal() }

    // Re-check behind the gate. The request that was second in line arrives
    // here with the child already started, which is the whole point.
    if let existing = instances.withLock({ $0[key] }), existing.isAlive { return existing }

    // Spawned outside the instances lock. Starting a child means a fork, an
    // exec and a blocking handshake, and holding that lock across all three
    // would stall every OTHER profile's requests behind one slow startup.
    let created = try Instance(profile: profile, server: server)
    instances.withLock { $0[key] = created }
    return created
  }
}

// MARK: - One child

nonisolated extension Supervisor {
  /// A single server process and everyone talking to it.
  final class Instance: @unchecked Sendable {
    let key: String
    private let profile: Profile
    private let server: BastionServer

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
      var process: Process?
      var stdin: FileHandle?
      /// Client requests waiting on the child, keyed by the id Bastion gave
      /// them — never the id the client used.
      var pending: [Int: Waiter] = [:]
      var nextID = 1
      /// The child's `initialize` result, taken once at spawn.
      var handshake: [String: Any]?
      var clients: Set<String> = []
      /// Consecutive failures, for the backoff and the breaker.
      var failures = 0
      var blockedUntil: Date?
      var lastActivity = Date()
    }

    private struct Waiter {
      let clientID: Any?
      let deadline: Date
      let resume: (Result<Data, Error>) -> Void
    }

    /// How long a single call may take.
    ///
    /// Generous, because these are real API calls over the network and a report
    /// download is genuinely slow — but finite, because a continuation that is
    /// never resumed is a client that hangs forever with no error to show.
    private static let callTimeout: TimeInterval = 180

    /// Stop a child that nobody has used for this long.
    ///
    /// The whole point of one instance per server is that it is cheap to leave
    /// running; the point of stopping it anyway is that `mcp-buzzberg` drives a
    /// browser, and a browser left running all week is not cheap.
    private static let idleTimeout: TimeInterval = 30 * 60

    private var reaper: DispatchSourceTimer?

    var pid: Int32 { state.withLock { $0.process?.processIdentifier ?? -1 } }
    var clientCount: Int { state.withLock { $0.clients.count } }
    var isAlive: Bool { state.withLock { $0.process?.isRunning ?? false } }

    init(profile: Profile, server: BastionServer) throws {
      self.key = profile.id
      self.profile = profile
      self.server = server
      try ensureRunning()
      startReaper()
    }

    // MARK: Lifecycle

    private func start() throws {
      if let until = state.withLock({ $0.blockedUntil }), until > Date() {
        throw SupervisorError.circuitOpen(profile: key, until: until)
      }

      let binaries: ServerBinaries
      do {
        binaries = try ServerLocator.locate(server)
      } catch {
        throw SupervisorError.startFailed(error.localizedDescription)
      }

      let environment = ProfileEnvironment.build(for: profile, server: server)

      let process = Process()
      process.executableURL = binaries.node
      process.arguments = [binaries.script.path]
      process.environment = environment
      // Not the app's working directory, which is `/` under LaunchServices.
      // At least one server (`mcp-boursobank`) resolves a default output
      // directory relative to `cwd`, so an unset cwd writes a profile's
      // statements into whatever directory the app happened to start in.
      process.currentDirectoryURL = ProfileEnvironment.directory(
        profile: profile.name, server: server.id)

      let toChild = Pipe(), fromChild = Pipe(), childErr = Pipe()
      process.standardInput = toChild
      process.standardOutput = fromChild
      process.standardError = childErr

      // The ends Bastion keeps. A child that inherited another profile's pipe
      // would hold it open past its owner's exit — a cross-profile leak in the
      // one process whose job is keeping profiles apart.
      for handle in [
        toChild.fileHandleForWriting, fromChild.fileHandleForReading,
        childErr.fileHandleForReading,
      ] {
        closeOnExec(handle.fileDescriptor)
      }

      do {
        try process.run()
      } catch {
        noteFailure()
        throw SupervisorError.startFailed(error.localizedDescription)
      }

      state.withLock {
        $0.process = process
        $0.stdin = toChild.fileHandleForWriting
        $0.lastActivity = Date()
      }

      hostLog(
        key, .info,
        "started (pid \(process.processIdentifier))"
          + (binaries.isDevelopment ? " — development build" : ""))

      readLoop(fromChild.fileHandleForReading.fileDescriptor)
      drainStderr(childErr.fileHandleForReading)
      watchExit(process)
    }

    /// Read newline-delimited JSON from the child until EOF.
    private func readLoop(_ fd: Int32) {
      onDedicatedThread("bastion.child.\(server.id)") { [weak self] in
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
          let n = buffer.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
          if n < 0 {
            if errno == EINTR { continue }
            break
          }
          if n == 0 { break }
          pending.append(contentsOf: buffer[0..<n])

          // Split on the LAST newline, not each chunk on its own. Reads come
          // back with no regard for line boundaries, so a frame that straddles
          // two chunks would otherwise be dropped — and a large tool result is
          // exactly the size that hits this.
          guard let last = pending.lastIndex(of: UInt8(ascii: "\n")) else {
            // A frame this long is not MCP framing. Stop buffering rather than
            // grow without bound on a child that never sends a newline.
            if pending.count > 32 << 20 { pending.removeAll(keepingCapacity: false) }
            continue
          }
          let complete = pending[..<last]
          pending = Data(pending[pending.index(after: last)...])
          for line in complete.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            self?.received(Data(line))
          }
        }
      }
    }

    /// stderr is log output by construction: every one of these servers keeps
    /// stdout clear because stdout is the JSON-RPC channel.
    private func drainStderr(_ handle: FileHandle) {
      let origin = key
      onDedicatedThread("bastion.stderr") {
        while true {
          let data = handle.availableData
          if data.isEmpty { break }
          let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty { hostLog(origin, .info, text) }
        }
      }
    }

    private func watchExit(_ process: Process) {
      onDedicatedThread("bastion.reap") { [weak self] in
        process.waitUntilExit()
        self?.childExited(status: process.terminationStatus)
      }
    }

    /// Everyone waiting is told. This is the "blast radius" half of the crash
    /// answer: with one process per client a crash was one client's problem and
    /// nobody had to say anything. Here it is several clients' problem, so it
    /// has to be said out loud, to each of them and in the Activity window.
    private func childExited(status: Int32) {
      let waiters = state.withLock { current -> [Waiter] in
        let taken = Array(current.pending.values)
        current.pending.removeAll()
        current.process = nil
        current.stdin = nil
        current.handshake = nil
        return taken
      }
      let detail = "exit \(status)"
      hostLog(
        key, status == 0 ? .info : .error,
        "server exited (\(detail))"
          + (waiters.isEmpty ? "" : " — \(waiters.count) request(s) in flight were dropped"))
      if status != 0 { noteFailure() }
      for waiter in waiters { waiter.resume(.failure(SupervisorError.childDied(detail))) }
    }

    /// Exponential backoff with a ceiling, then a breaker.
    ///
    /// A server that cannot start — a revoked credential, a bad endpoint — will
    /// not start on the fourth try either, and retrying it on every request
    /// turns one misconfigured profile into a fork bomb. The breaker makes the
    /// failure legible instead: the error names the profile and says when it
    /// will be tried again.
    private func noteFailure() {
      state.withLock {
        $0.failures += 1
        let delay = min(pow(2.0, Double($0.failures)), 60)
        $0.blockedUntil = Date().addingTimeInterval(delay)
      }
    }

    private func noteSuccess() {
      state.withLock {
        $0.failures = 0
        $0.blockedUntil = nil
        $0.lastActivity = Date()
      }
    }

    func stop(reason: String) {
      reaper?.cancel()
      reaper = nil
      let process = state.withLock { current -> Process? in
        let taken = current.process
        current.process = nil
        return taken
      }
      guard let process, process.isRunning else { return }
      hostLog(key, .info, "stopping — \(reason)")
      // SIGTERM, not SIGKILL: the child gets to close its own token file and
      // flush its own state. `childExited` still resolves every waiter.
      process.terminate()
    }

    /// Sweep expired calls and stop an idle child.
    private func startReaper() {
      let timer = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "io.mgcrea.bastion.reaper"))
      timer.schedule(deadline: .now() + 10, repeating: 10)
      timer.setEventHandler { [weak self] in self?.sweep() }
      timer.resume()
      reaper = timer
    }

    private func sweep() {
      let now = Date()
      let expired = state.withLock { current -> [Waiter] in
        let due = current.pending.filter { $0.value.deadline <= now }
        for id in due.keys { current.pending.removeValue(forKey: id) }
        return Array(due.values)
      }
      for waiter in expired {
        waiter.resume(.failure(SupervisorError.timedOut(seconds: Int(Self.callTimeout))))
      }

      let idle = state.withLock {
        $0.pending.isEmpty && now.timeIntervalSince($0.lastActivity) > Self.idleTimeout
      }
      if idle {
        Supervisor.shared.stop(profile: profile.name, server: server.id)
      }
    }

    // MARK: One request

    /// Handle one client frame, returning the response frame or `nil` for a
    /// notification.
    func handle(_ request: Data) throws -> Data? {
      guard var frame = try? JSONSerialization.jsonObject(with: request) as? [String: Any] else {
        throw SupervisorError.malformedRequest("not a JSON object")
      }
      guard let method = frame["method"] as? String else {
        throw SupervisorError.malformedRequest("no method")
      }
      let clientID = frame["id"]

      // The handshake never reaches the child. It happened once, at spawn, and
      // answering every client from that one result is precisely what makes a
      // shared instance possible: the old dialect's `initialize` is stateful,
      // and letting each client run its own would re-initialize a server other
      // clients are mid-conversation with.
      if method == "initialize" {
        guard let clientID else { throw SupervisorError.malformedRequest("initialize without id") }
        return try handshakeReply(to: clientID, from: frame)
      }
      // Same reason, in the other direction: a second `initialized` is a
      // protocol error to a server that has already had one.
      if method == "notifications/initialized" { return nil }

      LogStore.record(origin: key, frame: frame)

      // Make sure there is a child before rewriting anything into its numbering.
      try ensureRunning()

      guard let clientID else {
        // A notification. Forwarded and forgotten — there is nothing to
        // correlate and nothing to wait for.
        try write(frame)
        return nil
      }

      let internalID = state.withLock { current -> Int in
        let next = current.nextID
        current.nextID += 1
        return next
      }
      frame["id"] = internalID

      let outcome = OSAllocatedUnfairLock<Result<Data, Error>?>(initialState: nil)
      let semaphore = DispatchSemaphore(value: 0)
      let waiter = Waiter(
        clientID: clientID,
        deadline: Date().addingTimeInterval(Self.callTimeout)
      ) { result in
        // Exactly once. Three different threads can reach a waiter — the reader
        // when a response arrives, the reaper when it expires, and the exit
        // watcher when the child dies — and removing it from `pending` is not
        // enough on its own, because one path can be holding a waiter it has
        // already taken while another is mid-flight.
        let first = outcome.withLock { current -> Bool in
          guard current == nil else { return false }
          current = result
          return true
        }
        if first { semaphore.signal() }
      }
      state.withLock { $0.pending[internalID] = waiter }

      do {
        try write(frame)
      } catch {
        _ = state.withLock { $0.pending.removeValue(forKey: internalID) }
        throw error
      }

      // No timeout here: the reaper owns the deadline, and a second timer would
      // be a second answer to the same question. Waiting forever is safe only
      // because every path that can strand this request — expiry, child death,
      // shutdown — resolves the waiter.
      semaphore.wait()
      guard let result = outcome.withLock({ $0 }) else {
        throw SupervisorError.childDied("no response")
      }
      return try result.get()
    }

    /// Answer a client's `initialize` from the child's, with the client's id.
    private func handshakeReply(to clientID: Any, from request: [String: Any]) throws -> Data {
      try ensureRunning()
      guard let result = state.withLock({ $0.handshake }) else {
        throw SupervisorError.startFailed("the server did not complete its handshake")
      }

      if let params = request["params"] as? [String: Any],
        let info = params["clientInfo"] as? [String: Any],
        let name = info["name"] as? String
      {
        state.withLock { _ = $0.clients.insert(name) }
        hostLog(key, .info, "client attached: \(name)")
      }

      let reply: [String: Any] = ["jsonrpc": "2.0", "id": clientID, "result": result]
      return try JSONSerialization.data(withJSONObject: reply)
    }

    /// Both halves, because a running child that has not completed its
    /// handshake is not ready and looks exactly like one that is.
    ///
    /// `handshake` is cleared in `childExited` alongside the process, so a
    /// child that died and was restarted goes through this again rather than
    /// serving a cached capability list from a process that no longer exists.
    private func ensureRunning() throws {
      let ready = state.withLock { $0.process?.isRunning == true && $0.handshake != nil }
      if ready { return }
      if state.withLock({ $0.process?.isRunning != true }) { try start() }
      try performHandshake()
    }

    /// The one `initialize` the child ever sees.
    ///
    /// Synchronous and blocking on purpose: nothing may be routed to this child
    /// until it has answered, so there is no useful work to overlap with.
    private func performHandshake() throws {
      let id = state.withLock { current -> Int in
        let next = current.nextID
        current.nextID += 1
        return next
      }
      let request: [String: Any] = [
        "jsonrpc": "2.0", "id": id, "method": "initialize",
        "params": [
          // The dialect the CHILD speaks, from the manifest — not whatever a
          // client asked for. Translating between the two is `Dialect`'s job,
          // and conflating them here is how a server gets handed a protocol
          // version it has never heard of.
          "protocolVersion": server.dialect.rawValue,
          "capabilities": [:],
          "clientInfo": ["name": "bastion", "version": AppInfo.version],
        ],
      ]

      let semaphore = DispatchSemaphore(value: 0)
      let outcome = OSAllocatedUnfairLock<Result<Data, Error>?>(initialState: nil)
      let waiter = Waiter(clientID: id, deadline: Date().addingTimeInterval(30)) { result in
        outcome.withLock { current in
          guard current == nil else { return }
          current = result
        }
        semaphore.signal()
      }
      state.withLock { $0.pending[id] = waiter }
      try write(request)

      guard semaphore.wait(timeout: .now() + 30) == .success else {
        _ = state.withLock { $0.pending.removeValue(forKey: id) }
        throw SupervisorError.startFailed("the server did not answer initialize within 30s")
      }
      guard let result = outcome.withLock({ $0 }) else {
        throw SupervisorError.startFailed("the server did not answer initialize")
      }
      let data = try result.get()
      guard let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let payload = frame["result"] as? [String: Any]
      else {
        throw SupervisorError.startFailed("the server's initialize reply was not a result")
      }

      state.withLock { $0.handshake = payload }
      try write([
        "jsonrpc": "2.0", "method": "notifications/initialized",
      ])
      noteSuccess()
      hostLog(key, .info, "handshake complete")
    }

    // MARK: Wire

    private func write(_ frame: [String: Any]) throws {
      guard let stdin = state.withLock({ $0.stdin }) else {
        throw SupervisorError.childDied("stdin is closed")
      }
      var data = try JSONSerialization.data(withJSONObject: frame)
      data.append(UInt8(ascii: "\n"))
      guard writeAll(stdin.fileDescriptor, data) else {
        throw SupervisorError.childDied("could not write to the server")
      }
    }

    /// One frame from the child.
    private func received(_ line: Data) {
      guard var frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        return
      }

      // A server→client REQUEST: it has both a method and an id. The old spec
      // used these for sampling, elicitation and roots; 2026-07-28 replaces
      // them with Multi Round-Trip Requests and they are on a ~12-month
      // offramp. Bastion refuses rather than routing: a shared instance has no
      // single client to ask, and picking one arbitrarily would hand one
      // project's agent a prompt raised on behalf of another's.
      if let method = frame["method"] as? String {
        if let id = frame["id"] {
          hostLog(key, .error, "server asked for '\(method)' — refused (not supported by Bastion)")
          let refusal: [String: Any] = [
            "jsonrpc": "2.0", "id": id,
            "error": [
              "code": -32601,
              "message":
                "Bastion does not relay server-initiated requests: one instance serves several clients, so there is no single client to ask.",
            ],
          ]
          try? write(refusal)
        }
        // A notification from the child with no id. Nothing to correlate it to,
        // so it is logged and dropped rather than broadcast — sending one
        // client's progress notification to every client would be worse than
        // sending it to none.
        return
      }

      guard let internalID = frame["id"] as? Int else { return }
      let waiter = state.withLock { $0.pending.removeValue(forKey: internalID) }
      guard let waiter else { return }

      noteSuccess()

      // Hand the client back its own id. It has never seen Bastion's numbering
      // and must not start now: a client that saw an id it did not send would
      // treat the response as unsolicited and drop it.
      if let clientID = waiter.clientID {
        frame["id"] = clientID
      } else {
        frame.removeValue(forKey: "id")
      }
      guard let data = try? JSONSerialization.data(withJSONObject: frame) else {
        waiter.resume(.failure(SupervisorError.malformedRequest("unencodable response")))
        return
      }
      waiter.resume(.success(data))
    }
  }
}

extension LogStore {
  /// Record what a request reached for, and nothing more.
  ///
  /// Method names and the name of whatever was asked for — a tool, a prompt, a
  /// resource URI — never arguments and never results. That is the claim the
  /// Activity window makes on screen, and it is cheaper to keep here, at the
  /// one place frames are inspected, than to remember at each call site.
  nonisolated static func record(origin: String, frame: [String: Any]) {
    guard let method = frame["method"] as? String else { return }
    let params = frame["params"] as? [String: Any]
    let identifier: String? =
      switch method {
      case "tools/call": params?["name"] as? String
      case "prompts/get": (params?["name"] as? String).map { "prompt: \($0)" }
      case "resources/read": (params?["uri"] as? String).map { "read: \($0)" }
      default: nil
      }
    if let identifier {
      hostLog(origin, .call, identifier)
    } else {
      hostLog(origin, .info, method)
    }
  }
}
