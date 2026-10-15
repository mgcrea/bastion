# Rename a profile

Status: approved design, 2026-10-14. Implementation plan: not yet written.

## Problem

A profile cannot be renamed. The editor says so
(`ProfileEditor.swift:121-130`) and sends people to remove the profile and add
another, which loses its secrets, its OAuth authorization, the logins its child
keeps in its state directory, its workspace membership and its history.

The refusal exists because the name is not a label. `<name>/<server>` is the
profile id, a URL path segment, a Keychain account prefix and a directory name
(`Profiles.swift:14-15`, `ServerStore.swift:560-566`). Renaming means moving
each of those.

Goal: a rename that keeps everything the profile owns. Only its name, its
endpoint and its client entry key change.

## What holds the name

| Where | Keyed by | Storage | On rename |
| --- | --- | --- | --- |
| `profiles.json` (`ProfileStore`) | name + server | disk | rewritten |
| Keychain `.profile` scope | `<name>/<server>/<VAR>` | Keychain | copied, then old deleted |
| Keychain `.oauth` scope | `<name>/<server>/oauth` | Keychain | copied, then old deleted |
| State directory `profiles/<server>/<name>` (child logins, `callback-port`, cache) | name | disk | moved |
| `workspaces.json` `profiles` | id | disk | id substituted |
| `tool-costs.json` (`ToolCostStore`) | id | disk | measurement moved |
| `call-stats.json` (`CallStats`) | profile + server | disk | rows re-keyed, merged on collision |
| Client configs | entry key `<prefix><name>-<server>`, URL `/s/<name>/<server>` | other apps' files | rewired with `retiring: [oldID]` |
| `Supervisor`, `ChildLifecycle`, `RemoteOAuthSession` gates | id | memory | child stopped; state rebuilt on next start |
| `ServerCheck`, `CapabilityStore` | id | memory | forgotten |
| Audit chain `origin` | id, inside hashed lines | disk | **not moved**: rewriting breaks the chain |
| `LogStore` origin | id | memory | not moved: lines record what happened |
| OAuth dynamic registration `client_name` | id | upstream | not moved: cosmetic |

`ClientLockdown` (`/s/*` wildcard, keyed by client), `ClientProfiles` (Claude
Code config dirs), `ToolFacade` overrides (keyed by client) and skills do not
key on a Bastion profile.

## Design

### `ProfileStore.rename(_ profile: Profile, to newName: String) throws`

The one implementation. The UI and the MCP tool both call it, the way they
both call `upsert` and `remove`. The steps are ordered so that a failure
before step 5 leaves the old profile exactly as it was.

1. **Validate.** `Profile.isValidName(newName)`, `newName != profile.name`, and
   no profile `newName/<server>` in `profiles` *or* `orphaned`: an orphaned
   row's Keychain entries are live and would be overwritten. Throws a typed
   error with a sentence for each case.
2. **Quiesce.** `Supervisor.shared.stop(profile:server:)` on the old name, so
   nothing holds the state directory or the old credentials.
   `ServerCheck.shared.forget(oldID)` and `CapabilityStore.shared.forget(oldID)`.
   `ToolCostStore` gains `move(from:to:)`: the tool surface is unchanged, so
   the measurement stays valid under the new id.
3. **Copy Keychain items.** Every `.profile` and `.oauth` account with prefix
   `old/server/` is read and written under `new/server/` with the same suffix.
   If any write fails, the copies already made are deleted and the error is
   thrown. Reading may raise Keychain prompts; acceptable for an action the
   user started.
4. **Move the state directory**, if it exists. If something already sits at
   the destination (left by a removed profile of that name, since `remove` does
   not delete its directory), it goes to the Trash first: inheriting a dead
   profile's tokens is the bug, and the Trash keeps it recoverable. If the
   move fails, the Keychain copies are deleted and the error is thrown.
5. **Commit the profile.** Replace the entry in `profiles` at the same index
   with a `Profile` carrying the new name and every other field unchanged,
   then `save()`. This publishes the snapshot: the gateway serves the new URL
   and answers the old one with `unknownProfile`.
