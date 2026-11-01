# iCloud config sync, phases 0a and 0: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the environment routes by which synced data could choose code on another Mac (phase 0a), then prove on a signed Developer ID build that the data protection keychain and iCloud key-value storage work for Bastion (phase 0), before any sync code exists.

**Architecture:** Phase 0a adds a Foundation-only `ReservedEnv` policy consulted by `ServerStore.upsert` and `ProfileEnvironment.build`, and a `perMachine` flag on catalog variables carried from `servers.json` through the generator into `BastionServer.EnvVar`. Phase 0 adds the entitlements, an embedded Developer ID provisioning profile in `make sign`, rewrites the two "no entitlements" assertions to "exactly these", and adds an `-iCloudProbe YES` launch mode that exercises both stores and exits.

**Tech Stack:** Swift 6 / SwiftUI app with no XCTest target (pure files are checked by `scripts/unit-check.swift` via `make unit`), Node generator `scripts/generate-servers.mjs`, Bash `scripts/builtin-check.sh` and `scripts/audit-listener.sh`, Make.

**Spec:** `docs/superpowers/specs/2026-11-01-icloud-config-sync-design.md` (sections "The guard" and "Phases", items 0a and 0). Phases 1–3 are a later plan.

## Global Constraints

- Never switch branches in the shared checkout; work in a worktree under `.claude/worktrees/<name>` (check it is git-ignored first).
- Reserved names, case-insensitive: exactly `PATH`, `HOME`; prefixes `NODE_`, `NPM_CONFIG_`, `DYLD_`, `XDG_`. The list may grow with names of the same kind, never shrink.
- Catalog-declared names are exempt from the reserved refusal; the generator allows a reserved name in the catalog only as a per-Mac variable.
- Every `stateEnv` variable is per-Mac implicitly.
- Release entitlement set is exactly: `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups`, `com.apple.developer.ubiquity-kvstore-identifier`. Team `75QE9PRT3V`, bundle ids `io.mgcrea.bastion` (Release) and `io.mgcrea.bastion.debug` (Debug).
- New pure Swift files are Foundation-only and added to the `make unit` compile list. The Xcode project uses synchronized folders: a file placed in `apps/apple/Bastion/` is in the target without a pbxproj edit.
- `make builtin` and `make audit` run against port 8799 locally (`BASTION_PORT=8799`): the production Bastion holds 8720.
- Before each commit: `make format` (oxfmt + swift-format). Commit messages follow the repo's `type(scope): summary` style.
- Comment density and voice match the surrounding code: comments explain why, in full sentences.

## Review Focus

