import Foundation

/// The workspaces on disk, and the split every wire asks for: which profiles
/// stay global, and which folders each scoped one goes to.
///
/// Resolution walks the disk, so it is cached per workspace and recomputed by
/// `rescan`: on load, on every change here, and at the start of every
/// `ClientWiring.rewire`. SwiftUI bodies read the cache and never scan.
@MainActor
@Observable
final class WorkspaceStore {
  static let shared = WorkspaceStore()

  private(set) var workspaces: [Workspace] = []
  /// Set when the file is there and would not decode. Saves refuse while it
  /// is, so the original is never written over with what little survived —
  /// see `StoreFile`.
  private(set) var unreadable: StoreFile.Unreadable?
  /// Workspace name → the project keys its folders resolved to at the last scan.
  private(set) var resolved: [String: Set<String>] = [:]

  enum StoreError: LocalizedError {
    case invalidName(String)
    case duplicateName(String)

    var errorDescription: String? {
      switch self {
      case .invalidName(let name):
        "'\(name)' is not a usable workspace name. Use lowercase letters, digits and dashes."
      case .duplicateName(let name):
        "A workspace named '\(name)' already exists."
      }
    }
  }

  private var fileURL: URL { AppSupport.directory.appendingPathComponent("workspaces.json") }
  private let fs: WorkspaceFileSystem = LocalWorkspaceFileSystem()
  /// Lazy so its callback can capture `self`; lives as long as the store,
  /// which is the app.
  @ObservationIgnored private lazy var watcher = WorkspaceWatcher { [weak self] in
    self?.foldersChanged()
  }

  init() { load() }

  func load() {
    // The fixture, never the file: folder names routinely carry a client's name.
    if DemoSeed.isEnabled {
      workspaces = DemoSeed.workspaces
      rescan()
      return
    }
    let rows: [Workspace]
    switch StoreFile.load([Workspace].self, from: fileURL) {
    case .decoded(let decoded):
      rows = decoded
      unreadable = nil
    case .absent:
      unreadable = nil
      workspaces = []
      rescan()
      return
    case .unreadable(let problem):
      unreadable = problem
      hostLog("workspaces", .error, problem.localizedDescription)
      workspaces = []
      rescan()
      return
    }
    workspaces = rows.filter { row in
      guard Profile.isValidName(row.name) else {
        hostLog("workspaces", .error, "ignoring workspace with unusable name '\(row.name)'")
        return false
      }
      return true
    }
    rescan()
  }

