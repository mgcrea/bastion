# Rename a Profile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a profile be renamed from the server pane and from Bastion's own MCP server, keeping its credentials, sign-ins, workspaces, history and client wiring.

**Architecture:** One `ProfileStore.rename(_:to:)` does the work in a fixed order, so that a failure before `profiles.json` is saved leaves the old profile untouched. Keychain and state-directory moves live in a small new `ProfileRename` enum. The two migrations that can be tested offline are pure helpers: `CallStatsRollup.renamingProfile` (stats) and `WorkspaceScope.renamingProfile` (workspaces). The UI is a sheet opened from the profile row. The MCP tool is `rename_profile`.

**Tech Stack:** Swift 6 / SwiftUI macOS app (`apps/apple/Bastion`). Xcode uses file-system synchronized groups, so new `.swift` files need no `project.pbxproj` edit. The tests are standalone `swiftc` check programs (`make unit`, `make wiring-check`) and a bash end-to-end check run against a Debug build (`make builtin`).

**Spec:** `docs/superpowers/specs/2026-10-14-rename-profile-design.md`

## Global Constraints

- Profile name rule: `Profile.isValidName`. Non-empty, ≤ 64 characters, `^[a-z0-9][a-z0-9-]*$`.
- Profile id: `"<name>/<server>"`. Keychain accounts: `"<name>/<server>/<VAR>"` (`.profile`) and `"<name>/<server>/oauth"` (`.oauth`).
- State directory: `ProfileEnvironment.directory(profile:server:)` = `<AppSupport>/profiles/<server>/<name>`.
- Nothing before the `profiles.json` save may leave a half-renamed profile. Every step before it undoes its own work when it fails.
- Audit chain lines are never rewritten.
- Never touch the real Keychain or Application Support under `DemoSeed.isEnabled` (screenshot captures).
- The user-facing consequence sentence, used verbatim in the sheet and paraphrased in the tool description: _"Its credentials, sign-ins, workspaces and history move with it. Clients Bastion configured are updated, and their tools appear under the new name, so permission rules that name the old one stop matching. A client set up by hand keeps pointing at the old address."_
- Comment style: match the files you touch. Comments explain _why_, in full sentences. No em dashes in new user-facing copy.
- Commit style: `feat(profiles): …`, `docs(profiles): …`, `test(profiles): …`.

## Review Focus

