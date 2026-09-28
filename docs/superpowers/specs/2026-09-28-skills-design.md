# Skills: one set of Agent Skills, linked into every client

Status: design, 2026-09-28, awaiting review.

## Problem

Agent Skills (a folder holding a `SKILL.md`) are read by every coding agent on
this Mac, each from its own folders, and nothing keeps those folders in step.
On the reference machine, 2026-09-28:

- `~/.claude/skills` is maintained by hand from `~/Projects/claude-skills` (a
  Makefile, `external.links`, `projects.links`), and `~/.claude-skitrust/skills`
  is a symlink to it.
- Codex sees none of those skills: `~/.codex/skills` holds only `.system`.
- `~/.agents/skills` is a second, separate set installed by `npx skills`, and
  four of its skills (`astro-bootstrap`, `imagine`, `migrate-oxc`,
  `migrate-tsdown`) have drifted from the repo's copies.
- `~/.claude/skills/astro-bootstrap` is a dangling link; nothing reports it.

Goal: one list of skills, each switched on per target folder, globally or per
workspace, with drift and breakage visible. Bastion distributes skills; it never
edits them.

## Where clients look (researched 2026-09-28)

| Client                                     | User folder(s)                                                                | Project folder(s)                                                     |
| ------------------------------------------ | ----------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Claude Code (CLI, VS Code, Desktop Code)   | `$CLAUDE_CONFIG_DIR/skills` (default `~/.claude/skills`)                      | `.claude/skills`, nested, up to the repo root                         |
| Codex (CLI, IDE, ChatGPT desktop)          | `~/.agents/skills`; legacy `~/.codex/skills` still read (unconfirmed)         | `.agents/skills`, cwd up to repo root                                 |
| VS Code Copilot                            | `~/.copilot/skills`, `~/.claude/skills`, `~/.agents/skills`                   | `.github/skills`, `.claude/skills`, `.agents/skills`                  |
| Cursor                                     | `~/.agents/skills`, `~/.cursor/skills`, `~/.claude/skills`, `~/.codex/skills` | `.agents/skills`, `.cursor/skills`, `.claude/skills`, `.codex/skills` |
| Gemini CLI, Windsurf, OpenCode, Goose, Amp | all read `~/.agents/skills`, plus their own                                   | all read `.agents/skills`                                             |
| Claude Desktop (chat), claude.ai           | none: skills are uploaded to the account as a ZIP                             | none                                                                  |

Consequences:

- **Two kinds of folder reach everything**: `~/.agents/skills` and each Claude
  Code config folder's `skills`. The same two, `.agents/skills` and
  `.claude/skills`, cover a repository.
- **The unit of control is a folder, not a client.** A skill linked into
  `~/.agents/skills` is on for every client that reads it.
- **Account skills are unreachable from disk.** claude.ai has no public upload
  API; `/v1/skills` is a separate API workspace not shared with claude.ai.
  Claude Code downloads account skills into `~/.claude/skills/synced/`, which
  is the only local view of them.
- Claude Code and Codex document that they follow symlinked skill folders.
  Claude Code watches its skills folders; Codex needs a restart.

## Model

### Sources

`skill-sources.json` in `AppSupport.directory`, an ordered array:

```json
[
  { "name": "global", "path": "/Users/me/Projects/claude-skills/global", "kind": "collection" },
  {
    "name": "appshot-app-icon",
    "path": "/Users/me/Projects/appshot/skills/appshot-app-icon",
    "kind": "skill"
  }
]
```

- A `collection` is a folder whose immediate subfolders holding a `SKILL.md`
  are skills (other subfolders are ignored); a `skill` is one skill folder
  (this replaces `external.links`).
- `name` follows `Profile.isValidName`, is unique, and defaults to the folder's
  name made valid (`global`, `bastion`), with `-2`, `-3` appended on a clash.
  A skill's **id** is `<source>:<skill>` (`global:reply-as-olivier`,
  `bastion:cut-a-release`): the name alone does not identify a skill, because
  three sources hold a `cut-a-release`.
- Bastion never writes into a source.
- A source may not lie inside a target folder (`~/.agents/skills` cannot be a
  source), checked after resolving symlinks.
- Order is precedence, applied per target folder: when two skills of the same
  name are wanted in one folder, the one from the earlier source is linked and
  the other is reported as **shadowed** there.