  func save() throws {
    if DemoSeed.isEnabled { return }
    if let unreadable { throw unreadable }
    AppSupport.ensureDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workspaces).write(to: fileURL, options: .atomic)
    // After every write: `.atomic` replaces the file, so permissions set once
    // do not survive the next save.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  func rescan() {
    var out: [String: Set<String>] = [:]
    for workspace in workspaces {
      out[workspace.name] = WorkspaceScope.projectKeys(for: workspace.folders, fs: fs)
    }
    resolved = out
    watchFolders()
  }

  /// Watches the folders as picked, which is where a clone lands. Nothing
  /// under a capture: the fixture's folders are invented.
  private func watchFolders() {
    if DemoSeed.isEnabled { return }
    let folders = Set(workspaces.flatMap(\.folders).map(fs.canonical))
    let repositories = Set(resolved.values.joined()).filter { key in
      let git = (key as NSString).appendingPathComponent(".git")
      return fs.isDirectory(git) || fs.isFile(git)
    }
    watcher.watch(folders, repositoryKeys: repositories)
  }

  /// A clone, a `git init` or a deletion under a workspace's folders. Rewires
  /// only when what the folders reach moved, so a new plain folder with nothing
  /// in it writes nothing.
  private func foldersChanged() {
    let before = resolved
    rescan()
    guard resolved != before else { return }
    hostLog("workspaces", .info, "a workspace's folders changed; rewiring")
    ClientWiring.rewire()
  }

  /// Move profiles between sections of the sidebar, in one save and one
  /// rewire. A nil `from` or `to` is Everywhere; see `WorkspaceScope.moving`.
  ///
  /// A move that changes nothing, such as a drop on the section a row came
  /// from, returns before touching the file, so it never rewires either.
  func moveProfiles(_ ids: [String], from: String?, to: String?) throws {
    try replace(with: WorkspaceScope.moving(ids, from: from, to: to, in: workspaces))
  }

  /// Put one profile in `workspace` alone, or in none for nil, in one save and
  /// one rewire. The profile editor's Scope menu.
  func setScope(_ profileID: String, to workspace: String?) throws {
    try replace(with: WorkspaceScope.scoping(profileID, to: workspace, in: workspaces))
  }

  private func replace(with next: [Workspace]) throws {
    guard next != workspaces else { return }
    let previous = workspaces
    workspaces = next
    do {
      try save()
    } catch {
      // Unlike `upsert`, which leaves the sheet that asked holding the draft:
      // a refused drop has nothing else to show, so the sidebar goes back to
      // what is on disk.
      workspaces = previous
      throw error
    }
    rescan()
    ClientWiring.rewire()
  }

  func resolvedKeys(_ workspace: Workspace) -> Set<String> { resolved[workspace.name] ?? [] }

  /// How many folders a workspace reaches, for its sidebar header. The
  /// fixture's own count under a capture; see `DemoSeed.workspaceReach`.
  func reachCount(named name: String) -> Int {
    DemoSeed.isEnabled ? DemoSeed.workspaceReach : resolved[name]?.count ?? 0
  }

  /// Create, replace, or rename (`previousName`) one workspace, then rewire.
  func upsert(_ workspace: Workspace, replacing previousName: String? = nil) throws {
    guard Profile.isValidName(workspace.name) else { throw StoreError.invalidName(workspace.name) }
    let original = previousName ?? workspace.name
    if workspace.name != original, workspaces.contains(where: { $0.name == workspace.name }) {
      throw StoreError.duplicateName(workspace.name)
    }
    var next = workspace
    next.folders = Array(Set(next.folders)).sorted()
    next.profiles = Array(Set(next.profiles)).sorted()
    next.skills = Array(Set(next.skills)).sorted()
    workspaces.removeAll { $0.name == original }
    workspaces.append(next)
    workspaces.sort { $0.name < $1.name }
    try save()
    rescan()
    ClientWiring.rewire()
  }

  func remove(named name: String) throws {
    workspaces.removeAll { $0.name == name }
    try save()
    rescan()
    ClientWiring.rewire()
  }

  /// Swap a renamed profile's id in every workspace that holds it.
  ///
  /// No rewire, unlike `upsert`: `ProfileStore.rename` rewires once, retiring
  /// the old id, after everything has moved.
  func renameProfile(from oldID: String, to newID: String) throws {
    let next = WorkspaceScope.renamingProfile(workspaces, from: oldID, to: newID)
    guard next != workspaces else { return }
    workspaces = next
    try save()
  }

  /// Workspace name → skill ids, the shape `SkillLinks.desired` takes.
  var skillScopes: [String: [String]] {
    Dictionary(
      uniqueKeysWithValues: workspaces.filter { !$0.skills.isEmpty }.map { ($0.name, $0.skills) })
  }

  /// Merge skill ids into workspaces by name, once, then rewire. Adding a skill
  /// source seeds these from links already in each workspace's repositories.
  func addSkills(_ scopes: [String: Set<String>]) throws {
    guard !scopes.isEmpty else { return }
    for index in workspaces.indices {
      guard let extra = scopes[workspaces[index].name] else { continue }
      workspaces[index].skills = Array(Set(workspaces[index].skills).union(extra)).sorted()
    }
    try save()
    rescan()
    ClientWiring.rewire()
  }

  var scopedProfileIDs: Set<String> { WorkspaceScope.scopedIDs(workspaces) }

  func isScoped(_ profile: Profile) -> Bool { scopedProfileIDs.contains(profile.id) }

  func globalOnly(_ profiles: [Profile]) -> [Profile] {
    let scoped = scopedProfileIDs
    return profiles.filter { !scoped.contains($0.id) }
  }

  func workspaces(containing profile: Profile) -> [Workspace] {
    workspaces.filter { $0.profiles.contains(profile.id) }
  }

  /// Project key → the profiles written there, from the cached resolution.
  func projectAssignments(for profiles: [Profile]) -> [String: [Profile]] {
    let byID = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let resolved = resolved
    let map = WorkspaceScope.assignments(
      workspaces: workspaces, existing: Set(byID.keys),
      resolve: { resolved[$0.name] ?? [] })
    return map.mapValues { ids in ids.compactMap { byID[$0] }.sorted { $0.id < $1.id } }
  }
}
