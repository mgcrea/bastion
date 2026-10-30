# Workspaces in the Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage workspaces from the main window's sidebar, as Cadence manages recording groups: a section per workspace above Everywhere, drag and drop between them, New workspace in the footer, a workspace page. Also make "a folder and everything below it" true by adding the plain folders on the way to a repository and by watching for new clones.

**Architecture:** Pure, Foundation-only logic (section builder, moves, collapsed set, selection mapping, the resolution changes, the FSEvents filter) lives in files `make wiring-check` compiles and asserts. The SwiftUI side reads that logic and saves through `WorkspaceStore`, which rewires as it does today. `workspaces.json` is unchanged.

**Tech Stack:** Swift 6, SwiftUI on macOS 26 (`Section(isExpanded:)`, `.draggable`, `.dropDestination`, CoreTransferable), FSEvents, `swiftc`-compiled check scripts (no XCTest target).

**Spec:** `docs/superpowers/specs/2026-10-30-workspace-sidebar-design.md`. Background: `docs/superpowers/specs/2026-09-22-workspaces-design.md`.

**Reference implementation for the sidebar UI:** Cadence, `~/Projects/apps/cadence/apps/apple/`: `Cadence/Views/LibrarySidebar.swift` (sections, collapse, footer), `CadenceShared/Views/Library/GroupViews.swift` (drag source, drop target, `SectionDropHighlight`, `DropHereRow`), `Cadence/Views/SidebarTableFeedback.swift`. Copy the mechanism, not the copy or the Pro gate.

## Global Constraints

- Work in the worktree `.claude/worktrees/workspace-sidebar` on `feat/workspace-sidebar`. Never switch branches in the main checkout. Commit per task. Never push.
- New Swift files go in `apps/apple/Bastion/` (synchronized folder: no pbxproj edit needed).
- Pure files are `nonisolated`, import only Foundation, and are added to the `wiring-check` `swiftc` list in the `Makefile`. The Makefile must stay portable (BSD tools).
- After every task: `xcrun swift-format format --in-place <touched .swift files>`, then `make format-swift-check` and `make wiring-check` must pass; tasks touching app code also run `make app` and it must print `BUILD SUCCEEDED` with no new warnings.
- `workspaces.json` format does not change.
- Copy, verbatim: section header "Everywhere"; no-workspace header "Servers"; placeholder "Drag servers here"; reach caption "Claude Code · N folders" / "Claude Code · 1 folder"; empty reach "No folders found" (orange); footer "New workspace" with `folder.badge.plus`; delete title `Delete the workspace “<name>”?` and message "Its profiles go back to every client."; page caption "Only Claude Code sessions started in these folders get these profiles. Other clients do not get them."; new-profile caption "A profile named after a workspace joins it."
- Drag type: `io.mgcrea.bastion.profiles`, exported in `apps/apple/Bastion-Info.plist`, conforming to `public.data` only.
- Collapsed set: `@AppStorage("sidebar.collapsedServerSections")`, sorted comma-separated keys `workspace:<name>` / `everywhere`.
- `MainPane` raw values: `workspace:<name>`, `scoped-server:<workspace>/<server>`.
- FSEvents latency: 2 seconds. Nothing watches under `DemoSeed.isEnabled`.
- Comments follow the file's existing density and voice: say why, not what.

## Review Focus

1. **A profile in two workspaces** (made by `upsert_workspace`) dragged out of one stays in the other, and shows in both sections. Pinned by `movingFromOneOfTwoWorkspacesLeavesTheOther` (Task 3).
2. **A deep link to `.server(id)` whose server is only in workspaces** (menu bar, demo stage) still highlights a row and opens the server. Pinned by `aServerOnlyInAWorkspaceMapsToItsFirstRow` (Task 3).
3. **A drop on the section a row came from** saves nothing and does not rewire. Pinned by `aMoveWithinOneSectionChangesNothing` (Task 3) and `moveProfiles` returning early on an unchanged result (Task 4).
4. **A repository's own file churn** never triggers a rewire. Pinned by the `isRelevantChange` checks (Task 1).
5. **A workspace renamed or deleted while its page or one of its server rows is selected** shows `UnknownPane`, never a crash or a stale page. Checked by hand in Task 7's list, first item.

---

### Task 1: Resolution reaches plain folders, and the change filter

