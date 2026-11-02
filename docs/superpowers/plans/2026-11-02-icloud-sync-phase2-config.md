# iCloud config sync, phase 2: configuration through the key-value store — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Servers and their on/off state, profiles and their non-secret values, workspaces, skill sources and skill choices follow the person between their Macs through `NSUbiquitousKeyValueStore`. Sync is off by default and switched on in Settings, and synced data never chooses code on another Mac without a click there.

**Architecture:** A Foundation-only core (`ConfigSync`) owns keys, envelopes and the per-entity merge decision, and `make unit` checks it exhaustively. Each store projects its rows to synced entities, and applies remote ones through its own mutation paths, in a `// MARK: - Sync` section of its own file. A `@MainActor` engine (`ConfigSyncEngine`) talks to a `SyncCloud` backend: `NSUbiquitousKeyValueStore` in the entitled Release build, and a JSON file in Debug when given `-syncCloudFile`, which `make sync-check` drives end to end. Approvals for custom servers that arrive from another Mac live in a Keychain item, and the supervisor refuses a server that is still waiting for one.

**Tech Stack:** Swift 6 / SwiftUI, `NSUbiquitousKeyValueStore`, Security (`CredentialStore`), SystemConfiguration (`SCDynamicStoreCopyComputerName`), `scripts/unit-check.swift`, bash + `curl` for `scripts/sync-check.sh`, Make.

**Spec:** `docs/superpowers/specs/2026-11-01-icloud-config-sync-design.md`, section "Phases" item 2 and every section it names. Phase 1 (`docs/superpowers/plans/2026-11-01-icloud-sync-phase1-keychain.md`) is merged at `c1bcd68` and unreleased. Phases 1 and 2 ship together as one release (owner, 2026-11-02).

## Decisions this plan makes that the spec left open or got wrong

