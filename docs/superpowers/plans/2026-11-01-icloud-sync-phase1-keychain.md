# iCloud config sync, phase 1: the data protection keychain — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every credential the Release build holds from the login keychain into the data protection keychain, with no credential lost on any path, and give the Debug build a way to receive them now that `security` cannot read them, while sync stays absent.

**Architecture:** `CredentialStore` picks its keychain at runtime: the data protection keychain when the process carries `keychain-access-groups` (the Release build), the login keychain otherwise (Debug, the Apple Development fallback). On the data protection side it reads through to the login keychain until a migration pass has moved everything. That pass runs at launch, add first and delete on success, and then writes a marker item that only Bastion's access group can create. A Foundation-only `KeychainMigration` holds the decisions, so `make unit` can check them, and a `-keychainSelfTest YES` launch mode proves the real thing on a signed build against a throwaway service namespace. A Settings button in the Release app writes the Debug build's `import.json`, which `make dev-clone` used to build with `security`.

**Tech Stack:** Swift 6 / SwiftUI, Security framework (`SecItem*`, `SecTask`), `scripts/unit-check.swift`, `scripts/dev-clone.mjs`, Make.

**Spec:** `docs/superpowers/specs/2026-11-01-icloud-config-sync-design.md` ("Secrets", "Phases" item 1), and `docs/keychain.md` ("The data protection keychain, and what it really costs"), which the spec adopts.

## Global Constraints

- Work in a worktree under `.claude/worktrees/`; never switch branches in the shared checkout.
- Scopes and services stay as they are: `\(AppSupport.identifier).profile|gateway|oauth|audit|internal-hosts`. One new scope, `.migration`, service `\(AppSupport.identifier).migration`, account `login-keychain`.
- Every data protection item this phase writes is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronizable. Phase 3 changes `.profile` when the sync switch is on, and nothing else.
- Every data protection query that reads, lists, updates or deletes carries `kSecAttrSynchronizable: kSecAttrSynchronizableAny`, so phase 3's synced items are never missed.
- Never delete a login keychain item before its data protection copy has been written and read back equal.
- No secret value in any log line, file name or argv. Names and counts only. The export file is the one place values go, mode 0600, inside the Debug build's Application Support directory.
- `DemoSeed.isEnabled`: no keychain access of any kind, as today.
- Before each commit: `make format`. `make unit`, `make builtin` and `make audit` run with `BASTION_PORT=8799`. The production Bastion holds 8720.
- Never `make stop` or `make run` against the Release build. Both pkill every `Bastion.app` by path, `/Applications` included. Release-build launch modes run beside the installed copy, as `-iCloudProbe` does.
- **Never launch this branch's Release build as the full app on a Mac whose installed Bastion predates it.** It would migrate the real credentials out of the login keychain, and the installed copy, which still reads there, would find none. The only Release launches allowed before release are the modes that exit before the migration hook: `-iCloudProbe` and `-keychainSelfTest`.
- The Debug build stays on the login keychain and carries no entitlements in this phase. Whether it gets them for developing sync is phase 2's decision.

## Review Focus

1. **A read refused during migration** (a denied or unanswered ACL prompt, a keychain locked because Bastion launched at login before unlock). That item stays in the login keychain, still readable through the fallback. The marker is not written, and the next launch tries again. Test: Task 1 Step 1 (`isComplete` false with a leftover), Task 4 Step 1 (a refused read is a leftover).
2. **The same account in both keychains** (a crash between add and delete, or a write after a partial pass). The data protection value wins, the login copy is deleted, and `accounts()` lists the name once. Test: Task 1 Step 1 (`plan` drops the stale copy), Task 5 Step 1 (the self-test seeds a duplicate).
3. **A build without the entitlement** (Debug, the Apple Development fallback). It stays entirely on the login keychain, never meets `-34018`, and runs no migration. Test: Task 2 Step 5 (`make builtin` and `make audit` on Debug), Task 5 Step 4 (the self-test refuses to run without the entitlement).
4. **Deleting or renaming a profile before migration completes.** A delete must remove both copies, or a removed credential comes back through the fallback on the next read. Test: Task 5 Step 1 (the self-test deletes a not-yet-migrated item and checks both keychains).
5. **Export pressed with no Debug build on this Mac, or while the Debug build is running.** No directory is created where none existed. A running Debug build picks the file up on its next launch, as with `dev-clone`. Test: Task 6 Step 1 (`destination` is nil without the directory).