**Files:**
- Modify: `apps/apple/Bastion/WorkspaceScope.swift` (`projectKeys`, `scan`, new `isRelevantChange`)
- Test: `scripts/wiring-check.swift` (`workspaceResolution`, new `workspaceChangeFilter`, registered in `main`)

**Interfaces:**
- Produces: `WorkspaceScope.isRelevantChange(_ path: String, repositoryKeys: Set<String>) -> Bool`
- Produces: `projectKeys(for:fs:)` now also returns plain folders that have a repository below them within `scanDepth`.

- [ ] **Step 1: Write the failing checks.** In `workspaceResolution`, using the existing `fs` fixture:

```swift
check("a plain folder with a repository below it is a key", parent.contains("/w/rgis/clients"))
check("and so is each plain folder on the way down", parent.contains("/w/rgis/clients/acme"))
check(
  "a plain folder whose repository is past the depth limit is not",
  !parent.contains("/w/rgis/a") && !parent.contains("/w/rgis/a/b"))
check("exactly those keys", parent.count == 6)  // replaces the existing `== 4`
```

Add a fixture folder `/w/rgis/assets/img` (no repository) and assert `!parent.contains("/w/rgis/assets")`, keeping the count at 6.

New `workspaceChangeFilter()`:

```swift
let repos: Set<String> = ["/w/rgis/api", "/w/rgis/infra"]
check("a file inside a repository is not relevant",
  !WorkspaceScope.isRelevantChange("/w/rgis/api/src", repositoryKeys: repos))
check("a repository's own folder is not relevant",
  !WorkspaceScope.isRelevantChange("/w/rgis/api", repositoryKeys: repos))
check("a repository's parent is relevant",
  WorkspaceScope.isRelevantChange("/w/rgis", repositoryKeys: repos))
check("a sibling plain folder is relevant",
  WorkspaceScope.isRelevantChange("/w/rgis/new-clone", repositoryKeys: repos))
check("a prefix that is not a path component is relevant",
  WorkspaceScope.isRelevantChange("/w/rgis/api-v2", repositoryKeys: repos))
check("a trailing slash is ignored",
  !WorkspaceScope.isRelevantChange("/w/rgis/api/src/", repositoryKeys: repos))
```

- [ ] **Step 2: Run `make wiring-check`.** Expected: the new checks FAIL (and `isRelevantChange` does not compile until stubbed; stub it returning `true` first if needed).

- [ ] **Step 3: Implement.** `scan` returns `Bool` (found a repository at or below this directory); the caller inserts `fs.canonical(child)` for a plain child whose scan returned true. `isRelevantChange` trims a trailing slash, then is false when the path equals a key or has `key + "/"` as a prefix. Update the `projectKeys` doc comment to say plain folders on the way to a repository are keys, and why (Claude Code applies a non-git block to that exact folder only).

- [ ] **Step 4: Run `make wiring-check`.** Expected: all pass.

- [ ] **Step 5: Commit** `feat(workspaces): reach the plain folders between a workspace folder and its repositories`.

---

### Task 2: `MainPane` in its own file, with the two new cases

**Files:**
- Create: `apps/apple/Bastion/MainPane.swift` (the enum and its `RawRepresentable` extension, moved verbatim from `MainWindow.swift:1-55`, plus the new cases)
- Modify: `apps/apple/Bastion/MainWindow.swift` (remove the moved code), `Makefile` (`wiring-check` adds `MainPane.swift`)
- Modify: every `switch` over `MainPane` that must be exhaustive (`MainView.detail`, `DemoSeed` if it switches)
- Test: `scripts/wiring-check.swift` new `mainPaneRawValues()`

**Interfaces:**
- Produces: `MainPane.workspace(String)`, `MainPane.scopedServer(workspace: String, server: String)`, and `var serverID: String?` (the server id for `.server` and `.scopedServer`, else nil).

- [ ] **Step 1: Write the failing checks.** Round-trip every case through `rawValue` → `init(rawValue:)`, including `.workspace("rgis")` ↔ `"workspace:rgis"` and `.scopedServer(workspace: "rgis", server: "ovh")` ↔ `"scoped-server:rgis/ovh"`. Reject `"scoped-server:rgis"`, `"scoped-server:/ovh"`, `"scoped-server:rgis/"`, `"workspace:"`.
- [ ] **Step 2: Run `make wiring-check`.** Expected: compile failure on the new cases.
- [ ] **Step 3: Move the enum, add the cases, parse `scoped-server:` on the first `/` after the prefix.** `MainPane.swift` must import only Foundation. In `MainView.detail`, `.scopedServer` renders exactly what `.server` renders (look the server up by id); `.workspace` renders `UnknownPane(what: "workspace", id:)` for now (Task 7 replaces it).
- [ ] **Step 4: Run `make wiring-check` and `make app`.** Expected: pass, `BUILD SUCCEEDED`.
- [ ] **Step 5: Commit** `refactor(app): MainPane in its own file, with workspace and scoped-server panes`.

