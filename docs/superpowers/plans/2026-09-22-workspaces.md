# Workspaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a profile be scoped to named workspaces (sets of folders), so Bastion writes it only into those folders' Claude Code project blocks and leaves it out of every client's global block.

**Architecture:** Two pure layers compiled into `make wiring-check` (folder → project-key resolution in a new `WorkspaceScope.swift`, and project-block reconciliation added to `ClientWiringMerge`), one app-side store (`WorkspaceStore`, persisted to `workspaces.json`), then the existing `ClientWiring.wire`/`unwire`/`isWired`/`status` paths learn to split global from scoped. UI (a Settings pane, a Scope line in the profile editor, a card in the client pane) and three built-in MCP tools sit on top.

**Tech Stack:** Swift 6 / SwiftUI, macOS app with no XCTest target. Pure logic is tested by `scripts/wiring-check.swift`, compiled with `swiftc` by `make wiring-check`. The app builds with `make app`.

**Spec:** `docs/superpowers/specs/2026-09-22-workspaces-design.md`. Read it first. The measured Claude Code behaviour it records is the basis for Task 1.

## Global Constraints

- A profile listed in any workspace is scoped. It is omitted from every client's global block and written only into Claude Code project blocks (`projects[<key>].mcpServers` in each Claude Code row's `.claude.json`).
- A project key is a git repository root (worktrees resolve to the main repository), or the exact folder when no git repository contains it.
- `isOurs` is the only ledger. No record of which folders Bastion wrote to is kept anywhere.
- Every other key in `~/.claude.json`, every other project block, and every foreign entry inside a touched block must come back deep-equal.
- `workspaces.json` lives in `AppSupport.directory`, is written `.atomic` with sorted keys, and is chmod 0600 after every write. This matches `ProfileStore.save`.
- A demo or capture run (`DemoSeed.isEnabled`) never reads or writes the real `workspaces.json`.
- Workspace names follow `Profile.isValidName` (`^[a-z0-9][a-z0-9-]*$`, 1 to 64 characters).
- The folder scan descends at most 3 levels below a picked folder, skips names starting with `.` and `node_modules`, and does not descend into a repository once it finds one.
- Out of scope: enforcement tokens, in-repository config files (`.mcp.json`, `.cursor/…`, `.vscode/…`, `.codex/…`), and file watching.
- This Mac shadows BSD tools with GNU ones, so anything committed (Makefile lines) must stay portable.

## File map

| File                                         | Change | Responsibility                                                                                                |
| -------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------- |
| `apps/apple/Bastion/WorkspaceScope.swift`    | create | Pure: `Workspace` model, filesystem protocol, folder → project-key resolution, workspace → folder assignments |
| `apps/apple/Bastion/ClientWiringMerge.swift` | modify | Pure: `reconciledProjects`, `projectCollisions`, `hasOurProjectEntries`                                       |
| `scripts/wiring-check.swift`                 | modify | Checks for both pure layers, and the real-file check                                                          |
| `Makefile`                                   | modify | Compile `WorkspaceScope.swift` into `wiring-check`                                                            |
| `apps/apple/Bastion/Workspaces.swift`        | create | `WorkspaceStore`: persistence, resolution cache, and the scoped/global split the wiring asks for              |
| `apps/apple/Bastion/ClientWiring.swift`      | modify | `Client.supportsProjectScope`; the split in `wireOnce`, `unwireOnce`, `isWired`, `status`, `rewire`           |
| `apps/apple/Bastion/ServerStore.swift`       | modify | `setEnabled` rewires                                                                                          |
| `apps/apple/Bastion/DemoSeed.swift`          | modify | Fixture workspace                                                                                             |
| `apps/apple/Bastion/ClientDetail.swift`      | modify | Global rows exclude scoped profiles; a Workspaces card; Unwire also counts project entries                    |
| `apps/apple/Bastion/WorkspacesPane.swift`    | create | Settings → Workspaces                                                                                         |
| `apps/apple/Bastion/SettingsWindow.swift`    | modify | Register the pane                                                                                             |
| `apps/apple/Bastion/ProfileEditor.swift`     | modify | Scope line                                                                                                    |
| `apps/apple/Bastion/BuiltinTools.swift`      | modify | `list_workspaces`, `upsert_workspace`, `remove_workspace`                                                     |
| `docs/clients.md`, `CHANGELOG.md`            | modify | Documentation                                                                                                 |

The Xcode project uses synchronized groups, so new files under `apps/apple/Bastion/` are picked up with no `project.pbxproj` edit. Check this in Task 3 Step 4. If `make app` doesn't see the new file, stop and report it rather than hand-editing the pbxproj.

---

### Task 1: Folder resolution (pure)

**Files:**

- Create: `apps/apple/Bastion/WorkspaceScope.swift`
- Modify: `Makefile` (the `wiring-check` target, currently around line 570)
- Test: `scripts/wiring-check.swift`

**Interfaces:**

- Produces:
  - `struct Workspace: Codable, Equatable, Identifiable { var name: String; var folders: [String]; var profiles: [String]; var id: String }`
  - `protocol WorkspaceFileSystem { isDirectory, isFile, contents, children, canonical }`
  - `struct LocalWorkspaceFileSystem: WorkspaceFileSystem`
  - `WorkspaceScope.projectKey(containing: String, fs: WorkspaceFileSystem) -> String?`
  - `WorkspaceScope.projectKeys(for: [String], fs: WorkspaceFileSystem) -> Set<String>`
  - `WorkspaceScope.assignments(workspaces: [Workspace], existing: Set<String>, resolve: (Workspace) -> Set<String>) -> [String: Set<String>]`
  - `WorkspaceScope.scopedIDs(_: [Workspace]) -> Set<String>`

- [ ] **Step 1: Add the file to the wiring-check build**

In `Makefile`, the `wiring-check` recipe compiles three files. Add the new one:

```make
wiring-check: ## Assert the config merge leaves other people's files alone
	@mkdir -p apps/apple/.build
	@swiftc -O -o apps/apple/.build/wiring-check \
		apps/apple/Bastion/ClientWiringMerge.swift \
		apps/apple/Bastion/ClientWiringTOML.swift \
		apps/apple/Bastion/WorkspaceScope.swift \
		scripts/wiring-check.swift
	@apps/apple/.build/wiring-check
```

- [ ] **Step 2: Write the failing checks**

Add a fake filesystem and the checks to `scripts/wiring-check.swift`, inside `struct WiringCheck`. Put them after `tomlStaleWriteIsRefused()`:

