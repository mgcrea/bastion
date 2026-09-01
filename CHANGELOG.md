# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The signed macOS app is tagged per release, `app-v1.3.0` being the newest. GitHub release notes
are taken from this file, which is the curated summary.

## [Unreleased]

### Changed

- **Updates is its own pane in Settings, instead of the fourth card down General.** General is
  where the gateway port and the npm minimum release age live, and the update controls were below
  all of it. Automatic checking is off until asked for, so Check Now is the only way an unopted
  build ever looks at all — and it was the part hardest to find. The pane sits next to About, the
  two answering halves of one question: which build is this, and is there a newer one. It repeats
  the version in its first row and now says when the last check happened, which `UpdateController`
  had always recorded and nothing had ever shown.

## [1.2.1] - 2026-09-01

### Fixed

- **A modern client could handshake cleanly and then register no tools at all.** The 2026-07-28
  revision has every list result declare how long it may be cached and by whom, and a client
  validates the whole result against that schema — so an absent `ttlMs` is not weaker caching, it
  is a discarded tool list. Claude Code 2.1.251 reports it as `Invalid result for tools/list:
ttlMs expected number, received undefined`. Modern list results now carry both fields; legacy
  ones still carry neither, because handing a 2025-11-25 client a field from a later revision is
  the same mistake pointing the other way.

  The scope is `private` rather than `public` because a Bastion listing is per _profile_, not per
  server: `allowWrites` decides which tools come back, so a shared cache would be free to serve
  the read-only profile's answer to the writing one.

- **The same symptom from the other end: a child's `listChanged: true` was passed straight
  through.** Bastion cannot honour it, and never could — one supervised instance serves several
  clients, so there is no single client a `list_changed` belongs to, and `Supervisor.received`
  drops those notifications on purpose. A modern client that believed the advertisement opened
  `subscriptions/listen`, got `-32601`, and dropped the whole connection rather than that one
  subscription. It is now advertised as `false`, and `resources.subscribe` is withdrawn for the
  same reason. An honest `false` costs a notification nobody was going to receive; the hopeful
  `true` cost every tool on the server.

  The sixty-second TTL above is what stands in for it: the client re-lists on its own schedule
  rather than being told when to.

- **Typing a profile name allocated a callback port for every prefix of it.** `ProfileEditor`
  called the function that _decides_ the port from its view body, once per keystroke, against a
  half-typed name — so typing `olouv` left a profile directory and a burnt port behind for `o`,
  `ol`, `olo` and `olou`. Worse, the first keystroke claimed the server's documented default,
  which pushed the profile the user actually meant onto a port their upstream app had never heard
  of, and OAuth logins came back `invalid redirect_uri parameter`. Reading and deciding are now
  separate calls: a view asks, and only a spawn decides.

## [1.2.0] - 2026-08-31

### Added

- **The audit log can be kept on disk.** Settings ▸ Activity turns on a durable log: append-only
  files under Application Support, readable only by you, with retention by age and by size. Off by
  default, and with it off nothing changes — the log stays a ring in memory, cleared when Bastion
  quits, which `make builtin` asserts against the real bundle.

  Whether that file carries arguments and results is a second switch, off on its own. Keeping a
  record of _which_ tools ran is a smaller thing to leave on disk than keeping what they were
  called with. A credential is never written either way: a tool whose argument _is_ the secret has
  its arguments withheld whatever the setting says, and the same canary that proves it cannot be
  read back through `recent_activity` now also proves it never reaches the file.

  **Each record carries a hash of the one before it**, so an edited field, a removed record or a
  truncated file can be detected — and the pane says exactly that much and no more. It catches
  tampering by something that does not know it is a chain; it is not proof against anyone who can
  write the file, because they can recompute it. Retention drops whole files at a time for the
  same reason: a chain cannot lose a record from the middle and still verify.

  This completes the hash chain that shipped unwired in 1.1.0.

- **The log can be exported, and signed if you want it.** Export writes the log alongside a
  manifest naming each file, its record count and its digest. The count is the part that matters:
  a chain cannot detect its own truncation, because cutting off the end leaves a shorter chain
  that still verifies. The signature goes beside the manifest rather than inside it, because a
  signature written into the bytes it signs makes what was signed ambiguous.

  Signing is optional and off unless asked for. It proves an export came from this Mac and was not
  altered afterwards; it does not prove the log was not curated before it was signed, and it means
  nothing to someone who has not been given the key some other way — so the pane shows a
  fingerprint to send them once. A new Mac makes a new key, and exports already signed keep
  verifying against the old one.

- **The Activity log has a search.** It matches the tool name, the profile and the arguments and
  results a call carried, so "which call touched order 992" is answerable without reading the
  feed. A row whose match falls past the truncated preview opens itself, rather than appearing in
  the results with no visible reason for being there.

- **Logs and Settings are one click from the menu bar.** Two glyphs beside Quit, with ⌘L and ⌘,
  while the panel is open. The log is the one destination the panel argues for: every line in it
  is a count of calls, and "what were those calls" is the question the summary raises and cannot
  answer.

### Changed

- **The recording settings have a pane of their own.** What the live log keeps, what an agent may
  read back, whether any of it survives a quit, and how long it is kept are four questions with
  one subject, and they had outgrown a section in General. The per-profile override stays beside
  that profile's write gate, where it is the exception rather than the default.

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