---

### Task 1: `KeychainMigration`, the decisions

**Files:**

- Create: `apps/apple/Bastion/KeychainMigration.swift` (Foundation only)
- Modify: `Makefile` (`unit:` list, after `ICloudProbe.swift`)
- Test: `scripts/unit-check.swift` (new `keychainMigration()` section, called from `main`)

**Interfaces:**

- Produces:
  - `nonisolated enum KeychainMigration`
  - `enum Action: Equatable { case move, dropStale }`
  - `struct Step: Equatable { let account: String; let action: Action }`
  - `static func plan(legacy: [String], modern: [String]) -> [Step]`: one step per legacy account, sorted by account. `.move` when modern lacks the account. `.dropStale` when modern has it, because the modern copy was written later and wins.
  - `static func isComplete(leftover: [String: [String]]) -> Bool`: true only when every scope's leftover list is empty.
  - `static func union(modern: [String], legacy: [String]) -> [String]`: sorted, without duplicates.

- [ ] **Step 1: Write the failing checks**

```swift
static func keychainMigration() {
  print("\nKeychain migration decisions")
  let steps = KeychainMigration.plan(legacy: ["b", "a", "c"], modern: ["c"])
  check("an account only in the login keychain moves",
    steps.contains(.init(account: "a", action: .move)))
  check("an account in both drops the login copy, the modern one wins",
    steps.contains(.init(account: "c", action: .dropStale)))
  check("one step per legacy account, sorted", steps.map(\.account) == ["a", "b", "c"])
  check("nothing to do when the login keychain is empty",
    KeychainMigration.plan(legacy: [], modern: ["x"]).isEmpty)
  check("complete when every scope is empty",
    KeychainMigration.isComplete(leftover: ["profile": [], "oauth": []]))
  check("not complete while one item could not be read",
    !KeychainMigration.isComplete(leftover: ["profile": [], "oauth": ["p/s/oauth"]]))
  check("the union lists a name in both keychains once",
    KeychainMigration.union(modern: ["a", "c"], legacy: ["c", "b"]) == ["a", "b", "c"])
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `make unit`
Expected: compile error, `KeychainMigration.swift` missing from the `unit:` list's inputs.

- [ ] **Step 3: Implement `KeychainMigration` in `apps/apple/Bastion/KeychainMigration.swift`**

The doc comment says why a modern copy wins over a legacy one (it can only have been written after the migration started), and that the marker is written only on `isComplete`.

- [ ] **Step 4: Run the checks and make sure they pass**

Run: `make unit`
Expected: every `Keychain migration decisions` line `ok`, 0 failures.

- [ ] **Step 5: Commit**

```bash
make format
git add apps/apple/Bastion/KeychainMigration.swift scripts/unit-check.swift Makefile
git commit -m "feat(keychain): the migration's decisions, checked without a keychain"
```

### Task 2: `CredentialStore` on two keychains

**Files:**

- Modify: `apps/apple/Bastion/CredentialStore.swift` (`Scope` gains `.migration`; `baseQuery`; `write`, `lookup`, `delete`, `accounts`; the `write` comment about `ThisDeviceOnly`)

**Interfaces:**

- Consumes: `KeychainMigration.union` (Task 1).
- Produces:
  - `static let usesDataProtection: Bool`: computed once from `SecTaskCopyValueForEntitlement(SecTaskCreateFromSelf(nil), "keychain-access-groups" as CFString, nil) != nil`.
  - `static var migrationDone: Bool`: whether the `.migration` item exists on the data protection side. Cached after the first true.
  - `static func legacyAccounts(_ scope: Scope) -> [String]`, `static func legacyLookup(_ scope: Scope, account: String) throws -> String?`, `static func legacyDelete(_ scope: Scope, account: String) throws`, `static func modernAdd(_ scope: Scope, account: String, value: String) throws` (adds only, refusing a duplicate). These are the migration's primitives. Task 4 consumes them. Also `static func legacyAdd(_ scope: Scope, account: String, value: String) throws`, which only the self-test (Task 5) calls, to seed login keychain items.
  - `static var serviceBase: String`, defaulting to `AppSupport.identifier`. The self-test (Task 5) sets it before any keychain access, and nothing else does.

- [ ] **Step 1: Implement the backend switch in `baseQuery`**

`baseQuery(_:account:legacy:)` takes `legacy: Bool = false`. When `usesDataProtection && !legacy`, it adds `kSecUseDataProtectionKeychain: true` and `kSecAttrSynchronizable: kSecAttrSynchronizableAny`. `Scope.service` uses `serviceBase`.

- [ ] **Step 2: Implement the read-through and the two-sided writes**

The rules hold only when `usesDataProtection`. Otherwise every call behaves exactly as today.

- **`lookup`:** the modern copy first. On `errSecItemNotFound`, while `!migrationDone`, try `legacyLookup`.
- **`accounts`:** `KeychainMigration.union(modern:legacy:)` while `!migrationDone`, otherwise the modern list alone.
- **`write`:** modern only. The add sets `kSecAttrSynchronizable: false` and `AfterFirstUnlockThisDeviceOnly`. After a successful write, `try? legacyDelete` of the same account, so a stale login copy cannot come back.
- **`delete`:** both sides. Not-found on either is fine.

Rewrite the `ThisDeviceOnly` comment in `write`. The attribute is now honoured, it keeps every item out of iCloud in this phase, and phase 3 lifts it for `.profile` alone when the sync switch is on.

- [ ] **Step 3: Build**

Run: `make app`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Unit**

Run: `make unit`
Expected: unchanged count plus Task 1's, 0 failures.

- [ ] **Step 5: Prove a build without the entitlement is unchanged (Review Focus 3)**

Run: `BASTION_PORT=8799 make builtin && BASTION_PORT=8799 make audit`
Expected: `90/90 passed` and `All checks passed.` The Debug build carries no `keychain-access-groups`, so it takes the login path throughout.

- [ ] **Step 6: Commit**

```bash
make format
git add apps/apple/Bastion/CredentialStore.swift
git commit -m "feat(keychain): the data protection keychain when the build is entitled, reading through to the login keychain"
```

### Task 3: Debug's import document, shared

**Files:**

- Create: `apps/apple/Bastion/DevImportDocument.swift` (Foundation only, not `#if DEBUG`)
- Modify: `apps/apple/Bastion/DevSeed.swift` (drop the private `Document`, decode `DevImportDocument`)
- Modify: `Makefile` (`unit:` list)
- Test: `scripts/unit-check.swift` (new `devImportDocument()` section)