---

### Task 3: The sidebar model

**Files:**
- Create: `apps/apple/Bastion/WorkspaceSidebar.swift`
- Modify: `apps/apple/Bastion/WorkspaceScope.swift` (add `moving`), `Makefile` (`wiring-check` adds `WorkspaceSidebar.swift`)
- Test: `scripts/wiring-check.swift` new `workspaceSidebarSections()`, `workspaceMoves()`, `collapsedServerSections()`, `sidebarSelection()`

**Interfaces:**
- Consumes: `Workspace`, `MainPane` (Task 2).
- Produces:

```swift
nonisolated enum ServerSectionKind: Hashable, Codable {
  case servers, workspace(String), everywhere
  var collapseKey: String?   // nil for .servers, "workspace:<name>", "everywhere"
}
nonisolated struct ServerRow: Hashable, Identifiable {
  let serverID: String
  let profileIDs: [String]     // sorted; the profiles this section holds for this server
  let caption: String?         // profile names, ", "-joined, sorted; nil unless the server is in 2+ sections
  let pane: MainPane           // .scopedServer in a workspace section, else .server
  var id: String { serverID }
}
nonisolated struct ServerSection: Identifiable {
  let kind: ServerSectionKind
  let rows: [ServerRow]
  var id: ServerSectionKind { kind }
}
nonisolated enum WorkspaceSidebar {
  /// `profiles`: (id, serverID) pairs.
  static func sections(
    servers: [String], profiles: [(id: String, serverID: String)], workspaces: [Workspace]
  ) -> [ServerSection]
  /// `.server(id)` with no row tagged so → the first row of that server; anything else unchanged.
  static func rowPane(for pane: MainPane, in sections: [ServerSection]) -> MainPane
}
nonisolated enum CollapsedServerSections {
  static func decode(_ raw: String) -> Set<String>
  static func encode(_ keys: Set<String>) -> String       // sorted, comma-separated
  static func setting(_ kind: ServerSectionKind, expanded: Bool, in raw: String) -> String
}
extension WorkspaceScope {
  /// nil `from`/`to` means Everywhere. Returns the workspaces after the move.
  static func moving(
    _ profileIDs: [String], from: String?, to: String?, in workspaces: [Workspace]
  ) -> [Workspace]
}
```

- [ ] **Step 1: Write the failing checks.** Fixture: servers `["bastion", "ovh", "x", "shopify", "fresh"]`; profiles `local/bastion`, `mgcrea/ovh`, `rgis/ovh`, `mgcrea/x`, `risingpaw/x`, `prod/shopify`; workspaces `rgis: [rgis/ovh, gone/npm]`, `apps: [risingpaw/x]`, `empty: []`.

`workspaceSidebarSections`:
- no workspaces → one `.servers` section holding all five servers in order, every caption nil, every pane `.server`.
- with workspaces → kinds `[.workspace("apps"), .workspace("empty"), .workspace("rgis"), .everywhere]`.
- rgis holds one row `ovh` with profileIDs `["rgis/ovh"]`, caption `"rgis"`, pane `.scopedServer(workspace: "rgis", server: "ovh")`.
- Everywhere's `ovh` row has profileIDs `["mgcrea/ovh"]`, caption `"mgcrea"`, pane `.server("ovh")`.
- `empty` has no rows.
- `fresh` (no profile) is in Everywhere with empty profileIDs and nil caption; `shopify` has nil caption.
- `gone/npm` puts nothing anywhere.
- a profile listed in both rgis and apps appears in both sections (`movingFromOneOfTwoWorkspacesLeavesTheOther` uses the same shape).
- an Everywhere section with no rows is still present.