```swift
  // MARK: - Workspaces: folder resolution

  /// A filesystem made of a set of directories and a map of files, so
  /// resolution can be driven through every shape without touching the disk.
  struct FakeFS: WorkspaceFileSystem {
    var directories: Set<String>
    var files: [String: String] = [:]

    func isDirectory(_ path: String) -> Bool { directories.contains(path) }
    func isFile(_ path: String) -> Bool { files[path] != nil }
    func contents(_ path: String) -> String? { files[path] }
    func children(_ path: String) -> [String] {
      let prefix = path == "/" ? "/" : path + "/"
      let names = (directories.union(files.keys)).compactMap { candidate -> String? in
        guard candidate.hasPrefix(prefix) else { return nil }
        let rest = candidate.dropFirst(prefix.count)
        guard !rest.isEmpty, !rest.contains("/") else { return nil }
        return String(rest)
      }
      return names.sorted()
    }
    func canonical(_ path: String) -> String {
      path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
  }

  /// Every ancestor of every path, so a fixture only has to name the leaves.
  static func tree(_ leaves: [String], files: [String: String] = [:]) -> FakeFS {
    var directories: Set<String> = ["/"]
    for leaf in leaves + files.keys.map({ ($0 as NSString).deletingLastPathComponent }) {
      var path = leaf
      while path != "/" && !path.isEmpty {
        directories.insert(path)
        path = (path as NSString).deletingLastPathComponent
      }
    }
    return FakeFS(directories: directories, files: files)
  }

  static func workspaceResolution() {
    print("\nWorkspaces: folder resolution")
    let fs = tree(
      [
        "/w/rgis/api/.git", "/w/rgis/api/src/deep",
        "/w/rgis/infra/.git",
        "/w/rgis/clients/acme/web/.git",
        "/w/rgis/a/b/c/d/too-deep/.git",
        "/w/rgis/.hidden/secret/.git",
        "/w/rgis/node_modules/pkg/.git",
        "/w/rgis/api/vendor/nested/.git",
        "/w/rgis/api/.claude/worktrees/feat",
        "/w/rgis/api/.git/worktrees/feat",
        "/w/rgis/api/.git/modules/lib",
        "/w/rgis/api/lib",
        "/w/wt/feature",
        "/w/plain/notes",
      ],
      files: [
        "/w/rgis/api/.claude/worktrees/feat/.git": "gitdir: /w/rgis/api/.git/worktrees/feat\n",
        "/w/wt/feature/.git": "gitdir: /w/rgis/infra/.git/worktrees/feature\n",
        "/w/rgis/api/lib/.git": "gitdir: ../.git/modules/lib\n",
      ])

    check(
      "a repository root is its own key",
      WorkspaceScope.projectKey(containing: "/w/rgis/api", fs: fs) == "/w/rgis/api")
    check(
      "a subfolder resolves to the repository root",
      WorkspaceScope.projectKey(containing: "/w/rgis/api/src/deep", fs: fs) == "/w/rgis/api")
    check(
      "a worktree under .claude/worktrees resolves to the main repository",
      WorkspaceScope.projectKey(containing: "/w/rgis/api/.claude/worktrees/feat", fs: fs)
        == "/w/rgis/api")
    check(
      "a worktree elsewhere resolves to its main repository",
      WorkspaceScope.projectKey(containing: "/w/wt/feature", fs: fs) == "/w/rgis/infra")
    check(
      "a submodule is keyed by its own folder",
      WorkspaceScope.projectKey(containing: "/w/rgis/api/lib", fs: fs) == "/w/rgis/api/lib")
    check(
      "a folder in no repository has no containing key",
      WorkspaceScope.projectKey(containing: "/w/plain/notes", fs: fs) == nil)
    check(
      "a trailing slash is ignored",
      WorkspaceScope.projectKey(containing: "/w/rgis/api/", fs: fs) == "/w/rgis/api")

    let parent = WorkspaceScope.projectKeys(for: ["/w/rgis"], fs: fs)
    check("a parent folder is itself a key", parent.contains("/w/rgis"))
    check(
      "and every repository under it within three levels",
      parent.isSuperset(of: ["/w/rgis/api", "/w/rgis/infra", "/w/rgis/clients/acme/web"]))
    check(
      "but nothing deeper than three levels",
      !parent.contains("/w/rgis/a/b/c/d/too-deep"))
    check(
      "hidden folders and node_modules are skipped",
      !parent.contains("/w/rgis/.hidden/secret") && !parent.contains("/w/rgis/node_modules/pkg"))
    check(
      "the scan does not descend into a repository",
      !parent.contains("/w/rgis/api/vendor/nested"))
    check("exactly those keys", parent.count == 4)

    check(
      "a folder inside a repository yields only that repository",
      WorkspaceScope.projectKeys(for: ["/w/rgis/api/src"], fs: fs) == ["/w/rgis/api"])
    check(
      "a folder that does not exist yields nothing",
      WorkspaceScope.projectKeys(for: ["/w/gone"], fs: fs).isEmpty)
    check(
      "a folder with no repositories is an exact key",
      WorkspaceScope.projectKeys(for: ["/w/plain"], fs: fs) == ["/w/plain"])
  }

  static func workspaceAssignments() {
    print("\nWorkspaces: assignments")
    let workspaces = [
      Workspace(name: "rgis", folders: ["A"], profiles: ["rgis/ovh", "prod/npm"]),
      Workspace(name: "mgcrea", folders: ["B"], profiles: ["mgcrea/x", "prod/npm", "gone/x"]),
      Workspace(name: "empty", folders: ["C"], profiles: []),
    ]
    let resolve: (Workspace) -> Set<String> = { workspace in
      Set(workspace.folders.flatMap { folder -> [String] in
        switch folder {
        case "A": ["/r/api", "/r/infra"]
        case "B": ["/m/site", "/r/api"]
        default: ["/c"]
        }
      })
    }
    let existing: Set<String> = ["rgis/ovh", "prod/npm", "mgcrea/x", "home/unifi"]
    let map = WorkspaceScope.assignments(
      workspaces: workspaces, existing: existing, resolve: resolve)

    check("a key only in one workspace gets that workspace's profiles",
      map["/r/infra"] == ["rgis/ovh", "prod/npm"])
    check("a key in two workspaces gets the union",
      map["/r/api"] == ["rgis/ovh", "prod/npm", "mgcrea/x"])
    check("a profile id that no longer exists is ignored",
      map.values.allSatisfy { !$0.contains("gone/x") })
    check("a workspace with no live profiles writes no key", map["/c"] == nil)
    check("scoped ids are every id listed, live or not",
      WorkspaceScope.scopedIDs(workspaces) == ["rgis/ovh", "prod/npm", "mgcrea/x", "gone/x"])
  }
```

Call both from `main()`, after `tomlStaleWriteIsRefused()`:

```swift
    workspaceResolution()
    workspaceAssignments()
```

- [ ] **Step 3: Run it to verify it fails**

Run: `make wiring-check`
Expected: the compile fails with `cannot find type 'WorkspaceFileSystem' in scope` (and similar for `WorkspaceScope` and `Workspace`), or with "no such file" for `WorkspaceScope.swift`.

- [ ] **Step 4: Write the implementation**

Create `apps/apple/Bastion/WorkspaceScope.swift`:

