# Workspaces in the sidebar

Status: approved design, 2026-10-30. Implementation plan:
`docs/superpowers/plans/2026-10-30-workspace-sidebar.md`. Builds on
`2026-09-22-workspaces-design.md`, whose model, resolution and writing rules all
still hold except where this document changes them.

## What the owner asked for

Group MCP servers, so that all the RGIS ones are enabled only for Claude Code
sessions started inside `~/Projects/rgis` or below it, managed in the main window
the way Cadence manages recording groups
(`cadence/docs/superpowers/specs/2026-10-14-recording-groups-design.md`, the UI
section as revised on 2026-10-15): one section per group in the sidebar, drag and
drop between them, a button at the bottom of the sidebar to add one.

Workspaces are already that grouping, but they live in Settings as a form of
toggles, and two gaps make "or below it" untrue today:

1. A plain folder between the picked folder and the repositories under it
   (`~/Projects/rgis/rgis-ai`) gets nothing, because Claude Code applies a
   non-git block to that exact folder only and the scan writes only the picked
   folder and the repositories.
2. A repository cloned after the last rewire gets nothing until something else
   rewires.

Approved as a whole in conversation: the rest of this document.

## Decisions

- **The sidebar's rows stay servers.** A workspace holds profiles, and most
  servers have one profile, but OVH (`mgcrea/ovh`, `rgis/ovh`) and X
  (`mgcrea/x`, `risingpaw/x`) do not. A server is shown in every section that
  holds one of its profiles. Where its profiles are split across sections, each
  of its rows names the profiles that section holds, in secondary text after
  the server's name.
- **One place per profile, in the UI.** As in Cadence, a drag moves. The file
  format still allows a profile in several workspaces, and `upsert_workspace`
  can still make one. Such a profile is shown in each of its sections, and a
  drag moves it out of the section it was dragged from only.
- **`workspaces.json` does not change.** No migration, no new field.
- **No colour or symbol per workspace.** The names are short and the sections
  are headed. Revisit if the sidebar gets hard to scan.
- **Settings → Workspaces goes away.** Its content moves to a workspace page in
  the main window, so there is one place to edit a workspace.
- **No licence gate**, as today.

## Sidebar

### Sections

A pure builder, `WorkspaceSidebar.sections(servers:profiles:workspaces:)`,
decides the server sections. Inputs are plain values: the server ids in
`ServerStore` order, each profile's id and server id, and the workspaces.

- **No workspaces:** one section, `.servers`, holding every server, headed
  "Servers", exactly as today. It keeps today's header buttons and the
  "None installed yet." line.
- **With workspaces:** one `.workspace(name)` section per workspace, sorted by
  name, then `.everywhere` last, headed "Everywhere".
- **Membership.** A server is in a workspace section when at least one of its
  profiles is listed in that workspace. A server is in Everywhere when at least
  one of its profiles is in no workspace, **or** it has no profile at all (a
  server just installed, or one Bastion runs with no credentials). A profile id
  listed in a workspace whose profile does not exist puts nothing anywhere.
- **Rows** keep `ServerStore` order within a section, and carry the profile ids
  the section holds for that server.
- **The profile caption** is shown on a row when the server appears in more
  than one section: the profile names (the part before the slash) of the
  profiles that section holds, comma-separated, sorted. A server shown once has
  no caption, so the common case looks as it does today.
- **An empty workspace** shows one dimmed, non-selectable row, "Drag servers
  here", which is also a drop target. **Everywhere** is always shown once any
  workspace exists, even when empty, so there is somewhere to drag back to.
- The update-check and `+` buttons stay on the first section's header,
  whichever section that is.

### Section headers

A workspace header shows its name and, in caption text, what it reaches:
"37 folders" (one folder: "1 folder"), with "Claude Code only" in its help: the
longer "Claude Code · 37 folders" truncated beside the first header's buttons at
the sidebar's default width (changed after review, 2026-10-30). Under a capture
the count is `DemoSeed.workspaceReach`, since the fixture's invented folder
resolves to nothing. A workspace whose folders
resolve to nothing shows "No folders found" in orange instead, since every
profile in it then reaches no client at all.

Clicking a workspace's name opens its page (below). The header's context menu
holds Edit…, Rename… and Delete…:

- **Rename…** opens a small sheet with the name field, validated by
  `Profile.isValidName` and refusing a name already taken. It saves through
  `WorkspaceStore.upsert(_:replacing:)`, which rewires.