- A removed source is kept as `"retired": true` until every link into it has
  been removed, then dropped from the file (see [Ownership](#ownership)).

A skill is **valid** when its `SKILL.md` frontmatter passes the agentskills.io
rules: `name` of 1–64 `[a-z0-9-]` with no leading, trailing or doubled hyphen,
equal to the folder name; `description` of 1–1024 characters. `synced` and
`anthropic-skills` are reserved by Claude Code and invalid. Invalid skills are
listed with their errors and never linked.

### Targets

Discovered, never entered:

- **Shared**: `~/.agents/skills`.
- **One per Claude Code config folder**: `<dir>/skills` for every Claude Code
  row `ClientProfiles` already discovers (`~/.claude`, `~/.claude-skitrust`, …).

Targets are deduplicated by resolved path. On the reference machine
`~/.claude-skitrust/skills` resolves to `~/.claude/skills` and they are one
target, shown with both names.

### Selection

`skills.json` in `AppSupport.directory`, keyed by skill id:

```json
{
  "choices": { "global:reply-as-olivier": { "targets": ["shared", "claude-code"] } },
  "linkedProjects": ["/Users/me/Projects/apps/bastion"]
}
```

- Target ids reuse client ids (`claude-code`, `claude-code@<suffix>`) plus
  `shared`. Of two ids naming one deduplicated target, the first in
  `ClientWiring.all` order is stored.
- `linkedProjects` is the one ledger this feature keeps: the project keys
  Bastion has linked into. Without it, a folder taken out of a workspace, or a
  deleted workspace, would leave its links behind, because nothing would look
  there again. A key is visited on every reconcile and dropped once it holds
  nothing of Bastion's.
- A skill in no choice and no workspace is **not linked** anywhere, and is
  listed that way; switching it on is always a deliberate act.
- An entry whose skill no longer exists is kept and ignored, as
  `ProfileStore.orphaned` does.

### Workspace scope

`Workspace` gains `skills: [String]` of skill ids, beside `profiles`; a
`workspaces.json` written before this change decodes with `skills` empty. Semantics mirror
scoped profiles:

- A skill listed in **any** workspace is **scoped**: it is removed from every
  global target and linked into `<root>/.claude/skills` and
  `<root>/.agents/skills` for every project key its workspaces resolve to,
  using `WorkspaceScope.projectKeys` unchanged.
- A skill in no workspace is global, and uses its `targets`.
- The scoped skill's `targets` are kept, so taking it out of its last
  workspace restores it where it was.

`cut-a-release` in armada, bastion and cupertino is the case this covers: three
skills of the same name from three collection sources
(`~/Projects/claude-skills/projects/<repo>`), each scoped to a one-repo
workspace. They never meet in one folder, so none shadows another.

### Ownership

**A symlink is Bastion's when it points into a source** (current or retired),
compared after resolving the source path. There is no ledger of links, for the
same reason Workspaces has none: `isOurs` is the ledger.

- Everything else in a target is **foreign** and never touched: real
  directories, links pointing elsewhere, `.trash`, `synced`, `*-workspace`
  folders, `npx skills` installs.
- A foreign entry with the name of a skill Bastion wants to link is a
  **collision**. Resolving it ("Overwrite anyway") moves the entry to the Trash
  with `FileManager.trashItem`, never deletes it.
- Consequence, accepted: once `~/Projects/claude-skills/global` is a source,
  every link the Makefile made into it is Bastion's, and adoption needs no
  import step.

## Reconciling

### Plan

A pure function over a small filesystem protocol, as `WorkspaceScope` is, so
`make skills-check` drives it with fixtures:

```swift
SkillLinks.plan(sources:, selection:, workspaces:, targets:, fs:) -> [SkillAction]
```

| Action      | When                                                                                    |
| ----------- | --------------------------------------------------------------------------------------- |
| `link`      | desired at a path where nothing exists                                                  |
| `relink`    | Bastion's link exists but points at another folder (a source moved, precedence changed) |
| `unlink`    | Bastion's link not desired there, or pointing at a skill that no longer exists          |
| `collision` | desired where a foreign entry has the name                                              |

Alongside the actions the plan reports, per target, what it leaves alone:
foreign entries, links into an unavailable source, and shadowed skills. Invalid
skills are never desired anywhere, so they produce no action; the catalog
reports them.

**A source that is unavailable** (folder missing: repo not cloned, volume not
mounted) is not a source whose skills were deleted. Its links are left alone and
reported as "source unavailable". `unlink` for a missing skill applies only when
the source folder itself is present.

### Apply

- Links are absolute. Each is created under a temporary name in the target and
  renamed over the final name, so no reader sees a half-made entry.
- `~/.agents/skills` is created if missing. A Claude Code target is created only
  if its config folder exists. Repository targets are created on demand.
- **Repository targets are excluded from git.** For every link written in a
  repository, a line is added to a Bastion-marked block in
  `<root>/.git/info/exclude` (local, never committed), and removed with the
  link. Without it a `git add .` commits a symlink to `/Users/<me>/…`. Worktrees
  resolve to the main repository, whose `info/exclude` they share.
- Failures are per target: a target that cannot be written shows its error on
  its card and the rest still apply.
- Every applied action is written to the host log (`hostLog("skills", …)`).
  The Activity window is about tool calls and does not show link changes.

### When it runs

At the start of `ClientWiring.rewire`, before its `autoWires` gate (launch
through `migrateKeyScheme`, every profile, server and workspace edit), after
every skill or source edit, and on Rescan. With no source configured the plan is
empty, so the feature is dormant until somebody adds one. A demo or capture run
never reconciles. No file watching, as for Workspaces: edits to a
skill need no reconcile because the link is live, and a new skill starts off
anyway.

**Adding a source is a preview.** The new source's skills are seeded from the
links that already point into it (the targets they are in, and the workspaces
whose repositories hold them), so an already-wired machine plans no changes
except real faults, and the `.agents/skills` half of a repository link that
only had its `.claude/skills` half. The plan is shown and applied only on confirmation. On the
reference machine, adding `claude-skills/global` plans one `unlink`
(`astro-bootstrap`, dangling). The four `~/.agents/skills` collisions appear
when those skills are switched on for Shared.

Repository links are seen only through workspaces: the plan looks in a
repository only when a workspace resolves to it. A link that `projects.links`
made in a repository no workspace covers is neither adopted nor removed. So the
migration creates the workspaces first (`armada`, `bastion`, `cupertino`, `apps`),
then adds the sources, and the seeded selection scopes each existing repository
link to the workspace that reaches it.

## UI

- **Settings → Skills** (configuration group):
  - **Sources**: ordered list, added with `NSOpenPanel` (the kind is inferred:
    a folder holding `SKILL.md` is a `skill`), reorderable, removable.
  - **Skills table**: name, source, validity, description length, scope
    ("Everywhere" or workspace names), one checkbox column per target. The
    Shared column is labelled with the clients that read it.
  - **Per-target card**: foreign entries, collisions with "Overwrite anyway",
    unavailable sources, and the summed description length of what is linked
    there, because every description is in context in every session there.
  - **Rescan**.
- **Workspaces pane**: skill checkboxes beside the profile checkboxes.
- **Claude Desktop client pane**: an **Account skills** card listing
  `~/.claude/skills/synced/` read-only, saying why, and **Export ZIP** for a
  source skill not found there by name.
- `DemoSeed` gains fixture sources and skills; skill names and paths carry
  client names as readily as folder names do.

## Control plane

Beside the workspace tools, same conventions, each ending in a reconcile:

- `list_skills`: name, source, validity, targets, scope, per-target state.
- `update_skill`: set one skill's targets.
- `list_skill_sources`, `upsert_skill_source`, `remove_skill_source`.

Workspace skill scope goes through the existing `upsert_workspace`, whose input
gains an optional `skills`; absent keeps the workspace's current skills, so a
caller written before this change cannot clear them. `list_workspaces` reports
them. `upsert_skill_source` applies without a preview: its reply lists what it
did.

## Out of scope for v1

- Installing skills from GitHub, a registry or a catalog. A source is a folder;
  `git clone` makes one.
- Uploading to claude.ai or `/v1/skills`.
- Per-client control inside a shared folder, including Codex's
  `[[skills.config]] enabled = false`.
- Copying instead of linking. Revisit per target only if a client is measured
  not to follow symlinks.
- Vendor-specific folders (`~/.cursor/skills`, `~/.copilot/skills`,
  `~/.gemini/skills`): every one of those clients reads `~/.agents/skills`.
- Editing skills, and file watching.
- Armada: listing which skills a session loaded and what they cost, from
  `ContextProbe`, is a separate change in that repo.

## To measure before implementation

Each is a probe against the real client, recorded in this file as "measured
`<date>`", as Workspaces did with project blocks:

1. **Duplicates.** VS Code Copilot and Cursor read both `~/.claude/skills` and
   `~/.agents/skills` (and both project folders). With a skill linked into both,
   does it list once or twice? If twice, the Shared column's label says so, and
   the plan is unchanged: Claude Code cannot be served without its own folder.
2. **Symlinks** in VS Code, Cursor and Gemini CLI: is a linked skill folder
   loaded?
3. **Codex** on the installed version: `~/.agents/skills` read, and a new link
   seen after a restart.
4. **Claude Code**: a link added to an existing skills folder is picked up
   without `/reload-skills`; a newly created repository `.claude/skills` is not.
5. **Worktrees.** Claude Code finds skills by walking up from the working
   directory, while Bastion links into the main repository. Is a skill linked
   into `<repo>/.claude/skills` seen in a worktree under
   `<repo>/.claude/worktrees/<name>`, and in one outside the repository? If
   not, v1 says so in the Workspaces pane; linking into worktrees is a later
   change.

## Testing

- `make skills-check`: validation (each frontmatter rule, reserved names);
  `plan` over fixtures (link, relink after a source move, unlink of a dangling
  link, unavailable source left alone, collision, shadowing by order, scoped
  skill removed from global targets and added per project key, same-name skills
  in disjoint workspaces, deduplicated targets through a symlinked folder,
  retired source cleaned then dropped); `info/exclude` block add, remove, and
  every other line byte-identical.
- `make skills-check-real`: plan against the real targets in memory, with
  `~/Projects/claude-skills/global` as the one source, and assert the seeded
  plan changes nothing but dangling links.
- Manual: link one skill globally and one scoped to a workspace, then list
  skills in Claude Code (both config folders), Codex, VS Code and Cursor, in the
  workspace repo and outside it; `git status` in the repo stays clean.

## Retiring the Makefile's linking

Once Bastion owns linking, `~/Projects/claude-skills` keeps `make check` and
drops `install`, `link-external` and `link-projects`; `external.links` and
`projects.links` become sources and workspaces. That change is in that repo, not
this one.
