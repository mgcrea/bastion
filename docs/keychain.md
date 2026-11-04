# The Keychain, entitlements and provisioning

Where Bastion's secrets live, why the app traded its "no entitlements" claim for four,
and what that cost. Written down because the obvious reason to make the change was the
wrong one, and that is not visible from the code.

## Where secrets live today

**The Release build: the data protection keychain.** It carries
`keychain-access-groups`, so [`CredentialStore`](../apps/apple/Bastion/CredentialStore.swift)
sets `kSecUseDataProtectionKeychain` on every query, with
`kSecAttrSynchronizable: kSecAttrSynchronizableAny` so a synced item is never missed.
Every item is `AfterFirstUnlockThisDeviceOnly` and not synchronizable until the sync
design's phase 3.

**Debug, and a Release build signed without the profile: the file-based login keychain**,
as before. Without the entitlement every data protection call answers `-34018`, so
`CredentialStore.usesDataProtection` asks the running process which one it may use.

**Moving across.** On the first launch of an entitled build, `KeychainMigration.run()`
moves every item from the login keychain: add on the new side, read back and compare,
then delete the old one. An item it cannot read (a denied prompt, a keychain locked
since boot) stays where it is, and `CredentialStore` reads through to the login keychain
until a pass leaves nothing behind. That pass writes a `.migration` marker, on the data
protection side where only Bastion's access group can create it, and the fallback ends.
Deletes always clear both sides, so a removed credential cannot come back through it.
`make keychain-selftest` runs all of this for real on the signed build, in a throwaway
`io.mgcrea.bastion.selftest` namespace.

**One trap, measured.** In a process that carries `keychain-access-groups`, a query
_without_ `kSecUseDataProtectionKeychain` reaches the data protection keychain too: it
lists those items, reads their values and deletes them. So login-side queries state the
key as `false`. Leaving it out made the migration's last step, deleting the login copy,
delete the copy it had just moved. The self-test caught it on its first run, and checks
the two keychains stay two.

The scopes, keyed by service + account:

| Scope           | Service                     | Account                    | Holds                                     |
| --------------- | --------------------------- | -------------------------- | ----------------------------------------- |
| `.profile`      | `io.mgcrea.bastion.profile` | `<profile>/<server>/<VAR>` | What the user typed. The thing to protect |
| `.gatewayToken` | `io.mgcrea.bastion.gateway` | `<client>`                 | Per-client loopback bearer tokens         |
| `.oauth`        | `io.mgcrea.bastion.oauth`   | `<profile>/<server>/oauth` | Minted OAuth token sets, refreshable      |

The service string derives from the bundle identifier, so a Debug build addresses a
different namespace than the release. That suffix is load-bearing, not cosmetic.

Renaming a profile moves its `.profile` and `.oauth` items: each is copied to the new
`<profile>/<server>/` prefix before the new name is saved, and the old ones are deleted after.
A refused read stops the rename rather than skipping the item.

## The prompt problem, and what it actually was

The symptom: _"Bastion wants to use your confidential information"_, repeatedly, with
"Always Allow" never sticking. The unified log (`securityd`, category `kcacl`) named
two distinct failures, and neither was what it looked like.

```
00:16:45  displaying keychain prompt for …/Debug/Bastion.app(57077)
09:05:46  user approved 'always allow' for …Bastion.app(57077)
09:05:46  code requirement check failed (-67065)
09:05:46  suppressing keychain prompt …(57077); code signing check failed rc=-67065
```

`-67065` is `errSecCSNoSuchCode` — _host has no guest with the requested attributes_.

**Cause 1: approvals landing on dead processes.** Three prompts were raised overnight
and answered nine hours later. All three processes were long gone. An approval for a
dead process cannot be written back to the item's ACL, so the next launch asks again.
The prompts were being raised because `listProfiles` read _every secret of every
profile three times over_ — once for `secrets_set`, again for `secrets_unset`, then a
third time through `ProfileEnvironment.missing` → `values(for:)`. One `profile_list`
call was ~36 decryptions against 12 per-item ACLs.

**Cause 2: rebuilding under the running app.** `run: app` made the build a
prerequisite, so `xcodebuild` overwrote the bundle while the previous instance was
still running against that path. A process whose on-disk code no longer validates
cannot be identified by `securityd`, which then refuses the access _and suppresses the
dialog_. That is the silent half: not a prompt nobody answered, but a refusal nobody
was shown.

Both were amplifiers, not properties of the keychain. Both are fixed.

## What was done, and what it measured

Three changes, none of which trade anything away:

1. **Presence is answered by name, never by decrypting.**
   `CredentialStore.storedVariables` lists account names via `kSecReturnAttributes`,
   which never meets an ACL. `ProfileEnvironment.present` builds the "is it set"
   answer from those names plus `profile.values`; `missing` tests set membership.
   `listProfiles` makes **one** `accounts(.profile)` query for the whole tool call.
   Decryption is left to the two paths that need a value: `values(for:)` at spawn and
   `headers(for:)` on the wire. Both sinks still read the same account namespace, so
   they cannot disagree — which was the original reason for reading values.