```swift
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

/// The four questions resolution asks of a disk, so `wiring-check` can answer
/// them from a fixture.
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

  func canonical(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      .resolvingSymlinksInPath().standardizedFileURL.path
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
```

- [ ] **Step 5: Run it to verify it passes**

Run: `make wiring-check`
Expected: every line reads `ok`, and the last line is `N/N passed`.

Check the depth rule: `/w/rgis/a/b/c/d/too-deep` is four levels below `/w/rgis` (`a`=1, `b`=2, `c`=3, `d`=4), so a scan limited to depth 3 never lists `d`'s children. `/w/rgis/clients/acme/web` is at depth 3, so it's found.

- [ ] **Step 6: Commit**

```bash
git add apps/apple/Bastion/WorkspaceScope.swift scripts/wiring-check.swift Makefile
git commit -m "feat(workspaces): resolve folders into Claude Code project keys"
```

---

### Task 2: Reconciling project blocks (pure)

**Files:**

- Modify: `apps/apple/Bastion/ClientWiringMerge.swift`: add three functions at the end of the enum, after `mergedIntoProject` (around line 624)
- Test: `scripts/wiring-check.swift`

**Interfaces:**

- Consumes: `ClientWiringMerge.isOurs`, `collisions(servers:keys:)`, `projectScopeServers(in:folder:)` (all existing).
- Produces:
  - `ClientWiringMerge.reconciledProjects(_ root: [String: Any], desired: [String: [String: [String: Any]]]) -> [String: Any]`
  - `ClientWiringMerge.projectCollisions(in root: [String: Any], keys: [String: [String]]) -> [String]`, which returns `"<folder>: <key>"` strings
  - `ClientWiringMerge.hasOurProjectEntries(_ root: [String: Any]) -> Bool`

- [ ] **Step 1: Write the failing checks**

Add to `scripts/wiring-check.swift`. The `httpReach` and `entry` helpers already exist near the top of the struct.

```swift
  // MARK: - Workspaces: project blocks

  static func projectReconcile() {
    print("\nWorkspaces: reconciling project blocks")
    let ovh = entry(httpReach("ovh", profile: "rgis"))
    let npm = entry(httpReach("npm", profile: "prod"))
    let foreign: [String: Any] = ["command": "npx", "args": ["some-server"]]
    let root: [String: Any] = [
      "numStartups": 12,
      "mcpServers": ["rgis-ovh": ovh],
      "projects": [
        "/r/api": [
          "allowedTools": ["Bash"],
          "mcpServers": ["theirs": foreign, "prod-npm": npm],
        ],
        "/r/old": ["mcpServers": ["rgis-ovh": ovh]],
        "/untouched": ["hasTrustDialogAccepted": true, "mcpServers": ["x": foreign]],
      ],
    ]

    let after = ClientWiringMerge.reconciledProjects(
      root, desired: ["/r/api": ["rgis-ovh": ovh], "/r/new": ["rgis-ovh": ovh]])
    let projects = after["projects"] as? [String: Any] ?? [:]
    func servers(_ folder: String) -> [String: Any]? {
      (projects[folder] as? [String: Any])?["mcpServers"] as? [String: Any]
    }

    check("a desired entry is written", servers("/r/api")?["rgis-ovh"] != nil)
    check("an entry of ours no longer desired there is removed", servers("/r/api")?["prod-npm"] == nil)
    check("a foreign entry in a touched block survives",
      deepEqual(servers("/r/api")?["theirs"], foreign))
    check("other fields of a touched block survive",
      deepEqual((projects["/r/api"] as? [String: Any])?["allowedTools"], ["Bash"]))
    check("a block holding only stale entries of ours is emptied, not deleted",
      servers("/r/old").map { $0.isEmpty } == true)
    check("a new folder gets a bare mcpServers block",
      (projects["/r/new"] as? [String: Any]).map { Array($0.keys) } == ["mcpServers"])
    check("a block with nothing of ours is byte-identical",
      deepEqual(projects["/untouched"], (root["projects"] as? [String: Any])?["/untouched"]))
    check("the global block is not this function's business",
      deepEqual(after["mcpServers"], root["mcpServers"]))
    check("top-level keys survive", deepEqual(after["numStartups"], 12))

    let stripped = ClientWiringMerge.reconciledProjects(after, desired: [:])
    check("an empty desired set removes every entry of ours",
      !ClientWiringMerge.hasOurProjectEntries(stripped))
    check("and leaves foreign ones",
      ((stripped["projects"] as? [String: Any])?["/r/api"] as? [String: Any])
        .flatMap { $0["mcpServers"] as? [String: Any] }?["theirs"] != nil)

    let bare: [String: Any] = ["mcpServers": [:]]
    check("a config with no projects and nothing desired gains no projects key",
      ClientWiringMerge.reconciledProjects(bare, desired: [:])["projects"] == nil)

    check("hasOurProjectEntries sees an entry of ours", ClientWiringMerge.hasOurProjectEntries(root))
    check("and not a foreign one",
      !ClientWiringMerge.hasOurProjectEntries(["projects": ["/x": ["mcpServers": ["x": foreign]]]]))

    let taken = ClientWiringMerge.projectCollisions(
      in: root, keys: ["/r/api": ["theirs", "rgis-ovh"], "/nowhere": ["theirs"]])
    check("a foreign key under a desired key is a collision, named with its folder",
      taken == ["/r/api: theirs"])
  }
```

Also add a real-file check. In `realFileSurvives(_:)`, append this at the end of the function body. It's read-only like the rest of that function.

```swift
    if before["projects"] != nil {
      let folder = (before["projects"] as? [String: Any])?.keys.sorted().first ?? "/tmp/none"
      let reconciled = ClientWiringMerge.reconciledProjects(
        before, desired: [folder: ["bastion-probe": entry(httpReach("probe"))]])
      let beforeProjects = before["projects"] as? [String: Any] ?? [:]
      let afterProjects = reconciled["projects"] as? [String: Any] ?? [:]
      var otherBlocksIntact = true
      var fieldsIntact = true
      for (key, value) in beforeProjects {
        let hasOurs =
          ((value as? [String: Any])?["mcpServers"] as? [String: Any])?.values
          .contains(where: ClientWiringMerge.isOurs) == true
        if key != folder && !hasOurs && !deepEqual(value, afterProjects[key]) {
          otherBlocksIntact = false
        }
      }
      for (field, value) in beforeProjects[folder] as? [String: Any] ?? [:] where field != "mcpServers" {
        if !deepEqual(value, (afterProjects[folder] as? [String: Any])?[field]) { fieldsIntact = false }
      }
      check("reconciling one project block leaves the other \(beforeProjects.count - 1) alone",
        otherBlocksIntact)
      check("and every other field of the block it wrote", fieldsIntact)
    }
```

Call the new check from `main()` after `workspaceAssignments()`:

