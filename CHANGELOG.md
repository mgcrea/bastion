# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The signed macOS app is tagged per release, `app-v1.1.0` being the newest. GitHub release notes
are taken from this file, which is the curated summary.

## [1.1.0] - 2026-08-31

### Added

- **The menu bar icon says whether anything is running.** The curtain wall moves out of the app
  icon and becomes the menu bar's own state: the wall stands off the fort while at least one
  server is live, and the bare fort means nothing is. It is the one piece of status worth having
  without opening anything, and it was previously a sentence you had to open the popover to read.

### Changed

- **The menu bar popover is a panel, not a list of menu items.** It carries the version beside
  the name, the gateway's state as a glyph rather than a sentence, and a capped list of what is
  running. A menu answers "what is happening right now" at a glance; it had grown rows that were
  not a glance.

- **Add Server and Check for Updates left the popover.** Adding a server is an action with a
  window behind it, so it lives on the main window's own Add button (⌘N). Checking for updates is
  a thing you do once, so it sits in Settings ▸ Updates beside the standing preference it belongs
  with. Neither has a row in the menu any more.

### Fixed

- **The licence terms said the audit log records neither arguments nor results.** It records
  arguments by default, and results for a profile that asks for them. The sentence was inherited
  from a sibling project where it is true, and it was wrong here in the one document a buyer
  agrees to at checkout. What replaces it is stronger than a blanket denial: a tool whose
  argument _is_ the credential has its arguments withheld whatever the setting.

- **A Release build can no longer answer the licence question from a preference.** The screenshot
  pipeline reads `ScreenshotMode` from `UserDefaults`, which is deliberately not `#if DEBUG` —
  the store plates are captured from a Release build. The licence check now consults that path
  only under `#if DEBUG`, so what a shipped binary reports comes from a signature and nothing
  else. Nothing set the flag, so no build ever granted a licence this way; the guard is there
  because the line that would change that is one line, in a file nobody reads as
  security-sensitive.

### Internal

- A tamper-evident hash chain for the audit log (`AuditChain.swift`) is present but not yet
  wired to anything, and is deliberately not announced above.
- An App Store screenshot pipeline with fixed, fixture-seeded state, and a golden set to
  regression-check it against.

## [1.0.0] - 2026-08-31

First release.

### Added

- **One supervised server process per profile, instead of one per editor.** Every MCP client
  that wants a server spawns its own copy, so three editors mean three processes holding three
  copies of the same credential. Bastion runs one, behind a gateway on `127.0.0.1`, and clients
  reach it at `/s/<profile>/<server>`. A profile names a credential set — `prod/shopify`,
  `rgis/keycloak` — so the same server can serve two accounts without either knowing about the
  other.

  Children are started on demand, backed off when they crash, tripped out by a circuit breaker
  when they crash repeatedly, and stopped after half an hour idle.

- **Credentials live in the Keychain, and nothing reads them back.** Bastion holds the secrets
  its children need and hands them over at spawn. Nothing in the app, and nothing any client can
  call, returns a credential once set. The built-in server can say which secrets a profile has;
  it cannot say what they are.

- **The gateway binds loopback and refuses anything that is not local.** It validates `Origin`
  and `Host` on every request and requires a per-client bearer token. Those are not preferences:
  `make audit` asserts all five rules against the built binary, because CVE-2025-49596 was
  exactly this shape — a localhost MCP listener with no CSRF protection that a visited web page
  could reach and execute code through.

- **Both protocol eras, translated.** Bastion serves modern clients that send per-request
  `_meta` with no handshake, and legacy clients that expect an `initialize` handshake, in front
  of children that are all legacy. `make dialect` asserts the translation, including the exact
  status codes a dual-era client branches on.

- **Remote MCP servers over HTTP and SSE, with OAuth.** A remote endpoint is fronted like any
  other server, so a client sees no difference between something running on your Mac and
  something running on Stripe's. The callback listener is audited on the same terms as the
  gateway.

- **An editable catalog, and on-demand installation.** Nine servers ship seeded, and the list is
  yours to add to, remove from and switch off. Installing is a separate step from adding, so a
  failed download leaves something to retry rather than a half-added entry. A minimum package
  age can be set in Settings — npm can refuse versions published too recently, which is the
  window in which a compromised release tends to get caught.

- **Client wiring that leaves the rest of the file alone.** Claude Code, Claude Desktop, Visual
  Studio Code and Codex are wired from the Clients pane, including the three surfaces Codex
  shares in one TOML config. `make wiring-check` asserts the property that matters: after
  Bastion writes one key, every other byte in somebody's config is identical. Hand-configured
  entries are shown rather than silently overwritten, and stdio-only hosts reach the gateway
  through the bundled `bastion-bridge`.

- **Every call is recorded, and the record has limits.** The Activity window shows which
  profile, which method, which tool and how long, with the arguments a tool was called with.
  A profile can record results too, or names only. Capture sits behind a secrets wall and a
  size cap: a tool whose argument _is_ the credential — `set_credential` — has its arguments
  withheld whatever the setting, because a naive capture would write a Keychain secret into a
  feed the built-in server hands back to a model. Nothing is written to disk, and none of it
  leaves your Mac.

- **Bastion manages itself, through its own MCP server.** An agent can install servers, set
  credentials, wire clients and probe a profile. It ships disabled and takes three deliberate
  acts to reach, it obeys the same per-profile write gate as everything else, and it cannot
  switch itself off or delete itself.

- **A Chat pane, for trying a server's tools by hand.** Calling a tool yourself is how you find
  out whether a server works before wiring an assistant to it.

- **Licensing, verified offline.** A key is an Ed25519 signature the app checks locally in
  microseconds; there is no activation server and no way to add one without breaking what
  `make audit` asserts. A thirty-minute trial, started by hand and held in memory, runs every
  server at full function. The relay is what is licensed: Bastion's own server, and the write
  gates, are outside the gate on purpose. See [docs/licensing.md](docs/licensing.md).

- **Updates, off until you say otherwise.** Sparkle is pinned and checksum-verified, and the
  updater is not built at all until you opt in — so a Bastion nobody has said yes to has never
  resolved a name. It is the only outbound connection the app makes on its own account.

### Notes

- Requires macOS 26 or later.
- The app ships with no entitlements file at all. Spawning children and binding loopback need
  none.
