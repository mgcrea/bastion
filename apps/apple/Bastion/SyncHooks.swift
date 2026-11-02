import Foundation

/// What a store offers configuration sync: its entities as they travel, and a
/// way to bring remote ones in through its own mutation paths, so wiring, the
/// skills reconcile and the supervisor react as they do to an edit made here.
///
/// Each conformance lives in the store's own file, in its `// MARK: - Sync`
/// section, because it needs the store's private row types.
@MainActor
protocol SyncedStore: AnyObject {
  var syncKinds: [ConfigSync.Kind] { get }
  /// The file whose modification time stamps the launch pass's local
  /// changes, and whose absence means "fill from the cloud" rather than
  /// "everything was deleted".
  func syncFile(_ kind: ConfigSync.Kind) -> URL
  /// The file is there and would not decode: nothing is pushed or applied.
  var syncUnreadable: Bool { get }
  func syncEntities(_ kind: ConfigSync.Kind) -> [String: JSONValue]
  func syncKnownFields(_ kind: ConfigSync.Kind) -> Set<String>
  /// Brings remote envelopes in, deletions included, and returns the ids it
  /// could not apply. Those are held: kept as they arrived and never
  /// tombstoned by this Mac.
  func applySynced(_ kind: ConfigSync.Kind, _ envelopes: [ConfigSync.Envelope]) -> Set<String>
}

/// How a store's `save()` tells sync it changed, without knowing about the
/// engine. `ConfigSyncEngine.start()` sets it; until then it does nothing.
@MainActor
enum SyncHooks {
  static var didSave: (ConfigSync.Kind) -> Void = { _ in }
}
