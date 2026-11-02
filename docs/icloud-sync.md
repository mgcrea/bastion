# iCloud sync of configuration

Settings › General › iCloud › **Sync with iCloud**, off by default. With it on, your servers,
profiles, workspaces and skills follow you to every Mac signed in to the same iCloud account.
Credentials do not sync yet; each Mac asks for its own (phase 3 of the
[design](superpowers/specs/2026-11-01-icloud-config-sync-design.md)).

This page is what is true of the code today. It covers what travels, what waits for a yes, how the
merge decides, and how to check it. The design document is the reasoning; where this page and the
design differ, this page is current and says why.

## What travels and what stays

| Store                | Travels                                                                | Stays on this Mac                                         |
| -------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------- |
| `servers.json`       | which servers exist, a custom server's definition, the switch          | installed code and its version                            |
| `profiles.json`      | name, server, write switch, values that are neither secret nor per-Mac | per-Mac values, `captureMode`, state files children write |
| `workspaces.json`    | everything; folders under home as `~/…`                                | —                                                         |
| `skill-sources.json` | every source and the order; paths under home as `~/…`                  | —                                                         |
| `skills.json`        | `choices`                                                              | `repositoryLinks`, and the links on disk                  |

Never synced: client wiring and lockdown, every Keychain scope (this phase), `call-stats.json`,
`tool-costs.json`, the licence, `dev.json`, `import.json`, internal hosts, server approvals, and
`sync-state.json` itself.

Three calls that differ from the design's table, each because the literal reading loses something:

- **`repositoryLinks` stays local.** It records which links Bastion made or adopted in a repository
  on this Mac, which is what entitles the reconcile to relink or remove them. Synced, Mac B would
  treat a same-named link it never made as its own and remove it. Each workspace's `skills` list
  travels, and each Mac's reconcile makes and records its own links.
- **`captureMode` stays local.** What a profile records is a choice about this Mac's log.
- **Bastion's own server travels as its switch only**, and sync never removes it.

**Per-Mac values** are the catalog variables marked `perMachine` in `servers.json`, plus every
`stateEnv` variable: paths to a key file or kubeconfig, launch arguments, `NPM_BIN`, device and
simulator identifiers. They name code or a path on one Mac, so they are left out of what travels.
A per-Mac name in an arriving profile is ignored, whoever wrote it, and this Mac's own value is
kept. [`SyncProjection`](../apps/apple/Bastion/SyncProjection.swift) holds the rule;
`make servers-check` refuses a new path- or argument-shaped variable that does not say either way.

Secret values never reach iCloud, including one typed into `profiles.json` before its variable
became secret (`BastionServer.shareableValues`), and the write gate is never a value.

## What waits for a yes

Synced data must not choose code or an endpoint on another Mac. A **catalog** server arrives ready:
the package, its version range and its provenance come from the catalog compiled into the app, so
an enabled child is downloaded and a remote one is reachable at once. A **custom** server names its
own package or URL, so one that arrives new or changed waits:

- the sidebar shows an orange arrow, and its page says "From <Mac> through iCloud. It does not run
  on this Mac until you allow it.", with **Install** (child) or **Allow** (remote);
- the supervisor refuses it with that sentence, before anything is spawned or reached;
- `list_servers` and `get_server` carry `awaiting_approval: {from}`.

Approval is per server and per value: allowing `url = X` does not allow a later `url = Y`. A change
made on this Mac, through the window, a tool or a hand edit, counts as allowed here, and switching
sync on allows every custom server already on the Mac. Approvals live in one Keychain item
(`<bundle id>.approvals`, account `servers`), never synced, for the reason internal hosts do: a
file a shell could edit would let an agent forge the yes. See
[`ServerApprovals`](../apps/apple/Bastion/ServerApprovals.swift).

The guard stops at three mechanisms (reserved environment names, per-Mac variables, this wait).
A catalog variable that chooses an endpoint, such as `KEYCLOAK_URL`, travels freely: the owner's
decision of 2026-11-01, recorded in the design.

## How the merge decides

Each entity is one key, `<kind>/<FNV-1a 64 of its id>`, holding an envelope with the full id, a
millisecond timestamp and the Mac it came from. [`ConfigSync.plan`](../apps/apple/Bastion/ConfigSync.swift)
decides per entity against `sync-state.json`, the last version this Mac agreed with the cloud:

- **Last writer wins, per entity**, by time, ties to the Mac name that sorts higher.
- **A deletion is a tombstone**, kept 30 days, so a Mac that was offline does not push back what was
  deleted elsewhere.
- **An older version than this Mac already agreed is pushed back over**, not applied. The key-value
  store keeps the last write per key, not the latest version, and a Mac switching sync on writes its
  keys before it has seen the cloud.
- **Applying never echoes.** What was applied is recorded as agreed, so it is not pushed back.
- **A profile renamed elsewhere is renamed here**, through `was` on the envelope, so this Mac's
  credentials move with it rather than being swept.
- **What this build cannot apply is held**, never deleted: a catalog id it does not ship, a
  definition it refuses, an envelope from a newer Bastion (`v` > 1), which is left byte for byte.
  A later edit here still pushes, carrying forward the fields it did not understand.

And three that protect against wholesale loss:

- **A store that cannot be read** is neither pushed nor applied; Settings names the file.
- **A store file that is missing** while the snapshot remembers entities is filled from the cloud,
  never taken as "everything was deleted".
- **iCloud emptied of Bastion's keys** (another Mac's **Remove from iCloud…**, an iCloud reset)
  pauses sync here and asks: **Put This Mac's Back** or **Turn Sync Off**. Nothing is deleted.

An iCloud account change also pauses and asks: **Merge with This Account** or **Turn Sync Off**.
Pauses survive a relaunch.

A profile **removed** on one Mac is removed on the others with its credentials there, as a removal
on that Mac would be.

## Reading the status line

Settings › General › iCloud shows the last sync and the last five changes brought in, each with
the Mac it came from; any store file it is not syncing; how many keys came from a newer Bastion;
and a paused state with its two buttons. "This build cannot reach iCloud." is a Debug build without
`-syncCloudFile`: only the signed Release build carries the key-value store entitlement.

## Checking it

- `make unit`: the merge, the projections and the approvals, with no app.
- `BASTION_PORT=8799 make sync-check`: the Debug build end to end against a JSON file standing in for
  iCloud (`-syncCloudFile <path>`, Debug builds only). Arrival, sending, a rename, a removal, a
  newer Bastion's key, an idle relaunch, a deleted store file and an emptied cloud. It backs up and
  restores Debug's Application Support and defaults.
- Two Macs, on the signed Release build: pending, recorded below once run.