1. **A user's existing custom server already declares a reserved name** (say `NODE_EXTRA_CA_CERTS` for a corporate CA). It must still load and start, minus that variable, with one log line naming it, never a crash or a vanished row. Test: Task 1 Step 1 (`admit` skips and names it), Task 2 Step 6 (a hand-edited row in `make builtin`).
2. **Lower-case reserved names in a hand-edited `servers.json`** (`node_options`, `npm_config_script_shell`). These skip `isValidVariable`'s upper-case rule on load. `isReserved` must match case-insensitively. Test: Task 1 Step 1.
3. **The npm catalog entry keeps working**: `NPM_CONFIG_USERCONFIG` is catalog-declared and must still reach the child. Test: Task 1 Step 1 (catalog exemption) and Task 3 Step 1 (npm's `perMachineEnv`).
4. **A Release build carrying restricted entitlements with a missing or mismatched profile** is killed by AMFI at launch, on a user's Mac, after notarization passes. `make sign` must refuse to finish without the profile, and the gate must launch the notarized build. Test: Task 5 Step 5 (`make sign` refuses without the profile) and Task 7 Step 3.
5. **A Debug build on a Mac that isn't a registered development device** can't satisfy the Debug profile. Debug runs must not become unlaunchable for contributors or CI. Test: Task 5 Step 7 (CI's unsigned build still succeeds) and the Debug fallback in Task 5 Step 4.

---

## Phase 0a: environment hardening

### Task 1: `ReservedEnv` policy

**Files:**

- Create: `apps/apple/Bastion/ReservedEnv.swift`
- Modify: `Makefile` (the `unit:` compile list, after `apps/apple/Bastion/ServerCatalog.swift`)
- Test: `scripts/unit-check.swift` (new `reservedEnv()` section, called from `main`)

**Interfaces:**

- Produces:
  - `nonisolated enum ReservedEnv`
  - `static func isReserved(_ name: String) -> Bool`
  - `static func firstReserved(in names: [String]) -> String?`
  - `static func admit(_ values: [String: String], declaredByCatalog: Bool) -> (admitted: [String: String], skipped: [String])`. `skipped` is sorted, and empty when `declaredByCatalog` is true.

- [ ] **Step 1: Write the failing checks in `scripts/unit-check.swift`**

```swift
static func reservedEnv() {
  print("\nReserved environment names")
  check("PATH is reserved", ReservedEnv.isReserved("PATH"))
  check("HOME is reserved", ReservedEnv.isReserved("HOME"))
  check("NODE_OPTIONS is reserved", ReservedEnv.isReserved("NODE_OPTIONS"))
  check("NODE_EXTRA_CA_CERTS is reserved", ReservedEnv.isReserved("NODE_EXTRA_CA_CERTS"))
  check("NPM_CONFIG_USERCONFIG is reserved", ReservedEnv.isReserved("NPM_CONFIG_USERCONFIG"))
  check("DYLD_INSERT_LIBRARIES is reserved", ReservedEnv.isReserved("DYLD_INSERT_LIBRARIES"))
  check("XDG_CONFIG_HOME is reserved", ReservedEnv.isReserved("XDG_CONFIG_HOME"))
  check("a lower-case npm_config_ name is reserved", ReservedEnv.isReserved("npm_config_script_shell"))
  check("a lower-case node_options is reserved", ReservedEnv.isReserved("node_options"))
  check("PATHFINDER_TOKEN is not", !ReservedEnv.isReserved("PATHFINDER_TOKEN"))
  check("HOMEASSISTANT_URL is not", !ReservedEnv.isReserved("HOMEASSISTANT_URL"))
  check("NPM_TOKEN is not", !ReservedEnv.isReserved("NPM_TOKEN"))
  check("NODE alone is not", !ReservedEnv.isReserved("NODE"))
  check("firstReserved finds the first in order",
    ReservedEnv.firstReserved(in: ["A_TOKEN", "NODE_OPTIONS", "PATH"]) == "NODE_OPTIONS")
  check("firstReserved is nil for a clean list", ReservedEnv.firstReserved(in: ["A", "B_C"]) == nil)
  let custom = ReservedEnv.admit(["A": "1", "PATH": "/tmp", "NODE_OPTIONS": "x"], declaredByCatalog: false)
  check("a custom server keeps its own names", custom.admitted == ["A": "1"])
  check("and names what it skipped, sorted", custom.skipped == ["NODE_OPTIONS", "PATH"])
  let catalog = ReservedEnv.admit(["NPM_CONFIG_USERCONFIG": "/x/.npmrc"], declaredByCatalog: true)
  check("a catalog-declared reserved name is admitted", catalog.admitted["NPM_CONFIG_USERCONFIG"] == "/x/.npmrc")
  check("and nothing is skipped for the catalog", catalog.skipped.isEmpty)
}
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `make unit`
Expected: compile error, `cannot find 'ReservedEnv' in scope`.

- [ ] **Step 3: Implement `ReservedEnv` in `apps/apple/Bastion/ReservedEnv.swift`**

Foundation only. `isReserved` upper-cases the name, then tests the exact set and the prefix list from Global Constraints. The doc comment states why each family is there: PATH and HOME are set by Bastion, `NODE_*` covers `NODE_OPTIONS --import`, `NPM_CONFIG_*` covers npm's `script-shell` and userconfig, `DYLD_*` covers library injection, and `XDG_*` is set by Bastion per profile. Also state that the catalog is exempt because it is compiled into the app. Add the file to the `unit:` list in `Makefile`.

- [ ] **Step 4: Run the checks and make sure they pass**

Run: `make unit`
Expected: every `Reserved environment names` line `ok`, final line reports 0 failures.

- [ ] **Step 5: Commit**

```bash
make format
git add apps/apple/Bastion/ReservedEnv.swift scripts/unit-check.swift Makefile
git commit -m "feat(profiles): a reserved-name policy for child environments"
```

### Task 2: Refuse and skip reserved names for custom servers

**Files:**

- Modify: `apps/apple/Bastion/ServerStore.swift` (`StoreError`, around line 387; `errorDescription`, around line 412; `upsert(custom:definition:replacing:)`, after the `isValidVariable` loop, around line 497)
- Modify: `apps/apple/Bastion/Profiles.swift` (`ProfileEnvironment.build`, the `env.merge(values(…))` line, around line 518)
- Test: `scripts/builtin-check.sh` (in the block after "the id is reserved against a custom server", around line 237)

**Interfaces:**

- Consumes: `ReservedEnv.firstReserved(in:)`, `ReservedEnv.admit(_:declaredByCatalog:)` from Task 1; `BastionServer.origin` (`.catalog` for catalog entries).
- Produces: `ServerStore.StoreError.reservedVariable(String)`.

- [ ] **Step 1: Write the failing end-to-end checks in `scripts/builtin-check.sh`**

```bash
check "a custom server cannot declare NODE_OPTIONS" \
  "$(tool checkrw add_custom_server '{"id":"checkreserved","display_name":"X","npm_name":"@x/y","env":[{"name":"NODE_OPTIONS"}]}')" \
  'NODE_OPTIONS is set by Bastion'
check "nor PATH" \
  "$(tool checkrw add_custom_server '{"id":"checkreserved","display_name":"X","npm_name":"@x/y","env":[{"name":"PATH"}]}')" \
  'PATH is set by Bastion'
absent "and neither attempt left a row behind" "$(tool checkro list_servers '{}')" 'checkreserved'
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `make app && BASTION_PORT=8799 make builtin`
Expected: the two `check` lines FAIL. Today the server is added, so the reply carries no refusal and `checkreserved` is listed.

- [ ] **Step 3: Implement the refusal**

Add `case reservedVariable(String)` to `StoreError`, with exactly this copy: `"\(name) is set by Bastion, or can change what code a server runs, so a custom server cannot declare it"`. In `upsert(custom:…)`, after the `isValidVariable` loop, throw it for `ReservedEnv.firstReserved(in: definition.env.map(\.name))`. The comment says this is the same `spawn(whatever_you_typed)` hole as the package check above it, reached through the environment.

- [ ] **Step 4: Implement the skip in `ProfileEnvironment.build`**

Replace the direct merge with `ReservedEnv.admit(values(for: profile, server: server), declaredByCatalog: server.origin == .catalog)`. Merge `admitted` the same way as today. If `skipped` is non-empty, `hostLog("profiles", .error, …)` once per spawn, naming the server id and the skipped names, and saying the row was edited by hand. The gate and bypass blocks below stay where they are.

- [ ] **Step 5: Run the checks and make sure they pass**

Run: `make app && BASTION_PORT=8799 make builtin`
Expected: all lines `ok`, including the three new ones.

- [ ] **Step 6: Pin the hand-edited-row path (Review Focus 1)**

In `builtin-check.sh`'s setup, where it already writes the Debug `servers.json`, add a custom row `checkhand` (npm `@mgcrea/mcp-checkscratch`) declaring `CHECK_TOKEN` and `NODE_OPTIONS`. Then add:

```bash
check "a hand-edited row with a reserved name still loads" "$(tool checkro list_servers '{}')" 'checkhand'
```

Run: `make app && BASTION_PORT=8799 make builtin`
Expected: `ok`. The setup's backup/restore already returns the file afterwards.

- [ ] **Step 7: Commit**

```bash
make format
git add apps/apple/Bastion/ServerStore.swift apps/apple/Bastion/Profiles.swift scripts/builtin-check.sh
git commit -m "feat(servers): custom servers cannot declare reserved environment names"
```

### Task 3: The `perMachine` flag on catalog variables

**Files:**

- Modify: `scripts/servers.schema.json` (env item `properties`, beside `boolean`)
- Modify: `scripts/generate-servers.mjs` (validation near line 265, `swiftEnvVar` near line 546, the docs table near line 695)
- Modify: `servers.json` (seven variables, below)
- Modify: `apps/apple/Bastion/ServerCatalog.swift` (`EnvVar`, around line 562; a computed property on `BastionServer`). The generated table regenerates.
- Regenerated by `make servers`: `ServerCatalog.swift`'s table, `docs/servers.md`, and any website copy the generator writes.
- Test: `scripts/unit-check.swift` (new `perMachineEnv()` section)

**Interfaces:**

- Consumes: `ReservedEnv.isReserved` semantics, mirrored in JS. The generator can't import Swift, so it keeps its own copy of the list with a comment pointing at `ReservedEnv.swift`.
- Produces:
  - `BastionServer.EnvVar.isPerMachine: Bool` (defaulted `false`, declared last).
  - `BastionServer.perMachineEnv: Set<String>`, which is `stateEnv` ∪ the names of `env` with `isPerMachine`. Phase 2 reads it to leave values out of the synced entity.

- [ ] **Step 1: Write the failing checks in `scripts/unit-check.swift`**

```swift
static func perMachineEnv() {
  print("\nPer-Mac catalog variables")
  func server(_ id: String) -> BastionServer? { ServerCatalog.all.first { $0.id == id } }
  check("npm's NPM_BIN is per-Mac", server("npm")?.perMachineEnv.contains("NPM_BIN") == true)
  check("npm's NPM_CONFIG_USERCONFIG is per-Mac, through stateEnv",
    server("npm")?.perMachineEnv.contains("NPM_CONFIG_USERCONFIG") == true)
  check("npm's NPM_REGISTRY is not", server("npm")?.perMachineEnv.contains("NPM_REGISTRY") == false)
  check("iOS Device's launch arguments are per-Mac",
    server("ios-device")?.perMachineEnv.contains("IOS_DEVICE_LAUNCH_ARGS") == true)
  check("App Store Connect's .p8 path is per-Mac",
    server("appstore-connect")?.perMachineEnv.contains("APP_STORE_CONNECT_P8_PATH") == true)
  check("Reddit's redirect URI follows the sync",
    server("reddit")?.perMachineEnv.contains("REDDIT_REDIRECT_URI") == false)
  check("every reserved name in the catalog is per-Mac",
    ServerCatalog.all.allSatisfy { s in
      s.env.filter { ReservedEnv.isReserved($0.name) }.allSatisfy { s.perMachineEnv.contains($0.name) }
    })
}
```

Call `reservedEnv()` and `perMachineEnv()` from `UnitCheck.main()`, beside the other sections.

- [ ] **Step 2: Run it to make sure it fails**

Run: `make unit`
Expected: compile error, `value of type 'BastionServer' has no member 'perMachineEnv'`.

- [ ] **Step 3: Add the schema field and the generator rules**

Schema: `"perMachine": { "type": "boolean", "description": "The value names code, a launch argument or a path on this Mac, so it never leaves it: iCloud sync leaves it out. stateEnv variables are per-Mac without saying so." }`.

Generator validation, added to `problems`:

- A variable whose name ends in `_PATH`, `_FILE`, `_DIR`, `_ARGS`, `_BIN`, `_CONFIG` or `USERCONFIG`, or is reserved, and is not in the server's `stateEnv`, must state `perMachine` (true or false): `${eat}: looks like a path or launch argument; state perMachine either way`.
- A reserved name must be in `stateEnv` or carry `perMachine: true`: `${eat}: a reserved name is allowed in the catalog only as a per-Mac variable`.
- `perMachine` on a remote server's variable is refused: `${eat}: a header is not a local path; perMachine is for child variables`.

Emit `isPerMachine: true` after whichever of `summary` / `header` / `booleanDefault` closes the initializer, only when true. Turn the three-way `tail` into a list of trailing argument lines so a fourth optional doesn't multiply the cases. In `docs/servers.md`, append ` Per Mac — never synced.` to the meaning cell when `perMachine` is true or the name is in `stateEnv`.

- [ ] **Step 4: Mark the catalog**

In `servers.json`, set `"perMachine": true` on: `APP_STORE_CONNECT_P8_PATH`, `NPM_BIN`, `IOS_DEVICE_LAUNCH_ARGS`, `IOS_SIMULATOR_LAUNCH_ARGS`, `KUBECONFIG_PATH`, `APPLE_ADS_PRIVATE_KEY_PATH`, `YAHOO_FINANCE_COOKIE_IMPORT_FILE`. Run `make servers`. For every other variable the generator now flags, set `perMachine: true` when its value is a path, a launch argument or names code on this Mac, otherwise `false`. List those choices in the commit message body.

- [ ] **Step 5: Add `isPerMachine` and `perMachineEnv` in `ServerCatalog.swift`**

`var isPerMachine: Bool = false`, declared last in `EnvVar`, with a doc comment saying phase 2's sync leaves these values out and why (a path or launch argument on one Mac is code chosen on another). `perMachineEnv` goes on `BastionServer`, beside `editableEnv`.

- [ ] **Step 6: Run everything that reads the catalog**

Run: `make servers && make servers-check && make unit && make catalog-check`
Expected: generator clean, no drift, all `Per-Mac catalog variables` lines `ok`, catalog-check passes. If `catalog-check` needs `MCP_ROOT` and it's absent here, record that and rely on CI.

- [ ] **Step 7: Commit**

```bash
make format
git add scripts/servers.schema.json scripts/generate-servers.mjs servers.json \
  apps/apple/Bastion/ServerCatalog.swift docs/servers.md apps/website scripts/unit-check.swift
git commit -m "feat(catalog): mark the variables whose values belong to one Mac"
```

### Task 4: CHANGELOG for phase 0a

**Files:**

- Modify: `CHANGELOG.md` (an `## [Unreleased]` section above `## [1.35.0]`, created if absent)

- [ ] **Step 1: Write the entry**

Under `### Changed`: custom servers can no longer declare `PATH`, `HOME`, `NODE_*`, `NPM_CONFIG_*`, `DYLD_*` or `XDG_*`, because these change what code runs. An existing custom server that declares one still starts without it and logs which. Name `NODE_EXTRA_CA_CERTS` as the one most likely to be missed. Under `### Added`, one line: catalog variables naming a path or launch argument are marked per-Mac in the server docs. Keep the voice of the 1.35.0 entry. Don't rename any existing heading (a heading rename needs `make changelog`).

- [ ] **Step 2: Verify**

Run: `make changelog-check`
Expected: passes. An `Unreleased` section doesn't feed the app's notes until it's renamed at release time.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): reserved environment names and per-Mac variables"
```

---

## Phase 0: prove the gate

### Task 5: Entitlements, the embedded profile, and the assertions

**Owner steps first.** These need the Apple Developer portal. The App Store Connect MCP can create a bundle id and enable capabilities, but it cannot create a provisioning profile.

- [ ] **Step 1 (owner): Portal**

On App ID `io.mgcrea.bastion`, enable iCloud (key-value storage only, no containers). Keychain sharing needs no capability: the team prefix covers its own group. Create a **Developer ID** provisioning profile for that App ID with the Developer ID Application certificate. Download it to `apps/apple/Bastion.provisionprofile`. Provisioning profiles aren't secrets, so it's committed, and CI's release job gets it from the checkout. For `io.mgcrea.bastion.debug`, enable the same capability. Automatic signing makes the development profile on first build (`-allowProvisioningUpdates`).

- [ ] **Step 2: Inspect the profile**

Run: `security cms -D -i apps/apple/Bastion.provisionprofile | plutil -p - | grep -E 'Name|ExpirationDate|application-identifier|keychain-access-groups|ubiquity-kvstore|team-identifier|ProvisionsAllDevices'`
Expected: `ProvisionsAllDevices => 1`, `application-identifier` `75QE9PRT3V.io.mgcrea.bastion`, `keychain-access-groups` containing `75QE9PRT3V.*`, a `ubiquity-kvstore-identifier`. Record `ExpirationDate` for Task 7.

- [ ] **Step 3: Write the two entitlements files**

`apps/apple/Bastion.entitlements` (Release, literal values, used by `make sign`):

```xml
<key>com.apple.application-identifier</key><string>75QE9PRT3V.io.mgcrea.bastion</string>
<key>com.apple.developer.team-identifier</key><string>75QE9PRT3V</string>
<key>keychain-access-groups</key><array><string>75QE9PRT3V.io.mgcrea.bastion</string></array>
<key>com.apple.developer.ubiquity-kvstore-identifier</key><string>75QE9PRT3V.io.mgcrea.bastion</string>
```

`apps/apple/Bastion-Debug.entitlements`: the same four keys spelled with `$(TeamIdentifierPrefix)` / `$(AppIdentifierPrefix)$(CFBundleIdentifier)`, wired as `CODE_SIGN_ENTITLEMENTS` on the **Debug** configuration of the app target only. Each file opens with an XML comment saying what each key is for and that the set is asserted to be exactly this.

- [ ] **Step 4: Debug fallback (Review Focus 5)**

The Debug build must still build and launch where no development profile can be made, including on CI's unsigned build. Confirm `CODE_SIGNING_ALLOWED=NO` builds ignore `CODE_SIGN_ENTITLEMENTS`. If a contributor's Mac can't get a profile, `make app XCARGS="CODE_SIGN_ENTITLEMENTS="` must build a Debug app without the entitlements. Document that line in the Makefile's `app:` comment.

- [ ] **Step 5: `make sign` embeds and asserts**

Before signing the app itself: fail with `"  apps/apple/Bastion.provisionprofile is missing — a build with these entitlements and no profile is killed at launch"` if the profile is absent. Then `cp` it to `"$(RELEASE_APP)/Contents/embedded.provisionprofile"`. Sign the app with `--entitlements apps/apple/Bastion.entitlements`. Rewrite the comment block above `sign:` ("No `--entitlements` on the app…"): the claim is now that the set is exactly four keys, and it was traded on purpose for iCloud sync (`docs/keychain.md`). Replace the `grep -q '<key>'` assertion with one that extracts the signed entitlement keys (`codesign -d --entitlements - --xml … | plutil -convert json -o - - | node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(0))).sort().join(" "))'`) and compares them to the four keys sorted, printing `  entitlements are exactly the four sync needs` or failing with the difference. The Apple Development fallback identity can't carry the Developer ID profile. On that path, skip the profile and entitlements and say so, as it already warns that such a build won't notarize.

