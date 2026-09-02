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
    case serverDisabled(String)
    case unknownProfile(profile: String, server: String)
    case notConfigured(profile: String, missing: [String])
    case startFailed(String)
    /// A remote server answered, and the answer was no.
    ///
    /// Its own case rather than `startFailed` because there is nothing to
    /// start: "could not start the server" in front of "Stripe refused your
    /// key" describes a step that does not exist and sends the reader looking
    /// for a process. The detail is already a whole sentence, so this adds
    /// nothing to it.
    case remoteRefused(String)
    case circuitOpen(profile: String, until: Date)
    case childDied(String)
    case timedOut(seconds: Int)
    case malformedRequest(String)

    var errorDescription: String? {
      switch self {
      case .unknownServer(let id):
        return "no server '\(id)' — Bastion only runs the servers you have installed"
      case .serverDisabled(let id):
        return
          "'\(id)' is switched off in Bastion. Its profiles and credentials are untouched — turn "
          + "it back on in the Bastion window"
      case .unknownProfile(let profile, let server):
        return "no profile '\(profile)' for \(server) — create it in Bastion"
      case .notConfigured(let profile, let missing):
        return "profile '\(profile)' is missing \(missing.joined(separator: ", "))"
      case .startFailed(let detail):
        return "could not start the server: \(detail)"
      case .remoteRefused(let detail):
        return detail
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
  /// Remote sessions, keyed the same way. A separate table rather than a
  /// protocol over both: the two share a method name and nothing else, and an
  /// abstraction that hid "this one has a pid and that one does not" would hide
  /// the single most important difference between them.
  private let remotes = OSAllocatedUnfairLock<[String: RemoteInstance]>(initialState: [:])
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
  /// `client` is the name the bearer token was issued to — authenticated, and
  /// the only identity here worth attributing anything to. The name a client
  /// reports in `clientInfo` is self-reported and, per the spec, explicitly not
  /// to be relied on; it is recorded beside this one, never instead of it.
  func call(
    profile profileName: String, server serverID: String, frame: [String: Any], era: Dialect.Era,
    client: String
  ) throws -> Data? {
    // The user's installed list, never the catalog. Resolving through the
    // catalog here would spawn a server nobody asked for, which is the one
    // thing the old closed table was actually protecting against.
    guard let server = ServerStore.lookup(serverID) else {
      throw SupervisorError.unknownServer(serverID)
    }
    // Before the profile guard on purpose: a disabled server with no profile
    // should report the fact somebody can act on, not the incidental one.
    //
    // Note this is not a 404. It reaches the client as HTTP 200 carrying a
    // JSON-RPC error, the same way `unknownServer` already does, because a 500
    // or a 404 arrives in a client as "connection failed" — the least
    // informative possible rendering of a sentence that says exactly what to do.
    guard server.isEnabled else {
      throw SupervisorError.serverDisabled(serverID)
    }
    guard let profile = ProfileStore.lookup(name: profileName, server: serverID) else {
      throw SupervisorError.unknownProfile(profile: profileName, server: serverID)
    }

    // Dispatch on HOW this server is reached, which is the question being
    // asked. This used to test `origin == .builtin` — asking where a definition
    // came from in order to work out how to talk to it — and that conflation
    // had exactly one server to be wrong about until there were two kinds.
    switch server.transport {
    case .inProcess:
      // Bastion itself. There is no package to install, no child to spawn, and
      // none of the machinery below — no id remapping, no waiter, no restart —
      // has anything to be out of step with.
      return try BuiltinServer.handle(frame, era: era, profile: profile, client: client)

    case .remote:
      // Somebody else's server. Nothing is supervised, because nothing here is
      // running it; what Bastion still does is hold the credential, be the one
      // identity, and write the audit line.
      let instance = try remoteInstanceFor(profile: profile, server: server)
      return try instance.handle(frame, era: era, client: client)

    case .child:
      let instance = try instanceFor(profile: profile, server: server)
      return try instance.handle(frame, era: era, client: client)
    }
  }

  /// Stop everything. Called when the app quits.
  func stopAll() {
    let live = instances.withLock { taken -> [Instance] in
      let all = Array(taken.values)
      taken.removeAll()
      return all
    }
    for instance in live { instance.stop(reason: "Bastion is quitting") }

    let remote = remotes.withLock { taken -> [RemoteInstance] in
      let all = Array(taken.values)
      taken.removeAll()
      return all
    }
    for instance in remote { instance.stop(reason: "Bastion is quitting") }
  }

  func stop(profile: String, server: String) {
    let key = "\(profile)/\(server)"
    let instance = instances.withLock { $0.removeValue(forKey: key) }
    instance?.stop(reason: "stopped by request")
    let remote = remotes.withLock { $0.removeValue(forKey: key) }
    remote?.stop(reason: "stopped by request")
    Task(priority: Activity.priority) { @MainActor in Activity.shared.stopped(id: key) }
  }

  /// What is running right now, for the Activity window.
  var running: [(id: String, pid: Int32, clients: Int)] {
    instances.withLock { $0.values.map { ($0.key, $0.pid, $0.clientCount) } }
  }

  /// Requests handed to a child and not yet answered.
  ///
  /// The one number that says whether it is safe to replace this process. A
  /// running instance is not a reason to wait — Bastion keeps children alive
  /// for half an hour after the last call — but a request in flight is: the
  /// client is blocked on a response that a relaunch would turn into a dropped
  /// connection, which reads as Bastion breaking rather than as Bastion
  /// updating.
  var inFlightCount: Int {
    let children = instances.withLock { $0.values.reduce(0) { $0 + $1.pendingCount } }
    // Remote calls count too. They are the ones most likely to be slow — a real
    // API call over somebody else's network — so leaving them out would make
    // the number most wrong exactly when it matters.
    let remote = remotes.withLock { $0.values.reduce(0) { $0 + $1.pendingCount } }
    return children + remote
  }

  /// The remote counterpart to `instanceFor`, and deliberately much smaller.
  ///
  /// There is nothing to spawn, so there is no start race worth a per-key gate
  /// out here — what does need serialising is the upstream handshake, and
  /// `RemoteInstance` owns that itself. What survives is the missing-variable
  /// check, because a profile with no credential fails the same way whichever
  /// transport it is on, and saying so before a request leaves the machine is
  /// better than relaying a 401 back.
  private func remoteInstanceFor(profile: Profile, server: BastionServer) throws
    -> RemoteInstance
  {
    let key = profile.id
    if let existing = remotes.withLock({ $0[key] }) { return existing }

    let missing = ProfileEnvironment.missing(for: profile, server: server)
    guard missing.isEmpty else {
      throw SupervisorError.notConfigured(profile: profile.name, missing: missing)
    }

    let created = try RemoteInstance(profile: profile, server: server)
    // Last writer wins, and the loser is simply dropped: creating one opens no
    // process and no connection, so a lost race costs an object rather than an
    // orphaned child.
    return remotes.withLock { table in
      if let existing = table[key] { return existing }
      table[key] = created
      return created
    }
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
      /// The log row this call is recorded in, so the reply can be attached to
      /// it. Correlating through `pending` rather than through a second table:
      /// this is already the thing that knows which response answers which
      /// request, and a parallel map would be a second answer to that question.
      let logID: UUID?
      let resume: (Result<Data, Error>) -> Void
    }

    /// The manifest variables this profile's server marks secret.
    ///
    /// The one set of argument names Bastion can be *certain* are credentials.
    /// A third-party server's own `token` parameter is unknowable from here,
    /// which is why `CallCapture` carries a conventional-names backstop too.
    private var secretKeys: Set<String> {
      Set(server.env.filter(\.isSecret).map(\.name))
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

    var pendingCount: Int { state.withLock { $0.pending.count } }
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

      let id = key
      let pid = process.processIdentifier
      let profileName = profile.name
      let serverID = server.id
      let writes = profile.allowWrites
      Task(priority: Activity.priority) { @MainActor in
        Activity.shared.started(
          id: id, profile: profileName, server: serverID, pid: pid, allowWrites: writes)
      }

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
      let id = key
      let dropped = waiters.count
      Task(priority: Activity.priority) { @MainActor in
        Activity.shared.exited(
          id: id,
          detail: detail + (dropped == 0 ? "" : " — \(dropped) request(s) dropped"))
      }
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
    ///
    /// `era` decides what the client is owed. The child below is legacy either
    /// way — every server in the manifest is — so this is where the two eras
    /// stop being different.
    func handle(_ incoming: [String: Any], era: Dialect.Era, client: String) throws -> Data? {
      var frame = incoming
      guard let method = frame["method"] as? String else {
        throw SupervisorError.malformedRequest("no method")
      }
      let clientID = frame["id"]
      let reported = Dialect.clientName(of: frame)

      if let reported {
        let announced = state.withLock { $0.clients.insert(reported).inserted }
        if announced { hostLog(key, .info, "client attached: \(client) (\(reported))") }
      }

      // Attribution happens for every frame, but only a request counts. A
      // notification is traffic, not a call, and counting it would inflate the
      // one number on the window somebody might quote.
      let id = key
      let counts = clientID != nil
      Task(priority: Activity.priority) { @MainActor in
        Activity.shared.called(id: id, client: client, reported: reported, counts: counts)
      }

      if case .modern = era {
        // `server/discover` is mandatory in the modern revision and no legacy
        // child implements one — asking mcp-shopify returns -32601, which is
        // exactly how the spec says to recognise a legacy server. Bastion
        // answers it from the handshake it already took at spawn.
        if method == "server/discover" {
          guard let clientID else {
            throw SupervisorError.malformedRequest("server/discover without id")
          }
          return try discoverReply(to: clientID)
        }
        // A modern frame naming a legacy method. Not forwarded: the child was
        // initialized once at spawn and a second `initialize` is a protocol
        // error to it, so the honest answer is that Bastion does not implement
        // this method on this era — which the gateway turns into the 404 the
        // spec asks for.
        if method == "initialize" || method == "notifications/initialized" {
          guard let clientID else { return nil }
          return try encode([
            "jsonrpc": "2.0", "id": clientID,
            "error": Dialect.methodNotFoundError(method),
          ])
        }
        // Strip the three namespaced keys the child has never heard of, and
        // nothing else — `_meta` is an open extension field in the legacy
        // revisions too, and it is where a progress token lives.
        frame = Dialect.stripModernMeta(from: frame)
      } else {
        // The legacy handshake never reaches the child. It happened once, at
        // spawn, and answering every client from that one result is precisely
        // what makes a shared instance possible: `initialize` is stateful, and
        // letting each client run its own would re-initialize a server other
        // clients are mid-conversation with.
        if method == "initialize" {
          guard let clientID else {
            throw SupervisorError.malformedRequest("initialize without id")
          }
          return try handshakeReply(to: clientID, from: frame)
        }
        // Same reason, in the other direction: a second `initialized` is a
        // protocol error to a server that has already had one.
        if method == "notifications/initialized" { return nil }
      }

      let logID = LogStore.record(
        origin: key, frame: frame, mode: profile.capture, secretKeys: secretKeys)

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
        deadline: Date().addingTimeInterval(Self.callTimeout),
        logID: logID
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

    /// Answer a legacy client's `initialize` from the child's, with the
    /// client's id.
    private func handshakeReply(to clientID: Any, from request: [String: Any]) throws -> Data {
      try ensureRunning()
      guard let result = state.withLock({ $0.handshake }) else {
        throw SupervisorError.startFailed("the server did not complete its handshake")
      }
      return try encode(["jsonrpc": "2.0", "id": clientID, "result": result])
    }

    /// Answer a modern client's `server/discover` from the same handshake.
    ///
    /// The child is started first if it is not running. Discovery is the one
    /// modern request that has to spawn something before it can be answered,
    /// because what it describes — capabilities, identity — is the child's, and
    /// only the child can say.
    private func discoverReply(to clientID: Any) throws -> Data {
      try ensureRunning()
      guard let handshake = state.withLock({ $0.handshake }) else {
        throw SupervisorError.startFailed("the server did not complete its handshake")
      }
      let result = Dialect.discoverResult(fromHandshake: handshake, serverID: server.id)
      hostLog(key, .info, "server/discover")
      return try encode(["jsonrpc": "2.0", "id": clientID, "result": result])
    }

    private func encode(_ frame: [String: Any]) throws -> Data {
      try JSONSerialization.data(withJSONObject: frame)
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
      // The handshake is Bastion's own request, not a client's, so there is no
      // log row for its reply to attach to.
      let waiter = Waiter(
        clientID: id, deadline: Date().addingTimeInterval(30), logID: nil
      ) { result in
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

      // The version the child actually agreed to, not the one it was asked
      // for. Worth a line: the manifest said 2025-06-18 for every server until
      // a live handshake showed they all negotiate 2025-11-25, and a pin that
      // silently costs a year of protocol is exactly the kind of thing that is
      // only ever noticed if something says it out loud.
      let negotiated = payload["protocolVersion"] as? String ?? "unknown"
      let asked = server.dialect.rawValue
      hostLog(
        key, negotiated == asked ? .info : .error,
        "handshake complete (protocol \(negotiated)"
          + (negotiated == asked ? "" : ", but the manifest says \(asked)") + ")")
      let instanceKey = key
      Task(priority: Activity.priority) { @MainActor in
        Activity.shared.negotiated(id: instanceKey, dialect: negotiated)
      }

      measureToolCost()
    }

    /// Ask once, for the figure the detail pane shows without being asked.
    ///
    /// Fire-and-forget, and that is the whole design: `performHandshake` is
    /// synchronous because nothing may be routed to a child before it answers,
    /// and hanging a second blocking round trip off the end would put a
    /// measurement in front of the first client request. This one is written
    /// and forgotten. A child that never answers, or answers with an error,
    /// leaves the stored figure exactly as it was.
    ///
    /// Once per process rather than per connect. The write gate is applied to a
    /// child at spawn, so this list cannot change under a running one, and
    /// `ProfileStore.upsert` and `ServerInstaller` both stop the child when
    /// anything that would move it changes.
    ///
    /// Bastion's own request, like the handshake above, so it takes no log row
    /// and no client id: this is not traffic anybody asked for, and the
    /// Activity window must not imply somebody did.
    private func measureToolCost() {
      let id = state.withLock { current -> Int in
        let next = current.nextID
        current.nextID += 1
        return next
      }
      let profileID = profile.id
      let allowWrites = profile.allowWrites
      let version = ServerInstaller.installedVersion(of: server)
      let waiter = Waiter(
        clientID: nil, deadline: Date().addingTimeInterval(30), logID: nil
      ) { result in
        guard let data = try? result.get(),
          let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let payload = frame["result"] as? [String: Any],
          let entries = payload["tools"] as? [[String: Any]]
        else { return }
        let bytes = entries.reduce(0) { $0 + ToolCost.bytes(of: $1) }
        Task { @MainActor in
          ToolCostStore.shared.record(
            profileID: profileID, bytes: bytes, toolCount: entries.count,
            partial: payload["nextCursor"] != nil, version: version, allowWrites: allowWrites)
        }
      }
      state.withLock { $0.pending[id] = waiter }
      try? write(["jsonrpc": "2.0", "id": id, "method": "tools/list", "params": [:]])
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

      // The reply, for a profile that opted into results. This is the only
      // place a child's response is ever inspected — the rest of this function
      // is id bookkeeping — so it is where the record is completed.
      if let logID = waiter.logID {
        hostCallResult(
          logID,
          CallCapture.result(frame, mode: profile.capture, secretKeys: secretKeys),
          failed: CallCapture.isFailure(frame))
      }

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
  /// Record what a request reached for, and what it was called with.
  ///
  /// Method names, the name of whatever was asked for — a tool, a prompt, a
  /// resource URI — and, for a profile that records them, the arguments. Never
  /// a credential: `CallCapture` drops the tools whose argument *is* the
  /// secret and blanks anything under a secret-looking key, and it does that
  /// here rather than at each call site because a rule kept in one of three
  /// callers is a rule that holds a third of the time.
  ///
  /// Returns the id the reply should be attached to, or nil if this frame was
  /// not a call worth correlating. The caller keeps it across the wait.
  @discardableResult
  nonisolated static func record(
    origin: String, frame: [String: Any], mode: CallCapture.Mode = .off,
    secretKeys: Set<String> = []
  ) -> UUID? {
    guard let method = frame["method"] as? String else { return nil }
    let params = frame["params"] as? [String: Any]
    let identifier: String? =
      switch method {
      case "tools/call": params?["name"] as? String
      case "prompts/get": (params?["name"] as? String).map { "prompt: \($0)" }
      case "resources/read": (params?["uri"] as? String).map { "read: \($0)" }
      default: nil
      }
    guard let identifier else {
      hostLog(origin, .info, method)
      return nil
    }
    let arguments =
      method == "tools/call"
      ? CallCapture.arguments(
        tool: params?["name"] as? String, params: params, mode: mode, secretKeys: secretKeys)
      : nil
    return hostCall(origin, identifier, arguments: arguments)
  }
}
