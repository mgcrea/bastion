# The Keychain, entitlements and provisioning

Where Bastion's secrets live, why the app carries no entitlements today, and what it
would cost to change that. Written down because the obvious reason to make the change
is the wrong one, and that is not visible from the code.

## Where secrets live today

The **file-based login keychain**, reached through `SecItem*` with no
`kSecUseDataProtectionKeychain` flag. [`CredentialStore`](../apps/apple/Bastion/CredentialStore.swift)
keys everything by service + account, across three scopes:

| Scope           | Service                     | Account                    | Holds                                     |
| --------------- | --------------------------- | -------------------------- | ----------------------------------------- |
| `.profile`      | `io.mgcrea.bastion.profile` | `<profile>/<server>/<VAR>` | What the user typed. The thing to protect |
| `.gatewayToken` | `io.mgcrea.bastion.gateway` | `<client>`                 | Per-client loopback bearer tokens         |
| `.oauth`        | `io.mgcrea.bastion.oauth`   | `<profile>/<server>/oauth` | Minted OAuth token sets, refreshable      |

The service string derives from the bundle identifier, so a Debug build addresses a
different namespace than the release. That suffix is load-bearing, not cosmetic.

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

**That ends a documented security claim.** The app currently carries _no_
entitlements, asserted twice on every build:

- `make sign` fails if `codesign -d --entitlements -` finds any `<key>`
- [`scripts/audit-listener.sh`](../scripts/audit-listener.sh) fails if
  `CODE_SIGN_ENTITLEMENTS` appears anywhere in the pbxproj

An empty permission set that is true by construction is checkable; one arrived at by
deletion is not. Both assertions would have to be rewritten to assert the entitlement
set is _exactly_ `keychain-access-groups` — narrower, but still checkable.

### The real justification: iCloud sync

Sync requires `kSecAttrSynchronizable = true`, and synchronizable items on macOS live
in the data protection keychain **regardless** of the flag — legacy login-keychain
items are never synced. So sync inherits the same entitlement gate, and it is the only
thing that makes the trade worth it. Three consequences:

- **`ThisDeviceOnly` must go.** It is incompatible with sync. This reverses the stance
  written into `CredentialStore.write` — _"a gateway credential has no business
  syncing to a phone"_ — so that comment must be rewritten, not preserved. Note the
  file-based keychain **ignores `kSecAttrAccessible` entirely**, so today that comment
  describes an intent the code does not actually have. The attribute only starts
  meaning something after the migration.
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

- **Provisioning profile expiry is a new failure mode with no analogue today.** If
  macOS stops honouring the restricted entitlement past the embedded profile's expiry,
  every stored credential becomes unreadable on machines that never updated.
  **Unverified.** Settle it before shipping, not after.
- **Items become invisible to Keychain Access.app and the `security` CLI.** Manual
  inspection and repair get harder.
- **`ThisDeviceOnly` today also means credentials stop following a Migration
  Assistant transfer** once the attribute is honoured. Arguably correct for a
  credential vault, but it should be a decision, not a discovery.
- **A one-time round of ACL prompts on first launch after migrating.** Unavoidable —
  the values can only be read through the ACL guarding them — and it is the last one.

### The gate to check first

Before writing any migration code, confirm a `SecItemAdd` with
`kSecUseDataProtectionKeychain: true` returns `errSecSuccess` rather than `-34018`. If
it returns `-34018` the App ID or profile is wrong and everything downstream is wasted
effort.

## Restricted vs unrestricted entitlements

A distinction worth keeping straight, because a sibling app blurs it.

**Cupertino carries an entitlement and needs no provisioning profile.** Its
`Cupertino.entitlements` holds only `com.apple.security.automation.apple-events`,
which is _unrestricted_: declare it, sign it, done. No App ID, no portal work, no
embedded profile. It is a precedent for _"the app carries an entitlement"_ and **not**
for _"the app is provisioned."_

Nothing in this account has yet shipped a **Developer ID** provisioned Mac app. The
provisioning profiles cached locally are all `Mac Team Provisioning Profile` or
`Mac Team Store Provisioning Profile` — development and Mac App Store. The Developer
ID kind is a separate profile type, created explicitly, and it is the one Bastion
would need. Budget the portal work as new ground.

One thing an access group does **not** buy: access to anything but your own app's
items. It cannot read another app's credentials. Cupertino's `docs/passwords.md`
records the same finding from the other side — `Passwords.app` holds
`com.apple.password-manager`, an Apple-private group no Developer ID build can claim.

## Current state

|                                                  |                                                           |
| ------------------------------------------------ | --------------------------------------------------------- |
| Presence-by-name, loud refusals, `run` ordering  | **Done.** Zero `kcacl` activity measured                  |
| `keychain-access-groups` entitlement + migration | **Not started.** Needs App IDs and a Developer ID profile |
| iCloud sync toggle                               | **Not started.** Blocked on the above                     |

No migration code exists, no `kSecUseDataProtectionKeychain` appears anywhere in the
tree, and the app target carries no `CODE_SIGN_ENTITLEMENTS`. Existing credentials
have never moved and need no re-entry.