- **Delete…** asks first: "Delete the workspace “rgis”?", with the message
  "Its profiles go back to every client." when it holds any. Deleting goes
  through `WorkspaceStore.remove(named:)`.

The Everywhere header has no menu.

### Collapsing

Workspace and Everywhere sections collapse with the sidebar's own disclosure
(`Section(isExpanded:)`). The `.servers` section of the no-workspace case does
not. Which ones are collapsed is per Mac, in
`@AppStorage("sidebar.collapsedServerSections")`: the sorted, comma-separated
keys of the collapsed sections, `workspace:<name>` or `everywhere`. A new
workspace starts expanded. Unknown keys are ignored. A rename forgets the old
key, which only means the section reopens.

### Drag and drop

- A server row in a workspace or Everywhere section is draggable. The payload
  is the server id, the profile ids the row holds, and the section it came
  from, under a private exported type `io.mgcrea.bastion.profiles` (conforming
  to `public.data`, declared in `Bastion-Info.plist`).
- Every row of a workspace or Everywhere section, and the empty-workspace
  placeholder, is a drop target for its section. The section a drop would land
  in is outlined while the drag is over it, Cadence's `SectionDropHighlight`
  arrangement, with the table's own drop feedback turned off
  (`SidebarTableFeedback`).
- **Dropping on a workspace** adds the dragged profiles to it and removes them
  from the workspace they were dragged from, if that was a workspace.
- **Dropping on Everywhere** removes the dragged profiles from every workspace.
- **Dropping on the section it came from** does nothing and saves nothing.
- A row with no profiles (a server with no credentials) cannot move: it is not
  draggable.
- A drop is one save of `workspaces.json` and one rewire, whatever it changes,
  through a new `WorkspaceStore.moveProfiles(_:from:to:)`. The arithmetic is a
  pure `WorkspaceScope.moving(_:from:to:in:)`.
- A failed save shows the sidebar's existing "Could not change the server"
  alert with the error.

### Splitting a server

The row's context menu gains, when the row holds more than one profile **or**
any workspace exists, a "Move to" submenu per profile the row holds
("Move rgis/ovh to ▸", or "Move to ▸" when it holds one), listing Everywhere and
every workspace other than the current section. Choosing one is the same move as
a drop of that single profile.

### Selection

`MainPane` gains:

- `.workspace(String)`: a workspace's page. Raw value `workspace:<name>`.
- `.scopedServer(workspace: String, server: String)`: a server row in a
  workspace section. Raw value `scoped-server:<workspace>/<server>`; a workspace
  name never contains a slash.

Rows in Everywhere and in the `.servers` section keep `.server(id)`. So each
row's tag is unique and only the clicked row highlights. Both server cases open
the same `ServerDetail`.

`.server(id)` stays what every deep link uses (`MainWindowController.show`, the
menu bar, demo stages). When the sidebar has no row tagged `.server(id)` for it,
because every profile of that server is in workspaces, the selection getter maps
it to the server's first row instead, so the deep link still highlights
something.

A selection naming a workspace or a server that is gone shows the existing
`UnknownPane`.

### The footer

"New workspace" (`folder.badge.plus`) goes under "Add server", in the same
style. It opens the new-workspace sheet:

- A name field (`Profile.isValidName`, unique), and a folder list filled with
  an `NSOpenPanel` that allows several folders.
- **Create is disabled until there is a valid name and at least one folder.** A
  workspace with no folder would quietly take every profile dropped into it out
  of every client.
- Creating saves through `WorkspaceStore.upsert`, selects nothing new, and
  leaves the section expanded and empty, showing its placeholder.

When `workspaces.json` is unreadable (`WorkspaceStore.unreadable`), the sidebar
shows the `.servers` layout, and the footer shows the error in red above "Add
server" with the file's path. New workspace is disabled.

## The workspace page

`WorkspaceDetail`, in the main window's detail column, for `.workspace(name)`.
It holds what the Settings pane held for one workspace, in the server pane's
card style:

- **Header:** the name, Rename… and Delete… (the same sheet and confirmation as
  the header menu).
- **Folders:** each folder as picked, with a remove button, and Add Folder…
  (`NSOpenPanel`, several at once). Under them, "Written into N folders" with a
  disclosure listing the resolved project folders, and a Rescan button
  (`rescan()` then `ClientWiring.rewire()`).