6. **Delete the old Keychain items.** Failures are logged with `hostLog`, not
   thrown: the rename has happened, and a leftover item is inert.
7. **Workspaces.** `WorkspaceStore.renameProfile(from:to:)` substitutes the id
   in every workspace containing it, saves once and rescans, without its own
   rewire (step 9 does that). The auto-join in `upsert` does not apply: a
   rename is not a creation.
8. **Call stats.** `CallStats.renameProfile(from:to:server:)` re-keys the
   `calls`, `clients`, `life` and `labels` tables under the lock and marks the
   table dirty so the next flush writes it. When the new key already holds
   rows (a removed profile of that name; `remove` does not purge stats), they
   merge through `Bucket.merge` and `LifeRow.merge`, never overwrite. The
   re-keying itself is a pure helper in `CallStatsRollup` so `make unit` can
   compile it.
9. **Rewire.** `ClientWiring.rewire(retiring: [oldID])`. The endpoint changes,
   so `merged` will not drop the old key on its own; naming it in `retiring`
   leaves one entry per client, not two. Project blocks reconcile from the
   updated workspaces.

Known consequences, stated in the UI and the tool description:

- The client entry key changes, and with it the tool namespace
  (`mcp__bastion_<name>-<server>__…`). Permission rules that name the old one
  stop matching.
- Per-entry fields a user set on the old entry (`disabled`, a timeout) survive
  a rewrite only when the key is unchanged, so they are lost.
- A client configured by hand, outside Bastion, still points at the old URL.

### UI

- **Rename…** button in `ProfileRow` (`ServerDetail.swift`, beside Edit…). It
  opens an alert with a text field prefilled with the current name, validated
  on each keystroke with the editor's rule and messages, and the consequences
  above in one short paragraph. Confirm calls `ProfileStore.rename`; an error
  is shown in the same alert style `remove()` uses.
- Kept out of `ProfileEditor`: its sheet is keyed by `profile.id` and its
  save writes secrets under the name, so a rename inside it invites a
  half-saved state. The editor's "cannot be renamed" caption, and the
  new-profile caption saying the name "is fixed once created", are rewritten
  to point at Rename….

### MCP tool

`rename_profile {server, name, new_name}` in `BuiltinTools.swift`, declared and
implemented beside `remove_profile`. Validation errors come back as tool
errors with the same sentences. The reply carries the new endpoint, like
`upsert_profile`'s.

`server_stats` and `recent_activity` scope a Bastion-server caller by profile
name. After a rename, stats history follows (step 8); earlier log lines in
memory do not. Documented, not changed.

### Docs

- `docs/keychain.md`: a rename moves a profile's items to the new prefix.
- `docs/clients.md` stale-entries table: the row claiming renames are handled
  by `merged` applies to key-scheme renames only; a profile rename changes the
  endpoint and relies on `retiring`.
- `CHANGELOG.md`: entry under Unreleased.

## Testing

- **`make unit`** (`scripts/unit-check.swift`): the `CallStatsRollup` re-key
  helper. Plain re-key; merging into rows a removed profile left under the new
  name; rows of another server with the same profile name untouched.
- **`make wiring-check`** (`scripts/wiring-check.swift`): workspace id
  substitution (swapped in each workspace containing it, no duplicate when the
  new id is already present); `merged` with `retiring: [old]` and the new
  endpoint yields exactly one entry.
- **`make builtin`** (`scripts/builtin-check.sh`), against the running app:
  create scratch `checkro`, `set_credential`, `rename_profile` to `checkro2`;
  `list_profiles` shows `checkro2` with nothing missing; a request to
  `/s/checkro/...` is refused; renaming onto an existing name is refused;
  clean up.
- **By hand**: rename an OAuth profile and one whose server keeps a child
  login (Reddit or X); both work without signing in again.

## Out of scope

- Renaming a server: still refused (`ServerStore.renameWouldStrand`).
- `remove` leaving its state directory and stats behind: a separate bug,
  noted here only. This design copes with the leftovers rather than fixing
  their cause.
- Rewriting hand-made client entries.