```swift
    projectReconcile()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make wiring-check`
Expected: the compile fails with `type 'ClientWiringMerge' has no member 'reconciledProjects'`.

- [ ] **Step 3: Write the implementation**

Append inside `enum ClientWiringMerge`, after `mergedIntoProject`:

```swift
  /// Make Bastion's entries in every project block exactly `desired`.
  ///
  /// `desired` maps a project key to the entries that belong there. Every block
  /// that is either desired or already holds an entry `isOurs` claims is
  /// visited. Desired entries are written, entries of ours that are not
  /// desired there are removed, and nothing else in the block changes.
  /// Every other block is left alone.
  ///
  /// No ledger of past writes, on purpose. `isOurs` is the ledger here, as it is
  /// for the global block, so removing a folder, a profile or a whole workspace
  /// cleans up by itself. A block this empties keeps its `mcpServers: {}`
  /// rather than being deleted, because Claude Code may have filed other
  /// fields under that folder.
  static func reconciledProjects(
    _ root: [String: Any], desired: [String: [String: [String: Any]]]
  ) -> [String: Any] {
    var projects = root["projects"] as? [String: Any] ?? [:]
    var folders = Set(desired.keys)
    for (folder, block) in projects {
      let servers = (block as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
      if servers.values.contains(where: { isOurs($0) }) { folders.insert(folder) }
    }
    guard !folders.isEmpty else { return root }

    var root = root
    for folder in folders {
      var project = projects[folder] as? [String: Any] ?? [:]
      var servers = project["mcpServers"] as? [String: Any] ?? [:]
      let wanted = desired[folder] ?? [:]
      for (key, entry) in servers where isOurs(entry) && wanted[key] == nil {
        servers.removeValue(forKey: key)
      }
      for (key, entry) in wanted { servers[key] = entry }
      project["mcpServers"] = servers
      projects[folder] = project
    }
    root["projects"] = projects
    return root
  }

  /// `collisions`, asked of every project block Bastion is about to write.
  /// Each answer names its folder, because the same key can be foreign in one
  /// repository and free in the next.
  static func projectCollisions(
    in root: [String: Any], keys: [String: [String]]
  ) -> [String] {
    keys.keys.sorted().flatMap { folder -> [String] in
      let servers = projectScopeServers(in: root, folder: folder) ?? [:]
      return collisions(servers: servers, keys: keys[folder] ?? []).map { "\(folder): \($0)" }
    }
  }

  /// Whether any project block holds an entry `isOurs` claims.
  static func hasOurProjectEntries(_ root: [String: Any]) -> Bool {
    guard let projects = root["projects"] as? [String: Any] else { return false }
    return projects.values.contains { block in
      ((block as? [String: Any])?["mcpServers"] as? [String: Any])?.values
        .contains(where: { isOurs($0) }) == true
    }
  }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `make wiring-check`
Expected: all `ok`, then `N/N passed`.

Run: `make wiring-check-real`
Expected: all `ok`, including the two new lines for `~/.claude.json`. This is read-only and doesn't write your config.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Bastion/ClientWiringMerge.swift scripts/wiring-check.swift
git commit -m "feat(workspaces): reconcile Bastion's entries across Claude Code project blocks"
```

---

### Task 3: WorkspaceStore

**Files:**

- Create: `apps/apple/Bastion/Workspaces.swift`
- Modify: `apps/apple/Bastion/DemoSeed.swift` (add `workspaces` next to `static var profiles`, around line 406)
- Modify: `apps/apple/Bastion/ServerStore.swift:617-630` (`setEnabled`)

**Interfaces:**

- Consumes: everything Task 1 produces; `AppSupport.directory`, `AppSupport.ensureDirectory()`, `DemoSeed.isEnabled`, `hostLog`, `ClientWiring.rewire()`, `Profile`.
- Produces (all `@MainActor`):
  - `WorkspaceStore.shared`
  - `var workspaces: [Workspace]` (read-only)
  - `func resolvedKeys(_ workspace: Workspace) -> Set<String>`
  - `func rescan()`
  - `func upsert(_ workspace: Workspace, replacing previousName: String? = nil) throws`
  - `func remove(named name: String) throws`
  - `var scopedProfileIDs: Set<String>`
  - `func isScoped(_ profile: Profile) -> Bool`
  - `func globalOnly(_ profiles: [Profile]) -> [Profile]`
  - `func workspaces(containing profile: Profile) -> [Workspace]`
  - `func projectAssignments(for profiles: [Profile]) -> [String: [Profile]]`
  - `enum WorkspaceStore.StoreError: LocalizedError { case invalidName(String), duplicateName(String) }`
  - `DemoSeed.workspaces: [Workspace]`

- [ ] **Step 1: Create the store**

`apps/apple/Bastion/Workspaces.swift`:

```swift
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
    let map = WorkspaceScope.assignments(
      workspaces: workspaces, existing: Set(byID.keys),
      resolve: { [resolved] workspace in resolved[workspace.name] ?? [] })
    return map.mapValues { ids in ids.compactMap { byID[$0] }.sorted { $0.id < $1.id } }
  }
}
```

`projectAssignments` resolves through the cache by workspace name, so no SwiftUI body ever scans the disk.

- [ ] **Step 2: Add the demo fixture**

In `DemoSeed.swift`, directly after the closing brace of `static var profiles: [Profile]`:

```swift
  /// One workspace scoping the Keycloak profile, so the Workspaces pane and
  /// the client pane's card have something to draw. The folders are invented
  /// and do not exist, so a capture resolves them to nothing and scans nothing
  /// real.
  nonisolated static var workspaces: [Workspace] {
    [Workspace(name: "acme", folders: ["/Users/demo/Projects/acme"], profiles: ["acme/keycloak"])]
  }
```

- [ ] **Step 3: Rewire when a server is switched on or off**

`setEnabled` doesn't rewire today. Project blocks are reconciled against the profiles on enabled servers, so without this a scoped profile would stay out of its folders after its server is switched back on. In `ServerStore.setEnabled`, after `try save()` and before the `hostLog` line:

```swift
    // Project blocks are written from the switched-on set, so they follow the
    // switch. The global block is additive and is not changed by a disable.
    ClientWiring.rewire()
```

- [ ] **Step 4: Build**