1. **`repositoryLinks` stays local** (a change to the spec's "What syncs" table). It records which links Bastion made or adopted in a repository on this Mac, and it is what lets the reconcile relink or remove them. Synced, Mac B would treat a same-named link it never made as its own and remove it. Each workspace's `skills` list syncs, and each Mac's reconcile makes and records its own links.
2. **`captureMode` stays local.** The spec's table lists `name`, `server`, `values`, `allowWrites`. What a profile records is a choice about this Mac's log.
3. **`bastion` (the built-in server) syncs its `enabled` only**: `{"enabled": Bool}`, never removed by sync.
4. **The cloud emptied.** If every sync key is gone from the cloud while this Mac's snapshot holds live entities, sync pauses with `cloudEmptied` and Settings asks: put this Mac's configuration back in iCloud, or turn sync off. A single key that vanishes while others remain is a remote deletion. This is the spec's anti-goal "No silent wholesale loss", applied to another Mac's "Remove from iCloud" and to an iCloud reset.
5. **A store file that is missing while the snapshot holds live entities** (deleted by hand, or a fresh Application Support on an old snapshot) pushes nothing for that kind. It is filled from the cloud instead. Otherwise one deleted file would tombstone that kind on every Mac.
6. **Profile renames carry `was`.** The push infers a rename when one profile id disappears and another appears in the same diff with the same `server`, `values` and `allowWrites`. It writes the new entity's envelope with `"was": "<old id>"` beside the old id's tombstone. A Mac that holds the old id locally applies it as `ProfileStore.rename`, so its own Keychain items move with it rather than being swept by a removal.
7. **Approvals are one Keychain item:** scope `.approvals`, service `<base>.approvals`, account `servers`, holding JSON `{"approved": {id: [value]}, "pending": {id: {"value", "from"}}}`. A value is `npm:<npmName>|<binName>` or `url:<url>`. It mirrors `InternalHostStore`. It is not in `credentialScopes`, because phase 1's migration has nothing of it to move.
8. **Keys** are `<kind>/<16 lowercase hex of FNV-1a 64 of the full id>`. **`at`** is ISO 8601 UTC with milliseconds, compared as dates and matched as strings. **`from`** is `SCDynamicStoreCopyComputerName`, falling back to `"a Mac"`. Pushes are debounced by 1 s.
9. **Debug has no entitlement**, as in phase 1. In a `#if DEBUG` build, `-syncCloudFile <path>` (argument domain only) selects a JSON-file cloud. Without it, a build lacking `com.apple.developer.ubiquity-kvstore-identifier` shows the switch disabled: "This build cannot reach iCloud."
10. **`DSN` (sql) is not marked per-Mac.** It is a secret, so it never reaches the key-value store, and phase 3 owns it.

## Global Constraints

- Work in `.claude/worktrees/icloud-sync-phase2` on branch `icloud-sync-phase2`. Never switch branches in the shared checkout.
- The key-value store never holds a secret. `ProfileEnvironment` secrets stay in the Keychain, and `.profile` items stay unsynchronizable in this phase.
- Limits: 1 MB total, 1024 keys, 64-byte keys. Envelope version `v` is `1`. Tombstones older than 30 days are pruned.
- Kinds, as raw values: `server`, `profile`, `workspace`, `skillsource`, `skillchoice`, `order`. The single order entity's id is `skillsources`.
- Paths under the home folder are stored as `~/…` (workspace folders, skill source paths) and expanded on apply. Paths outside it stay absolute.
- A store in `StoreFile` unreadable state is neither pushed nor applied, and the status line names its file.
- `DemoSeed.isEnabled`: the engine never starts, reads or writes.
- No credential value and no profile value in any log line. Ids, kinds and counts only.
- New pure files are Foundation-only and join the `unit:` list in the Makefile.
- Before each commit: `make format`. `make unit`, `make builtin`, `make audit` and `make sync-check` run with `BASTION_PORT=8799`, after checking that `lsof -nP -iTCP:8799 -sTCP:LISTEN` is silent. Production Bastion holds 8720.
- Never `make stop` / `make run` against the Release build, and never launch this branch's Release build as the full app on this Mac or `eva` until Task 10, with the owner's yes.

## Review Focus

1. **A store file deleted or replaced by hand while sync is on.** Nothing is tombstoned, and the kind is filled back from the cloud. Test: Task 2 Step 1 (`localMissing`), Task 9 (`sync-check` deletes `workspaces.json` and relaunches).
2. **Another Mac's "Remove from iCloud", or an iCloud reset.** This Mac pauses and asks. It does not delete its configuration. Test: Task 2 Step 1 (`cloudEmptied`), Task 7 Step 1.
3. **A remote entity this build cannot apply**: a catalog id it does not ship, a `v` of 2, or a custom definition `upsert` refuses. It is held, never tombstoned, and never rewritten, and a later local edit of the same id still pushes, carrying the unknown fields forward. Test: Task 2 Step 1 (held, carry-forward), Task 9 (a `v: 2` key unchanged byte for byte).
4. **A profile renamed on another Mac.** This Mac renames it, and its Keychain items move rather than being swept. Test: Task 3 Step 1 (rename inference), Task 9 (rename through `rename_profile`, then the envelope carries `was`).
5. **The echo.** Applying a remote change must not push it back, so two Macs do not ping-pong, and a workspace drag's burst of saves becomes one push. Test: Task 2 Step 1 (apply then re-plan is empty), Task 9 (a relaunch with nothing changed leaves the cloud file byte-identical).

---

### Task 1: `JSONValue`, keys and the envelope

**Files:**

- Create: `apps/apple/Bastion/ConfigSync.swift` (Foundation only)
- Modify: `Makefile` (`unit:` list, after `StoreFile.swift`)
- Test: `scripts/unit-check.swift` (new `configSyncEnvelope()` section, called from `main`)

**Interfaces:**

- Produces:
  - `nonisolated enum JSONValue: Codable, Hashable, Sendable { case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue]) }`, plus `init<T: Encodable>(encoding: T) throws` and `func decode<T: Decodable>(_: T.Type) throws -> T`. `.object` keys decode in any order, and equality is structural.
  - `nonisolated enum ConfigSync` with `static let version = 1`, `static let tombstoneLifetime: TimeInterval = 30 * 24 * 3600`.
  - `enum Kind: String, Codable, CaseIterable { case server, profile, workspace, skillSource = "skillsource", skillChoice = "skillchoice", order }`
  - `static func key(_ kind: Kind, id: String) -> String`: `"\(kind.rawValue)/" + 16 hex FNV-1a 64 of id's UTF-8`.
  - `static func isSyncKey(_ key: String) -> Bool`: the prefix is a known kind and 16 hex digits follow.
  - `struct Envelope: Codable, Equatable { var v: Int; var kind: Kind; var id: String; var at: String; var from: String; var deleted: Bool; var entity: JSONValue?; var was: String? }`. `entity` is nil exactly when `deleted`.
  - `static func timestamp(_ date: Date) -> String` and `static func date(_ at: String) -> Date?`: ISO 8601, UTC, fractional seconds.
  - `static func wins(_ a: (at: String, from: String), over b: (at: String, from: String)) -> Bool`: the later date wins, and a tie goes to the `from` that sorts higher.

- [ ] **Step 1: Write the failing checks**

```swift
static func configSyncEnvelope() {
  print("\nConfig sync: keys and envelopes")
  let long = String(repeating: "a-very-long-profile-name/", count: 6) + "server"
  let key = ConfigSync.key(.profile, id: long)
  check("a key fits the 64-byte limit however long the id", key.utf8.count <= 64)
  check("a key is stable", key == ConfigSync.key(.profile, id: long))
  check("kinds do not share keys", ConfigSync.key(.server, id: "x") != ConfigSync.key(.profile, id: "x"))
  check("a sync key is recognised", ConfigSync.isSyncKey(key))
  check("the probe's key is not a sync key", !ConfigSync.isSyncKey("bastion.icloud-probe"))
  let at = ConfigSync.timestamp(Date(timeIntervalSince1970: 1_800_000_000.123))
  check("timestamps keep milliseconds", at.hasSuffix(".123Z"))
  check("a later time wins", ConfigSync.wins((at: "2026-11-02T10:00:01.000Z", from: "A"), over: (at: "2026-11-02T10:00:00.000Z", from: "Z")))
  check("a tie goes to the higher Mac name, on every Mac",
    ConfigSync.wins((at: at, from: "Mac B"), over: (at: at, from: "Mac A"))
      && !ConfigSync.wins((at: at, from: "Mac A"), over: (at: at, from: "Mac B")))
  let value = try! JSONValue(encoding: ["b": 1, "a": 2])
  check("JSON objects compare by content", value == (try! JSONValue(encoding: ["a": 2, "b": 1])))
  let envelope = ConfigSync.Envelope(v: 1, kind: .workspace, id: "rgis", at: at, from: "A", deleted: true, entity: nil, was: nil)
  let round = try! JSONDecoder().decode(ConfigSync.Envelope.self, from: JSONEncoder().encode(envelope))
  check("an envelope round-trips", round == envelope)
}
```

- [ ] **Step 2: Run it to make sure it fails.** Run `make unit`. Expected: a compile error, because `ConfigSync` isn't defined.
- [ ] **Step 3: Implement** the interfaces above in `ConfigSync.swift`, with a doc comment that points at the spec.
- [ ] **Step 4: Run it to make sure it passes.** Run `make unit`. Expected: every check passes, the previous 847 included.
- [ ] **Step 5: Commit** `feat(sync): keys, envelopes and a JSON value for configuration sync`.

### Task 2: The merge decision

**Files:**

- Modify: `apps/apple/Bastion/ConfigSync.swift`
- Test: `scripts/unit-check.swift` (`configSyncMerge()`)

**Interfaces:**

- Consumes: Task 1.
- Produces:
  - `struct Entry: Codable, Equatable { var at: String; var from: String; var entity: JSONValue?; var carry: [String: JSONValue]; var held: Bool; var heldLocal: JSONValue? }`: the last state this Mac agreed with the cloud, per id. `entity` nil means deleted. `carry` holds remote fields this build did not know. `heldLocal` is the local projection at the moment an entry was held.
  - `struct Input { var kind: Kind; var local: [String: JSONValue]; var remote: [String: Envelope]; var snapshot: [String: Entry]; var mac: String; var localAt: String; var now: Date; var knownFields: Set<String>; var localMissing: Bool }`. `remote` is keyed by id and holds this kind's decoded envelopes, every `v` included.
  - `struct Plan: Equatable { var push: [Envelope]; var apply: [Envelope]; var prune: [String]; var newer: [String]; var overwrote: [String] }`. `apply` holds remote envelopes to bring into the local store, upserts and deletions alike. `prune` holds ids whose tombstone is removed from the cloud and the snapshot. `newer` holds ids left alone because `v > version`. `overwrote` holds ids where a remote version replaced a different local one.
  - `static func plan(_ input: Input) -> Plan`
  - `static func agreed(remote: Envelope, local: JSONValue?, knownFields: Set<String>) -> Entry`: the entry recorded after an apply. `entity` is the local projection after the apply, and `carry` is the remote entity's fields outside `knownFields`.
  - `static func held(remote: Envelope, local: JSONValue?) -> Entry`
  - `static func carryForward(_ entity: JSONValue, _ carry: [String: JSONValue]) -> JSONValue`
  - `static func cloudEmptied(syncKeys: Int, liveSnapshot: Int) -> Bool`: true when `syncKeys == 0 && liveSnapshot > 0`.

The rules, per id across local, remote and snapshot (`snap` is the snapshot entry, `R` the remote envelope):

| Condition                                                              | Plan                                                                                                                                                              |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `R.v > version`                                                        | `newer`. No push, no apply, the snapshot untouched.                                                                                                               |
| `localMissing`                                                         | Apply every live `R` whose entity differs from local, and push nothing.                                                                                           |
| `snap.held`                                                            | Local changed means `local != snap.heldLocal`. An absent local is never a change.                                                                                 |
| otherwise                                                              | Local changed means `local != snap?.entity`. Remote changed means `R` exists and `(R.at, R.from) != (snap.at, snap.from)`, or `R` is absent while `snap` is live. |
| local changed, remote not                                              | Push. The envelope is `at: localAt`, `from: mac`, with the entity carried forward from `snap.carry`, or a tombstone if absent.                                    |
| remote changed, local not                                              | Apply `R`. A vanished `R` applies as a tombstone at `snap.at`.                                                                                                    |
| both changed, same content                                             | Nothing to apply or push. The snapshot takes `R`.                                                                                                                 |
| both changed                                                           | `wins((localAt, mac), over: (R.at, R.from))` decides between push and apply. On apply with a live local that differs, add the id to `overwrote`.                  |
| `R.deleted`, `R.at` older than `now - tombstoneLifetime`, local absent | `prune`.                                                                                                                                                          |

- [ ] **Step 1: Write the failing checks.** One `check` per row above, plus these:

```swift
// The offline Mac: deleted on A on Monday, B comes back on Friday with an
// untouched copy from before Monday. The tombstone stands.
check("an offline Mac does not resurrect a deletion", plan(local: ["w": ws], snap: ["w": live(at: mon)], remote: ["w": tomb(at: tue)]).apply.map(\.deleted) == [true])
// A store applied, then re-planned with the agreed entry: nothing to push.
check("applying never echoes", plan(local: ["w": ws2], snap: ["w": agreed(remoteWs2)], remote: ["w": remoteWs2]) == .init())
check("a held entity whose local copy is missing is not a deletion", plan(local: [:], snap: ["s": held(remoteS)], remote: ["s": remoteS]).push.isEmpty)
check("a held entity edited here still pushes", !plan(local: ["s": edited], snap: ["s": held(remoteS, local: nil)], remote: ["s": remoteS]).push.isEmpty)
check("a push carries forward fields this build does not know", plan(...).push.first?.entity == .object(["enabled": .bool(false), "future": .string("x")]))
check("a newer envelope is left alone", plan(local: ["s": a], snap: [:], remote: ["s": v2]).newer == ["s"])
check("a missing file pushes nothing", plan(local: [:], snap: ["w": live()], remote: ["w": liveR], localMissing: true).push.isEmpty)
check("a missing file is filled from the cloud", plan(... localMissing: true).apply.count == 1)
check("the cloud emptied is told apart from a deletion", ConfigSync.cloudEmptied(syncKeys: 0, liveSnapshot: 3) && !ConfigSync.cloudEmptied(syncKeys: 1, liveSnapshot: 3))
check("first switch-on: the newer side wins and the overwrite is reported", firstRun.overwrote == ["rgis/keycloak"])
check("old tombstones are pruned", plan(local: [:], snap: [:], remote: ["x": tomb(at: now - 31 days)]).prune == ["x"])
```

The fixture helpers (`live`, `tomb`, `agreed`, `held`, a `plan(local:snap:remote:)` wrapper with defaults) go in the same section.

- [ ] **Step 2: Run it to make sure it fails.** Run `make unit`. Expected: a compile error on `ConfigSync.plan`.
- [ ] **Step 3: Implement** `plan`, `agreed`, `held`, `carryForward` and `cloudEmptied`.
- [ ] **Step 4: Run it to make sure it passes.** Run `make unit`. Expected: every check passes.
- [ ] **Step 5: Commit** `feat(sync): the per-entity merge, tombstones, held entities and the emptied cloud`.

### Task 3: Projections, and the per-Mac audit

**Files:**

- Create: `apps/apple/Bastion/SyncProjection.swift` (Foundation only, uses `ServerCatalog` types)
- Modify: `servers.json` (`"perMachine": true` on `IOS_SIMULATOR_ID`, `IOS_DEVICE_ID`, `NPM_TOTP_KEYCHAIN_SERVICE`), then `make servers` regenerates `ServerCatalog.swift` and `docs/servers.md`
- Modify: `Makefile` (`unit:` list, after `ConfigSync.swift`)
- Test: `scripts/unit-check.swift` (`syncProjection()`)

**Interfaces:**

- Consumes: Task 1's `JSONValue`. `BastionServer.perMachineEnv` exists.
- Produces, all in `nonisolated enum SyncProjection`:
  - `static func homeRelative(_ path: String, home: String) -> String` and `static func expandingHome(_ path: String, home: String) -> String`. `home` itself becomes `~`, and `/Users/o/x` becomes `~/x`. `/Users/other` is not under `/Users/o`, so it stays absolute.
  - `static func profileEntity(name: String, server: String, values: [String: String], allowWrites: Bool, perMachine: Set<String>) -> JSONValue`: `{"name", "server", "values", "allowWrites"}`, with per-Mac names removed from `values`.
  - `static let profileFields: Set<String> = ["name", "server", "values", "allowWrites"]`
  - `static func mergedValues(remote: [String: String], local: [String: String], perMachine: Set<String>) -> [String: String]`: the remote non-per-Mac values, plus the local per-Mac ones. A per-Mac name in `remote` is ignored.
  - `static func renames(removed: [String: JSONValue], added: [String: JSONValue]) -> [String: String]`: new id mapped to old id, for profile entities equal in everything except `name`. Only one-to-one matches count.
  - `static func perMachine(server: String, installed: BastionServer?) -> Set<String>`: `installed?.perMachineEnv`, else `ServerCatalog.byID[server]?.perMachineEnv`, else empty.

- [ ] **Step 1: Write the failing checks.** Cover each of these:
  - a per-Mac value never appears in the entity
  - `mergedValues` keeps the local `KUBECONFIG_PATH` and takes the remote `KEYCLOAK_URL`
  - a per-Mac value arriving from a hand-edited cloud is ignored
  - home paths round-trip, and a sibling user's folder stays absolute
  - a rename is inferred for `old/keycloak` → `new/keycloak` with identical values
  - no rename is inferred when the values differ, or when two candidates match
  - `ServerCatalog.byID["ios-simulator"]?.perMachineEnv` contains `IOS_SIMULATOR_ID`.
- [ ] **Step 2: Run it to make sure it fails.** Run `make unit`. Expected: a compile error.
- [ ] **Step 3: Implement** `SyncProjection`, mark the three catalog variables, and run `make servers`.
- [ ] **Step 4: Run it to make sure it passes.** Run `make unit && make servers-check`. Expected: both pass.
- [ ] **Step 5: Commit** `feat(sync): what each entity carries, and three more per-Mac variables`.

### Task 4: Approvals for custom servers from another Mac

**Files:**

- Create: `apps/apple/Bastion/ServerApprovals.swift` (a pure `ServerApprovals` value type, Foundation only, plus a `@MainActor final class ServerApprovalStore` in the same file below a `// MARK: - Keychain` line, outside the unit list. If `swiftc` objects, split it into `ServerApprovalStore.swift`.)
- Modify: `apps/apple/Bastion/CredentialStore.swift` (`Scope.approvals`, service `\(base).approvals`)
- Modify: `apps/apple/Bastion/ServerStore.swift` (`upsert(custom:)` records an approval for the saved value, `remove` forgets the id)
- Modify: `apps/apple/Bastion/Supervisor.swift` (a guard after each `serverDisabled` guard, at lines 161 and 363)
- Modify: `apps/apple/Bastion/BuiltinTools.swift` (`list_servers` / `get_server` add `"awaitingApproval": {"from": "<Mac>"}` when pending)
- Test: `scripts/unit-check.swift` (`serverApprovals()`)

**Interfaces:**

- Produces:
  - `nonisolated struct ServerApprovals: Codable, Equatable { var approved: [String: [String]]; var pending: [String: Pending]; struct Pending: Codable, Equatable { var value: String; var from: String } }`
  - `static func value(of definition: ServerStore.Definition) -> String` (`npm:<npmName>|<binName>` or `url:<url>`). It lives on `ServerStore.Definition` as `var approvalValue: String` if the pure file can't see `Definition`.
  - `mutating func approve(_ id: String, value: String)`: records the value and clears any pending entry.
  - `mutating func arrived(_ id: String, value: String, from: String)`: pending unless `value` is already approved for `id`.
  - `mutating func forget(_ id: String)`
  - `func isPending(_ id: String) -> Pending?`
  - `ServerApprovalStore.shared` with `nonisolated static func pending(_ id: String) -> ServerApprovals.Pending?`, read through an `OSAllocatedUnfairLock` snapshot as `InternalHostStore` does. Its mutations write the Keychain item and log ids only.
  - `SupervisorError.awaitingApproval(server: String, from: String)` with the sentence: `"<server> arrived from <Mac> through iCloud and has not been allowed on this Mac. Open Bastion and allow it there."`

- [ ] **Step 1: Write the failing checks.**
  - a value approved once does not go pending again
  - `url = Y` goes pending although `url = X` was approved
  - approving clears pending
  - `forget` removes both
  - `value(of:)` distinguishes a binName change.
- [ ] **Step 2: Run it to make sure it fails.** Run `make unit`. Expected: a compile error.
- [ ] **Step 3: Implement** the type, the store, the scope, the `upsert` and `remove` hooks, the supervisor guard and the tool fields.
- [ ] **Step 4: Run it to make sure it passes.** Run `make unit && make app && BASTION_PORT=8799 make builtin && BASTION_PORT=8799 make audit`. Expected: all pass. No server is pending yet, so nothing changes at runtime.
- [ ] **Step 5: Commit** `feat(sync): a custom server from another Mac waits for a yes on this one`.

### Task 5: Servers and profiles project and apply

**Files:**

- Modify: `apps/apple/Bastion/ServerStore.swift`, `apps/apple/Bastion/Profiles.swift` (a `// MARK: - Sync` section in each, plus one `SyncHooks.didSave(.server)` / `.profile` line at the end of each `save()`)
- Create: `apps/apple/Bastion/SyncHooks.swift` (`@MainActor enum SyncHooks { static var didSave: (ConfigSync.Kind) -> Void = { _ in } }`, set by the engine in Task 7)

**Interfaces:**

- Consumes: Tasks 1–4.
- Produces, on both stores:
  - `var syncFile: URL`, `var syncUnreadable: Bool`
  - `func syncEntities() -> [String: JSONValue]`
  - `func applySynced(_ envelopes: [ConfigSync.Envelope]) -> Set<String>`: returns the ids it could not apply. The engine records each as `held`.
- `ServerStore`:
  - **Entity:** the `Stored` row's `enabled` and `definition`, keyed by server id. The built-in server carries `enabled` only. Known fields are `enabled` and `definition`.
  - **Applying a new catalog id:** `install(catalogEntry:)`, then `setEnabled`. If it is a child and enabled, `Task { await ServerInstaller.shared.install(server) }`. An id this build does not ship is held.
  - **Applying a custom entity:** goes through the same validation as `upsert(custom:)`. Factor it into `private func validate(id:definition:original:) throws`. A refusal holds the id and logs the refusal. A new or changed `approvalValue` goes through `ServerApprovalStore.arrived(…, from: envelope.from)`. A custom child is never installed by sync.
  - **Applying a tombstone:** `remove(_:)`, except for the built-in server, which is ignored.
- `ProfileStore`:
  - **Entity:** `SyncProjection.profileEntity`, with `perMachine` from `SyncProjection.perMachine(server:installed:)`. Orphaned rows are included.
  - **Applying:** the values are `mergedValues` with the local row's. If `was` names a local profile and the new id is absent, apply it as `rename`, then `upsert` the values. Otherwise `upsert` it, or add it to `orphaned` and `save()` when its server is not in the list.
  - **Applying a tombstone:** `remove(_:)`. That sweeps this Mac's Keychain items for the profile, as a removal here does, and the CHANGELOG says so.
- [ ] **Step 1: Build, and run the existing checks.** Run `make app && BASTION_PORT=8799 make builtin`. Expected: both pass. The hooks are no-ops until Task 7, and the behaviour is pinned end to end in Task 9.
- [ ] **Step 2: Commit** `feat(sync): servers and profiles as synced entities`.

### Task 6: Workspaces and skills project and apply

**Files:**

- Modify: `apps/apple/Bastion/Workspaces.swift`, `apps/apple/Bastion/Skills.swift` (a `// MARK: - Sync` section in each, plus a `SyncHooks.didSave` line in each `save()`)

**Interfaces:**

- Consumes: Tasks 1, 3 and 5's `SyncHooks`, and the same three members as Task 5.
- `WorkspaceStore` (`.workspace`):
  - **Entity:** `{"name", "folders" (home-relative), "profiles", "skills"}`.
  - **Applying:** `upsert`, with folders expanded, or `remove(named:)`. A folder missing on this Mac is kept as typed, and `rescan` already resolves it to nothing.
- `SkillStore` (`.skillSource`, `.skillChoice`, `.order`):
  - **Sources:** `{"name", "path" (home-relative), "kind", "retired"}`. They are applied directly to `sources` without `preview`'s folder checks, so a source whose folder is missing on this Mac is kept and listed as unavailable.
  - **Order:** `{"names": [...]}`, applied by sorting `sources` along it, with unknown names last in their current order.
  - **Choices:** keyed by skill id as `{"targets": [...]}`, and written directly to `choices`.
  - **After an apply:** `save()`, then `reconcile()`.
  - `repositoryLinks` is never part of an entity.
- [ ] **Step 1: Confirm** that `SkillLinks.desired` ignores choices naming a skill or target it doesn't know. Read it, and add a `unit-check` case if no existing one pins that. Expected: unknown ids produce no link and no throw.
- [ ] **Step 2: Implement.** Then run `make app && BASTION_PORT=8799 make builtin`. Expected: both pass.
- [ ] **Step 3: Commit** `feat(sync): workspaces, skill sources and skill choices as synced entities`.

### Task 7: The engine

**Files:**

- Create: `apps/apple/Bastion/SyncCloud.swift` (`protocol SyncCloud`, `UbiquitousCloud`, and `FileCloud` under `#if DEBUG`)
- Create: `apps/apple/Bastion/ConfigSyncEngine.swift`
- Modify: `apps/apple/Bastion/BastionApp.swift` (`ConfigSyncEngine.shared.start()` after `_ = InternalHostStore.shared` and before the gateway starts. Never under `DemoSeed`, and never before `KeychainMigration.run()`.)
- Test: `scripts/unit-check.swift` (`FileCloud` round trip, if it compiles Foundation-only. Otherwise Task 9 covers it.)

**Interfaces:**

- `protocol SyncCloud: AnyObject { func all() -> [String: String]; func set(_ value: String, for key: String); func remove(_ key: String); func synchronize() }`. `UbiquitousCloud` wraps `NSUbiquitousKeyValueStore.default` and forwards `didChangeExternallyNotification` with its reason. `FileCloud(url:)` writes the whole dictionary atomically with mode 0600 on every mutation.
- `@MainActor @Observable final class ConfigSyncEngine`:
  - `static let enabledKey = "iCloudSyncEnabled"`, a `UserDefaults` bool, default false.
  - `enum Status: Equatable { case off, unavailable, idle(last: Date?), paused(Pause) }`
  - `enum Pause: Equatable { case unreadable(String), account, quota, cloudEmptied }`
  - `private(set) var status: Status`
  - `private(set) var recent: [Change]`, the last 5 applied, where `Change` is `(kind, id, from, at)`.
  - `private(set) var newer: Int`, the count of keys left alone for a newer Bastion.
  - `private(set) var firstRunOverwrites: [String]?`, which drives the sheet in Task 8.
  - `func start()`: decides `unavailable` when the build lacks the KVS entitlement (`SecTaskCopyValueForEntitlement`) and has no `-syncCloudFile`. Otherwise, if enabled: `synchronize()`, run a full pass, observe notifications, and set `SyncHooks.didSave` to schedule a debounced pass.
  - `func setEnabled(_ on: Bool)`: on switch-on, approves every existing custom server's current value, then runs the first pass and records the overwrites. On switch-off, it stops observing and keeps the snapshot.
  - `func resolveAccountChange(merge: Bool)`: merging clears the snapshot and runs a first pass; otherwise it turns sync off.
  - `func resolveCloudEmptied(pushBack: Bool)`: pushing back clears the snapshot and runs a pass that pushes everything local; otherwise it turns sync off.
  - `func removeFromICloud()`: removes every sync key, clears the snapshot, and turns sync off.
- A **pass** runs:
  1. Read `cloud.all()` and decode sync keys by kind. An undecodable value counts as newer for its key.
  2. If `cloudEmptied`, pause.
  3. For each kind, in the order server, profile, workspace, skillSource, order, skillChoice: skip it if its store is unreadable (and pause with its file name), compute `localMissing` from the file's existence, build the `Input` with `localAt` = file mtime for launch passes and now for save passes, then `plan`.
  4. Write `push` and `prune` to the cloud.
  5. Update the snapshot entries for pushed ids **before** calling the store's `applySynced`, then record `agreed` or `held` entries from the store's post-apply projection.
  6. Persist `sync-state.json` (Application Support, mode 0600, `{"snapshot": {kind: {id: Entry}}}`).
- **Notification reasons:**
  - `ServerChange` and `InitialSyncChange` run a pass.
  - `QuotaViolationChange` pauses with `quota`.
  - `AccountChange` pauses with `account`.
- **Renames on push:** run `SyncProjection.renames` over the profile ids this pass is tombstoning and adding, and set `was` on the added envelopes.

- [ ] **Step 1: Write the failing check** for the pause logic that can run without the app: a `unit-check` case that `ConfigSync.cloudEmptied` is what a pass consults. This is already covered in Task 2. The engine itself is pinned by Task 9, so this step is `make app` failing to link `ConfigSyncEngine` from `BastionApp`.
- [ ] **Step 2: Implement** `SyncCloud`, the engine, and the launch line.
- [ ] **Step 3: Verify.** Run `make app && make unit && BASTION_PORT=8799 make builtin && BASTION_PORT=8799 make audit`. Expected: all pass, with sync off by default.
- [ ] **Step 4: Commit** `feat(sync): the engine, a key-value store backend and a file backend for checks`.

### Task 8: Settings, the first-run sheet, and the arrival UI

**Files:**

- Create: `apps/apple/Bastion/SyncSettings.swift` (`ICloudSyncSection`, `SyncFirstRunSheet`)
- Modify: `apps/apple/Bastion/SettingsWindow.swift` (`ICloudSyncSection()` after `InternalHostsSection()`)
- Modify: the server detail view and its sidebar row (find them with `grep -n 'struct ServerDetail\|struct ServerRow' apps/apple/Bastion/*.swift`): a pending server shows "From <Mac>". A child gets an **Install** button, which approves and then installs. A remote gets an **Allow** button, which approves.

**Copy** (exact, within the spec's sentences):

- Toggle: "Sync with iCloud"
- Under it: "Servers, profiles, workspaces and skills follow you to your other Macs signed in to the same iCloud account. Profile values that are not secret sit in iCloud, encrypted by Apple, end to end only with Advanced Data Protection. Credentials are not synced yet: enter them on each Mac."
- **Status:**
  - "Last synced <relative time>.", plus one line per recent change: "<kind> <id> from <Mac>".
  - "Paused: <file> could not be read."
  - "Paused: the iCloud account changed." with buttons **Merge with This Account** and **Turn Sync Off**.
  - "Paused: iCloud's storage for Bastion is full."
  - "Paused: Bastion's data is gone from iCloud, perhaps removed on another Mac." with buttons **Put This Mac's Back** and **Turn Sync Off**.
  - When `newer > 0`: "<n> items were updated on a newer Bastion and are left alone until this one is updated."
  - `unavailable`: "This build cannot reach iCloud."
- **Remove from iCloud…**, which asks first: "Remove Bastion's configuration from iCloud? Every Mac still syncing will stop and ask what to do. Nothing on this Mac is deleted."
- **First-run sheet**, shown only when `firstRunOverwrites` is non-empty: "These were newer in iCloud and replaced this Mac's version:", then the list of ids, then **OK**.

- [ ] **Step 1: Implement.** Run `make app`. Expected: it builds.
- [ ] **Step 2: Look at it.** Open the Debug build with `-syncCloudFile "$TMPDIR/cloud.json"`, under `make run` (Debug only), and check the section in each state by seeding the file. Expected: the copy reads as above at the default window width.
- [ ] **Step 3: Commit** `feat(settings): Sync with iCloud, and allowing a server that arrived from another Mac`.

### Task 9: `make sync-check`, end to end on Debug

**Files:**

- Create: `scripts/sync-check.sh`, modelled on `scripts/builtin-check.sh`: same `ok`/`bad`/`check` helpers and the same backup-and-restore of Debug's Application Support and defaults
- Modify: `Makefile` (`sync-check: app ## Assert configuration sync end to end against a file-backed cloud`, and the `.PHONY` list)

**What it asserts**, launching `Bastion.app` (Debug) with `-gatewayPort $PORT -syncCloudFile $CLOUD`, `iCloudSyncEnabled` set to YES, and checking through Bastion's own MCP tools on a scratch profile:

1. **Arrival.** The cloud file is seeded with:
   - a remote catalog server, enabled (no npm, no network)
   - a profile for it, carrying a per-Mac name that must be ignored
   - a workspace
   - a custom remote server
   - a `server` key with `v: 2`

   After launch:
   - the catalog server is listed and enabled
   - the profile is listed without the per-Mac value
   - the workspace is listed
   - the custom server is listed with `awaitingApproval.from`
   - a gateway call to it returns the "has not been allowed on this Mac" sentence.

2. **A local edit.** `upsert_profile` changes a value, and within 3 s the cloud holds that profile's envelope with `from` equal to `scutil --get ComputerName`.
3. **Rename.** `rename_profile`, then the cloud holds a tombstone for the old id and an envelope with `was`.
4. **Deletion.** `remove_profile`, then a tombstone.
5. **Newer.** The `v: 2` key is byte-identical to how it was seeded.
6. **No echo.** Quit and relaunch with nothing changed. The cloud file is byte-identical across the relaunch.
7. **Missing file.** Quit, delete `workspaces.json` and relaunch. The workspace comes back, and the cloud holds no workspace tombstone.
8. **Emptied cloud.** Quit, empty the cloud file to `{}` and relaunch. Every local profile is still listed, and nothing was written to the cloud.

- [ ] **Step 1: Write the script.**
- [ ] **Step 2: Run it.** Run `BASTION_PORT=8799 make sync-check`. Expected: every item `ok`, and the Debug Application Support restored as found (`diff` it against the backup in the script's last step).
- [ ] **Step 3: Fix** what it finds in Tasks 5–7, and commit those fixes with it as `test(sync): configuration sync end to end against a file-backed cloud`.

### Task 10: Docs, CHANGELOG, then the two-Mac test on the signed build

**Files:**

- Create: `docs/icloud-sync.md`, covering:
  - what syncs and what doesn't, with this plan's decisions 1–5 and their reasons
  - the approval rule
  - how to read the status line
  - `make sync-check`
  - the two-Mac procedure below
- Modify: `docs/superpowers/specs/2026-11-01-icloud-config-sync-design.md` (Status line: phase 2 built; the `repositoryLinks` row corrected with a pointer to `docs/icloud-sync.md`)
- Modify: `README.md` (a short "Sync with iCloud" paragraph linking to the doc)
- Modify: `CHANGELOG.md` `[Unreleased]`, then `make changelog`. An `### Added` entry says:
  - what follows you, and that it's off by default
  - custom servers wait for a click
  - credentials don't sync yet
  - a profile removed on one Mac removes its credentials on the others.

**Steps:**

- [ ] **Step 1: Write the docs.** Then run `make format && make changelog-check`. Expected: it passes.
- [ ] **Step 2: Commit** `docs(sync): configuration sync, what follows and what waits`.
- [ ] **Step 3: Owner's yes required.** Ask before this step. Build the notarized Release build. Install it as the daily app on this Mac and on `eva`. That is phase 1's migration for real on both, and it is the release candidate.
- [ ] **Step 4: Run the two-Mac test.**
  1. Switch sync on on this Mac. On `eva`, switch it on and confirm the first-run sheet.
  2. Enable a catalog server on one Mac. It arrives enabled on the other within a minute.
  3. Add a custom remote server on `eva`. It waits for **Allow** here.
  4. Rename a profile here. `eva`'s copy is renamed, and its credentials still work.
  5. Switch sync off on `eva`. Edits here no longer arrive, and `eva` keeps its configuration.

  Record the outcome and the date in `docs/icloud-sync.md`.

---

## Self-review

- **Spec coverage:**
  - "What syncs" is covered by Tasks 5 and 6 (with decisions 1 and 2), and "Keys and values" by Tasks 1–3.
  - "When it runs" is Task 7, including unreadable stores, account change and quota.
  - Arrival behaviour is Tasks 4, 5 and 8, and the guard is Task 3 (mechanism 2, plus the catalog audit) and Task 4 (mechanism 3). Mechanism 1 shipped in phase 0a.
  - Settings is Task 8. First switch-on is Tasks 2, 7 and 8. Demo and Debug are Task 7 and decision 9.
  - Secrets are phase 3 and out of scope here, apart from the copy.
- **Left for the owner:** decisions 1, 4 and 5 go beyond the spec's text. Each is safer than the literal reading, and each is reversible before release.