`workspaceMoves`:
- `moving(["mgcrea/ovh"], from: nil, to: "rgis")` → rgis gains it.
- `moving(["rgis/ovh"], from: "rgis", to: "apps")` → out of rgis, into apps.
- `moving(["rgis/ovh"], from: "rgis", to: nil)` with `rgis/ovh` also in apps → out of **both** (Everywhere clears every workspace).
- `aMoveWithinOneSectionChangesNothing`: `moving(x, from: "rgis", to: "rgis", in: w) == w`, and `from: nil, to: nil` likewise.
- `movingFromOneOfTwoWorkspacesLeavesTheOther`: profile in rgis and apps, `moving([p], from: "rgis", to: "empty")` → still in apps, in empty, not in rgis.
- profile arrays stay sorted and unique; a move to a workspace name that does not exist changes nothing.

`collapsedServerSections`: decode `""` → empty; decode `"everywhere,workspace:rgis,junk"` keeps all three (junk is harmless); `setting(.workspace("rgis"), expanded: false, in: "")` → `"workspace:rgis"`; then `expanded: true` → `""`; `.servers` never changes the raw value; encode sorts.

`sidebarSelection`: `aServerOnlyInAWorkspaceMapsToItsFirstRow`: with a server whose only profile is in rgis, `rowPane(for: .server(id))` → `.scopedServer(workspace: "rgis", server: id)`; a server in Everywhere maps to itself; `.running` and `.workspace` unchanged; an unknown server id unchanged.

- [ ] **Step 2: Run `make wiring-check`.** Expected: compile failure.
- [ ] **Step 3: Implement** in the files above. Sections sort workspaces with plain `<` on name (names are lowercase kebab-case).
- [ ] **Step 4: Run `make wiring-check`.** Expected: all pass.
- [ ] **Step 5: Commit** `feat(workspaces): the sidebar's sections, moves and collapsed set`.

---

### Task 4: Store moves and the watcher

**Files:**
- Modify: `apps/apple/Bastion/Workspaces.swift` (`moveProfiles`, owns the watcher, restarts it in `rescan`)
- Create: `apps/apple/Bastion/WorkspaceWatcher.swift`

**Interfaces:**
- Consumes: `WorkspaceScope.moving`, `WorkspaceScope.isRelevantChange` (Tasks 1, 3).
- Produces: `WorkspaceStore.moveProfiles(_ ids: [String], from: String?, to: String?) throws` (nil = Everywhere). Returns without saving or rewiring when `moving` returns the current workspaces. Otherwise saves once, `rescan()`, `ClientWiring.rewire()` once.
- Produces: `@MainActor final class WorkspaceWatcher { init(onRelevantChange: @escaping @MainActor () -> Void); func watch(_ folders: Set<String>, repositoryKeys: Set<String>) }`. `watch` with an unchanged folder set only updates the keys; with a changed set it tears down and recreates the stream; with an empty set it stops.

- [ ] **Step 1: Implement `moveProfiles`**, guarded by `unreadable` as `save()` already is.
- [ ] **Step 2: Implement `WorkspaceWatcher`** with `FSEventStreamCreate` on the canonical folders, latency 2.0, flags `kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer`, dispatched on the main queue (`FSEventStreamSetDispatchQueue`). Call back only when some event path passes `isRelevantChange`. Repository keys are the resolved keys that are repositories, i.e. every resolved key except the picked folders and the plain folders: pass all resolved keys **that hold a `.git`** (check with `LocalWorkspaceFileSystem().isDirectory/isFile` of `<key>/.git`).
- [ ] **Step 3: Wire it into the store.** `rescan()` ends by calling `watcher.watch(...)` with the canonical folders of every workspace (empty under `DemoSeed.isEnabled`). The callback recomputes `resolved`; when it differs from the previous value it calls `ClientWiring.rewire()` (which rescans again, harmlessly); otherwise nothing.
- [ ] **Step 4: Run `make app`.** Expected: `BUILD SUCCEEDED`.
- [ ] **Step 5: Check by hand** with the Debug app (`make dev-clone`, then `BASTION_PORT=8799 make run`): add a workspace on a scratch folder, `git init` a subfolder in it, and see `list_workspaces`-equivalent state (the Workspaces UI or the log) pick it up within a few seconds without Rescan. Note the result in the commit body.
- [ ] **Step 6: Commit** `feat(workspaces): move profiles in one save, and pick up new repositories by themselves`.

---

### Task 5: Sidebar sections, headers, footer and sheets