Run: `make app`
Expected: `** BUILD SUCCEEDED **`, and the new files are compiled (see the file map note on synchronized groups). `ClientWiring.rewire` doesn't call `rescan` yet; that's added in Task 4.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Bastion/Workspaces.swift apps/apple/Bastion/DemoSeed.swift apps/apple/Bastion/ServerStore.swift
git commit -m "feat(workspaces): persist workspaces and split scoped from global profiles"
```

---

### Task 4: The wiring path

**Files:**

- Modify: `apps/apple/Bastion/ClientWiring.swift`: `Client` (around line 70), `status(of:profiles:)` (around 556), `wireOnce` (615–686), `rewire` (733), `isWired` (around 820), `unwireOnce` (832)

**Interfaces:**

- Consumes: `WorkspaceStore.shared.{scopedProfileIDs, globalOnly, projectAssignments, rescan}`, `ClientWiringMerge.{reconciledProjects, projectCollisions, hasOurProjectEntries}`.
- Produces: `ClientWiring.Client.supportsProjectScope: Bool`, and `ClientWiring.projectEntries(for client: Client) -> [String: [Profile: String]]` (project key → profile → entry key), used by Task 5.

- [ ] **Step 1: Mark the clients whose project blocks Bastion writes**

In `struct Client`, next to `var family`:

```swift
    /// Whether Bastion writes this client's per-folder project blocks. Claude
    /// Code's alone: the other clients keep project scope in files inside each
    /// repository, which v1 does not write (they would carry a token into a
    /// file that is routinely committed).
    var supportsProjectScope: Bool { family == "claude-code" && format == .json }
```

- [ ] **Step 2: Add the project-entry planner**

Next to `static func keys(for:)`:

```swift
  /// Project key → the scoped profiles written there and the key each one
  /// gets. Empty for a client whose project blocks Bastion does not write.
  ///
  /// Always computed from every profile on a switched-on server, whatever
  /// subset a caller of `wire` passed. The reconcile that consumes this
  /// removes what is not in it, so a partial answer would unwire the rest.
  static func projectEntries(for client: Client) -> [String: [Profile: String]] {
    guard client.supportsProjectScope else { return [:] }
    let assigned = WorkspaceStore.shared.projectAssignments(
      for: ProfileStore.shared.onEnabledServers)
    let keys = keys(for: Array(Set(assigned.values.flatMap { $0 })))
    return assigned.mapValues { profiles in
      Dictionary(profiles.compactMap { profile in keys[profile].map { (profile, $0) } },
        uniquingKeysWith: { first, _ in first })
    }
  }
```

- [ ] **Step 3: Split in `wireOnce`**

Make these changes in order.

(a) Replace the first line of `wireOnce`, `let keys = keys(for: profiles)`, with:

```swift
    // Scoped profiles leave the global block of EVERY client. Retiring every
    // scoped id, not only the ones passed in, is what removes an entry written
    // before its profile was scoped.
    let scoped = WorkspaceStore.shared.scopedProfileIDs
    let profiles = profiles.filter { !scoped.contains($0.id) }
    let retiring = retiring.union(scoped)
    let planned = projectEntries(for: client)
    let keys = keys(for: profiles)
```

(b) The `duplicates` guard stays as it is. Global keys and project keys come from the same `keys(for:)` rule, so they can't clash in a way that guard doesn't already cover.

(c) In the `if !force { … }` block, after the existing `guard taken.isEmpty else { … }`:

```swift
      if client.supportsProjectScope {
        let projectTaken = ClientWiringMerge.projectCollisions(
          in: root, keys: planned.mapValues { Array($0.values) })
        guard projectTaken.isEmpty else {
          throw WireError.collision(client: client.displayName, keys: projectTaken)
        }
      }
```

(d) Replace:

```swift
    let merged = ClientWiringMerge.merged(
      into: root, rootKey: client.rootKey, entries: entries, retiring: retiring)
```

with:

```swift
    var merged = ClientWiringMerge.merged(
      into: root, rootKey: client.rootKey, entries: entries, retiring: retiring)
    var projectCount = 0
    if client.supportsProjectScope {
      let desired = planned.mapValues { byProfile in
        Dictionary(byProfile.map { profile, key in
          (key, entry(for: profile, transport: client.transport, token: token, format: client.format))
        }, uniquingKeysWith: { first, _ in first })
      }
      projectCount = desired.values.reduce(0) { $0 + $1.count }
      merged = ClientWiringMerge.reconciledProjects(merged, desired: desired)
    }
```

(e) In the closing `hostLog`, include the project count:

```swift
    hostLog(
      "wiring", .info,
      "\(client.displayName): wrote \(entries.count) entr\(entries.count == 1 ? "y" : "ies")"
        + (projectCount > 0 ? " and \(projectCount) across \(planned.count) project folder\(planned.count == 1 ? "" : "s")" : "")
        + (backup.map { " (backup at \($0.lastPathComponent))" } ?? ""))
```

The shadowing of `profiles` and `retiring` in (a) is deliberate. The rest of the function then reads the global-only set with no further edits. If the compiler rejects shadowing a parameter with a `let`, rename to `globalProfiles` and `allRetiring` and update the two later uses: the `for profile in profiles` loop and the `merged(... retiring:)` call.

- [ ] **Step 4: `rewire` rescans first**

At the top of `rewire`, after `guard autoWires else { return }`:

```swift
    // New clones under a workspace's parent folder are found here.
    WorkspaceStore.shared.rescan()
```

- [ ] **Step 5: `isWired` counts project blocks**

Replace the body of `isWired`:

```swift
    guard hasConfig(client), let config = try? read(client) else { return false }
    if config.servers.values.contains(where: { ClientWiringMerge.isOurs($0) }) { return true }
    // A config whose every profile is scoped holds nothing of ours globally,
    // and still has to be kept current.
    return client.supportsProjectScope
      && config.root.map(ClientWiringMerge.hasOurProjectEntries) == true
```

- [ ] **Step 6: `unwireOnce` strips project blocks**

In the `.json` case, replace:

```swift
      let stripped = ClientWiringMerge.unmerged(from: root, rootKey: client.rootKey)
```

with:

```swift
      var stripped = ClientWiringMerge.unmerged(from: root, rootKey: client.rootKey)
      if client.supportsProjectScope {
        stripped = ClientWiringMerge.reconciledProjects(stripped, desired: [:])
      }
```

- [ ] **Step 7: `status` audits the global block only**

At the top of `status(of:profiles:)`:

```swift
    // Scoped profiles are not expected in the global block, so they must not be
    // counted missing there. Their folders are reported by the client pane.
    let profiles = WorkspaceStore.shared.globalOnly(profiles)
