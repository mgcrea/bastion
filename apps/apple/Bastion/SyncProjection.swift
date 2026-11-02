import Foundation

/// What a synced entity carries, and what stays on this Mac.
///
/// The stores call these to turn their rows into `JSONValue` entities and back,
/// so the rules that decide what leaves the Mac are in one place `make unit`
/// can check. The stores themselves are not compiled there.
nonisolated enum SyncProjection {
  /// The fields of a profile entity. `captureMode` is not one: what a profile
  /// records is a choice about this Mac's log.
  static let profileFields: Set<String> = ["name", "server", "values", "allowWrites"]

  /// A profile as it travels, without its per-Mac values.
  ///
  /// A per-Mac value names code, a launch argument or a path on this Mac (see
  /// `EnvVar.isPerMachine`), so carried to another Mac it would choose what
  /// runs there.
  static func profileEntity(
    name: String, server: String, values: [String: String], allowWrites: Bool,
    perMachine: Set<String>
  ) -> JSONValue {
    .object([
      "name": .string(name),
      "server": .string(server),
      "values": .object(
        values.filter { !perMachine.contains($0.key) }.mapValues { JSONValue.string($0) }),
      "allowWrites": .bool(allowWrites),
    ])
  }

  /// A profile's values once a remote version is applied: the remote synced
  /// values, plus this Mac's own per-Mac ones. A per-Mac name in `remote` is
  /// ignored, whoever put it there.
  static func mergedValues(
    remote: [String: String], local: [String: String], perMachine: Set<String>
  ) -> [String: String] {
    remote.filter { !perMachine.contains($0.key) }
      .merging(local.filter { perMachine.contains($0.key) }) { _, mine in mine }
  }

  /// The per-Mac names of `server`: the installed definition's, else the
  /// catalog's, else none.
  static func perMachine(server: String, installed: BastionServer?) -> Set<String> {
    installed?.perMachineEnv ?? ServerCatalog.byID[server]?.perMachineEnv ?? []
  }

  /// `~/…` for a path under `home`, so a folder synced from one Mac lands in
  /// the same place under another account's home. Anything else is left as
  /// it is.
  static func homeRelative(_ path: String, home: String) -> String {
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  static func expandingHome(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    return path
  }

  /// New id → old id, for profile entities that disappeared and appeared in
  /// one diff and differ in nothing but their name. Only one-to-one matches:
  /// two candidates either way is ambiguous, and an ambiguous rename is
  /// pushed as the removal and addition it looks like.
  static func renames(removed: [String: JSONValue], added: [String: JSONValue]) -> [String: String]
  {
    func nameless(_ entity: JSONValue) -> JSONValue {
      guard case .object(var fields) = entity else { return entity }
      fields["name"] = nil
      return .object(fields)
    }
    let gone = removed.mapValues(nameless)
    let new = added.mapValues(nameless)
    var out: [String: String] = [:]
    for (newID, entity) in new {
      let olds = gone.filter { $0.value == entity }.map(\.key)
      guard olds.count == 1, new.filter({ $0.value == entity }).count == 1 else { continue }
      out[newID] = olds[0]
    }
    return out
  }
}
