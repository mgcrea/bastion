# Plan

Queued work that isn't started yet. Each entry says where it came from and
where it lands in the code.

## Workspace sidebar: minors deferred from the 1.34.0 review

- **Kind:** polish and robustness, none blocking. Queued 2026-10-31 from the
  whole-branch review of the workspace sidebar (merge 8a2e307, shipped in
  1.34.0). The drag, Move to, rename and delete flows were never clicked
  through by hand before release; do that first, since a finding there
  outranks everything below.
- **Items, each with where it lands:**
  - The watcher's ignore set is narrow, so it can rescan (never rewrite) every
    2 seconds on the main thread: a worktree or submodule beside a repository
    resolves to the main repository's path, churn in a non-git folder
    (`.next/`, `dist/`), and repositories deeper than `scanDepth`. Fix in
    `WorkspaceScope.isRelevantChange` (`WorkspaceScope.swift:138`) and
    `WorkspaceStore.watchFolders` (`Workspaces.swift:103`): ignore paths more
    than `scanDepth` below a watched folder and paths with a hidden or
    `node_modules` component.
  - `upsert` and `remove` (`Workspaces.swift:165`, `:183`) change `workspaces`
    before saving and do not restore it on failure, unlike `replace(with:)`. A
    failed rename or delete from the workspace page drops its error.
  - A failed workspace delete in the sidebar shows the alert titled "Could not
    change the server" (`MainWindow.swift:217`).
  - `WorkspaceWatcher.swift:10` says a clone settles into one burst, but
    `kFSEventStreamCreateFlagNoDefer` (`:50`) delivers the first event at once.
    Fix the comment or drop the flag.
  - A collapsed section and an empty Everywhere take no drop
    (`MainWindow.swift:300`): headers are not drop targets, and Everywhere has
    no "Drag servers here" row.
  - The workspace page removes a workspace's last folder without asking
    (`WorkspaceDetail.swift:78`), the state the New sheet refuses.
  - The `installedClients` doc comment now sits above `serverSections`
    (`MainWindow.swift:243`).
  - `foldersChanged` scans twice when it rewires (`Workspaces.swift:116`),
    because `rewire()` rescans again.
