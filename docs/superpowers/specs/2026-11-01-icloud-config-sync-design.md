# iCloud sync of Bastion's configuration

Status: approved design, 2026-11-01. Implementation plan for phases 0a and 0:
`docs/superpowers/plans/2026-11-01-icloud-config-sync.md`. Phases 1–3 are
planned once phase 0's gate has passed. Builds on `docs/keychain.md`, whose data
protection keychain migration and `.profile`-only sync rules this document
adopts unchanged and schedules.

## What the owner asked for

"Could we have iCloud sharing of our config across Macs?" Set Bastion up once,
and have the same servers, profiles, workspaces and skills on every Mac signed
in to the same iCloud account, credentials included.

Approved in conversation: the design below, with one change made by the owner —
**a server's on/off state follows the sync**, so a server enabled on one Mac
arrives enabled on the others.

## Goals

- The configuration a person types follows them between their Macs: servers,
  their definitions and on/off state, profiles and their values, profile
  secrets, workspaces, skill sources and skill choices.
- Off by default, one switch in Settings, and turning it off leaves every Mac
  with a working local copy.
- A Mac that was offline for a week comes back without resurrecting what was
  deleted elsewhere or overwriting newer edits wholesale.

## Non-goals

- iPhone or iPad. Bastion is Mac only; nothing here is shaped for iOS.
- Sharing between people or iCloud accounts. One account, one person's Macs.
- Syncing machine-bound state: installed code, client wiring and lockdown,
  gateway bearer tokens, OAuth token sets, children's own state files, the
  audit signing key, internal hosts, call stats, tool costs, the licence.
- A sync history or undo beyond what each store already offers.

## Anti-goals

- **A write to one Mac's files must not choose code that runs on another.** An
  agent with a shell can edit `servers.json` or call `add_custom_server` on Mac
  A today. Sync must not turn that into code chosen by that agent running on
  Mac B without a person on Mac B saying yes. See "The guard".
- **No credential leaves the Keychain.** Secrets never pass through the
  key-value store, a file, or a log line, in either direction.
- **No silent wholesale loss.** The `StoreFile` rule holds across sync: a store
  that is unreadable locally is neither pushed nor written over by a pull.
- **The Debug build never touches the release build's iCloud data**, the same
  isolation the `.debug` bundle identifier gives the Keychain and Application
  Support today.

## Constraints

- Developer ID signed and notarized, distributed outside the App Store
  (`cut-a-release`). iCloud key-value storage and keychain sharing both need a
  **Developer ID provisioning profile** embedded at
  `Contents/embedded.provisionprofile` and a registered App ID with both
  capabilities. Nothing in this account has shipped one yet (`docs/keychain.md`,
  "Restricted vs unrestricted entitlements").
- This ends the "the app carries no entitlements" claim, on purpose (decided
  2026-08-31). `make sign` and `scripts/audit-listener.sh` assert it today; both
  are rewritten to assert the entitlement set is **exactly**
  `keychain-access-groups` and `com.apple.developer.ubiquity-kvstore-identifier`
  (plus the team identifier key the profile requires), still checkable.
- `NSUbiquitousKeyValueStore` limits: 1 MB total, 1024 keys, 1 MB per value.
  Today's stores are about 15 KB across roughly 80 entities.
- Key-value storage is encrypted by Apple, not end to end unless the account
  has Advanced Data Protection. Profile values that are not secret (issuer IDs,
  key IDs, account names, URLs) will sit there. The Settings copy says so.
- Every new file that is pure logic stays Foundation-only so
  `scripts/unit-check.swift` can compile it, as `StoreFile` does.

## Decisions

### Two transports

| What                                                                            | Transport                                                                        |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| Profile secrets (`CredentialStore.Scope.profile`)                               | iCloud Keychain: `kSecAttrSynchronizable = true` in the data protection keychain |
| Servers, profiles (non-secret fields), workspaces, skill sources, skill choices | `NSUbiquitousKeyValueStore`, one key per entity                                  |

Rejected: CloudKit / `CKSyncEngine` (a schema, zones and an `aps-environment`
entitlement for 15 KB of JSON); a JSON file in iCloud Drive (whole-file
conflicts, a TCC prompt on `~/Library/Mobile Documents`); configuration as
keychain items like `InternalHostStore` (no change notification, whole-blob
last writer wins).

### What syncs

| Store                | Synced                                                             | Stays on this Mac                                                               |
| -------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| `servers.json`       | which servers exist, custom `definition`, `enabled`                | installed code and its version                                                  |
| `profiles.json`      | `name`, `server`, `values` except per-Mac variables, `allowWrites` | per-Mac variable values; `profiles/<server>/<name>/` state files children write |
| Keychain `.profile`  | every value                                                        | —                                                                               |
| `workspaces.json`    | every field; folder paths under the home folder stored as `~/…`    | —                                                                               |
| `skill-sources.json` | every field and the order; paths as `~/…`                          | —                                                                               |
| `skills.json`        | `choices`, `repositoryLinks` (paths as `~/…`)                      | the links on disk, which each Mac's reconcile makes                             |

