import Foundation
import SystemConfiguration

/// Runs configuration sync: reads the cloud, asks `ConfigSync` what to do per
/// entity, writes what this Mac changed and hands the stores what arrived.
///
/// Off by default. Every decision is in `ConfigSync`, which `make unit`
/// checks; this is the plumbing, and `make sync-check` drives it end to end
/// against a file-backed cloud. The design is
/// `docs/superpowers/specs/2026-11-01-icloud-config-sync-design.md`.
@MainActor
@Observable
final class ConfigSyncEngine {
  static let shared = ConfigSyncEngine()
  static let enabledKey = "iCloudSyncEnabled"

  enum Status: Equatable {
    case off
    /// This build cannot reach iCloud: no entitlement, and no file stand-in.
    case unavailable
    case idle(last: Date?)
    case paused(Pause)
  }

  typealias Pause = ConfigSync.Pause

  /// One entity brought in from another Mac, for the status line.
  struct Change: Equatable, Identifiable {
    let kind: ConfigSync.Kind
    let entity: String
    let from: String
    let at: Date
    var id: String { "\(kind.rawValue)/\(entity)/\(at.timeIntervalSince1970)" }
  }

  private(set) var status: Status = .off
  private(set) var recent: [Change] = []
  /// Keys left alone because a newer Bastion wrote them.
  private(set) var newer = 0
  /// Store files that could not be read, whose kinds are neither pushed nor
  /// applied until somebody fixes them.
  private(set) var skipped: [String] = []
  /// Set after the first pass of a switch-on when iCloud's version replaced
  /// some of this Mac's. The sheet that lists them clears it.
  var firstRunOverwrites: [String]?

  var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

  private var cloud: SyncCloud?
  private var observer: NSObjectProtocol?
  private var scheduled: Task<Void, Never>?
  private var state = State()
  /// Which store files existed before anything at launch could save one.
  /// A file deleted by hand is then still "missing" to the launch pass, even
  /// if a reconcile or a rewire has written an empty one since.
  private var existedAtLaunch: [String: Bool] = [:]
  private static let files = [
    "servers.json", "profiles.json", "workspaces.json", "skill-sources.json", "skills.json",
  ]

  /// The order kinds are passed in: a profile's server before the profile,
  /// a workspace's profiles before the workspace, sources before their order
  /// and the choices of their skills.
  private static let kinds: [ConfigSync.Kind] = [
    .server, .profile, .workspace, .skillSource, .order, .skillChoice,
  ]

  /// `sync-state.json`: what this Mac last agreed with the cloud, per kind
  /// and id. A cache: losing it costs a first-run merge, never data.
  private struct State: Codable {
    var snapshot: [String: [String: ConfigSync.Entry]] = [:]
    var lastSync: Date?
    var pause: Pause?
    /// A digest of the iCloud account this snapshot belongs to.
    var account: String?
    /// The cloud's epoch this snapshot was made against. See
    /// `ConfigSync.epochKey`.
    var epoch: String?
    /// Whether the custom servers set up here before sync first ran have
    /// been recorded as allowed here.
    var approvedExisting: Bool?
  }

  private var stateURL: URL { AppSupport.directory.appendingPathComponent("sync-state.json") }

  // MARK: - Starting

  /// First thing at launch, before any store loads or saves.
  func noteFilesAtLaunch() {
    for name in Self.files {
      existedAtLaunch[name] = FileManager.default.fileExists(
        atPath: AppSupport.directory.appendingPathComponent(name).path)
    }
  }

  /// At launch. Decides whether this build can sync at all, and if sync is
  /// on, runs a pass and starts listening.
  func start() {
    guard !DemoSeed.isEnabled else { return }
    guard let cloud = Self.makeCloud() else {
      status = .unavailable
      return
    }
    self.cloud = cloud
    SyncHooks.didSave = { [weak self] _ in self?.schedule() }
    loadState()
    guard isEnabled else {
      // Off answers a full store or an emptied cloud, however it was
      // switched off; never an account change.
      if state.pause != state.pause?.afterSwitchingOff {
        state.pause = state.pause?.afterSwitchingOff
        saveState()
      }
      existedAtLaunch = [:]
      status = .off
      return
    }
    begin(firstRun: state.snapshot.isEmpty)
  }

