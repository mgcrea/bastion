import Foundation
import Observation

/// What is running, who is talking to it, and what they asked for.
///
/// This is the product. Bastion's claim is that one shared instance is *more*
/// auditable than nine private ones, and this is where that is either true or
/// marketing. Nine private copies of `mcp-x-api` — which is not hypothetical,
/// there were ten on this machine while step 5 was being written — produce no
/// record at all: no list of what is running, no count of what was called, and
/// nothing that says which project asked.
///
/// Observation, not bookkeeping: nothing in the gateway or the supervisor reads
/// back out of here. `Supervisor` remains the authority on what is alive; this
/// is a projection of it that a window can watch.
@MainActor
@Observable
final class Activity {
  static let shared = Activity()

  /// Main-actor hops are pinned to one priority on purpose.
  ///
  /// `started` is enqueued from the thread that spawned the child and
  /// `called`/`attached` from a connection thread, always later in wall-clock
  /// time — but the actor's executor only guarantees FIFO **within** a
  /// priority. Left to inherit, a call could land before the instance it
  /// belongs to exists and be dropped, so a busy server would show zero calls.
  /// Cupertino's `Sessions` learned this the same way.
  nonisolated static let priority = TaskPriority.userInitiated

  struct Client: Identifiable {
    /// The name the bearer token was issued to. Authenticated: this is who the
    /// caller actually is.
    let id: String
    /// What the client calls itself in `clientInfo`. Self-reported and,
    /// per the spec, explicitly not to be trusted for anything — shown beside
    /// the token identity rather than instead of it, because the interesting
    /// case is exactly when the two disagree.
    var reportedName: String?
    var calls: Int
    var lastSeen: Date
  }

  struct Instance: Identifiable {
    /// `<profile>/<server>`.
    let id: String
    let profile: String
    let server: String
    /// The child's pid, or `nil` for a server with no process — Bastion's own,
    /// and every remote one. `-1` still means "exited", which is a different
    /// fact from "never had one".
    var pid: Int32?
    /// The host a remote instance answers on, in the place a pid would go.
    /// Nil for a child, whose pid is the more useful identifier.
    var remoteHost: String?
    var startedAt: Date
    /// The version the child actually negotiated, not the one it was asked for.
    var dialect: String?
    var allowWrites: Bool
    var clients: [Client]
    var calls: Int
    /// How many times this child has been restarted under the supervisor. The
    /// number that turns "it feels flaky" into a fact.
    var restarts: Int
    var lastExit: String?

    var displayName: String { "\(profile) / \(server)" }

    /// Whether this will answer a request right now.
    ///
    /// A child says so with a live pid. A remote server has none and cannot
    /// die, so what stands in for "running" is that Bastion still holds a
    /// session with it — `stopped` removes the row when it does not.
    var isLive: Bool { (pid ?? 0) > 0 || remoteHost != nil }
  }

  private(set) var instances: [Instance] = []

  // MARK: - From the supervisor

  func started(
    id: String, profile: String, server: String, pid: Int32?, allowWrites: Bool,
    remoteHost: String? = nil
  ) {
    if let index = instances.firstIndex(where: { $0.id == id }) {
      // A restart, not a new instance. Keeping the row — and its client list —
      // is the point: "this server has restarted four times today" is only
      // visible if the row survives the restart that would otherwise clear it.
      instances[index].pid = pid
      instances[index].remoteHost = remoteHost
      instances[index].startedAt = Date()
      instances[index].restarts += 1
      instances[index].dialect = nil
      return
    }
    instances.append(
      Instance(
        id: id, profile: profile, server: server, pid: pid, remoteHost: remoteHost,
        startedAt: Date(), dialect: nil, allowWrites: allowWrites, clients: [], calls: 0,
        restarts: 0, lastExit: nil))
  }

  /// Seed a fully-formed instance, for `DemoSeed` only.
  ///
  /// The live path builds one across `started` -> `negotiated` -> `called`xN,
  /// because that is the order the wire delivers them. A fixture has no wire,
  /// and replaying those three calls to reach a known row would mean seeding
  /// `startedAt` through `Date()` — which is exactly the determinism this is
  /// here to avoid.
  func startDemo(
    profile: String, server: String, pid: Int32?, startedAt: Date, dialect: String?,
    allowWrites: Bool, clients: [Client], calls: Int, restarts: Int, lastExit: String?
  ) {
    instances.append(
      Instance(
        id: "\(profile)/\(server)", profile: profile, server: server, pid: pid,
        remoteHost: nil, startedAt: startedAt, dialect: dialect, allowWrites: allowWrites,
        clients: clients, calls: calls, restarts: restarts, lastExit: lastExit))
  }

  func negotiated(id: String, dialect: String) {
    guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
    instances[index].dialect = dialect
  }

  func exited(id: String, detail: String) {
    guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
    instances[index].pid = -1
    instances[index].lastExit = detail
  }

  /// Removed entirely — the supervisor has let go of it, so there is nothing
  /// left to be the state of.
  func stopped(id: String) {
    instances.removeAll { $0.id == id }
  }

  /// One request, attributed to the client the bearer token identifies.
  ///
  /// `reported` is whatever the client called itself. It is recorded rather
  /// than believed: two configs sharing one token both authenticate as that
  /// token's name, and seeing two different `clientInfo` names under one
  /// identity is how you find that out.
  func called(id: String, client: String, reported: String?, counts: Bool) {
    guard let index = instances.firstIndex(where: { $0.id == id }) else { return }
    if counts { instances[index].calls += 1 }

    if let seat = instances[index].clients.firstIndex(where: { $0.id == client }) {
      if counts { instances[index].clients[seat].calls += 1 }
      instances[index].clients[seat].lastSeen = Date()
      if let reported, instances[index].clients[seat].reportedName != reported {
        instances[index].clients[seat].reportedName = reported
      }
    } else {
      instances[index].clients.append(
        Client(id: client, reportedName: reported, calls: counts ? 1 : 0, lastSeen: Date()))
    }
  }

  // MARK: - Derived

  /// A child with a live pid, or a remote server Bastion holds a session with.
  /// "Running" means "will answer", which is the question the menu is asking.
  var runningCount: Int {
    instances.filter { ($0.pid ?? 0) > 0 || $0.remoteHost != nil }.count
  }
  var totalCalls: Int { instances.reduce(0) { $0 + $1.calls } }

  /// Every client currently attached to anything, deduplicated.
  ///
  /// The headline number for the whole idea: N clients, M processes. With one
  /// process per connection those two were the same number by construction, so
  /// there was nothing to report.
  var attachedClients: [String] {
    Array(Set(instances.flatMap { $0.clients.map(\.id) })).sorted()
  }
}