Not synced at all: client wiring and lockdown, `.gateway`, `.oauth`, `.audit`,
`.internal-hosts`, `call-stats.json`, `tool-costs.json`, the licence, `dev.json`,
`import.json`.

Internal hosts are deliberately local: that list widens what remote servers may
reach, and syncing it would let a compromise of one Mac widen it on all.

A synced folder that does not exist on this Mac is kept and shown as missing,
the way a workspace folder that has been moved is shown today. It contributes
nothing to wiring or to the skills reconcile until it exists.

### Keys and values

Entities: servers by id, profiles by `<server>/<name>`, workspaces by name,
skill sources by name, skill choices by skill id, repository links by path, and
one `order/skillsources` entity for the skill-source order, which decides which
skill wins a name clash (`SkillStore.move(_:by:)`). The server list has no
stored order (`ServerStore.sort()` is alphabetical, Bastion first), so none is
synced.

Key-value store keys are limited to 64 bytes, and profile ids and paths can
exceed that. So each key is `<kind>/<hash of identity>`, a short stable hash
(builder's choice of function), and the full identity lives in the envelope.

Each value is a small JSON envelope:
`{ "v": 1, "kind": "profile", "id": "<full identity>", "at": <ISO 8601 modified time>, "from": <Mac name>, "deleted": false, "entity": { … } }`.

- **Per-entity last writer wins**, by `at`. Ties break on `from`, so every Mac
  picks the same winner.
- **Deletion writes a tombstone** (`deleted: true`, no `entity`) instead of
  removing the key, so a Mac that was offline does not push back what was
  deleted elsewhere. Tombstones older than 30 days are removed by whichever Mac
  sees them first.
- **Rename** (`ProfileRename`, a workspace rename) is a tombstone for the old
  key and a new entity, written together. The Keychain side of a profile rename
  already moves the items.
- `v` is the envelope version. A Mac that meets a higher `v` than it knows
  leaves that key alone and says "updated on a newer Bastion" in the status
  line, rather than decoding it lossily and writing it back.
- **An older Bastion never deletes what it does not understand.** An older
  build drops catalog ids it does not ship (`ServerStore.resolve`) and fields
  it does not know. Neither may sync as a deletion or as a rewrite: a remote
  entity this build cannot resolve is held in the snapshot as it arrived and
  never tombstoned by this Mac, and a push of an entity this Mac did change
  carries forward any fields it did not decode from the version it pulled.

### When it runs

- **Push.** Each store's `save()` already runs after every edit. After a
  successful save, the sync layer diffs the store against the snapshot it last
  pushed and writes only the changed entities. Hand edits to the JSON files are
  picked up the same way at launch: they are local edits, pushed like any
  other, and the guard below is what keeps that from being dangerous.
- **Pull.** On `NSUbiquitousKeyValueStore.didChangeExternallyNotification`, and
  once at launch after `synchronize()`, the changed keys are merged into the
  local stores through the stores' own mutation paths, so wiring, the skills
  reconcile, and the supervisor react exactly as they do to a local edit.
- **Nothing is pulled into an unreadable store.** If a store is in
  `StoreFile.Loaded.unreadable`, its keys are neither pushed nor applied until
  it is fixed, and the status line names it.
- **Account change** (`NSUbiquitousKeyValueStoreAccountChange`): sync pauses
  and Settings asks whether to merge with the new account or turn sync off. It
  never merges into a different account's configuration silently.
- **Quota violation**: sync pauses and says so. At today's sizes it should not
  happen.

### On/off state follows, and arrival behaviour

Per the owner: `enabled` is part of the synced entity. A server enabled on Mac
A arrives enabled on Mac B, and turning one off anywhere turns it off
everywhere.

What happens when an enabled server arrives on a Mac:

- **Catalog server, child (npm).** Installed automatically, then started. The
  package, version range and provenance come from the catalog compiled into the
  app, not from the synced data, so nothing synced chooses the code.
- **Catalog server, remote.** Reachable at once. The endpoint is the catalog's.
- **Custom child (npm package named in `definition`).** Arrives enabled but not
  installed, and shows "From <Mac>, install?" in the sidebar. Installing needs a
  click on this Mac.
- **Custom remote (URL named in `definition`).** Held, not reachable, with the
  same "From <Mac>, allow?" until a click on this Mac.
- **A profile that arrives for a catalog server with per-Mac variables** (see
  the guard) starts without those values on this Mac, and shows as needing
  them if they are required, the same state as a missing credential.

### The guard

Synced data must not be able to choose code or an endpoint on another Mac.
Three mechanisms close every route found in review; together they are the
guard, and the builder keeps it to these:

1. **Reserved environment names are refused, in every build, sync or not**
   (owner's decision, 2026-11-01). Today `ProfileEnvironment.build` merges
   profile values last, so a value wins over `PATH`
   (`Profiles.swift`, `env.merge(values(…)) { _, resolved in resolved }`), and
   a custom definition's `env` accepts any `^[A-Z][A-Z0-9_]*$` name, including
   `NODE_OPTIONS`. A fixed reserved set — `PATH`, `HOME`, `NODE_*`,
   `npm_config_*` / `NPM_CONFIG_*`, `DYLD_*`, `XDG_*` (the builder may add
   names of the same kind, never remove) — is refused when a custom definition
   declares it (save fails with a sentence naming the variable) and skipped,
   with a log line, if a hand-edited custom row carries one. The values Bastion
   itself sets for those names always win. A profile can only set names its
   server declares (`ProfileEnvironment.values` drops the rest), so for a
   catalog server the catalog is the only source of a reserved name, and the
   catalog is compiled into the app: catalog-declared names are exempt, and
   the generator allows a reserved name in the catalog only as a per-Mac
   variable (npm's `NPM_CONFIG_USERCONFIG`, in its `stateEnv`, is the one
   today). This ships as its own change before any sync code (phase 0a) and is
   worth having without sync.
2. **Per-Mac catalog variables never sync.** A catalog variable gains a
   per-Mac flag when its value names code, a launch argument or a local path:
   `NPM_BIN`, `IOS_DEVICE_LAUNCH_ARGS`, `IOS_SIMULATOR_LAUNCH_ARGS`, every
   `*_PATH`, and any other the builder finds of the same kind while auditing
   the catalog. Every `stateEnv` variable is per-Mac without saying so: each
   is a path into this Mac's profile directory. Their values stay in the local `profiles.json`, are left out of
   the synced entity, and are preserved locally when a pulled profile is
   applied. `make catalog-check` (or the existing catalog checks) should fail on
   a new variable named like a path or launch-argument variable that lacks a
   decision either way.
3. **A custom server's package or URL needs a local yes when it arrives new or
   changed:** a custom `npmName`/`binName` or `url`, as in the arrival rules
   above.

Everything else, `enabled` and the remaining profile values included, follows
the sync freely. Approval is remembered per Mac, per server, per value: approving
`url = X` does not approve a later `url = Y`.

**The guard stops here** (owner's decision, 2026-11-01, after phase 0's review
raised it). A catalog variable that chooses an endpoint — `KEYCLOAK_URL`,
`GRAFANA_URL`, `NPM_REGISTRY`, `UNIFI_HOST` — syncs freely, even though an agent
on one Mac could use it to point another Mac's server, credentials included, at
a host of its choosing. The reasoning: this is one person's own devices on one
iCloud account, and an agent able to do that on one Mac already holds those
credentials there. The same goes for a custom server's variable names: no
approval beyond mechanism 3. Phase 2 does not add a fourth mechanism.

Separately from security, a value that is meaningless on another Mac — a
simulator or device UDID (`IOS_SIMULATOR_ID`, `IOS_DEVICE_ID`), a keychain
service name on this Mac (`NPM_TOTP_KEYCHAIN_SERVICE`), a `sqlite:` path in a
DSN — is per-Mac by function, and phase 2 marks it `perMachine` when it audits
the catalog, by the rule in mechanism 2.

Approval state is local only and never synced, or approving on one Mac would
approve on all and the guard would mean nothing. Where it is stored is left to
the builder, with one requirement: an agent with a shell must not be able to
forge an approval by editing a file. The internal-host list solved the same
problem with a Keychain item (`InternalHostStore`); that is the expected
answer.

**Changes made on this Mac count as approved on this Mac** (my call): a
custom server added or edited here, through the UI, Bastion's MCP tools or a
hand edit, runs here as it does today, and only arrivals from another Mac wait
for a click. An agent on Mac B re-saving a pending value through
`update_server` therefore approves it on B, which grants nothing new: that
agent could already add the same server on B directly. When sync is first
switched on, every custom server already on the Mac is recorded as approved
for its current values.

### Secrets

Exactly as `docs/keychain.md` describes, scheduled here:

- `.profile` items gain `kSecAttrSynchronizable = true` when sync is on, and
  drop `ThisDeviceOnly` (becoming `AfterFirstUnlock`). The comment in
  `CredentialStore.write` that says a gateway credential has no business
  syncing is rewritten to say which scopes sync and why.
- Every query uses `kSecAttrSynchronizableAny`, so presence checks, listing,
  and profile deletion see synced and unsynced items alike.
- **Which copy is read** (my call). A Mac can hold a synced and a local item
  for the same secret: at first switch-on, after switch-off, and on any Mac
  with Bastion's sync off but iCloud Keychain on, which receives synced items
  regardless. With Bastion's sync on, the synced item is read; with it off,
  the local item is read, falling back to the synced one only if there is no
  local item.
- **Switch-on**: for each `.profile` secret, if only a local item exists it is
  added as a synced item, then the local item is deleted. If both exist with
  different values, the one with the newer `kSecAttrModificationDate` wins and
  becomes the synced item; the first-switch-on sheet lists the secret's name
  (never its value) when the iCloud copy won.
- **Switch-off never deletes a synced item**, because deleting one deletes it
  on every Mac. It adds a local copy of each synced secret (add-first) and
  leaves the synced items alone. Only "Remove from iCloud", which asks first,
  deletes synced items.
- `.gateway`, `.oauth`, `.audit` and `.internal-hosts` never sync.
- iCloud Keychain being off on a Mac cannot be detected. Settings says
  "credentials sync only when iCloud Keychain is on" rather than implying a
  check. A synced profile whose secrets have not arrived shows as needing
  credentials, the state it already has today when a value is missing.

### Settings

A "Sync with iCloud" section, off by default:

- The switch.
- A status line: last sync time, the Mac each recent change came from,
  paused-and-why when paused.
- The two honest sentences: profile values sit in iCloud encrypted by Apple
  (end to end only with Advanced Data Protection); credentials go through
  iCloud Keychain and sync only when it is on.
- **First switch-on on a Mac that has configuration while iCloud also has
  some:** union by entity; where both have the same entity, the newer `at`
  wins; then a one-time sheet lists what was taken from iCloud over a local
  version, so nothing changes unseen. Entities that exist only locally are
  given `at` = their store file's modification time.
- **Switching off:** stops pushing and pulling, keeps everything local. A
  separate "Remove from iCloud" button writes nothing new, removes Bastion's
  keys from the key-value store, and turns every `.profile` item back into a
  local one. It asks first, because other Macs still syncing will see
  everything deleted.

### Demo and Debug

- `DemoSeed.isEnabled`: the sync layer does nothing, read or write, as
  `CredentialStore` already refuses.
- Debug builds have their own key-value store and keychain group through the
  `.debug` bundle identifier. No extra code.

## Phases

0a. **Environment hardening**, guard mechanisms 1 and 2 (the reserved-name
refusal and the per-Mac catalog flag, the flag doing nothing yet but
documenting itself). No entitlement, no sync; ships first. 0. **Prove the gate before writing sync code.** Register the App ID with
iCloud (key-value storage) and keychain sharing, create the Developer ID
provisioning profile, embed it in `make build-release`/`make sign`, rewrite
the two entitlement assertions. Then, on a signed build: a data protection
`SecItemAdd` returns `errSecSuccess` (not `-34018`), and a key-value round
trip between two Macs succeeds. Settle `docs/keychain.md`'s open question of
what happens to stored credentials when the embedded profile expires, and
write the answer there.
_If keychain sharing turns out not to be available to Developer ID_, phases
1 and 3 are dropped and phase 2 still ships: configuration syncs, and each
Mac asks for its own credentials.

1. **Data protection keychain migration**, per `docs/keychain.md`: the one-time
   round of ACL prompts, then no more. `kSecAttrSynchronizableAny` everywhere.
   Ships on its own, with sync still absent.
2. **Configuration sync** through the key-value store, including the guard,
   the Settings section, first-switch-on merge, account change and tombstones.
3. **Secrets sync**: `.profile` items follow the switch.

Each phase is a release on its own; CHANGELOG entries per phase.

## Left to the builder

- The module layout. Expected: a Foundation-only merge core
  (`ConfigSync.merge(local:remote:snapshot:)` or similar, unit-checked through
  `scripts/unit-check.swift`) and a thin `@MainActor` layer that talks to
  `NSUbiquitousKeyValueStore` and the stores.
- Where the last-pushed snapshot lives (Application Support is fine: it is a
  cache, and losing it only causes a re-push).
- How each store exposes "apply this remote entity" without re-triggering a
  push of the same entity.
- Debouncing pushes during bursts (a workspace drag can save several times).
- The exact sidebar and Settings copy, within the sentences above.
- Whether `bastion` (the built-in server, `id: "bastion"`, no definition) is a
  synced entity at all. It exists on every Mac, so only its `enabled` would
  carry.
- Tests: the merge core exhaustively (ties, tombstones, offline Mac, newer
  envelope version, unreadable store, rename); the guard's approval logic; the
  keychain phase against the real Keychain on a signed build only.