  private static func makeCloud() -> SyncCloud? {
    #if DEBUG
      let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
      if let path = arguments["syncCloudFile"] as? String, !path.isEmpty {
        return FileCloud(url: URL(fileURLWithPath: path))
      }
    #endif
    guard let task = SecTaskCreateFromSelf(nil),
      SecTaskCopyValueForEntitlement(
        task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil) != nil
    else { return nil }
    return UbiquitousCloud()
  }

  private func begin(firstRun: Bool) {
    guard let cloud else { return }
    if let pause = state.pause {
      status = .paused(pause)
      return
    }
    if cloud is UbiquitousCloud, accountChanged() {
      pause(.account)
      return
    }
    // The first time sync runs on this Mac, however it was switched on:
    // what is already here was set up here, so it is allowed here, and a copy
    // of it edited on another Mac does not then wait for a yes. Not a server
    // already waiting.
    if state.approvedExisting != true {
      ServerStore.shared.approveCurrentCustomServers()
      state.approvedExisting = true
      saveState()
    }
    observe()
    cloud.synchronize()
    pass(launch: true, firstRun: firstRun)
  }

  private func observe() {
    guard observer == nil, cloud is UbiquitousCloud else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: NSUbiquitousKeyValueStore.default, queue: .main
    ) { [weak self] note in
      let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
      MainActor.assumeIsolated { self?.cloudChanged(reason: reason) }
    }
  }

  private func cloudChanged(reason: Int?) {
    guard isEnabled, state.pause == nil else { return }
    switch reason {
    case NSUbiquitousKeyValueStoreQuotaViolationChange: pause(.quota)
    case NSUbiquitousKeyValueStoreAccountChange: pause(.account)
    default: pass(launch: false, firstRun: false)
    }
  }

  /// A pass a second after the last save, so a burst of saves (a workspace
  /// drag) is one push.
  private func schedule() {
    guard isEnabled, cloud != nil, state.pause == nil else { return }
    scheduled?.cancel()
    scheduled = Task { [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      self?.pass(launch: false, firstRun: false)
    }
  }

  // MARK: - The switch and the questions

  func setEnabled(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: Self.enabledKey)
    guard on else {
      stop()
      state.pause = state.pause?.afterSwitchingOff
      saveState()
      status = cloud == nil ? .unavailable : .off
      hostLog("sync", .info, "iCloud sync switched off; this Mac keeps its configuration")
      return
    }
    guard cloud != nil else { return }
    hostLog("sync", .info, "iCloud sync switched on")
    begin(firstRun: state.snapshot.isEmpty)
  }

  /// After the iCloud account changed: merge with the new account's
  /// configuration as a first switch-on would, or stop.
  func resolveAccountChange(merge: Bool) {
    guard merge else {
      state.pause = nil
      saveState()
      setEnabled(false)
      return
    }
    state = State()
    state.account = Self.accountDigest()
    saveState()
    begin(firstRun: true)
  }

  /// After every key left iCloud: put this Mac's configuration back, or stop.
  func resolveCloudEmptied(pushBack: Bool) {
    guard pushBack else {
      state.pause = nil
      saveState()
      setEnabled(false)
      return
    }
    state.snapshot = [:]
    state.epoch = nil
    state.pause = nil
    saveState()
    begin(firstRun: false)
  }

  /// After iCloud's storage for Bastion was full: look again.
  func retryAfterQuota() {
    guard state.pause == .quota else { return }
    state.pause = nil
    saveState()
    begin(firstRun: false)
  }

  /// Removes every key Bastion keeps in iCloud and switches sync off here.
  /// Other Macs still syncing pause and ask rather than delete anything.
  func removeFromICloud() {
    if let cloud {
      for key in cloud.all().keys where ConfigSync.isSyncKey(key) { cloud.remove(key) }
      cloud.remove(ConfigSync.epochKey)
      cloud.synchronize()
    }
    state = State()
    saveState()
    hostLog("sync", .info, "removed Bastion's configuration from iCloud")
    setEnabled(false)
  }

  private func stop() {
    scheduled?.cancel()
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  private func pause(_ reason: Pause) {
    state.pause = reason
    saveState()
    status = .paused(reason)
    hostLog("sync", .info, "iCloud sync paused: \(reason.rawValue)")
  }

  // MARK: - A pass

  private func pass(launch: Bool, firstRun: Bool) {
    guard let cloud, isEnabled, state.pause == nil else { return }
    let now = Date()
    let mac = Self.macName()

    var remote: [ConfigSync.Kind: [String: ConfigSync.Envelope]] = [:]
    var unreadableKeys = Set<String>()
    let everything = cloud.all()
    let raw = everything.filter { ConfigSync.isSyncKey($0.key) }
    for (key, text) in raw {
      guard
        let envelope = try? JSONDecoder().decode(ConfigSync.Envelope.self, from: Data(text.utf8))
      else {
        unreadableKeys.insert(key)
        continue
      }
      // A value under a key its own id does not hash to is not one this
      // Mac can attribute, and is left alone.
      guard ConfigSync.key(envelope.kind, id: envelope.id) == key else { continue }
      remote[envelope.kind, default: [:]][envelope.id] = envelope
    }
    let live = state.snapshot.values.reduce(0) { $0 + $1.values.filter { $0.entity != nil }.count }
    switch ConfigSync.epoch(
      cloud: everything[ConfigSync.epochKey], mine: state.epoch, fresh: UUID().uuidString,
      syncKeys: raw.count, liveSnapshot: live)
    {
    case .pause:
      pause(.cloudEmptied)
      return
    case .use(let epoch, let write):
      if write { cloud.set(epoch, for: ConfigSync.epochKey) }
      state.epoch = epoch
    }

    var newerCount = unreadableKeys.count
    var overwrites: [String] = []
    var skippedFiles: [String] = []
    for kind in Self.kinds {
      let store = Self.store(for: kind)
      let file = store.syncFile(kind)
      if store.syncUnreadable {
        if !skippedFiles.contains(file.lastPathComponent) {
          skippedFiles.append(file.lastPathComponent)
        }
        continue
      }
      var snapshot = state.snapshot[kind.rawValue] ?? [:]
      let known = store.syncKnownFields(kind)
      let local = store.syncEntities(kind)
      let modified =
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
      let existed =
        (launch ? existedAtLaunch[file.lastPathComponent] : nil) ?? (modified != nil)
      var input = ConfigSync.Input(
        kind: kind, local: local, remote: remote[kind] ?? [:], snapshot: snapshot, mac: mac,
        localAt: ConfigSync.timestamp(launch ? modified ?? now : now), now: now,
        knownFields: known,
        localMissing: !existed && snapshot.values.contains { $0.entity != nil })
      input.retryHeld = launch
      // An id whose key is there but unreadable is left alone, never taken
      // for a deletion because it is missing from what decoded.
      input.untouchable = Set(
        snapshot.keys.filter { unreadableKeys.contains(ConfigSync.key(kind, id: $0)) })
      let plan = ConfigSync.plan(input)

      var pushes = plan.push
      if kind == .profile { Self.markRenames(&pushes, snapshot: snapshot) }
      for envelope in pushes {
        guard let text = try? String(decoding: JSONEncoder().encode(envelope), as: UTF8.self)
        else { continue }
        cloud.set(text, for: ConfigSync.key(kind, id: envelope.id))
        snapshot[envelope.id] = ConfigSync.agreed(
          remote: envelope, local: local[envelope.id], knownFields: known)
      }
      for id in plan.prune {
        cloud.remove(ConfigSync.key(kind, id: id))
        snapshot[id] = nil
      }
      for envelope in plan.adopt {
        snapshot[envelope.id] = ConfigSync.agreed(
          remote: envelope, local: local[envelope.id], knownFields: known)
      }
      if !plan.apply.isEmpty {
        let held = store.applySynced(kind, plan.apply)
        let after = store.syncEntities(kind)
        for envelope in plan.apply {
          if held.contains(envelope.id) {
            snapshot[envelope.id] = ConfigSync.held(
              remote: envelope, local: after[envelope.id], knownFields: known)
          } else {
            snapshot[envelope.id] = ConfigSync.agreed(
              remote: envelope, local: after[envelope.id], knownFields: known)
            recent.insert(
              Change(
                kind: kind, entity: envelope.id, from: envelope.from,
                at: ConfigSync.date(envelope.at) ?? now), at: 0)
          }
        }
        hostLog(
          "sync", .info,
          "brought in \(plan.apply.count - held.count) \(kind.rawValue) change(s)"
            + (held.isEmpty ? "" : ", kept \(held.count) aside"))
      }
      if !pushes.isEmpty {
        hostLog("sync", .info, "sent \(pushes.count) \(kind.rawValue) change(s)")
      }
      overwrites += plan.overwrote.map { "\(kind.rawValue) \($0)" }
      newerCount += plan.newer.count
      state.snapshot[kind.rawValue] = snapshot
    }
    // Once: a later switch-on looks at the files as they are then.
    if launch { existedAtLaunch = [:] }
    recent = Array(recent.prefix(5))
    newer = newerCount
    skipped = skippedFiles
    state.lastSync = now
    if state.account == nil { state.account = Self.accountDigest() }
    saveState()
    status = .idle(last: now)
    if firstRun, !overwrites.isEmpty { firstRunOverwrites = overwrites }
  }

  /// `was` on the envelope of a profile that replaces one tombstoned in the
  /// same pass and differs from it only by name, so other Macs rename it
  /// rather than remove one and add the other.
  private static func markRenames(
    _ pushes: inout [ConfigSync.Envelope], snapshot: [String: ConfigSync.Entry]
  ) {
    var removed: [String: JSONValue] = [:]
    var added: [String: JSONValue] = [:]
    for envelope in pushes {
      if envelope.deleted, let entity = snapshot[envelope.id]?.entity {
        removed[envelope.id] = entity
      } else if !envelope.deleted, snapshot[envelope.id]?.entity == nil,
        let entity = envelope.entity
      {
        added[envelope.id] = entity
      }
    }
    let renames = SyncProjection.renames(removed: removed, added: added)
    let renamedTo = Dictionary(renames.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    for index in pushes.indices {
      if let old = renames[pushes[index].id] { pushes[index].was = old }
      // Both halves say so, because the other Mac may see either first.
      if let new = renamedTo[pushes[index].id] { pushes[index].to = new }
    }
  }

  private static func store(for kind: ConfigSync.Kind) -> SyncedStore {
    switch kind {
    case .server: ServerStore.shared
    case .profile: ProfileStore.shared
    case .workspace: WorkspaceStore.shared
    case .skillSource, .order, .skillChoice: SkillStore.shared
    }
  }

  // MARK: - State and identity

  private func loadState() {
    guard let data = try? Data(contentsOf: stateURL),
      let decoded = try? JSONDecoder().decode(State.self, from: data)
    else { return }
    state = decoded
  }

  private func saveState() {
    AppSupport.ensureDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(state) else { return }
    try? data.write(to: stateURL, options: .atomic)
    // Profile values that are not secret are in it, as in `profiles.json`.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }

  /// Whether the iCloud account is not the one the snapshot was made with.
  /// Unknowable without a token, in which case it is never claimed.
  private func accountChanged() -> Bool {
    guard let recorded = state.account, let current = Self.accountDigest() else { return false }
    return recorded != current
  }

  private static func accountDigest() -> String? {
    guard let token = FileManager.default.ubiquityIdentityToken,
      let data = try? NSKeyedArchiver.archivedData(
        withRootObject: token, requiringSecureCoding: true)
    else { return nil }
    return ConfigSync.key(.server, id: data.base64EncodedString())
  }

  /// The name people gave this Mac, as the status line shows where a change
  /// came from. Not `Host.current()`, which can wait on DNS.
  static func macName() -> String {
    (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "a Mac"
  }
}