**Interfaces:**

- Produces:
  - `struct DevImportDocument: Codable`, with the fields and doc comments moved verbatim from `DevSeed.Document`: `token`, `tokens`, `gatewayTokens`, `profiles: [Row]`, `Row { name, server, allowWrites, values }`.
  - `static func export(profiles: [Row], gatewayTokens: [String: String]) -> DevImportDocument`, which drops the `dev` client, as `dev-clone` does, because that is the Debug build's own scripting identity.
  - `static func destination(debugSupport: URL, fileManager: FileManager = .default) -> URL?`: `debugSupport/import.json`, or nil when `debugSupport` does not exist.

- [ ] **Step 1: Write the failing checks**

```swift
static func devImportDocument() {
  print("\nThe Debug build's import document")
  let doc = DevImportDocument.export(
    profiles: [.init(name: "prod", server: "shopify", allowWrites: true, values: ["SHOPIFY_TOKEN": "x"])],
    gatewayTokens: ["claude-code": "t1", "dev": "t2"])
  check("profiles are carried with their values", doc.profiles.first?.values["SHOPIFY_TOKEN"] == "x")
  check("the Debug build's own dev token is left alone", doc.gatewayTokens == ["claude-code": "t1"])
  check("it decodes as DevSeed reads it",
    (try? JSONDecoder().decode(DevImportDocument.self, from: JSONEncoder().encode(doc)))?.profiles.count == 1)
  let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("no-such-\(UUID())")
  check("no destination where there is no Debug build", DevImportDocument.destination(debugSupport: missing) == nil)
  check("import.json inside it when there is one",
    DevImportDocument.destination(debugSupport: URL(fileURLWithPath: NSTemporaryDirectory()))?.lastPathComponent == "import.json")
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `make unit`
Expected: compile error, `DevImportDocument` missing.

- [ ] **Step 3: Move the type and add the two functions**

`DevSeed` decodes `DevImportDocument` and behaves exactly as before.

- [ ] **Step 4: Run the checks, and prove DevSeed still imports**

Run: `make unit && make app && BASTION_PORT=8799 make builtin`
Expected: the new section `ok`. `90/90 passed`, because `builtin-check` seeds through `import.json`.

- [ ] **Step 5: Commit**

```bash
make format
git add apps/apple/Bastion/DevImportDocument.swift apps/apple/Bastion/DevSeed.swift scripts/unit-check.swift Makefile
git commit -m "refactor(dev): the import document is shared, so the Release build can write one"
```

### Task 4: The migration pass at launch

**Files:**

- Modify: `apps/apple/Bastion/KeychainMigration.swift` (the pure `leftovers` and `Outcome`)
- Create: `apps/apple/Bastion/KeychainMigrationRun.swift` (`extension KeychainMigration` with `@MainActor static func run()`. It is a separate file kept out of the `unit:` list, because it calls `CredentialStore`, `DemoSeed` and `hostLog`.)
- Modify: `apps/apple/Bastion/BastionApp.swift` (`applicationDidFinishLaunching`, after the probe hook and before `_ = ServerStore.shared`)
- Test: `scripts/unit-check.swift` (a check on the pure part of a refused read, below)

**Interfaces:**

- Consumes: Task 1's `plan`/`isComplete`, Task 2's primitives and `usesDataProtection`/`migrationDone`.
- Produces: `KeychainMigration.run()`, and `KeychainMigration.leftovers(after outcomes: [String: [Outcome]]) -> [String: [String]]` with `enum Outcome: Equatable { case moved(String), dropped(String), refused(String) }`. Only `refused` counts as a leftover.

- [ ] **Step 1: Write the failing check (Review Focus 1)**

```swift
check("a refused read is a leftover, so the marker waits",
  KeychainMigration.leftovers(after: ["profile": [.moved("a"), .refused("b")], "oauth": [.dropped("c")]])
    == ["profile": ["b"], "oauth": []])
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `make unit`
Expected: compile error, `leftovers` missing.