**Files:**
- Modify: `apps/apple/Bastion/MainWindow.swift` (sidebar body, selection binding, footer, server context menu)
- Create: `apps/apple/Bastion/WorkspaceSheets.swift` (`NewWorkspaceSheet`, `RenameWorkspaceSheet`, the delete confirmation modifier, `ServerSectionHeader`)

**Interfaces:**
- Consumes: `WorkspaceSidebar.sections`, `rowPane`, `CollapsedServerSections`, `WorkspaceStore.moveProfiles`, `upsert(_:replacing:)`, `remove(named:)`, `resolvedKeys`.

- [ ] **Step 1: Sections.** Replace the single Servers `Section` with a `ForEach` over `WorkspaceSidebar.sections(...)` (servers from `ServerStore.shared.servers`, profiles from `ProfileStore.shared.profiles`, workspaces from `WorkspaceStore.shared.workspaces`, or `[]` when `unreadable`). The row view (icon, name, `ServerBadge`, enabled dimming, context menu) is extracted into a `serverRow(_ server:, _ row: ServerRow, in: ServerSection)` builder and gains the caption in `.secondary` after the name. Tag with `row.pane`. `.servers` keeps today's header and empty line; workspace and Everywhere sections use `Section(isExpanded:)` bound through `CollapsedServerSections.setting`. The header buttons go on the first section's header.
- [ ] **Step 2: Selection.** The `pane` getter returns `WorkspaceSidebar.rowPane(for: current, in: sections)`; `detail` handles `.scopedServer` (Task 2).
- [ ] **Step 3: Headers.** `ServerSectionHeader`: name as a plain button selecting `.workspace(name)`, the reach caption (orange "No folders found" when `resolvedKeys` is empty), context menu Edit… / Rename… / Delete…. Everywhere: plain "Everywhere", no menu.
- [ ] **Step 4: Move to.** In the server context menu, when any workspace exists and the row holds profiles: per profile a `Menu("Move \(id) to")` (or `"Move to"` when it holds one) with Everywhere and every workspace except the current section, calling `moveProfiles([id], from: currentWorkspace, to: target)`. Errors go to `sidebarError`.
- [ ] **Step 5: Footer and sheets.** "New workspace" row under `sidebarAdd`, disabled when `unreadable`; when `unreadable`, a red caption with `unreadable.localizedDescription` above it. `NewWorkspaceSheet`: name field, folder list with remove buttons, Add Folder… (`NSOpenPanel`, multiple), Create disabled until `Profile.isValidName(name)`, the name is unused, and folders are non-empty; errors from `upsert` shown inline. `RenameWorkspaceSheet`: same validation, `upsert(renamed, replacing: old)`. Delete confirmation with the copy in Global Constraints; it holds the "Its profiles…" message only when the workspace lists any profile.
- [ ] **Step 6: Run `make app`**, launch the Debug app, and check: no workspaces looks exactly like before; one workspace shows its section and Everywhere; collapse persists across relaunch; Move to moves and the section updates; New/Rename/Delete work.
- [ ] **Step 7: Commit** `feat(app): workspaces as sections of the sidebar's server list`.

---

### Task 6: Drag and drop

**Files:**
- Create: `apps/apple/Bastion/ServerDrag.swift` (payload, `UTType.bastionProfiles`, `SectionDropHighlight`, `DropHereRow`, the drag-source and drop-target modifiers)
- Create: `apps/apple/Bastion/SidebarTableFeedback.swift` (from Cadence, verbatim apart from the doc comment's wording)
- Modify: `apps/apple/Bastion-Info.plist` (`UTExportedTypeDeclarations`), `apps/apple/Bastion/MainWindow.swift`

**Interfaces:**
- Produces: `struct ServerDragPayload: Codable, Transferable { let serverID: String; let profileIDs: [String]; let from: ServerSectionKind }` with `CodableRepresentation(contentType: .bastionProfiles)`.

- [ ] **Step 1: Declare the type** in the Info.plist: identifier `io.mgcrea.bastion.profiles`, conforms to `public.data`, description "Bastion server profiles".
- [ ] **Step 2: Source and targets.** Rows with non-empty `profileIDs` in workspace and Everywhere sections are draggable. Every such row and each empty workspace's `DropHereRow` is a drop target for its section; the drop calls `moveProfiles(payload.profileIDs, from: workspaceName(payload.from), to: workspaceName(section.kind))`, and returns false (no save) when `payload.from == section.kind`. The section under the drag is outlined via `SectionDropHighlight`, as in Cadence. `.background(SidebarTableFeedback())` on the List. The `.servers` section has no drag or drop.
- [ ] **Step 3: Run `make app`** and check by hand: drag a single-profile server into a workspace and back; drag a split row; drop on its own section (nothing happens, nothing is logged as a rewire); drop on an empty workspace's placeholder; selection still looks right with the table highlight turned off (rows draw the selection outline as in Cadence — copy `SelectionOutline` too if the table's own selection is turned off).
- [ ] **Step 4: Commit** `feat(app): drag servers between workspaces`.

