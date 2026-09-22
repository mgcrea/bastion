# Workspaces: folder-scoped profiles

Status: approved design, 2026-09-22. Implementation plan:
`docs/superpowers/plans/2026-09-22-workspaces.md`.

## Problem

Every Configure and every automatic `rewire` writes every profile on a
switched-on server into every wired client's global block. A session in an
`mgcrea` repo therefore sees `rgis-ovh`, `prod-appstore-connect` and the rest:
context spent on tools that do not belong there, and a standing chance of the
model picking the wrong account's tool.

Goal: a profile can be made to appear only in chosen folders. The design must
leave room for enforcing that boundary later, but v1 is about visibility.

## What Claude Code does with a project block (measured 2026-09-22)

Probed with `claude mcp add --scope local` and `claude mcp list` under a
throwaway `CLAUDE_CONFIG_DIR`:

- Inside a git repository the block is keyed by the **repository root**, and
  applies in every subfolder of it.
- A **worktree** resolves to the main repository's root, including worktrees
  under `<repo>/.claude/worktrees/`.
- Outside git the block applies to that **exact folder** only; subfolders do
  not inherit it.
- A block holding nothing but `{"mcpServers": {...}}` is accepted as is, and
  Claude Code does not add fields to it on read.

So the unit Bastion writes to is "a git repository root, or an exact non-git
folder", and a parent folder such as `~/Projects/rgis` reaches nothing on its
own.

## Model

`workspaces.json` in `AppSupport.directory`, beside `profiles.json`:

```json
[{ "name": "rgis", "folders": ["/Users/me/Projects/rgis"], "profiles": ["rgis/ovh"] }]
```

- `name` follows `Profile.isValidName`.
- `folders` are absolute paths, stored as picked (not resolved).
- `profiles` are profile ids (`<name>/<server>`). An id whose profile no longer
  exists is kept in the file and ignored, the way `ProfileStore.orphaned` keeps
  rows for uninstalled servers.

Semantics:

- A profile listed in **any** workspace is **scoped**: it is written only into
  the Claude Code project blocks its workspaces resolve to, and is omitted from
  every client's global block, Claude Code's included.
- A profile in no workspace is **global**, exactly as today.
- A profile may be in several workspaces; it is written into the union of
  their project keys.
- Creating a profile whose name equals a workspace's name adds it to that
  workspace, once, at creation. Taking it out afterwards sticks.

Clients that have no project scope Bastion can write (Claude Desktop, VS Code,
Cursor, LM Studio, Windsurf, ChatGPT & Codex) simply do not get scoped
profiles.

## Folder resolution

A pure function, `WorkspaceScope.projectKeys(for folders:) -> Set<String>`,
over a small filesystem protocol so `wiring-check` can drive it with fixtures:

1. Standardise the path (resolve symlinks, drop a trailing slash).
2. Walk up from the folder looking for `.git`:
   - a `.git` **directory** at `R` → key `R`;
   - a `.git` **file** reading `gitdir: <X>/.git/worktrees/<name>` → key `X`
     (the main repository);
   - any other `.git` file (a submodule) → key is the folder holding it.
3. No `.git` above: the folder is a parent. Keys are the folder itself (exact)
   plus every repository root found beneath it, resolved as in step 2. The scan
   descends at most 3 levels, skips hidden directories and `node_modules`, and
   does not descend into a repository once found.

Resolution runs on every wire, so a repository cloned after the workspace was
saved is picked up at the next rewire (launch, a profile or workspace edit,
Configure). The workspace editor has a Rescan button that calls `rewire()`.
No file watching in v1.

## Writing

Applies to every Claude Code row (`family == "claude-code"`, including the
`CLAUDE_CONFIG_DIR` rows), each against its own `.claude.json`.

`ClientWiring.wire(client, profiles:)` splits `profiles` into global and scoped
using the workspace snapshot:

- **Global block**: merged as today with the global profiles only. The scoped
  profiles' endpoints are added to `retiring`, so an entry written before the
  profile was scoped is removed rather than left behind. This applies to every
  client, not only Claude Code: scoping a profile takes it out of Cursor too.
- **Project blocks** (Claude Code only): a new pure
  `ClientWiringMerge.reconciledProjects(root, desired: [folder: [key: entry]])`.
  For every folder that is in `desired` **or** whose block holds an entry
  `isOurs` claims:
  - write the desired entries;
  - remove every entry `isOurs` claims whose key is not desired there;
  - leave every other key in the block, and every other block, untouched.

  No record of what was written where is kept: `isOurs` is the ledger, as it is
  for the global block. Removing a folder, a profile or a whole workspace cleans
  up by itself. The consequence, accepted: a Bastion-shaped entry someone added
  to a project block by hand is reconciled away, as it would be globally.
  A block Bastion emptied is left as `{"mcpServers": {}}` rather than deleted,
  because Claude Code may have written other fields into it.
- **Collisions**: the foreign-key check runs against each desired project block
  as well as the global one, refusing with the same `WireError.collision` and
  the same "Overwrite anyway" escape.
- The write stays a single conditional write of the whole file, under the
  existing stamp and `retryingIfChanged`.

`unwire` also strips every entry `isOurs` claims from every project block.

`isWired` (the gate on `rewire`) counts an entry `isOurs` claims in any project
block, so a config whose profiles are all scoped keeps being maintained.

`status(of:)` and the client pane's audit are computed over global profiles for
the global rows. Project blocks get their own card (below) and do not change the
headline status.

## UI

- **Settings → Workspaces** pane (configuration group): a list of workspaces and
  a section per workspace with its folders (added with an `NSOpenPanel`), how
  many project folders they resolve to, profile checkboxes sorted by id (so one
  account's profiles sit together), a Rescan button and Delete.
- **Profile editor**: a Scope line, "Everywhere" or the workspace names, with a
  link to the Workspaces pane.
- **Client pane** (Claude Code rows): a Workspaces card listing each project
  block Bastion writes, with the keys in it and their state. The existing
  foreign-project-entries card is unchanged; `foreignEntries` already excludes
  what `isOurs` claims.
- `DemoSeed` gains a fixture workspace so screenshots never show the developer's
  folder names, which routinely carry a client's name.

## Control plane

Three built-in tools beside the profile tools, same conventions:

- `list_workspaces`: name, folders, resolved keys, profile ids.
- `upsert_workspace`: create or replace one workspace by name, then rewire.
- `remove_workspace`: delete one by name, then rewire.

## Out of scope for v1

- **Enforcement.** A per-workspace gateway token (account
  `claude-code#<workspace>`) whose allowlist is the workspace's profiles would
  slot into `Gateway.route` after `GatewayToken.identify`. It protects nothing
  yet: every token a client holds sits in the same `~/.claude.json`, which the
  agent can read. Revisit if tokens ever move out of that file.
- In-repository config files (`.mcp.json`, `.cursor/mcp.json`,
  `.vscode/mcp.json`, `.codex/config.toml`): each puts a bearer token in a file
  that is routinely committed.
- File watching for newly cloned repositories.

## Testing

- `make wiring-check`: resolution (repo, subfolder, worktree, `.claude/worktrees`,
  submodule, parent with nested repos, depth limit, hidden and `node_modules`
  skipped), and `reconciledProjects` (add, remove when unassigned, foreign key
  untouched, other blocks byte-identical, emptied block kept, collision
  detection).
- `make wiring-check-real`: reconcile the real `~/.claude.json` in memory with
  one scoped profile and assert every other block comes back deep-equal.
- Manual: scope a profile to one repo, run `claude mcp list` in that repo, a
  subfolder, a worktree and an unrelated folder.