- [ ] **Step 6: `audit-listener.sh` rule 5**

Replace the `CODE_SIGN_ENTITLEMENTS` absence check with three checks:

- The pbxproj sets `CODE_SIGN_ENTITLEMENTS` only to `Bastion-Debug.entitlements`, only once.
- `apps/apple/Bastion.entitlements` holds exactly the four keys.
- If the app under audit is a Release build, its signed entitlements equal those keys.

Keep the comment's argument: a set that is exact by construction is checkable.

Run: `make bundle && BASTION_PORT=8799 make audit`
Expected: `entitlements are exactly the four sync needs`, and rule 5's checks pass.

- [ ] **Step 7: CI still builds**

Run, in the worktree: `make app XCARGS="CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"`
Expected: `BUILD SUCCEEDED`. This is what CI's App job does.

- [ ] **Step 8: Commit**

```bash
make format
git add apps/apple/Bastion.entitlements apps/apple/Bastion-Debug.entitlements \
  apps/apple/Bastion.provisionprofile apps/apple/Bastion.xcodeproj/project.pbxproj \
  Makefile scripts/audit-listener.sh
git commit -m "feat(sign): the four entitlements iCloud sync needs, and an embedded profile"
```

### Task 6: The `-iCloudProbe YES` launch mode

**Files:**