- [ ] **Step 3: Implement `leftovers`, then `run()`**

`run()` returns at once when `!usesDataProtection || migrationDone || DemoSeed.isEnabled`. For each scope except `.migration`, it plans from `legacyAccounts` against the modern accounts, then works each step:

- **`.move`:** `legacyLookup`. A throw, or a nil, is `refused`. Then `modernAdd`, read back through the modern side and compare. Only on equal, `legacyDelete`.
- **`.dropStale`:** `legacyDelete`.

When `isComplete(leftover:)` holds, it writes the marker with `modernAdd(.migration, account: "login-keychain", value: <ISO 8601 now>)`. It logs one line per scope, `hostLog("keychain", .info, "moved N, dropped M, kept K for <scope>")`, plus an `.error` line naming each kept account. Never a value.

- [ ] **Step 4: Hook it**

In `applicationDidFinishLaunching`, call `KeychainMigration.run()` after `if ICloudProbe.isRequested { … }` and before `_ = ServerStore.shared`. The comment says this is before anything asks for a credential, and that a pass which keeps anything is retried on the next launch, the fallback covering the gap.

- [ ] **Step 5: Run the checks and build**

Run: `make unit && make app && BASTION_PORT=8799 make builtin`
Expected: all `ok`. `90/90 passed`, because `run()` returns at once on Debug.

