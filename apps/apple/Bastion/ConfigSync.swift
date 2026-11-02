import Foundation

/// Any JSON value, compared by content.
///
/// A synced entity travels as one of these rather than as a store's own row
/// type, for two reasons. The merge has to compare entities of every kind
/// without knowing any of them, and a field written by a newer Bastion has to
/// survive a round trip through an older one: decoded into a row type, it would
/// be dropped on the floor and the next push would delete it everywhere.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  init<T: Encodable>(encoding value: T) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
  }

  func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
  }
}

/// Configuration sync through iCloud's key-value store: the keys, the envelope
/// every value travels in, and the per-entity merge.
///
/// Every decision lives here, with no store, no Keychain and no iCloud, so
/// `make unit` can check the merge exhaustively. `ConfigSyncEngine` is the thin
/// layer that reads the cloud and calls the stores. The design is
/// `docs/superpowers/specs/2026-11-01-icloud-config-sync-design.md`, "Keys and
/// values".
nonisolated enum ConfigSync {
  /// The envelope version this build writes and understands. A higher one is
  /// left alone, never decoded lossily and written back.
  static let version = 1
  /// How long a deletion is remembered, so a Mac that was offline for a while
  /// does not push back what was deleted elsewhere.
  static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600

  enum Kind: String, Codable, CaseIterable, Sendable {
    case server, profile, workspace
    case skillSource = "skillsource"
    case skillChoice = "skillchoice"
    /// One entity, id `skillsources`: the source order, which decides which
    /// skill wins a name clash.
    case order
  }

  /// `<kind>/<16 hex digits>`. A profile id or a path can pass the store's
  /// 64-byte key limit, so the key is a hash and the envelope carries the id.
  /// FNV-1a rather than a cryptographic hash: nothing here is a secret, and a
  /// collision would show as two ids under one key, which the envelope's own
  /// `id` makes visible.
  static func key(_ kind: Kind, id: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in id.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01b3
    }
    let hex = String(hash, radix: 16)
    return "\(kind.rawValue)/" + String(repeating: "0", count: 16 - hex.count) + hex
  }

  /// Whether a key in the store is one of these, rather than something else
  /// the app keeps there, such as the probe's.
  static func isSyncKey(_ key: String) -> Bool {
    let parts = key.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, Kind(rawValue: String(parts[0])) != nil else { return false }
    return parts[1].count == 16 && parts[1].allSatisfy { $0.isHexDigit && !$0.isUppercase }
  }

  /// One value in the store.
  ///
  /// `entity` is nil exactly when `deleted`: a deletion is a tombstone rather
  /// than a removed key, so a Mac that missed it does not push the entity
  /// back. `was` is set on a profile that was renamed, naming its old id.
  struct Envelope: Codable, Equatable, Sendable {
    var v: Int
    var kind: Kind
    var id: String
    var at: String
    var from: String
    var deleted: Bool
    var entity: JSONValue?
    var was: String?
    /// On a profile's tombstone, the id it was renamed to, so a Mac that
    /// sees the tombstone first renames rather than removes it.
    var to: String? = nil
  }

  /// ISO 8601, UTC, with milliseconds. Compared as dates, matched as strings.
  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  static func date(_ at: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: at)
  }

  /// Last writer wins, by time, and a tie goes to the Mac whose name sorts
  /// higher, so every Mac picks the same winner. An unreadable time loses.
  static func wins(_ a: (at: String, from: String), over b: (at: String, from: String)) -> Bool {
    let first = date(a.at) ?? .distantPast
    let second = date(b.at) ?? .distantPast
    if first != second { return first > second }
    return a.from > b.from
  }

  // MARK: - The merge

  /// What this Mac last agreed with the cloud about one entity: pushed it, or
  /// applied it. Kept in `sync-state.json`, a cache whose loss costs a re-push.
  ///
  /// `entity` is nil for a deletion. `carry` holds the remote fields this
  /// build did not know, put back on the next push. `held` marks a remote
  /// entity this Mac could not apply; `heldLocal` is what this Mac had then,
  /// so only an edit made here afterwards counts as a change.
  struct Entry: Codable, Equatable, Sendable {
    var at: String
    var from: String
    var entity: JSONValue?
    var carry: [String: JSONValue]
    var held: Bool
    var heldLocal: JSONValue?
  }

  struct Input {
    var kind: Kind
    /// This Mac's entities, by id, as `knownFields` describe them.
    var local: [String: JSONValue]
    /// This kind's envelopes in the cloud, by id, every version included.
    var remote: [String: Envelope]
    var snapshot: [String: Entry]
    var mac: String
    /// When the local side changed: now for a pass after a save, the store
    /// file's modification time for the pass at launch.
    var localAt: String
    var now: Date
    var knownFields: Set<String>
    /// The store's file is gone while the snapshot remembers entities: fill
    /// it from the cloud and push nothing, rather than tombstone everything.
    var localMissing: Bool
    /// Offer held entities again, unchanged here since: a launch pass, when
    /// this build may now ship the catalog id or read the approvals.
    var retryHeld = false
    /// Ids whose key is in the cloud but could not be read: left alone like a
    /// newer envelope, and never taken as a deletion.
    var untouchable: Set<String> = []
  }

  struct Plan: Equatable {
    /// Envelopes to write to the cloud.
    var push: [Envelope] = []
    /// Remote envelopes to bring into the store: upserts and deletions.
    var apply: [Envelope] = []
    /// Remote envelopes that already match this Mac, recorded as agreed
    /// without touching the store.
    var adopt: [Envelope] = []
    /// Ids whose old tombstone leaves the cloud and the snapshot.
    var prune: [String] = []
    /// Ids left alone because a newer Bastion wrote them.
    var newer: [String] = []
    /// Ids where a remote version replaced a different one here.
    var overwrote: [String] = []
  }

  /// One decision per entity. See the table in the phase 2 plan
  /// (`docs/superpowers/plans/2026-11-02-icloud-sync-phase2-config.md`, Task 2).
  static func plan(_ input: Input) -> Plan {
    var plan = Plan()
    let ids = Set(input.local.keys).union(input.remote.keys).union(input.snapshot.keys)
    for id in ids.sorted() {
      let local = input.local[id]
      let remote = input.remote[id]
      let snap = input.snapshot[id]
      if let remote, remote.v > version {
        plan.newer.append(id)
        continue
      }
      if input.untouchable.contains(id) {
        plan.newer.append(id)
        continue
      }
      let theirs = remote.flatMap { $0.deleted ? nil : $0.entity }.map {
        known($0, input.knownFields)
      }
      if input.localMissing {
        if let remote, !remote.deleted, theirs != local { plan.apply.append(remote) }
        continue
      }
      if let remote, remote.deleted, local == nil, let at = date(remote.at),
        at < input.now.addingTimeInterval(-tombstoneLifetime)
      {
        plan.prune.append(id)
        continue
      }
      if let snap, snap.held, input.retryHeld, local == snap.heldLocal, let remote,
        remote.at == snap.at, remote.from == snap.from
      {
        plan.apply.append(remote)
        continue
      }
      let localChanged: Bool
      if let snap, snap.held {
        localChanged = local != nil && local != snap.heldLocal
      } else {
        localChanged = local != snap?.entity
      }
      // A key gone from the cloud while this Mac remembers it live is a
      // deletion there, stamped with what this Mac last knew of it.
      let incoming: Envelope?
      if let remote {
        incoming = snap.map { remote.at == $0.at && remote.from == $0.from } == true ? nil : remote
      } else if let snap, snap.entity != nil {
        incoming = Envelope(
          v: version, kind: input.kind, id: id, at: snap.at, from: snap.from, deleted: true,
          entity: nil, was: nil)
      } else {
        incoming = nil
      }
      let outgoing = Envelope(
        v: version, kind: input.kind, id: id, at: input.localAt, from: input.mac,
        deleted: local == nil, entity: local.map { carryForward($0, snap?.carry ?? [:]) },
        was: nil)

      switch (localChanged, incoming) {
      case (false, nil):
        continue
      case (true, nil):
        plan.push.append(outgoing)
      case (_, let incoming?):
        let same =
          (incoming.deleted ? nil : incoming.entity.map { known($0, input.knownFields) }) == local
        // Older than the version this Mac already agreed: a Mac that wrote
        // its key before it had seen the cloud. The key-value store keeps the
        // last write per key, not the latest version, so the newer one is
        // written back here rather than lost.
        let stale = snap.map { wins(($0.at, $0.from), over: (incoming.at, incoming.from)) } == true
        // No shared history: a deletion this Mac never saw the entity of is
        // not one to apply over what is here. First switch-on is a union.
        let unrelatedDeletion = snap == nil && incoming.deleted && local != nil
        if same {
          plan.adopt.append(incoming)
        } else if stale || unrelatedDeletion {
          plan.push.append(outgoing)
        } else if !localChanged {
          plan.apply.append(incoming)
        } else if wins((input.localAt, input.mac), over: (incoming.at, incoming.from)) {
          plan.push.append(outgoing)
        } else {
          plan.apply.append(incoming)
          if local != nil { plan.overwrote.append(id) }
        }
      }
    }
    return plan
  }

  /// The entry recorded once `remote` is pushed or applied, `local` being the
  /// store's projection after the apply.
  static func agreed(remote: Envelope, local: JSONValue?, knownFields: Set<String>) -> Entry {
    Entry(
      at: remote.at, from: remote.from, entity: local,
      carry: unknown(remote.entity, knownFields), held: false, heldLocal: nil)
  }

  /// The entry recorded when the store could not apply `remote`. The remote
  /// entity stays in the snapshot as it arrived, and is never tombstoned by
  /// this Mac for being missing here.
  static func held(remote: Envelope, local: JSONValue?, knownFields: Set<String>) -> Entry {
    Entry(
      at: remote.at, from: remote.from, entity: remote.entity,
      carry: unknown(remote.entity, knownFields), held: true, heldLocal: local)
  }

  /// `entity` with every field of `carry` it does not set itself.
  static func carryForward(_ entity: JSONValue, _ carry: [String: JSONValue]) -> JSONValue {
    guard case .object(var fields) = entity, !carry.isEmpty else { return entity }
    for (name, value) in carry where fields[name] == nil { fields[name] = value }
    return .object(fields)
  }

  /// Every sync key gone while this Mac remembers live entities: another
  /// Mac's "Remove from iCloud", or an iCloud reset. Not a deletion to apply.
  static func cloudEmptied(syncKeys: Int, liveSnapshot: Int) -> Bool {
    syncKeys == 0 && liveSnapshot > 0
  }

  private static func known(_ entity: JSONValue, _ fields: Set<String>) -> JSONValue {
    guard case .object(let all) = entity, !fields.isEmpty else { return entity }
    return .object(all.filter { fields.contains($0.key) })
  }

  private static func unknown(_ entity: JSONValue?, _ fields: Set<String>) -> [String: JSONValue] {
    guard case .object(let all)? = entity, !fields.isEmpty else { return [:] }
    return all.filter { !fields.contains($0.key) }
  }

  // MARK: - The epoch and pauses

  /// The key holding the epoch: a random value written by the first Mac to
  /// push after iCloud held nothing of Bastion's. "Remove from iCloud" takes
  /// it away, so a Mac that was asleep through a removal, and wakes to keys
  /// other Macs have written since, sees an epoch it does not know and asks,
  /// rather than reading every key it misses as a deletion.
  static let epochKey = "epoch"

  enum EpochStep: Equatable {
    case use(String, write: Bool)
    case pause
  }

  static func epoch(
    cloud: String?, mine: String?, fresh: String, syncKeys: Int, liveSnapshot: Int
  ) -> EpochStep {
    guard let cloud else {
      return cloudEmptied(syncKeys: syncKeys, liveSnapshot: liveSnapshot)
        ? .pause : .use(mine ?? fresh, write: true)
    }
    if mine == cloud || mine == nil || liveSnapshot == 0 { return .use(cloud, write: false) }
    return .pause
  }

  /// Why sync stopped on this Mac. Kept across a relaunch.
  enum Pause: String, Codable, Equatable, Sendable {
    case account, quota, cloudEmptied

    /// What is left after sync is switched off. Off answers a full store or
    /// an emptied one (switching back on looks again), but an account change
    /// has its own question, and switching off and on again must not merge
    /// into another account's configuration without it.
    var afterSwitchingOff: Pause? { self == .account ? .account : nil }
  }
}