- Create: `apps/apple/Bastion/ICloudProbe.swift`
- Modify: `apps/apple/Bastion/BastionApp.swift` (`applicationDidFinishLaunching`, directly after the `DemoSeed.isEnabled` block, around line 29)
- Modify: `Makefile` (new `icloud-probe` target beside `builtin`)

**Interfaces:**

- Produces:
  - `enum ICloudProbe`
  - `static var isRequested: Bool`, from `UserDefaults.standard.bool(forKey: "iCloudProbe")`.
  - `@MainActor static func run() -> Never`.

- [ ] **Step 1: Implement `ICloudProbe`**

It prints one line per step to stdout, prefixed `probe:`, and exits `0` only if every step passed. The steps:

1. Add a generic password with service `"\(AppSupport.identifier).probe"`, account the Mac's `Host.current().localizedName ?? "unknown"`, `kSecUseDataProtectionKeychain: true`, `kSecAttrSynchronizable: true` and `kSecAttrAccessibleAfterFirstUnlock`. Print `keychain add: ok` or `keychain add: <OSStatus> <SecCopyErrorMessageString>`. `-34018` means the entitlement or profile is wrong.
2. Read it back with `kSecAttrSynchronizableAny`.
3. List every account under the probe service. A second Mac's name here proves iCloud Keychain sync.
4. `NSUbiquitousKeyValueStore.default.set(<ISO 8601 now>, forKey: "probe/<Mac name>")`, then `synchronize()`. Print the return value.
5. Wait up to 20 s for `didChangeExternallyNotification` or for a `probe/` key that isn't this Mac's. Print every `probe/` key and value seen.