```

- [ ] **Step 8: Build and check**

Run: `make app && make wiring-check`
Expected: `** BUILD SUCCEEDED **` and all checks pass.

- [ ] **Step 9: Verify against a throwaway Claude Code config directory**

A Debug build shares client configs with the installed Release app, so exercise this on a disposable Claude Code row, not on `~/.claude.json`:

```bash
mkdir -p ~/.claude-wsprobe
echo '{"mcpServers":{}}' > ~/.claude-wsprobe/.claude.json
mkdir -p /tmp/wsprobe/repo && git -C /tmp/wsprobe/repo init -q && mkdir -p /tmp/wsprobe/repo/sub
make run
```

Then:

1. In the app, open the **Claude Code (wsprobe)** client row and press Configure. Every global profile is written.
2. Create `~/Library/Application Support/io.mgcrea.bastion.debug/workspaces.json` with `[{"name":"probe","folders":["/private/tmp/wsprobe"],"profiles":["<one of your profile ids>"]}]`, then run `make run` again and press Configure on the same row. (The UI arrives in Task 6.)
3. Run `python3 -c "import json,os;d=json.load(open(os.path.expanduser('~/.claude-wsprobe/.claude.json')));print(list(d['mcpServers']));print({k:list(v['mcpServers']) for k,v in d.get('projects',{}).items()})"`.
   Expected: the scoped key has gone from `mcpServers`, and it appears under both `/private/tmp/wsprobe` and `/private/tmp/wsprobe/repo`.
4. Run `cd /tmp/wsprobe/repo/sub && CLAUDE_CONFIG_DIR=~/.claude-wsprobe claude mcp list`.
   Expected: the scoped entry is listed. From `cd /tmp && CLAUDE_CONFIG_DIR=~/.claude-wsprobe claude mcp list` it isn't.
5. Press Unwire. Expected: no entry of ours in any project block.

Clean up: `rm -rf ~/.claude-wsprobe /tmp/wsprobe`, then remove the debug `workspaces.json`.

If step 3 shows `/tmp/wsprobe` instead of `/private/tmp/wsprobe`, Claude Code's key and `canonical` disagree about symlinks. Stop and report it: the canonicalisation in `LocalWorkspaceFileSystem` would need to match what Claude Code does.

- [ ] **Step 10: Commit**

```bash
git add apps/apple/Bastion/ClientWiring.swift
git commit -m "feat(workspaces): write scoped profiles into Claude Code project blocks only"
```

---

### Task 5: Client pane

**Files:**

- Modify: `apps/apple/Bastion/ClientDetail.swift`: `profiles` and `writable` (lines 43–46), `Snapshot` (76–84), `read()` (around 100–200), `body` (the card list), plus a new `workspacesCard`

**Interfaces:**

- Consumes: `ClientWiring.projectEntries(for:)`, `ClientWiring.reach(for:transport:)`, `ClientWiringMerge.state(of:key:reach:)`, `ClientWiringMerge.projectScopeServers(in:folder:)`, `ClientWiringMerge.hasOurProjectEntries`.

- [ ] **Step 1: Global rows exclude scoped profiles**

```swift
  private var profiles: [Profile] { WorkspaceStore.shared.globalOnly(ProfileStore.shared.profiles) }

  /// The profiles Configure writes to the global block, and the only ones the
  /// audit is taken over. Scoped profiles are reported by the Workspaces card.
  private var writable: [Profile] {
    WorkspaceStore.shared.globalOnly(ProfileStore.shared.onEnabledServers)
  }
```

`wire(force:)` passes `writable` to `ClientWiring.wire`. That's still correct, because `wireOnce` plans project blocks from the stores itself.

- [ ] **Step 2: Snapshot carries the scoped folders**

Add to `Snapshot`:

```swift
    /// Each project folder Bastion writes for this client, and the state of
    /// each entry there. Empty for clients without project scope.
    var scoped: [(folder: String, rows: [(key: String, state: ClientWiringMerge.EntryState)])] = []
```

In `unread(_:)`, the `Snapshot(...)` initialiser doesn't need changing because the new field has a default.

In the final `return Snapshot(...)` of `read()`, add the argument and widen `hasOurEntries`:

```swift
      hasOurEntries: servers.values.contains { ClientWiringMerge.isOurs($0) }
        || (client.supportsProjectScope
          && config.root.map(ClientWiringMerge.hasOurProjectEntries) == true),
      scoped: scopedFolders(config.root ?? [:]))
```

Add the helper next to `read()`. `projectEntries` is computed once, and never inside the per-folder loop:

```swift
  private func scopedFolders(
    _ root: [String: Any]
  ) -> [(folder: String, rows: [(key: String, state: ClientWiringMerge.EntryState)])] {
    let plan = ClientWiring.projectEntries(for: client)
    return plan.keys.sorted().map { folder in
      let servers = ClientWiringMerge.projectScopeServers(in: root, folder: folder) ?? [:]
      let rows = (plan[folder] ?? [:]).sorted { $0.value < $1.value }.map { profile, key in
        (key: key, state: ClientWiringMerge.state(
          of: servers, key: key,
          reach: ClientWiring.reach(for: profile, transport: client.transport)))
      }
      return (folder, rows)
    }
  }
```

- [ ] **Step 3: The card**

In `body`, after `if !snapshot.others.isEmpty { othersCard(snapshot) }`:

```swift
        if !snapshot.scoped.isEmpty { workspacesCard(snapshot) }