1. **A Keychain read refused part-way through the copy** (the user clicks Deny on an ACL prompt). Expected: the rename stops, the copies already made are deleted, and the old profile still works. Owned by Task 3 (`copySecrets` uses throwing `lookup`, not `read`). Verified by hand in Task 7.
2. **A leftover state directory under the new name**, left by a profile removed earlier (`remove` never deletes its directory). Expected: it goes to the Trash and the renamed profile does not inherit its tokens. Pinned in Task 5's builtin check.
3. **Renaming back to a name the profile used before** (`a → b → a`). Old stats rows under `a` belong to the same profile. Expected: they merge, with no duplicate rows and no lost counts. Pinned in Task 1's unit checks (merge on collision).
4. **A workspace already holding the new id** (hand-edited, or a dead profile's id kept by design). Expected: the workspace ends up with one copy of the new id, not two. Pinned in Task 2's wiring checks.
5. **The old endpoint after a rename.** Expected: a client still on `/s/<old>/<server>` gets the gateway's `no profile '<old>' for <server>` sentence, not a crash or a stale child. Pinned in Task 5's builtin check.

---

## File Structure

| File                                                  | Change     | Responsibility                                                                      |
| ----------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------- |
| `apps/apple/Bastion/CallStatsRollup.swift`            | modify     | `renamingProfile(_:from:to:server:)`, pure, merges collisions                       |
| `apps/apple/Bastion/WorkspaceScope.swift`             | modify     | `WorkspaceScope.renamingProfile(_:from:to:)`, pure                                  |
| `apps/apple/Bastion/CallStats.swift`                  | modify     | `renameProfile(from:to:server:)` re-keys live tables via the helper                 |
| `apps/apple/Bastion/ToolCostStore.swift`              | modify     | `move(from:to:)`                                                                    |
| `apps/apple/Bastion/Workspaces.swift`                 | modify     | `WorkspaceStore.renameProfile(from:to:)`                                            |
| `apps/apple/Bastion/ProfileRename.swift`              | **create** | Keychain copy and sweep, state-directory move                                       |
| `apps/apple/Bastion/Profiles.swift`                   | modify     | `Profile.nameProblem(_:)`, `ProfileStore.RenameError`, `ProfileStore.rename(_:to:)` |
| `apps/apple/Bastion/RenameProfileSheet.swift`         | **create** | The rename sheet                                                                    |
| `apps/apple/Bastion/ServerDetail.swift`               | modify     | Rename… button in `ProfileRow`, sheet on the pane                                   |
| `apps/apple/Bastion/ProfileEditor.swift`              | modify     | Captions; use `Profile.nameProblem`                                                 |
| `apps/apple/Bastion/BuiltinTools.swift`               | modify     | `rename_profile` declaration, dispatch, implementation                              |
| `scripts/unit-check.swift`                            | modify     | Stats re-key checks                                                                 |
| `scripts/wiring-check.swift`                          | modify     | Workspace substitution and retire-on-rename checks                                  |
| `scripts/builtin-check.sh`                            | modify     | End-to-end rename checks                                                            |
| `docs/keychain.md`, `docs/clients.md`, `CHANGELOG.md` | modify     | Docs                                                                                |

---

### Task 1: Stats re-key helper

**Files:**

- Modify: `apps/apple/Bastion/CallStatsRollup.swift` (add after `prune`, around line 401)
- Test: `scripts/unit-check.swift` (new section between the `"Usage rollup: retention"` and `"Usage rollup: the file"` sections, around line 1795)

**Interfaces:**

- Produces: `CallStatsRollup.renamingProfile(_ days: [Day], from old: String, to new: String, server: String) -> [Day]`. Every `CallRow`, `ClientRow` and `LifeRow` whose `(profile, server)` is `(old, server)` is filed under `new`. A row that then shares its full key with another row in the same day is merged into it (`Bucket.merge` / `LifeRow.merge`). The first occurrence's position is kept.

- [ ] **Step 1: Write the failing checks.** In `scripts/unit-check.swift`, directly before `print("\nUsage rollup: the file")`, insert:

```swift
    print("\nUsage rollup: a renamed profile")

    var one = Bucket()
    one.record(milliseconds: 40, bytes: 100, failed: false)
    var two = Bucket()
    two.record(milliseconds: 900, bytes: 50, failed: true)
    let beforeRename = [
      CallStatsRollup.Day(
        day: 10,
        rows: [
          CallStatsRollup.CallRow(
            profile: "prod", server: "shopify", label: "get_order", isTool: true, bucket: one),
          // A removed profile's leftover under the name being taken.
          CallStatsRollup.CallRow(
            profile: "live", server: "shopify", label: "get_order", isTool: true, bucket: two),
          // Same profile name, another server: not this profile.
          CallStatsRollup.CallRow(
            profile: "prod", server: "stripe", label: "get_order", isTool: true, bucket: one),
        ],
        clients: [
          CallStatsRollup.ClientRow(client: "code", profile: "prod", server: "shopify", bucket: one),
          CallStatsRollup.ClientRow(client: "code", profile: "live", server: "shopify", bucket: two),
        ],
        life: [
          CallStatsRollup.LifeRow(profile: "prod", server: "shopify", starts: 2, exits: 1),
          CallStatsRollup.LifeRow(profile: "live", server: "shopify", starts: 1, restarts: 1),
        ])
    ]
    let renamedDays = CallStatsRollup.renamingProfile(
      beforeRename, from: "prod", to: "live", server: "shopify")
    let renamedDay = renamedDays.first!
    let shopifyRows = renamedDay.rows.filter { $0.server == "shopify" }
    check("the renamed profile's rows carry the new name", shopifyRows.allSatisfy { $0.profile == "live" })
    check("and land on a leftover row as one row, not two", shopifyRows.count == 1)
    check("merged rather than overwritten", shopifyRows.first?.bucket == one.merged(with: two))
    check(
      "the same name on another server is left alone",
      renamedDay.rows.contains { $0.server == "stripe" && $0.profile == "prod" })
    check(
      "client rows move and merge too",
      renamedDay.clients.count == 1 && renamedDay.clients.first?.bucket == one.merged(with: two)
        && renamedDay.clients.first?.profile == "live")
    let movedLife = renamedDay.life.first
    check(
      "life rows move and merge too",
      renamedDay.life.count == 1 && movedLife?.profile == "live" && movedLife?.starts == 3
        && movedLife?.restarts == 1 && movedLife?.exits == 1)
    check(
      "a rename that matches nothing changes nothing",
      CallStatsRollup.renamingProfile(beforeRename, from: "nope", to: "x", server: "shopify")
        .first?.rows.count == 3)
```

- [ ] **Step 2: Run them to see them fail.** Run `make unit`. Expected: a compile error, `type 'CallStatsRollup' has no member 'renamingProfile'`.

- [ ] **Step 3: Implement the helper.** In `apps/apple/Bastion/CallStatsRollup.swift`, after the closing brace of `prune(_:today:maxDays:maxBytes:)`, add:

```swift
  /// `days` with every row of `old` on `server` filed under `new`.
  ///
  /// Merged into a row already filed there, never written over it:
  /// `ProfileStore.remove` leaves a profile's history behind, so the name being
  /// taken can already hold rows of a profile that was deleted under it, or of
  /// this one, renamed away and back. Rows keep the order they had, which is
  /// the order `absorb` and the panes have always seen.
  static func renamingProfile(_ days: [Day], from old: String, to new: String, server: String)
    -> [Day]
  {
    func moved(_ profile: String, _ rowServer: String) -> String {
      profile == old && rowServer == server ? new : profile
    }
    return days.map { day in
      var out = Day(day: day.day)
      var calls: [[String]: Int] = [:]
      for var row in day.rows {
        row.profile = moved(row.profile, row.server)
        let key = [row.profile, row.server, row.label, row.isTool ? "tool" : "method"]
        if let at = calls[key] {
          out.rows[at].bucket.merge(row.bucket)
        } else {
          calls[key] = out.rows.count
          out.rows.append(row)
        }
      }
      var clients: [[String]: Int] = [:]
      for var row in day.clients {
        row.profile = moved(row.profile, row.server)
        let key = [row.client, row.profile, row.server]
        if let at = clients[key] {
          out.clients[at].bucket.merge(row.bucket)
        } else {
          clients[key] = out.clients.count
          out.clients.append(row)
        }
      }
      var life: [[String]: Int] = [:]
      for var row in day.life {
        row.profile = moved(row.profile, row.server)
        let key = [row.profile, row.server]
        if let at = life[key] {
          out.life[at].merge(row)
        } else {
          life[key] = out.life.count
          out.life.append(row)
        }
      }
      return out
    }
  }
```

- [ ] **Step 4: Run them to see them pass.** Run `make unit`. Expected: every check in "Usage rollup: a renamed profile" prints `ok`, and the run ends `N/N passed`.

- [ ] **Step 5: Commit.**

```bash
git add apps/apple/Bastion/CallStatsRollup.swift scripts/unit-check.swift
git commit -m "feat(profiles): re-key a renamed profile's usage rows, merging collisions"
```

---

### Task 2: Workspace substitution and the retire-on-rename merge

**Files:**

- Modify: `apps/apple/Bastion/WorkspaceScope.swift` (in `enum WorkspaceScope`, after `scopedIDs`, around line 146)
- Test: `scripts/wiring-check.swift` (two new `static func`s, registered in `main` next to `retiredProfileEntryIsRemoved()` at line 117 and `workspaceAssignments()` at line 163)

**Interfaces:**

- Produces: `WorkspaceScope.renamingProfile(_ workspaces: [Workspace], from oldID: String, to newID: String) -> [Workspace]`. A workspace holding `oldID` ends up holding `newID` exactly once, and its `profiles` are sorted (as `WorkspaceStore.upsert` stores them). A workspace without `oldID` is returned unchanged.

- [ ] **Step 1: Write the failing checks.** In `scripts/wiring-check.swift`, add these two functions after `workspaceAssignments()`:

```swift
  static func workspaceProfileRename() {
    print("\nWorkspaces: a renamed profile")
    let workspaces = [
      Workspace(name: "rgis", folders: ["A"], profiles: ["prod/npm", "rgis/ovh"]),
      // Already holds the new id: a dead profile's id kept by design.
      Workspace(name: "both", folders: ["B"], profiles: ["live/ovh", "rgis/ovh"]),
      Workspace(name: "other", folders: ["C"], profiles: ["prod/npm"]),
    ]
    let out = WorkspaceScope.renamingProfile(workspaces, from: "rgis/ovh", to: "live/ovh")
    check("the id is swapped", out[0].profiles == ["live/ovh", "prod/npm"])
    check("a workspace already holding the new id keeps one", out[1].profiles == ["live/ovh"])
    check("a workspace without the old id is untouched", out[2] == workspaces[2])
    check("nothing else about a workspace moves", out[0].folders == ["A"] && out[0].name == "rgis")
  }

  /// A renamed profile changes its endpoint, so the merge cannot recognise the
  /// old entry as the one it is replacing. `ProfileStore.rename` names it.
  static func renamedProfileLeavesOneEntry() {
    print("\nRenamed profiles")
    let before: [String: Any] = [
      "mcpServers": [
        "prod-shopify": ["type": "http", "url": "http://127.0.0.1:8720/s/prod/shopify"]
      ]
    ]
    let entries = ["live-shopify": entry(httpReach("shopify", profile: "live"))]

    let untold = ClientWiringMerge.merged(into: before, rootKey: "mcpServers", entries: entries)
    check(
      "without being told, the old entry survives beside the new one",
      (untold["mcpServers"] as? [String: Any])?.count == 2)

    let out = ClientWiringMerge.merged(
      into: before, rootKey: "mcpServers", entries: entries, retiring: ["prod/shopify"])
    let after = out["mcpServers"] as? [String: Any] ?? [:]
    check("retiring the old id leaves exactly one entry", after.count == 1)
    check("and it is the new one", after["live-shopify"] != nil)
  }
```

In `main`, register them. Put `renamedProfileLeavesOneEntry()` on the line after `retiredProfileEntryIsRemoved()`, and `workspaceProfileRename()` on the line after `workspaceAssignments()`.

- [ ] **Step 2: Run them to see them fail.** Run `make wiring-check`. Expected: a compile error, `type 'WorkspaceScope' has no member 'renamingProfile'`.

- [ ] **Step 3: Implement the helper.** In `apps/apple/Bastion/WorkspaceScope.swift`, after `scopedIDs`:

```swift
  /// `workspaces` with one profile id swapped for another, for a rename.
  ///
  /// A workspace that already holds the new id (a dead profile's id is kept by
  /// design, see `Workspace`) ends up with it once. Sorted, the way
  /// `WorkspaceStore.upsert` stores them.
  static func renamingProfile(_ workspaces: [Workspace], from oldID: String, to newID: String)
    -> [Workspace]
  {
    workspaces.map { workspace in
      guard workspace.profiles.contains(oldID) else { return workspace }
      var next = workspace
      next.profiles = (next.profiles.filter { $0 != oldID && $0 != newID } + [newID]).sorted()
      return next
    }
  }
```

- [ ] **Step 4: Run them to see them pass.** Run `make wiring-check`. Expected: the "Workspaces: a renamed profile" and "Renamed profiles" sections are all `ok`. Note that the "without being told" check documents current `merged` behaviour, so it passes before and after this change. Only the helper check was failing.

- [ ] **Step 5: Commit.**

```bash
git add apps/apple/Bastion/WorkspaceScope.swift scripts/wiring-check.swift
git commit -m "feat(profiles): swap a renamed profile's id in workspaces"
```

---

### Task 3: The store-side rename

This task has no offline harness: `ProfileStore` is not compiled by any check program. It is verified by building here and end to end in Task 5.

**Files:**

- Create: `apps/apple/Bastion/ProfileRename.swift`
- Modify: `apps/apple/Bastion/CallStats.swift` (new method after `noteExited`, around line 254)
- Modify: `apps/apple/Bastion/ToolCostStore.swift` (new method after `forget`, around line 90)
- Modify: `apps/apple/Bastion/Workspaces.swift` (new method after `remove(named:)`, around line 121)
- Modify: `apps/apple/Bastion/Profiles.swift` (`Profile.nameProblem` after `isValidName`, around line 43; `RenameError` and `rename` after `remove`, around line 331)

**Interfaces:**

- Consumes: `CallStatsRollup.renamingProfile` (Task 1), `WorkspaceScope.renamingProfile` (Task 2).
- Produces:
  - `Profile.nameProblem(_ name: String) -> String?`: nil when `isValidName`, otherwise the sentence the UI shows.
  - `ProfileStore.RenameError: LocalizedError` with cases `invalidName(String)`, `unchanged(String)`, `taken(name: String, server: String)`, `noSuchProfile(String)`.
  - `@discardableResult ProfileStore.rename(_ profile: Profile, to newName: String) throws -> Profile`, which returns the renamed profile.
  - `CallStats.renameProfile(from: String, to: String, server: String)`
  - `ToolCostStore.move(from oldID: String, to newID: String)`
  - `WorkspaceStore.renameProfile(from oldID: String, to newID: String) throws`
  - `ProfileRename.copySecrets(from:to:server:) throws -> [ProfileRename.Copied]`, `ProfileRename.delete(_ copied: [Copied])`, `ProfileRename.sweepSecrets(profile:server:)`, `ProfileRename.moveState(from:to:server:) throws`

- [ ] **Step 1: Create `apps/apple/Bastion/ProfileRename.swift`.**

```swift
import Foundation

/// What a profile rename moves outside `profiles.json`: its Keychain items and
/// its state directory.
///
/// Copy first, delete last. `ProfileStore.rename` copies the items and moves
/// the directory before it saves the new name, and deletes the old items only
/// after, so a failure anywhere before the save leaves the profile exactly as
/// it was.
nonisolated enum ProfileRename {
  /// One Keychain item written under the new name, kept so a failure later can
  /// take it back.
  struct Copied {
    let scope: CredentialStore.Scope
    let account: String
  }

  /// Every `.profile` and `.oauth` item of `old` on `server`, written again
  /// under `new` with the same suffix.
  ///
  /// `lookup`, never `read`. `read` answers a refused ACL prompt with nil,
  /// which here would skip the item and then let the sweep after the save
  /// delete the only copy of a secret. A refusal stops the rename instead.
  static func copySecrets(from old: String, to new: String, server: String) throws -> [Copied] {
    let oldPrefix = "\(old)/\(server)/"
    let newPrefix = "\(new)/\(server)/"
    var copied: [Copied] = []
    do {
      for scope in [CredentialStore.Scope.profile, .oauth] {
        for account in CredentialStore.accounts(scope) where account.hasPrefix(oldPrefix) {
          guard let value = try CredentialStore.lookup(scope, account: account), !value.isEmpty
          else { continue }
          let target = newPrefix + account.dropFirst(oldPrefix.count)
          try CredentialStore.write(scope, account: target, value: value)
          copied.append(Copied(scope: scope, account: target))
        }
      }
    } catch {
      delete(copied)
      throw error
    }
    return copied
  }

  /// Take back copies made by `copySecrets`.
  static func delete(_ copied: [Copied]) {
    for item in copied {
      try? CredentialStore.delete(item.scope, account: item.account)
    }
  }

  /// Delete every item under the old name, once the new one is saved.
  ///
  /// Logged, not thrown: the rename has happened by now, and an item left
  /// under a name nothing serves is inert.
  static func sweepSecrets(profile: String, server: String) {
    let prefix = "\(profile)/\(server)/"
    for scope in [CredentialStore.Scope.profile, .oauth] {
      for account in CredentialStore.accounts(scope) where account.hasPrefix(prefix) {
        do {
          try CredentialStore.delete(scope, account: account)
        } catch {
          hostLog("profiles", .error, "could not delete \(account) after a rename: \(error.localizedDescription)")
        }
      }
    }
  }

  /// Move the state directory, where a child keeps its own sign-in and the
  /// callback port it was given.
  ///
  /// Whatever already sits under the new name goes to the Trash first.
  /// `ProfileStore.remove` leaves a profile's directory behind, so that is a
  /// dead profile's tokens, and inheriting them is the bug. The Trash keeps it
  /// recoverable.
  static func moveState(from old: String, to new: String, server: String) throws {
    if DemoSeed.isEnabled { return }
    let files = FileManager.default
    let source = ProfileEnvironment.directory(profile: old, server: server)
    let target = ProfileEnvironment.directory(profile: new, server: server)
    if files.fileExists(atPath: target.path) {
      try files.trashItem(at: target, resultingItemURL: nil)
      hostLog("profiles", .info, "moved a leftover '\(new)/\(server)' state directory to the Trash")
    }
    guard files.fileExists(atPath: source.path) else { return }
    try files.moveItem(at: source, to: target)
  }
}
```

- [ ] **Step 2: Add `ToolCostStore.move`.** After `forget(_:)` in `ToolCostStore.swift`:

```swift
  /// Carry a profile's figure to its new id. A rename changes nothing the
  /// figure was measured from, so dropping it would only cost a re-measure.
  func move(from oldID: String, to newID: String) {
    guard let measurement = measurements.removeValue(forKey: oldID) else { return }
    measurements[newID] = measurement
    save()
  }
```

- [ ] **Step 3: Add `CallStats.renameProfile`.** After `noteExited(profile:server:)` in `CallStats.swift`:

```swift
  /// File a renamed profile's history under its new name.
  ///
  /// Through the rows rather than key by key: `CallStatsRollup.renamingProfile`
  /// holds the rule where `make unit` can check it, and `absorb` already
  /// rebuilds every table from rows, label counts included.
  func renameProfile(from old: String, to new: String, server: String) {
    state.withLock { table in
      guard table.writable, table.loaded else { return }
      let days = CallStatsRollup.renamingProfile(
        Self.materialise(table), from: old, to: new, server: server)
      table.calls = [:]
      table.clients = [:]
      table.life = [:]
      table.labels = [:]
      Self.absorb(days, into: &table)
      table.dirty = true
    }
  }
```

- [ ] **Step 4: Add `WorkspaceStore.renameProfile`.** After `remove(named:)` in `Workspaces.swift`:

```swift
  /// Swap a renamed profile's id in every workspace that holds it.
  ///
  /// No rewire, unlike `upsert`: `ProfileStore.rename` rewires once, retiring
  /// the old id, after everything has moved.
  func renameProfile(from oldID: String, to newID: String) throws {
    let next = WorkspaceScope.renamingProfile(workspaces, from: oldID, to: newID)
    guard next != workspaces else { return }
    workspaces = next
    try save()
  }
```

- [ ] **Step 5: Add `Profile.nameProblem`.** In `Profiles.swift`, inside `struct Profile`, after `isValidName`:

```swift
  /// Why `name` cannot be a profile name, or nil when it can. The sentences
  /// the editor and the rename sheet show, kept beside the rule they explain.
  static func nameProblem(_ name: String) -> String? {
    guard !isValidName(name) else { return nil }
    if name.count > 64 { return "A name is at most 64 characters." }
    return "A name must be lower case letters, digits and hyphens, and start with one."
  }
```

- [ ] **Step 6: Add `RenameError` and `rename`.** In `Profiles.swift`, inside `ProfileStore`, after `remove(_:)`:

```swift
  enum RenameError: LocalizedError {
    case invalidName(String)
    case unchanged(String)
    case taken(name: String, server: String)
    case noSuchProfile(String)

    var errorDescription: String? {
      switch self {
      case .invalidName(let name):
        "'\(name)' cannot be a profile name. \(Profile.nameProblem(name) ?? "")"
      case .unchanged(let name): "The profile is already called '\(name)'."
      case .taken(let name, let server): "A profile named '\(name)' already exists for \(server)."
      case .noSuchProfile(let id): "There is no profile '\(id)' to rename."
      }
    }
  }

  /// Give a profile a new name, and move everything that is keyed by it.
  ///
  /// The name is the profile id, the endpoint path, the Keychain account
  /// prefix and the state directory, so a rename is a move of each. Ordered so
  /// that nothing is lost on the way: the Keychain items are copied and the
  /// directory moved BEFORE `profiles.json` is saved, each undone if a later
  /// step fails, and the old items are deleted only after. From the save on,
  /// the gateway serves the new endpoint and answers the old one with "no
  /// profile".
  ///
  /// Here rather than in the sheet, for the reason `upsert` gives: the tool
  /// `rename_profile` is the other caller.
  @discardableResult
  func rename(_ profile: Profile, to newName: String) throws -> Profile {
    let server = profile.serverID
    guard Profile.isValidName(newName) else { throw RenameError.invalidName(newName) }
    guard newName != profile.name else { throw RenameError.unchanged(newName) }
    // The set-aside rows too: an orphan's Keychain items are live, and the
    // copy below would write over them.
    guard self.profile(named: newName, server: server) == nil,
      !orphaned.contains(where: { $0.name == newName && $0.server == server })
    else { throw RenameError.taken(name: newName, server: server) }
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
      throw RenameError.noSuchProfile(profile.id)
    }
    // Before anything moves, not at the save: `save()` refuses an unreadable
    // file, and finding that out after the Keychain copy is a rollback for
    // nothing.
    if let unreadable { throw unreadable }

    let oldID = profile.id
    let renamed = Profile(
      name: newName, serverID: server, values: profile.values,
      allowWrites: profile.allowWrites, captureMode: profile.captureMode)

    // Nothing may hold the old directory or the old credentials while they move.
    Supervisor.shared.stop(profile: profile.name, server: server)
    ServerCheck.shared.forget(oldID)
    CapabilityStore.shared.forget(oldID)

    let copied = try ProfileRename.copySecrets(from: profile.name, to: newName, server: server)
    do {
      try ProfileRename.moveState(from: profile.name, to: newName, server: server)
    } catch {
      ProfileRename.delete(copied)
      throw error
    }

    profiles[index] = renamed
    do {
      try save()
    } catch {
      profiles[index] = profile
      refreshSnapshot()
      try? ProfileRename.moveState(from: newName, to: profile.name, server: server)
      ProfileRename.delete(copied)
      throw error
    }

    // Committed. Everything below finishes the move and none of it can undo
    // the rename, so a failure is logged rather than thrown.
    ProfileRename.sweepSecrets(profile: profile.name, server: server)
    ToolCostStore.shared.move(from: oldID, to: renamed.id)
    CallStats.shared.renameProfile(from: profile.name, to: newName, server: server)
    do {
      try WorkspaceStore.shared.renameProfile(from: oldID, to: renamed.id)
    } catch {
      // Only when `workspaces.json` is unreadable, which the Workspaces pane
      // already reports and which refuses every workspace save alike.
      hostLog(
        "profiles", .error,
        "renamed \(oldID) to \(renamed.id) but could not update workspaces: "
          + error.localizedDescription)
    }
    // Named, because the endpoint changed: `merged` recognises an entry it is
    // replacing only by endpoint, so without this every client keeps the old
    // entry beside the new one.
    ClientWiring.rewire(retiring: [oldID])
    return renamed
  }
```

- [ ] **Step 7: Build.** Run `make app`. Expected: `** BUILD SUCCEEDED **` with no new warnings in the five files touched.

- [ ] **Step 8: Run the offline checks again.** Run `make unit && make wiring-check`. Expected: both pass. They compile `CallStatsRollup.swift` and `WorkspaceScope.swift`, which this task did not change, so this confirms Tasks 1 and 2 still hold.

- [ ] **Step 9: Commit.**

```bash
git add apps/apple/Bastion/ProfileRename.swift apps/apple/Bastion/Profiles.swift \
  apps/apple/Bastion/CallStats.swift apps/apple/Bastion/ToolCostStore.swift \
  apps/apple/Bastion/Workspaces.swift
git commit -m "feat(profiles): rename a profile, moving its secrets, state, stats and workspaces"
```

---

### Task 4: The rename sheet

**Files:**

- Create: `apps/apple/Bastion/RenameProfileSheet.swift`
- Modify: `apps/apple/Bastion/ServerDetail.swift`. State at line ~34, sheets at ~73-82, the `ProfileRow(...)` call at ~1008-1017, `ProfileRow` properties at ~1220-1228, and its button row at ~1318-1324.
- Modify: `apps/apple/Bastion/ProfileEditor.swift`. `nameProblem` at ~97-101, captions at ~117-130.

**Interfaces:**

- Consumes: `ProfileStore.rename(_:to:)` and `Profile.nameProblem(_:)` (Task 3).
- Produces: `RenameProfileSheet(profile: Profile, server: BastionServer, report: @escaping (String?) -> Void)`.

- [ ] **Step 1: Create `apps/apple/Bastion/RenameProfileSheet.swift`.**

```swift
import SwiftUI

/// Asks for a profile's new name, says what a rename changes, and does it.
///
/// A sheet rather than an alert, because the name is checked as it is typed
/// and an alert's message cannot change under its field.
struct RenameProfileSheet: View {
  let profile: Profile
  let server: BastionServer
  let report: (String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var error: String?

  init(profile: Profile, server: BastionServer, report: @escaping (String?) -> Void) {
    self.profile = profile
    self.server = server
    self.report = report
    _name = State(initialValue: profile.name)
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

  /// Why the typed name cannot be used, or nil. The current name and an empty
  /// field are not complaints, just nothing to do yet.
  private var problem: String? {
    guard !trimmed.isEmpty, trimmed != profile.name else { return nil }
    if let rule = Profile.nameProblem(trimmed) { return rule }
    if ProfileStore.shared.profile(named: trimmed, server: server.id) != nil {
      return "A profile named '\(trimmed)' already exists for \(server.displayName)."
    }
    return nil
  }

  private var canRename: Bool { !trimmed.isEmpty && trimmed != profile.name && problem == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename '\(profile.name)'").font(.headline)
      TextField("Name", text: $name, prompt: Text(profile.name))
        .textFieldStyle(.roundedBorder)
        .onSubmit { if canRename { rename() } }
      if let shown = problem ?? error {
        Label(shown, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      }
      Text(
        "Its credentials, sign-ins, workspaces and history move with it. Clients Bastion "
          + "configured are updated, and their tools appear under the new name, so permission "
          + "rules that name the old one stop matching. A client set up by hand keeps pointing "
          + "at the old address."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { rename() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canRename)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func rename() {
    do {
      try ProfileStore.shared.rename(profile, to: trimmed)
      report(nil)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
```

- [ ] **Step 2: Present it from the pane.** In `ServerDetail.swift`:

Next to `@State private var browsing: Profile?` (line ~34), add:

```swift
  @State private var renaming: Profile?
```

After the `.sheet(item: $browsing) { … }` modifier (line ~80), add:

```swift
    // On the pane, not the row: the row's identity is the profile id, which is
    // exactly what a rename changes, so a sheet hung on the row would be torn
    // down with it.
    .sheet(item: $renaming) { profile in
      RenameProfileSheet(profile: profile, server: server, report: { lastError = $0 })
    }
```

In the `ProfileRow(...)` call (line ~1008), add the argument after `edit:`:

```swift
                rename: { renaming = profile },
```

In `struct ProfileRow`, add the property after `let edit: () -> Void`:

```swift
  let rename: () -> Void
```

In `ProfileRow`'s button row, between the `Edit…` button and the `Remove` button:

```swift
        Button {
          rename()
        } label: {
          Label("Rename…", systemImage: "character.cursor.ibeam")
        }
        .help("Give this profile a new name. Its credentials and history move with it.")
```

Then update the comment above the `HStack(spacing: 8)` that says "four things you can do to this profile". It should no longer state a count: "…they read as what they are, things you can do to this profile."

- [ ] **Step 3: Point the editor at Rename… and share the name rule.** In `ProfileEditor.swift`:

Replace the body of `nameProblem` (line ~97-101) with:

```swift
  private var nameProblem: String? {
    guard !trimmedName.isEmpty else { return nil }
    return Profile.nameProblem(trimmedName)
  }
```

Replace the new-profile caption text with:

```swift
              "Lower case, digits and hyphens. It becomes a URL path segment, a Keychain account "
                + "and a directory name. Rename it later from the profile's row."
```

Replace the existing-profile caption text with:

```swift
              "To change the name, close this and choose Rename… on the profile's row. Its "
                + "credentials and history move with it."
```

- [ ] **Step 4: Build.** Run `make app`. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Try it in the Debug app.** Launch `apps/apple/.build/Build/Products/Debug/Bastion.app`. On a server with a scratch profile:
  - Open Rename…. Typing `Bad Name` shows the orange rule sentence and disables Rename. Typing an existing sibling's name shows "already exists". Typing the current name disables Rename with no message.
  - Rename to a fresh name. The sheet closes, the row shows the new name and endpoint, and any error appears in the pane's usual error line.
  - Open Edit… on the renamed profile. The caption points at Rename….

- [ ] **Step 6: Commit.**

```bash
git add apps/apple/Bastion/RenameProfileSheet.swift apps/apple/Bastion/ServerDetail.swift \
  apps/apple/Bastion/ProfileEditor.swift
git commit -m "feat(profiles): Rename… on a profile's row"
```

---

### Task 5: `rename_profile` tool and its end-to-end check

**Files:**

- Modify: `apps/apple/Bastion/BuiltinTools.swift`. Declaration after `remove_profile` (~line 415), dispatch after `case "remove_profile"` (~597), implementation after `removeProfile` (~1832).
- Test: `scripts/builtin-check.sh` (new section before `echo "Cleanup"`, ~line 437)

**Interfaces:**

- Consumes: `ProfileStore.rename(_:to:)` (Task 3).
- Produces: tool `rename_profile {name, server, new_name}`. It is a mutating tool, so the write gate applies. Its reply is `{name, previous_name, server, endpoint, note}`.

- [ ] **Step 1: Write the failing checks.** In `scripts/builtin-check.sh`, directly before `echo` / `echo "Cleanup"`, insert the following. It reuses the `checkscratch` server and its profile `one`, which holds the `CHECK_TOKEN` credential and is set up in "Secrets are write-only":

```bash
echo
echo "Renaming a profile"
SCRATCH_STATE="$SUPPORT/profiles/checkscratch"
mkdir -p "$SCRATCH_STATE/one" "$SCRATCH_STATE/two"
echo kept > "$SCRATCH_STATE/one/marker"
# A removed profile's leftover under the name being taken: it must not be inherited.
echo dead > "$SCRATCH_STATE/two/leftover"
check "rename_profile is refused with writes off" \
  "$(tool checkro rename_profile '{"name":"one","server":"checkscratch","new_name":"two"}')" \
  'write gate is off'
RENAMED="$(tool checkrw rename_profile '{"name":"one","server":"checkscratch","new_name":"two"}')"
check "rename_profile answers with the new endpoint" "$RENAMED" '/s/two/checkscratch'
AFTER="$(tool checkrw list_profiles '{"server":"checkscratch"}')"
check  "the profile is listed under its new name" "$AFTER" '"name":"two"'
absent "and not under its old one"                "$AFTER" '"name":"one"'
check  "its secret moved with it"                 "$AFTER" '"secrets_set":["CHECK_TOKEN"]'
absent "and nothing is reported missing"          "$AFTER" '"missing"'
check  "its state directory moved with it" "$(cat "$SCRATCH_STATE/two/marker" 2>&1)" 'kept'
absent "a leftover under the new name is not inherited" \
  "$(ls "$SCRATCH_STATE/two")" 'leftover'
tool checkrw upsert_profile '{"name":"three","server":"checkscratch"}' >/dev/null
check "renaming onto an existing name is refused" \
  "$(tool checkrw rename_profile '{"name":"two","server":"checkscratch","new_name":"three"}')" \
  'already exists'
check "an unusable name is refused" \
  "$(tool checkrw rename_profile '{"name":"two","server":"checkscratch","new_name":"Two Words"}')" \
  'cannot be a profile name'
# The old endpoint, on a profile the gateway can actually serve.
tool checkrw upsert_profile '{"name":"checkmove","server":"bastion"}' >/dev/null
tool checkrw rename_profile '{"name":"checkmove","server":"bastion","new_name":"checkmoved"}' >/dev/null
check "the old endpoint answers with a sentence, not a stale server" \
  "$(rpc checkmove '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')" "no profile 'checkmove'"
check "and the new one serves" \
  "$(rpc checkmoved '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')" '"tools"'
tool checkrw remove_profile '{"name":"checkmoved","server":"bastion"}' >/dev/null
```

`remove_server` in "Cleanup" removes `two` and `three` along with `checkscratch`. The `checkscratch` state directory is left behind, as it already is today. Also add `"checkmove", "checkmoved"` to the names the Python seed block strips from `profiles.json` (the tuple `("checkro", "checkrw", "checknosy")`, ~line 103), so an interrupted run does not leave them behind.

- [ ] **Step 2: Run it to see it fail.** Run `make builtin`. Expected: the "Renaming a profile" checks FAIL. The tool does not exist yet, so the replies carry the unknown-tool sentence instead.

- [ ] **Step 3: Add the declaration.** After the `remove_profile` `Declaration(...)` in `BuiltinTools.swift`:

```swift
    Declaration(
      "rename_profile", title: "Rename a profile",
      "Give a profile a new name. Its credentials, sign-ins, workspaces and usage history move "
        + "with it, and every client Bastion configured is rewired to the new endpoint. The "
        + "client's entry key and tool names change with it, so permission rules naming the old "
        + "ones stop matching, and a client configured by hand keeps the old endpoint.",
      properties: [
        "name": schema("string", "The profile's current name."),
        "server": schema("string", "The server id."),
        "new_name": schema("string", "Kebab-case, unique within the server."),
      ],
      required: ["name", "server", "new_name"], mutates: true),
```

- [ ] **Step 4: Dispatch and implement.** After `case "remove_profile": return try removeProfile(arguments)`:

```swift
    case "rename_profile": return try renameProfile(arguments)
```

After `removeProfile(_:)`:

```swift
  private static func renameProfile(_ arguments: [String: Any]) throws -> Any {
    let name = try string(arguments, "name")
    let serverID = try string(arguments, "server")
    let newName = try string(arguments, "new_name")
    guard let profile = ProfileStore.shared.profile(named: name, server: serverID) else {
      throw ToolError.noSuchProfile(profile: name, server: serverID)
    }
    let renamed = try ProfileStore.shared.rename(profile, to: newName)
    return [
      "name": renamed.name, "previous_name": name, "server": serverID,
      "endpoint": "http://127.0.0.1:\(Gateway.shared.port)/s/\(renamed.name)/\(serverID)",
      "note": "Clients Bastion configured now point at the new endpoint. A client configured by "
        + "hand still points at the old one, which no longer answers.",
    ]
  }
```

- [ ] **Step 5: Run it to see it pass.** Run `make builtin`. Expected: every "Renaming a profile" check is `ok`, and the run ends `N/N passed`. If the "no profile 'checkmove'" assertion fails, print the `rpc` reply and compare it with `SupervisorError.unknownProfile`'s sentence in `Supervisor.swift:69-70`. Fix whichever side is wrong. Do not loosen the needle.

- [ ] **Step 6: Commit.**

```bash
git add apps/apple/Bastion/BuiltinTools.swift scripts/builtin-check.sh
git commit -m "feat(profiles): rename_profile on Bastion's own server"
```

---

### Task 6: Docs and changelog

**Files:**

- Modify: `docs/keychain.md` (after the scope table, ~line 17)
- Modify: `docs/clients.md` (the "Not stale" table, ~line 830)
- Modify: `CHANGELOG.md` (new `## [Unreleased]` above `## [1.28.0]`)

- [ ] **Step 1: `docs/keychain.md`.** After the paragraph that follows the scope table, add:

```markdown
Renaming a profile moves its `.profile` and `.oauth` items: each is copied to the new
`<profile>/<server>/` prefix before the new name is saved, and the old ones are deleted after.
A refused read stops the rename rather than skipping the item.
```

- [ ] **Step 2: `docs/clients.md`.** In the "Not stale" table, change the first row's second cell from `A rename; \`merged\` drops the old one on the next write` to:

```markdown
A change of key scheme (prefix or format); `merged` drops the old one on the next write, because the endpoint is the same
```

Below the table, add:

```markdown
A renamed profile is the other kind of rename, and `merged` cannot see it: the endpoint changes
along with the key. `ProfileStore.rename` names the old id in `retiring`, so each client ends up
with one entry. Fields set by hand on the old entry (`disabled`, a timeout) do not carry over,
because they survive a rewrite only under an unchanged key.
```

- [ ] **Step 3: `CHANGELOG.md`.** Above `## [1.28.0] - 2026-10-13`:

```markdown
## [Unreleased]

### Added

- **Rename a profile.** Rename… on a profile's row, and `rename_profile` on Bastion's own server,
  give a profile a new name. Its credentials and OAuth sign-in, the state its server keeps (a
  child's own login, its callback port), its workspaces and its usage history move with it, and
  every client Bastion configured is rewired to the new endpoint. The client's tool names change
  with the entry, so permission rules naming the old ones stop matching. The audit log keeps the
  old name, since its lines are signed.
```

- [ ] **Step 4: Commit.**

```bash
git add docs/keychain.md docs/clients.md CHANGELOG.md
git commit -m "docs(profiles): renaming a profile"
```

---

### Task 7: Verify by hand against real sign-ins

Nothing in the check programs holds a real OAuth token or a child's own login, so these are walked by hand in the Debug build. Report each result. If one fails, stop and debug it (superpowers:systematic-debugging) before claiming the feature works.

- [ ] **Step 1: An OAuth profile.** Rename a profile of a remote server authorized with OAuth. Then run Test on it. Expected: it connects without asking to authorize again, and `security find-generic-password -s io.mgcrea.bastion.debug.oauth -a '<new>/<server>/oauth'` finds the item while the old account does not.
- [ ] **Step 2: A child that keeps its own login** (mcp-reddit or mcp-x). Rename a signed-in profile, then Test it. Expected: still signed in, and `profiles/<server>/<new>/callback-port` holds the same value it held under the old name.
- [ ] **Step 3: A refused Keychain read** (Review Focus 1). In Keychain Access, set one of a profile's `.profile` items to "Confirm before allowing access", then rename the profile and click Deny. Expected: the sheet shows the Keychain error, the profile keeps its old name and still works, and no item exists under the new prefix.
- [ ] **Step 4: Wiring and workspaces.** With Claude Code wired and the profile in a workspace, rename it. Expected: `~/.claude.json` (the Debug build's configured client) has one entry under the new key and none under the old, and the Workspaces pane still lists the profile in its workspace.
- [ ] **Step 5: Stats.** Before the rename, note the profile's call count in the Stats pane. After it, expect the same count under the new name and no row under the old one. The flush runs every 60 seconds, or on quit.