It doesn't delete anything, so the second Mac's run can see the first's. A `-iCloudProbeClean YES` variant deletes the probe items and keys. The doc comment says it's a diagnostic kept for phases 1–2, and that it runs before anything real, as `DemoSeed` does.

- [ ] **Step 2: Hook it**

In `applicationDidFinishLaunching`, after the `DemoSeed` block: `if ICloudProbe.isRequested { ICloudProbe.run() }`. The comment says it runs before the stores, the gateway and Sparkle, for the reason the `DemoSeed` comment gives.

- [ ] **Step 3: `make icloud-probe`**

The target runs `"$(RELEASE_APP)/Contents/MacOS/Bastion" -iCloudProbe YES`, after `make stop`, because the release app holds `bastion.lock` and the gateway port. It prints its output. The help text says to run it on two Macs.

- [ ] **Step 4: Build and run on this Mac**

Run: `make build-release && make icloud-probe`
Expected: `keychain add: ok`, `keychain read: ok`, `kvs synchronize: true`, exit 0. If `keychain add` prints `-34018`, stop: the plan's premise fails, which is the outcome this phase exists to find. Record the exact output and go to Task 7 Step 4.

- [ ] **Step 5: Commit**

```bash
make format
git add apps/apple/Bastion/ICloudProbe.swift apps/apple/Bastion/BastionApp.swift Makefile
git commit -m "feat(icloud): a launch mode that proves the keychain and key-value store"
```

