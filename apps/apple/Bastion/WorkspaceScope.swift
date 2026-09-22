import Foundation

/// A named set of folders and the profiles that should appear only there.
///
/// Folders are stored as picked, never as resolved: a parent folder's
/// repositories change as things are cloned, and the answer is recomputed on
/// every wire. Profile ids are `<name>/<server>`, and an id whose profile no
/// longer exists is kept rather than pruned, the way `ProfileStore` keeps rows
/// for a server that is not installed.
nonisolated struct Workspace: Codable, Equatable, Identifiable {
  var name: String
  var folders: [String]
  var profiles: [String]
  var id: String { name }
}

/// The questions resolution asks of a disk, so `wiring-check` can answer them
/// from a fixture.
nonisolated protocol WorkspaceFileSystem {
  func isDirectory(_ path: String) -> Bool
  func isFile(_ path: String) -> Bool
  func contents(_ path: String) -> String?
  /// Entry names, not paths.
  func children(_ path: String) -> [String]
  /// Symlinks resolved, no trailing slash.
  func canonical(_ path: String) -> String
}

nonisolated struct LocalWorkspaceFileSystem: WorkspaceFileSystem {
  func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
      && directory.boolValue
  }

  func isFile(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
      && !directory.boolValue
  }

  func contents(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
  }

  func children(_ path: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
  }

  /// `realpath(3)`, and deliberately not `URL.resolvingSymlinksInPath()`: that
  /// one strips a leading `/private`, turning `/private/tmp/x` into `/tmp/x`,
  /// while Claude Code keys a project by the physical path its process sees
  /// (`getcwd`), which keeps it. A block filed under the `/tmp` spelling is one
  /// Claude Code never reads.
  func canonical(_ path: String) -> String {
    let expanded = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    guard let resolved = realpath(expanded, nil) else { return expanded }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

/// Where a workspace's profiles get written, in the unit Claude Code reads.
///
/// Measured on 2026-09-22 with `claude mcp add --scope local`: inside a git
/// repository Claude Code files a project block under the repository ROOT and
/// applies it in every subfolder; a worktree, including one under
/// `<repo>/.claude/worktrees/`, resolves to the main repository; outside git
/// the block applies to that exact folder and no subfolder inherits it. So a
/// parent folder such as `~/Projects/rgis` reaches nothing by itself, and has
/// to be expanded into the repositories under it.
nonisolated enum WorkspaceScope {
  /// How far below a picked folder the scan looks for repositories.
  static let scanDepth = 3

  /// The key Claude Code files a session started at `path` under, when `path`
  /// is inside a git repository. `nil` when it is not.
  static func projectKey(containing path: String, fs: WorkspaceFileSystem) -> String? {
    var directory = fs.canonical(path)
    while true {
      if let key = repositoryKey(at: directory, fs: fs) { return key }
      let parent = (directory as NSString).deletingLastPathComponent
      if parent == directory || parent.isEmpty { return nil }
      directory = parent
    }
  }

  /// Every key a set of picked folders reaches.
  ///
  /// A folder inside a repository is that repository. Any other folder is
  /// itself, as an exact key, plus every repository found beneath it.
  static func projectKeys(for folders: [String], fs: WorkspaceFileSystem) -> Set<String> {
    var keys: Set<String> = []
    for folder in folders {
      let path = fs.canonical(folder)
      guard fs.isDirectory(path) else { continue }
      if let key = projectKey(containing: path, fs: fs) {
        keys.insert(key)
        continue
      }
      keys.insert(path)
      scan(path, depth: 1, fs: fs, into: &keys)
    }
    return keys
  }

  /// Which live profiles each key gets. A key two workspaces reach gets both
  /// sets; an id with no live profile behind it gets nothing written.
  static func assignments(
    workspaces: [Workspace], existing: Set<String>, resolve: (Workspace) -> Set<String>
  ) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    for workspace in workspaces {
      let members = Set(workspace.profiles).intersection(existing)
      guard !members.isEmpty else { continue }
      for key in resolve(workspace) {
        out[key, default: []].formUnion(members)
      }
    }
    return out
  }

  /// Every profile id some workspace claims. These leave the global block.
  static func scopedIDs(_ workspaces: [Workspace]) -> Set<String> {
    Set(workspaces.flatMap(\.profiles))
  }

  // MARK: - Private

  /// The key for a directory that holds `.git` itself, or nil.
  private static func repositoryKey(at directory: String, fs: WorkspaceFileSystem) -> String? {
    let git = (directory as NSString).appendingPathComponent(".git")
    if fs.isDirectory(git) { return directory }
    if fs.isFile(git) { return mainRepository(gitFile: git, holder: directory, fs: fs) }
    return nil
  }

  /// A `.git` FILE is a worktree or a submodule. A worktree's `gitdir:` points
  /// at `<main>/.git/worktrees/<name>`, and Claude Code files it under
  /// `<main>`. Anything else, a submodule's `.git/modules/…` included, is keyed
  /// by the folder holding the file.
  private static func mainRepository(
    gitFile: String, holder: String, fs: WorkspaceFileSystem
  ) -> String {
    guard let text = fs.contents(gitFile),
      let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
    else { return holder }
    var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
    if !gitdir.hasPrefix("/") {
      gitdir = (holder as NSString).appendingPathComponent(gitdir)
    }
    gitdir = (gitdir as NSString).standardizingPath
    guard let marker = gitdir.range(of: "/.git/worktrees/", options: .backwards) else {
      return holder
    }
    return String(gitdir[..<marker.lowerBound])
  }

  private static func scan(
    _ directory: String, depth: Int, fs: WorkspaceFileSystem, into keys: inout Set<String>
  ) {
    guard depth <= scanDepth else { return }
    for name in fs.children(directory) where !name.hasPrefix(".") && name != "node_modules" {
      let child = (directory as NSString).appendingPathComponent(name)
      guard fs.isDirectory(child) else { continue }
      if let key = repositoryKey(at: child, fs: fs) {
        keys.insert(key)
        continue
      }
      scan(child, depth: depth + 1, fs: fs, into: &keys)
    }
  }
}