- **Profiles:** the profiles in this workspace, sorted by id, each with a
  remove button that moves it to Everywhere, plus an "Add Profile" menu listing
  every profile not in this workspace (moving it here, out of wherever it was).
  This is the keyboard and VoiceOver route that drag and drop is not. A listed
  id with no profile behind it is shown as "(missing)" with its remove button.
- **Skills:** the skill toggles, as in the Settings pane today, including the
  unavailable-skill rows.
- A caption that says the rule once: "Only Claude Code sessions started in
  these folders get these profiles. Other clients do not get them."

## The profile editor

The Workspaces section's "Scope" line and "Edit Workspaces…" button become a
Scope menu: Everywhere and each workspace, with a checkmark on the current one
(several when the profile is in several). Choosing an item moves the profile
there exclusively, out of every other workspace, through `moveProfiles`.

A profile being created has no id yet, so it shows no menu, only the caption "A
profile named after a workspace joins it." The existing rule in
`ProfileStore` (a profile whose name equals a workspace's name joins it at
creation) is unchanged.

`ClientDetail`'s and `SkillsPane`'s "Edit Workspaces…" buttons open the main
window on the first workspace's page instead (`MainWindowController.show(.workspace(…))`),
or are hidden when there is no workspace.

## Folder resolution

Two changes to `WorkspaceScope`, both covered by `wiring-check`.

### Plain folders on the way down

A picked folder outside git already gives its own exact key plus every
repository beneath it. It now also gives the exact key of **every plain folder
the scan passes through on its way to a repository**: a directory that is not a
repository, is within `scanDepth`, and has a repository somewhere beneath it
within `scanDepth`. A plain folder with no repository below it is not added, so
a folder of assets does not become a project block.

For `~/Projects/rgis` that adds `rgis-ai`, `rgis-projects`, `rgis-apps` and the
like, and any plain folder between them and their repositories.

### Watching for new repositories

A `WorkspaceWatcher` holds one FSEvents stream over the canonical folders of
every workspace (not under a capture, not when there are no workspaces),
restarted when the set of folders changes. Latency 2 seconds, so a clone or a
batch of them settles into one event burst.

An event path is relevant when it is **not inside any repository key** the
last scan found (not equal to one and not below one). A repository's own churn
(edits, builds, `git` internals) is therefore ignored, while a clone (an event
on its parent), `git init` in a plain folder, a deleted repository and a new
plain folder all count. The filter is a pure
`WorkspaceScope.isRelevantChange(_:repositoryKeys:)`.

On a relevant burst the store rescans. If any workspace's resolved keys
changed, it calls `ClientWiring.rewire()`. Otherwise nothing is written.

The workspace page's Rescan button stays, for a folder on a volume FSEvents does
not report.

## Demo seed and screenshots

`DemoSeed.workspaces` already scopes `acme/keycloak` to an `acme` workspace, so
every main-window plate shows an "acme" section above Everywhere. That is the
feature, so the goldens are re-accepted after review rather than the fixture
changed. The `server` stage selects Shopify, which stays in Everywhere.

## Out of scope

- Workspaces for clients other than Claude Code. Their configs have no project
  scope Bastion writes (see the 2026-09-22 design).
- Reordering workspaces by hand. Sections are sorted by name.
- Enforcement (per-workspace tokens), as in the 2026-09-22 design.

## Testing

- `make wiring-check` gains:
  - the section builder: no workspaces, one server per section, a server split
    across two sections with its captions, a server with no profiles in
    Everywhere, a missing profile id ignored, an empty workspace present, a
    profile in two workspaces shown in both;
  - `moving`: Everywhere to a workspace, a workspace to another, a workspace to
    Everywhere clearing every workspace, a same-section move being a no-op, a
    profile in two workspaces dragged from one leaving the other alone;
  - resolution: a plain folder with a repository below it is a key, one with no
    repository below it is not, the depth limit still holds;
  - `isRelevantChange`: inside a repository, equal to one, the parent of one,
    and a sibling plain folder.
- `MainPane` raw values round-trip for the two new cases, in `wiring-check`
  only if `MainPane` can be compiled there without SwiftUI; otherwise by hand.
- By hand, in the running Debug app: make a workspace, drag a single-profile
  server into it and back, split OVH, collapse and relaunch, rename and delete,
  the profile editor's Scope menu, and a fresh clone under a workspace folder
  picked up without pressing Rescan. Then `claude mcp list` in a repository, a
  plain intermediate folder and an unrelated folder.
- `make screenshots` and a review of every main-window plate before the goldens
  are accepted.