### Task 7: Run the gate on two Macs and record it

**Files:**

- Modify: `docs/keychain.md` ("Costs to weigh", the provisioning-profile bullet; "Current state" table)

- [ ] **Step 1 (owner): Second Mac**

Copy the notarized `Bastion.app` from `make build-release` to the second Mac, signed in to the same iCloud account with iCloud Keychain on. Run `Bastion.app/Contents/MacOS/Bastion -iCloudProbe YES` there, then `make icloud-probe` again here.
Expected: each Mac lists the other's `probe/<name>` key and keychain account. Key-value storage can take minutes, so re-run if empty.

- [ ] **Step 2: Profile expiry**

Look up Apple's current documentation on Developer ID provisioning profile lifetime, and on what macOS does with a restricted entitlement when the embedded profile has expired, for launch and for keychain access. Compare against the `ExpirationDate` recorded in Task 5 Step 2. If the docs don't settle it, say so, and record that the profile date is the deadline for shipping a renewed profile.

- [ ] **Step 3: Launch check (Review Focus 4)**

On the second Mac, open the notarized app normally, not with the probe. It must launch, and `spctl -a -vv Bastion.app` must say `accepted`, `source=Notarized Developer ID`.

- [ ] **Step 4: Record the result in `docs/keychain.md`**

Rewrite the provisioning-profile bullet with what Step 2 found, with sources. In the "Current state" table, set `keychain-access-groups entitlement + migration` to `Gate passed <date>: entitlements and profile shipped, migration not started` (or the exact failure). Add a row `iCloud key-value storage` with the same treatment. Mention `make icloud-probe`.

- [ ] **Step 5: Commit**

```bash
make format
git add docs/keychain.md
git commit -m "docs(keychain): the iCloud gate, run on two Macs"
```

The gate's outcome decides the next plan. If both stores work, plan phases 1–3. If only key-value storage works, plan phase 2 alone, as the spec's fallback says.