2. **A refusal is no longer silent.** `CredentialStore.read` returns `nil` only for
   `errSecItemNotFound`. Every other status is logged at `.error` before returning
   `nil`. This matters permanently: `errSecInteractionNotAllowed` stays reachable on a
   device that has not been unlocked since boot.
3. **`make run` stops before it builds.** Reusing the `pkill` line already in `stop`.

**Measured after:** ten consecutive `list_profiles` calls, `secrets_set` correct,
and **zero** lines from

```
log show --predicate 'subsystem == "com.apple.securityd" AND category == "kcacl"'
```

A spawned `prod/appstore-connect` reported `"privateKey": "loaded"`, proving the
decrypting path still works.

**So the prompts are gone with no entitlement.** That result is the whole point of
this section. Anyone reaching for the data protection keychain to stop keychain
prompts should check the `kcacl` log first — the argument has already been settled
once and it did not need an entitlement.

## The data protection keychain, and what it really costs

`kSecUseDataProtectionKeychain: true` selects the iOS-style keychain, which has **no
ACLs at all** — access is gated by the app's signing identity via a keychain access
group. No dialog can ever appear mid-tool-call, by construction rather than by
tuning. It is the correct end state. It is not free.

**It requires an entitlement.** `keychain-access-groups` is _profile-restricted_: its
value must be validated against a provisioning profile, so a Developer ID build needs
an embedded `Contents/embedded.provisionprofile` and a registered App ID. Without it,
`SecItemAdd` returns `-34018` (`errSecMissingEntitlement`).

**That ended a documented security claim.** Until 2026-11-01 the app carried _no_
entitlements, asserted on every build. Both assertions now assert the set is _exactly_
four (identity, team, `keychain-access-groups`, `ubiquity-kvstore-identifier`) — narrower
than "none", but still checkable: `make sign` compares the signed keys, and
[`scripts/audit-listener.sh`](../scripts/audit-listener.sh) checks
`apps/apple/Bastion.entitlements` and that the pbxproj still sets no
`CODE_SIGN_ENTITLEMENTS`.

### The real justification: iCloud sync

Sync requires `kSecAttrSynchronizable = true`, and synchronizable items on macOS live
in the data protection keychain **regardless** of the flag — legacy login-keychain
items are never synced. So sync inherits the same entitlement gate, and it is the only
thing that makes the trade worth it. Three consequences:

- **`ThisDeviceOnly` must go.** It is incompatible with sync. This reverses the stance
  written into `CredentialStore.write` — _"a gateway credential has no business
  syncing to a phone"_ — so that comment must be rewritten, not preserved. The
  file-based keychain **ignores `kSecAttrAccessible` entirely**; the data protection
  keychain honours it, so since phase 1 `ThisDeviceOnly` is a fact, and phase 3 lifts
  it for `.profile` alone.
- **`kSecAttrSynchronizable` is part of the primary key.** A synced and an unsynced
  item with the same service + account are two _distinct_ items, and a query omitting
  the attribute matches only unsynced ones. Every query would need
  `kSecAttrSynchronizableAny` or presence checks and profile deletion silently miss
  half the store. Toggling sync is delete-then-add — add first, delete only on
  success, which is the hazard `write` was already written to avoid.
- **Sync failure is silent.** No error if the user has iCloud Keychain off.

**Only `.profile` should ever sync.** Gateway tokens are per-machine loopback bearers,
and `.oauth` holds device-bound authorizations where a second Mac should run its own
flow rather than race the first one's refresh. Only `.profile` holds something a user
typed and would rather not retype.

### Costs to weigh before committing

- **Provisioning profile expiry is a new failure mode with no analogue today, and it
  is worse than unreadable credentials: the app stops launching.** Apple: a Developer
  ID profile "is also evaluated, both at app installation time and at every app
  launch", and "if your Developer ID provisioning profile expires, the app will no
  longer launch" ([Developer ID certificates][devid-help]). Profiles made after
  2017-02-22 last 18 years from creation. Bastion's, made 2026-11-01, expires
  **2044-10-27** (`TimeToLive` 6570 days), so the deadline for shipping a build with a
  renewed profile is that date, for anyone who has not updated by then. The
  certificate is not the limit: it expires 2031-08-21, and a build signed while it was
  valid keeps launching after. But the profile lists the certificates it accepts, so
  every build signed with a renewed one needs a regenerated profile:
  `scripts/profile-check.sh`, run by `make sign`, refuses to sign otherwise. Nothing found says what a re-signed build sees, but the
  items belong to the access group, not to the profile, so a new profile for the same
  App ID and team should read them. Unverified until a renewal happens.