```

Next to `projectsCard`:

```swift
  private func workspacesCard(_ snapshot: Snapshot) -> some View {
    let written = snapshot.scoped.reduce(0) { $0 + $1.rows.filter { $0.state == .matches }.count }
    let total = snapshot.scoped.reduce(0) { $0 + $1.rows.count }
    return Card(title: "Workspaces (\(written) of \(total) written)") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "Profiles in a workspace are written only into these folders, and apply in every "
            + "subfolder and worktree of a repository. They are left out of the list above."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(snapshot.scoped, id: \.folder) { group in
              VStack(alignment: .leading, spacing: 4) {
                Text(abbreviate(group.folder))
                  .font(.caption).bold().foregroundStyle(.secondary)
                  .lineLimit(1).truncationMode(.head)
                  .textSelection(.enabled)
                ForEach(group.rows, id: \.key) { row in
                  HStack {
                    Text(row.key).font(.callout.monospaced())
                    Spacer()
                    Text(row.state == .matches ? "written" : "not written")
                      .font(.caption)
                      .foregroundStyle(row.state == .matches ? .secondary : Color.orange)
                  }
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        Button("Edit Workspaces…") { SettingsWindowController.show(.workspaces) }
          .controlSize(.small)
      }
    }
  }
```

`SettingsWindowController.show(_:)` is the existing deep-link helper (`SettingsWindow.swift`, around line 130; `ClientDetail` already calls it for `.general`). The `.workspaces` case is added in Task 6, so if you build this task on its own, temporarily leave that `Button` out and add it in Task 6.

- [ ] **Step 4: Build**

Run: `make app`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Bastion/ClientDetail.swift
git commit -m "feat(workspaces): show scoped folders in the client pane"
```

---

### Task 6: Settings pane and profile Scope line

**Files:**

- Create: `apps/apple/Bastion/WorkspacesPane.swift`
- Modify: `apps/apple/Bastion/SettingsWindow.swift`: the `SettingsPane` enum (around lines 34–71) and the `SettingsView` switch (around 142)
- Modify: `apps/apple/Bastion/ProfileEditor.swift`: add a Section after the Activity section (around line 176)

**Interfaces:**

- Consumes: `WorkspaceStore.shared` (Task 3), `ProfileStore.shared.profiles`.

- [ ] **Step 1: Register the pane**

In `enum SettingsPane`, add `case workspaces` after `case audit`, and extend each switch:

- title: `case .workspaces: "Workspaces"`
- symbol: `case .workspaces: "folder.badge.gearshape"`
- group: change `case .general, .audit: .configuration` to `case .general, .audit, .workspaces: .configuration`

In `SettingsView`'s switch: `case .workspaces: WorkspacesPane()`.

- [ ] **Step 2: The pane**

`apps/apple/Bastion/WorkspacesPane.swift`:

```swift
import AppKit
import SwiftUI

/// Settings → Workspaces. Every edit saves and rewires at once, the same as a
/// profile save, so there is no Apply button to forget.
struct WorkspacesPane: View {
  @State private var newName = ""
  @State private var error: String?

  private var store: WorkspaceStore { WorkspaceStore.shared }

  var body: some View {
    Form {
      Section {
        Text(
          "A profile in a workspace is written only into the folders listed here, and left out "
            + "of every other client. A folder inside a git repository means the whole "
            + "repository, its subfolders and its worktrees. A parent folder means every "
            + "repository found up to three levels below it. Only Claude Code supports this "
            + "today, and other clients do not get a profile that is in a workspace."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          TextField("New workspace name", text: $newName)
          Button("Add") { add() }
            .disabled(newName.isEmpty)
          Button("Rescan") {
            store.rescan()
            ClientWiring.rewire()
          }
        }
        if let error {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }

      ForEach(store.workspaces) { workspace in
        Section {
          ForEach(workspace.folders, id: \.self) { folder in
            HStack {
              Text((folder as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.head)
              Spacer()
              Button(role: .destructive) {
                update(workspace) { $0.folders.removeAll { $0 == folder } }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
            }
          }
          Text(summary(workspace)).font(.caption).foregroundStyle(.secondary)
          Button("Add Folder…") { pickFolders(for: workspace) }

          ForEach(ProfileStore.shared.profiles.sorted { $0.id < $1.id }) { profile in
            Toggle(profile.id, isOn: Binding(
              get: { workspace.profiles.contains(profile.id) },
              set: { on in
                update(workspace) { draft in
                  if on { draft.profiles.append(profile.id) }
                  else { draft.profiles.removeAll { $0 == profile.id } }
                }
              }))
          }

          Button("Delete Workspace", role: .destructive) {
            perform { try store.remove(named: workspace.name) }
          }
        } header: {
          Text(workspace.name)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func summary(_ workspace: Workspace) -> String {
    let count = store.resolvedKeys(workspace).count
    return count == 0
      ? "Resolves to no folder yet."
      : "Written into \(count) folder\(count == 1 ? "" : "s")."
  }

  private func add() {
    perform {
      try store.upsert(Workspace(name: newName, folders: [], profiles: []))
      newName = ""
    }
  }

  private func update(_ workspace: Workspace, _ change: (inout Workspace) -> Void) {
    var draft = workspace
    change(&draft)
    perform { try store.upsert(draft) }
  }

  private func pickFolders(for workspace: Workspace) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add"
    guard panel.runModal() == .OK else { return }
    update(workspace) { $0.folders += panel.urls.map(\.path) }
  }

  private func perform(_ body: () throws -> Void) {
    do {
      try body()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}
```

Profile toggles are listed flat, sorted by id (`rgis/ovh` and so on), so profiles of the same account sit together. Don't group them by server: your profile names carry the account, which is what a workspace is about.

- [ ] **Step 3: Scope line in the profile editor**

In `ProfileEditor.body`, after the Activity `Section { … } header: { Text("Activity") }` and before `writesSection`:

```swift
        if let profile = subject.profile {
          Section {
            let names = WorkspaceStore.shared.workspaces(containing: profile).map(\.name)
            LabeledContent("Scope", value: names.isEmpty ? "Everywhere" : names.joined(separator: ", "))
            Button("Edit Workspaces…") { SettingsWindowController.show(.workspaces) }
              .controlSize(.small)
          } header: {
            Text("Workspaces")
          }
        }
```

Only existing profiles get this section: a profile being created has no id yet. The pre-tick from the spec (a new profile whose name matches a workspace) is covered by Step 4.

- [ ] **Step 4: Pre-tick on create**

In `ProfileStore.upsert(_:)` (`Profiles.swift`, around line 250), inside the `else` branch (new profile), **before** `ClientWiring.rewire()`:

```swift
      // A profile named after a workspace joins it, so `rgis/ovh` lands where
      // the other `rgis` profiles already are. Only on creation; removing it
      // from the workspace afterwards sticks.
      if var workspace = WorkspaceStore.shared.workspaces.first(where: { $0.name == profile.name }) {
        workspace.profiles.append(profile.id)
        try? WorkspaceStore.shared.upsert(workspace)
      }
```

`WorkspaceStore.upsert` rewires as well, so the second rewire that follows is a no-op write that `ClientWiringMerge.write` refuses. That duplication is acceptable.

- [ ] **Step 5: Build and click through**

Run: `make app && make run`
Check in the running app:

1. Settings shows **Workspaces** under General and Activity.
2. Add a workspace `probe`. Add a folder containing two git repos. The summary reads "Written into 3 folders".
3. Tick a profile. Open that profile's editor: Scope reads `probe`.
4. On the throwaway `wsprobe` Claude Code row from Task 4 Step 9, the Workspaces card lists the folders as `written` after Configure.
5. Delete the workspace. The card disappears, and after Configure the profile is back in the global list.

- [ ] **Step 6: Commit**

```bash
git add apps/apple/Bastion/WorkspacesPane.swift apps/apple/Bastion/SettingsWindow.swift apps/apple/Bastion/ProfileEditor.swift apps/apple/Bastion/Profiles.swift apps/apple/Bastion/ClientDetail.swift
git commit -m "feat(workspaces): Settings pane, profile scope line, join by name on create"
```

---

### Task 7: Built-in MCP tools

**Files:**

- Modify: `apps/apple/Bastion/BuiltinTools.swift`: declarations (next to `list_profiles`, around line 173, and `remove_profile`, around 380), the `invoke` switch (around 460), implementations (next to `listProfiles`, around 765)

**Interfaces:**

- Consumes: `WorkspaceStore.shared`, `ToolError.badArgument(name:expected:)`, the `string(_:_:)` argument helper, `schema(_:_:)`, `Declaration(...)` (all existing in this file).

- [ ] **Step 1: Declarations**

After the `list_profiles` declaration:

```swift
    Declaration(
      "list_workspaces", title: "List workspaces",
      "Every workspace: the folders it was given, the Claude Code project folders those resolve "
        + "to right now, and the profiles scoped to it. A profile in any workspace is written "
        + "only into those folders and is left out of every client's global list."),
```

After the `remove_profile` declaration:

```swift
    Declaration(
      "upsert_workspace", title: "Create or update a workspace",
      "Create a workspace or replace one by name, then rewire every configured client. A folder "
        + "inside a git repository means the whole repository. Any other folder means itself "
        + "plus every repository up to three levels below it. Profiles listed here leave every "
        + "client's global list.",
      properties: [
        "name": schema("string", "Kebab-case, e.g. 'rgis'."),
        "folders": [
          "type": "array", "items": ["type": "string"],
          "description": "Absolute folder paths. Replaces the current list.",
        ],
        "profiles": [
          "type": "array", "items": ["type": "string"],
          "description": "'<profile>/<server>' ids, as list_profiles shows them. Replaces the current list.",
        ],
      ],
      required: ["name", "folders", "profiles"], mutates: true),

    Declaration(
      "remove_workspace", title: "Remove a workspace",
      "Delete a workspace and rewire. Its profiles become global again.",
      properties: ["name": schema("string", "The workspace name.")],
      required: ["name"], mutates: true),
```

- [ ] **Step 2: Dispatch**

In `invoke`'s switch, with the reads:

```swift
    case "list_workspaces": return listWorkspaces()
```

with the writes:

```swift
    case "upsert_workspace": return try upsertWorkspace(arguments)
    case "remove_workspace": return try removeWorkspace(arguments)
```

- [ ] **Step 3: Implementations**

Next to `listProfiles`:

```swift
  private static func listWorkspaces() -> Any {
    let store = WorkspaceStore.shared
    return store.workspaces.map { workspace -> [String: Any] in
      [
        "name": workspace.name,
        "folders": workspace.folders,
        "resolves_to": store.resolvedKeys(workspace).sorted(),
        "profiles": workspace.profiles,
      ]
    }
  }

  private static func upsertWorkspace(_ arguments: [String: Any]) throws -> Any {
    let name = try string(arguments, "name")
    guard let folders = arguments["folders"] as? [String] else {
      throw ToolError.badArgument(name: "folders", expected: "an array of absolute paths")
    }
    guard folders.allSatisfy({ $0.hasPrefix("/") || $0.hasPrefix("~") }) else {
      throw ToolError.badArgument(name: "folders", expected: "absolute paths, or paths under ~")
    }
    guard let profiles = arguments["profiles"] as? [String] else {
      throw ToolError.badArgument(name: "profiles", expected: "an array of '<profile>/<server>' ids")
    }
    let known = Set(ProfileStore.shared.profiles.map(\.id))
    let unknown = profiles.filter { !known.contains($0) }
    guard unknown.isEmpty else {
      throw ToolError.badArgument(
        name: "profiles",
        expected: "ids list_profiles shows; not found: \(unknown.joined(separator: ", "))")
    }
    let expanded = folders.map { ($0 as NSString).expandingTildeInPath }
    try WorkspaceStore.shared.upsert(Workspace(name: name, folders: expanded, profiles: profiles))
    let saved = WorkspaceStore.shared.workspaces.first { $0.name == name }
    return [
      "name": name,
      "resolves_to": saved.map { WorkspaceStore.shared.resolvedKeys($0).sorted() } ?? [],
      "profiles": profiles,
      "note": "Clients Bastion already configures were rewired. Restart Claude Code sessions to pick it up.",
    ]
  }

  private static func removeWorkspace(_ arguments: [String: Any]) throws -> Any {
    let name = try string(arguments, "name")
    guard WorkspaceStore.shared.workspaces.contains(where: { $0.name == name }) else {
      throw ToolError.badArgument(name: "name", expected: "a workspace list_workspaces shows")
    }
    try WorkspaceStore.shared.remove(named: name)
    return ["removed": name]
  }
```

Check that `ToolError.badArgument` and `string(_:_:)` have exactly these signatures. `upsertProfile` (around line 1348) uses both. Adjust if they differ.

- [ ] **Step 4: Build and exercise**

Run: `make app && make builtin`
Expected: `** BUILD SUCCEEDED **` and `make builtin` passes. It asserts the write gate on every `mutates: true` tool, and that no tool returns a secret.

- [ ] **Step 5: Commit**

```bash
git add apps/apple/Bastion/BuiltinTools.swift
git commit -m "feat(workspaces): list, upsert and remove workspaces over Bastion's own MCP server"
```

---

### Task 8: Documentation

**Files:**

- Modify: `docs/clients.md`: a new `## Workspaces` section before the section on the one TOML client
- Modify: `CHANGELOG.md`: an `## [Unreleased]` heading above `## [1.22.0]` if none exists, with an `### Added` entry

- [ ] **Step 1: `docs/clients.md`**

```markdown
## Workspaces

A workspace is a named set of folders plus the profiles that should appear only
there. A profile in any workspace leaves every client's global list, and is
written into Claude Code's per-folder project blocks
(`projects[<folder>].mcpServers` in `.claude.json`) for the folders its
workspaces resolve to.

Claude Code files a project block under the **git repository root** and applies
it in every subfolder and worktree. Outside git it applies to that exact folder
only (measured 2026-09-22). So a folder is resolved before it is written: one
inside a repository becomes that repository, and any other folder becomes itself
plus every repository up to three levels below it. Hidden folders and
`node_modules` are skipped. Resolution runs again on every rewire, so a
repository cloned later is picked up on the next one.

Nothing records where Bastion wrote. `isOurs` claims the entries, as it does in
the global block, so a folder or profile taken out of a workspace is cleaned up
on the next write, and Unwire strips every project block too.

Only Claude Code has project blocks Bastion writes. The other clients keep
per-project servers in files inside each repository, which would put a gateway
token in a file that is routinely committed. Those clients simply do not get
scoped profiles.

This is about what a session **sees**, not what it may reach. Every token a
client holds sits in the same file, which the agent can read, and any token
reaches every profile (see above). A per-workspace token would protect nothing
until that changes.
```

- [ ] **Step 2: `CHANGELOG.md`**

```markdown
## [Unreleased]

### Added

- **Workspaces scope profiles to folders.** A workspace is a set of folders and the profiles that
  belong there. A profile in one is left out of every client's global list and written into Claude
  Code's per-folder project blocks instead, so a session in an `rgis` repository sees the `rgis`
  servers and nothing from another account. A folder inside a git repository means the whole
  repository, its subfolders and its worktrees, which is how Claude Code itself files project
  blocks. A parent folder is expanded to every repository below it. Managed in Settings →
  Workspaces, or with the new `list_workspaces`, `upsert_workspace` and `remove_workspace` tools.
  Claude Code only for now.
```

If an `[Unreleased]` section already exists, add the bullet under its `### Added` instead. Don't run `make changelog` here. It regenerates the in-app notes from released headings, and that belongs to the release (see the cut-a-release skill).

- [ ] **Step 3: Final verification**

Run: `make wiring-check && make wiring-check-real && make app && make builtin`
Expected: all pass.

- [ ] **Step 4: Commit**

```bash
git add docs/clients.md CHANGELOG.md
git commit -m "docs(workspaces): describe folder-scoped profiles"
```