- [ ] **Step 6: Commit**

```bash
make format
git add apps/apple/Bastion/KeychainMigration.swift apps/apple/Bastion/BastionApp.swift scripts/unit-check.swift
git commit -m "feat(keychain): move every credential at launch, add first and delete on success"
```

### Task 5: `-keychainSelfTest YES`, the real thing on a signed build

**Files:**

- Create: `apps/apple/Bastion/KeychainSelfTest.swift`
- Modify: `apps/apple/Bastion/BastionApp.swift` (beside the probe hook)
- Modify: `Makefile` (a `keychain-selftest` target beside `icloud-probe`, with the same precondition note and no `make stop`)

**Interfaces:**

- Consumes: everything from Tasks 2 and 4.
- Produces: `enum KeychainSelfTest { static var isRequested: Bool; @MainActor static func run() -> Never }`. Argument domain only, through `ICloudProbe.requests`.

- [ ] **Step 1: Implement the self-test**

It first sets `CredentialStore.serviceBase = "\(AppSupport.identifier).selftest"`, so nothing real is touched, and deletes anything left under that base from an earlier run. Then it checks each of these, printing `selftest: ok <label>` or `selftest: FAIL <label>`:

1. Without the entitlement, it prints `selftest: needs the Developer ID build` and exits 2 (Review Focus 3).
2. It seeds login keychain items through `CredentialStore.legacyAdd` in `.profile` (`p/s/A`, `p/s/B`, `p/s/GONE`), `.oauth` (`p/s/oauth`) and `.gatewayToken` (`client`). It also seeds a modern `p/s/B` holding a different value, the duplicate case.
3. Before migrating, `lookup(.profile, "p/s/A")` returns the legacy value, through the fallback.
4. `accounts(.profile)` lists `p/s/A`, `p/s/B` and `p/s/GONE` once each.
5. `delete(.profile, "p/s/GONE")` leaves it in neither keychain (Review Focus 4).
6. `KeychainMigration.run()`. Afterwards no legacy accounts remain under the base, the modern side has every seeded account, `p/s/B` holds the modern value (Review Focus 2), and `migrationDone` is true.
7. A second `run()` changes nothing.
8. Every modern item reads back with `kSecAttrSynchronizable` false.
9. It cleans up everything under the base, both keychains and the marker, then exits 0 if every check was `ok`, otherwise 1.

- [ ] **Step 2: Hook it and add the target**

`if KeychainSelfTest.isRequested { KeychainSelfTest.run() }` sits beside the probe hook. The `make keychain-selftest` target runs `"$(RELEASE_APP)/Contents/MacOS/Bastion" -keychainSelfTest YES`.

- [ ] **Step 3: Run it on the signed build**

Run: `make bundle && make keychain-selftest`
Expected: every line `selftest: ok`, exit 0.

- [ ] **Step 4: Run it on the Debug build (Review Focus 3)**

Run: `make app && apps/apple/.build/Build/Products/Debug/Bastion.app/Contents/MacOS/Bastion -keychainSelfTest YES; echo $?`
Expected: `selftest: needs the Developer ID build`, exit 2.

- [ ] **Step 5: Commit**

```bash
make format
git add apps/apple/Bastion/KeychainSelfTest.swift apps/apple/Bastion/BastionApp.swift Makefile
git commit -m "feat(keychain): a self-test of the migration on the signed build, in a throwaway namespace"
```

### Task 6: Export to the Debug build, and `dev-clone` without `security`

**Files:**

- Modify: `apps/apple/Bastion/SettingsWindow.swift` (the General pane: a "Debug build" card, Release only)
- Modify: `scripts/dev-clone.mjs` (stop reading secrets and gateway tokens and stop writing `import.json`; say to press the button)
- Test: Task 3's `destination` checks cover the path decision (Review Focus 5). The button gets a manual check in Step 3.

**Interfaces:**

- Consumes: `DevImportDocument.export`, `DevImportDocument.destination` (Task 3); `ProfileStore.shared.profiles`; `CredentialStore.read`/`accounts` for `.profile` and `.gatewayToken`.
- Produces: none for later tasks.