---

### Task 7: The workspace page, and Settings → Workspaces retired

**Files:**
- Create: `apps/apple/Bastion/WorkspaceDetail.swift`
- Delete: `apps/apple/Bastion/WorkspacesPane.swift`
- Modify: `apps/apple/Bastion/SettingsWindow.swift` (remove the `.workspaces` case), `MainWindow.swift` (`detail` renders `WorkspaceDetail`), `ProfileEditor.swift:176-189` (Scope menu), `ClientDetail.swift:961`, `SkillsPane.swift:165` (open the main window on the first workspace, hidden when there is none), `DemoSeed.swift:438` and `Profiles.swift:429` (comments that name the Settings pane)

- [ ] **Step 1: `WorkspaceDetail(name:)`** per the spec's "The workspace page": header with Rename…/Delete… (reusing Task 5's sheet and confirmation), Folders card (remove, Add Folder…, "Written into N folders" with a disclosure of `resolvedKeys` sorted, Rescan), Profiles card (sorted, remove → `moveProfiles([id], from: name, to: nil)`, "(missing)" for an id with no profile, an "Add Profile" menu of every other profile → `moveProfiles([id], from: <its current workspace or nil>, to: name)`), Skills card (the toggles and unavailable rows moved from `WorkspacesPane`), and the caption from Global Constraints. A name with no workspace renders `UnknownPane(what: "workspace", id:)`.
- [ ] **Step 2: Profile editor Scope menu** per the spec: a `Menu` labelled with the current scope, items Everywhere and each workspace with checkmarks; choosing moves exclusively (`moveProfiles([id], from: each current workspace…, to: target)`; implement as one `WorkspaceScope.moving` per current workspace folded, then one save, or add a `moveProfileExclusively(_ id:, to:)` to the store that does that in one save). For a new profile, the caption only.
- [ ] **Step 3: Remove the Settings pane** and fix every reference the compiler reports.
- [ ] **Step 4: Run `make app` and check by hand, in this order:** (1) rename and then delete a workspace while its page is selected, then while one of its server rows is selected: `UnknownPane`, no crash; (2) every card on the page; (3) the Scope menu on a split profile and on a profile in two workspaces; (4) the Claude Code client pane and Skills pane buttons.
- [ ] **Step 5: Commit** `feat(app): a page per workspace in the main window, replacing the Settings pane`.

---

### Task 8: Docs, changelog, screenshots, end-to-end check

**Files:**
- Modify: `CHANGELOG.md` (an `## [Unreleased]` section if none: **Added** — workspaces in the sidebar with drag and drop, the page, the Scope menu; **Changed** — plain folders on the way to a repository get a workspace's profiles, new repositories are picked up without Rescan, Settings → Workspaces moved to the main window). Do not run `make changelog`; that belongs to the release.
- Modify: any docs or website copy that says "Settings → Workspaces" (`grep -rn -i "workspaces" apps/website/src docs/*.md README.md`), and `apps/website/public/llms.txt` if it describes where workspaces are edited.
- Modify: `apps/apple/Screenshots/golden/*` only after review.

- [ ] **Step 1: Update the copy and the CHANGELOG.**
- [ ] **Step 2: `make screenshots`.** Expected: the main-window plates drift (the acme section). Read each diff image; the only change must be the sidebar's acme section and Everywhere header. Do not accept goldens; leave them for the owner with the list of drifted plates.
- [ ] **Step 3: End to end, Debug app:** a workspace on a scratch parent folder with a repository two levels down and a plain folder between; scope one profile to it; `claude mcp list` in the repository (present), in the plain folder (present), in an unrelated folder (absent).
- [ ] **Step 4: Run every gate:** `make wiring-check unit format-check lint` and `make app`. Expected: all pass.
- [ ] **Step 5: Commit** `docs: workspaces live in the sidebar now`.
