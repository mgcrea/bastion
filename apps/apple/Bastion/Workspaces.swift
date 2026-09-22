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

  init() { load() }

  func load() {
    // The fixture, never the file: folder names routinely carry a client's name.
    if DemoSeed.isEnabled {
      workspaces = DemoSeed.workspaces
      rescan()
      return
    }
    guard let data = try? Data(contentsOf: fileURL),
      let rows = try? JSONDecoder().decode([Workspace].self, from: data)
    else {
      workspaces = []
      resolved = [:]
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
  }

  func resolvedKeys(_ workspace: Workspace) -> Set<String> { resolved[workspace.name] ?? [] }

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