- [ ] **Step 1: The card**

In a Release build (`#if !DEBUG`), the card shows only when `DevImportDocument.destination(debugSupport:)` for `~/Library/Application Support/io.mgcrea.bastion.debug` is non-nil. It has one button, "Export to the Debug Build…". The button:

- Asks once with an `NSAlert`: "Write every profile's credentials and the gateway tokens into the Debug build's import file? It moves them into its own Keychain on its next launch." Buttons: Export / Cancel.
- Then builds the document from the profiles (values plus each secret variable read through `CredentialStore.read`) and the gateway tokens, skipping OAuth token sets, as `dev-clone` did and for its reason.
- Writes it atomically with mode 0600.
- Reports how many profiles and tokens it wrote. Never values.

No MCP tool reaches this, the same rule as internal hosts.

- [ ] **Step 2: `dev-clone`**

Remove `accountsIn`, `keychain()`, `gatewayTokens` and the `import.json` write. Keep the OAuth names in the summary if they can still be derived without values. Otherwise drop that list and say so in the header comment. Rewrite the header's "profiles" and "gateway tokens" bullets: they now come from the Release app's Settings › General › Export to the Debug Build, because the Release build's credentials live in the data protection keychain, which `security` cannot read. Print that instruction last.

- [ ] **Step 3: Check what can be checked before release**

Run: `make unit && make bundle`
Expected: the `DevImportDocument` checks pass and the bundle builds. The card itself cannot be opened before release: launching this branch's Release build as the full app would migrate the real credentials (see Global Constraints). Its check is part of Task 7 Step 4. Also confirm `node scripts/dev-clone.mjs` prints the new instruction. Its existing flags show how to run it without writing, and if there are none, read the change instead of running it.

- [ ] **Step 4: Commit**

```bash
make format
git add apps/apple/Bastion/SettingsWindow.swift scripts/dev-clone.mjs
git commit -m "feat(settings): export credentials to the Debug build, which dev-clone can no longer read"
```

### Task 7: Docs, CHANGELOG, and the release check

**Files:**

- Modify: `docs/keychain.md` ("Where secrets live today", the costs list, "Current state")
- Modify: `CHANGELOG.md` (`[Unreleased]`), then `make changelog`

- [ ] **Step 1: `docs/keychain.md`**

Write what is now true:

- The Release build is on the data protection keychain, Debug on the login keychain.
- The read-through and the marker.
- `make keychain-selftest`.
- Items are invisible to Keychain Access and `security`, which is why the export button exists.

Move "Data protection keychain migration" to done in the table.

- [ ] **Step 2: CHANGELOG**

Under `### Changed`: credentials move to the data protection keychain on first launch, and macOS may ask once per item. Going back to 1.35.0 or earlier after that finds no stored credentials, because they were moved, not copied.

Under `### Added`: Settings › General › Export to the Debug Build, for contributors. Run `make changelog && make changelog-check`.

- [ ] **Step 3: Commit**

```bash
make format
git add docs/keychain.md CHANGELOG.md apps/apple/Bastion/Changelog.swift
git commit -m "docs: the data protection keychain, and what moving to it costs"
```

- [ ] **Step 4 (owner, at release): the real migration**

This happens on installing the release build, on this Mac first, then on `eva`. The owner checks:

- Profiles still show their secrets set, and a server with a secret starts and answers.
- The log has the `moved N … kept 0` lines. To find them: `log show --last 5m --predicate 'process == "Bastion"' | grep keychain`.
- No prompt came back on a second launch: `log show --predicate 'subsystem == "com.apple.securityd" AND category == "kcacl"'`.

If anything was kept, the next launch retries, and the credential still works through the fallback in the meantime.

Then, with a Debug build on that Mac: Settings › General shows the "Debug build" card. Cancel writes nothing. Export writes `~/Library/Application Support/io.mgcrea.bastion.debug/import.json` (mode 600) whose profile names match. The next Debug launch moves those profiles into its own keychain and leaves `imported.json` behind.