- **Items become invisible to Keychain Access.app and the `security` CLI.** Manual
  inspection and repair get harder, and `make dev-clone` could no longer read the
  Release build's credentials. The Release app writes the Debug build's `import.json`
  itself instead, after a click: Settings › General › Export to the Debug Build. No
  launch argument or MCP tool can do it, or any process could collect every credential
  in a file without a prompt.
- **Going back to 1.35.0 or earlier after migrating finds no credentials.** They were
  moved, not copied. Copying would have left a stale login copy for an old build to use.
- **Credentials no longer follow a Migration Assistant transfer.** `ThisDeviceOnly` is
  honoured on the data protection keychain, so a new Mac starts with none. Decided with
  phase 1 and stated in its CHANGELOG entry: for a credential vault it is the right
  default, and iCloud sync (phase 3, `.profile` only) is how they reach another Mac.
- **A one-time round of ACL prompts on first launch after migrating.** Unavoidable —
  the values can only be read through the ACL guarding them — and it is the last one.

### The gate to check first

A `SecItemAdd` with `kSecUseDataProtectionKeychain: true` must return `errSecSuccess`,
not `-34018`; `-34018` means the App ID or profile is wrong. Passed 2026-11-01, and
`make icloud-probe` re-checks it on any signed build (see "Current state").

## Restricted vs unrestricted entitlements

A distinction worth keeping straight, because a sibling app blurs it.

**Cupertino carries an entitlement and needs no provisioning profile.** Its
`Cupertino.entitlements` holds only `com.apple.security.automation.apple-events`,
which is _unrestricted_: declare it, sign it, done. No App ID, no portal work, no
embedded profile. It is a precedent for _"the app carries an entitlement"_ and **not**
for _"the app is provisioned."_

Bastion is the first **Developer ID** provisioned Mac app in this account. Its profile,
"Bastion Developer ID", is committed at `apps/apple/Bastion.provisionprofile` and
embedded by `make sign`, which signs with exactly the four entitlements in
`apps/apple/Bastion.entitlements` and refuses to sign without the profile. It grants
`keychain-access-groups` and `ubiquity-kvstore-identifier` as `75QE9PRT3V.*`, and the
App ID `io.mgcrea.bastion` has iCloud enabled. `io.mgcrea.bastion.debug` is registered
too, with iCloud, but the Debug build carries no entitlements yet: restricted ones
would need a development profile and a registered device for every `make run`.

One thing an access group does **not** buy: access to anything but your own app's
items. It cannot read another app's credentials. Cupertino's `docs/passwords.md`
records the same finding from the other side — `Passwords.app` holds
`com.apple.password-manager`, an Apple-private group no Developer ID build can claim.

## Current state

|                                                 |                                                                                     |
| ----------------------------------------------- | ----------------------------------------------------------------------------------- |
| Presence-by-name, loud refusals, `run` ordering | **Done.** Zero `kcacl` activity measured                                            |
| `keychain-access-groups` entitlement            | **Gate passed on two Macs, 2026-11-01.** Entitlements and profile ship; see below   |
| iCloud key-value storage                        | **Gate passed on two Macs, 2026-11-01.** See below                                  |
| Data protection keychain migration              | **Built, 2026-11-01.** `make keychain-selftest` passes; ships with the next release |
| iCloud sync toggle                              | **Not started.** Phases 2–3                                                         |

`make icloud-probe` runs the gate against the signed Release build: it writes one
synchronizable data protection keychain item and one key-value pair named after the
Mac, then lists every other Mac's it can see. On the first Mac, a `make bundle` build
answered `keychain add: ok`, `keychain read: ok` and `kvs synchronize: true` — no
`-34018`, so the entitlement and the profile are accepted. The same answers came from
the notarized, stapled `make build-release` build, unpacked from its zip, quarantined
the way Safari marks a download and opened through LaunchServices (`open -n … --args
-iCloudProbe YES`): `spctl` accepted it as `Notarized Developer ID`, it launched with
its four restricted entitlements, and the probe passed.

Sync itself, across two Macs on one iCloud account (both macOS 27.0.1): the same
notarized zip, copied to the second Mac and opened there the same way, listed the
first Mac's keychain account and key-value pair (Gatekeeper again `Notarized Developer
ID`). A run on the first Mac six seconds later listed the second's in both. So iCloud
Keychain carries a synchronizable data protection item written by a Developer ID
build, and the key-value store carries a pair, both within seconds. Both ran beside
the installed Bastion on each Mac, which they never touched. `-iCloudProbeClean YES`
removed the probe's entries afterwards.

The migration is built and self-tested, and runs on a person's Mac when they first
launch the release that carries it. The sync design and its plans are in
`docs/superpowers/specs/` and `docs/superpowers/plans/`, dated 2026-11-01.

[devid-help]: https://developer.apple.com/help/account/certificates/create-developer-id-certificates/
