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
}
