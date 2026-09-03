# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The signed macOS app is tagged per release, `app-v1.4.1` being the newest. GitHub release notes
are taken from this file, which is the curated summary.

## [1.4.1] - 2026-09-03

### Fixed

- **The sidebar is sorted alphabetically, with Bastion pinned to the top.** The list had followed
  the order of `servers.json` for catalog entries and gone alphabetical only for the ones you add
  yourself. That order is the catalog's rather than yours and nothing in the app ever shows it, so
  a sidebar of five servers read as shuffled: a name had to be scanned for instead of jumped to,
  and the more servers were installed the worse it got.

  Bastion's own entry stays first whatever its name would sort as. It is the app rather than one
  of the choices, and a control plane that moves down the list as servers are added and removed is
  one nobody can find twice.

## [1.4.0] - 2026-09-03

### Added

- **Ten more remote servers in the catalog.** GitHub, Notion, Linear, Sentry, Atlassian, Figma,
  Vercel, Cloudflare, Cloudflare Docs and Cloudflare Observability join Stripe as endpoints their
  own vendors operate: an https URL, the vendor's OAuth or token, Bastion holding the credential
  in the Keychain and writing the audit line. Nothing is installed and no process is started for
  any of them. The catalog is now twenty entries, nine children and eleven remote.

  Ten of the eleven carry a seeded dialect rather than a measured one. Every one of them refuses
  `initialize` without a credential, so `2025-11-25` is a starting point and the first real
  handshake through a profile is what measures it; Activity shows what was actually negotiated.
  Cloudflare Docs is the exception: it answers unauthenticated, so `make remote-live-check` now
  drives it through a real `tools/list`, the one call Stripe's 401 could never prove.

### Security

- **The gateway bounds what a connection costs before it presents a token.** A connection used
  to cost a dedicated thread the moment it was accepted, and the parser then waited for the rest
  of the request for as long as the peer cared to stay quiet. Nothing needed a token to do
  either. There is now a cap of sixty-four connections in flight — a further one is answered
  `503` with `Retry-After: 1` and spawns nothing — and a request that has not fully arrived in
  ten seconds is closed with `408`. Neither timer touches the wait on a child, which is the
  operation and is bounded by the supervisor. `make audit` holds sixty-four idle connections and
  sends half a header to assert both against the built app; `make unit` drives the deadline
  through the real parser on a socketpair, including the byte-at-a-time trickle a per-read
  timeout never catches.

- **The licence Worker's two public routes are rate-limited, and `/thanks` stops showing the key
  after a week.** `/thanks?session_id=` handed the key to anyone holding a checkout session id,
  forever — and that id lands in browser history, in the Referer of the link on the page, and in
  support screenshots. It is now limited per address and, a week after issue, says where the key
  was sent instead of what it is. `/license/resend` is limited per address too; it used to cost a
  D1 query per request for any address at all, since its only cooldown was on a customer's row.
  A limited request answers exactly as an unlimited one does, so nothing is learned from it.

  The webhook is tightened at the same time: the body is bounded before it is buffered rather
  than after, a signature timestamped more than a minute in the future is refused (Stripe's own
  libraries take the absolute difference, which quietly doubled the replay window), and a session
  that arrives without a `payment_status` is a shape error rather than a sale.

  The `Host` allowlist also loses `[::1]` and `::1`. They never matched — the check split on the
  colon — and the listener is IPv4 only, so nothing could have arrived under them; the rule now
  lives in `HTTPRequest.isLoopbackHost` where `make unit` tables it.

- **A spawned server's credentials are struck from its stderr.** stderr is relayed to the log
  verbatim, so a server that echoes its configuration on startup, or an API error quoting the
  token it was sent, would put a credential into the log pane — and, with auditing on, into the
  audit file that the secrets wall exists to keep them out of. Every credential value the child
  was spawned with is now redacted before the line reaches the log. Values shorter than eight
  characters are left alone, since striking a single digit would mangle far more than it protects.

- **Every embedded Node tarball is verified before it is extracted.** The build fetches a Node
  runtime to embed; it now checks each tarball against `nodejs.org`'s `SHASUMS256.txt` first, the
  same way the Sparkle zip is checked. A cached tarball that fails is deleted rather than kept, so
  the next run re-fetches it instead of failing forever on the same bad bytes.

### Changed

- **The download is 57% smaller — 110 MB to 48 MB.** The embedded Node dropped its `x86_64`
  slice, which was 118 MB before compression. A Release build of Bastion and `bastion-bridge` is
  arm64, so an Intel Mac could never launch the process that would spawn `node` in the first
  place — the slice was shipped to nobody. macOS 26 is the last release supporting Intel and
  Bastion already requires 26.0, so the window this could have mattered in was three Mac models
  wide before it closed.

- **The update dialog shows formatted release notes instead of raw markdown.** Sparkle renders
  the feed's description as HTML, and the appcast had been handed the CHANGELOG section as
  markdown — so notes like these used to arrive carrying literal `**` and `- ` in
  them. They are rendered now, and the feed is checked for well-formedness before it ships rather
  than leaving each installed copy's updater to discover it was not.

### Fixed

- **An audit log that cannot be written no longer reads as tampered with.** A record is sealed
  before its bytes land, so a disk that filled, a permission that changed or an immutable flag
  left the next record chained to a hash that was never on disk — a gap the verifier reported as
  a removed record, with nothing anywhere saying it was an I/O failure. The writer now appends a
  record only if it links to what is on disk, logs the failure with its reason, and has the main
  actor rewind and seal one record from origin `audit` naming the range that was lost. The file
  stays a contiguous chain: an I/O failure reads as intact with a declared hole, and tampering
  still reads as broken.
- **`bastion-bridge` explains a profile or server name that does not form a URL** instead of
  trapping on it. The gateway still resolves both against its closed table; this is only the
  sentence for a name with a space in it.
- **A persisted `ScreenshotMode` default can no longer put a release build into demo mode.**
  The screenshot arguments are read from the launch arguments only, which apply to one launch —
  a `defaults write` of the key used to enable demo mode on every launch, and the stage argument
  that must then be present would trap on every launch after it.
- **The Worker's handlers are tested, in workerd, against a real D1.** Every route — fulfilment,
  redelivery, the unpaid and malformed sessions, the mail that fails and the retry that sends,
  refunds partial and full, disputes created, lost and won, `/thanks` in every state and
  `/license/resend` in every state — had no test at all, for want of a `Request`, an `Env` and a
  database to hand them. `@cloudflare/vitest-pool-workers` supplies all three, the schema comes
  from the same migrations production runs, and the suite is in CI beside the script tests that
  assert the Node minter and the Worker produce byte-identical keys. Neither ran anywhere before.
  Workers Logs are switched on for the Worker as well: a fulfilment that failed used to leave no
  trace on this side at all.
- **Fresh npm publishes install again.** The embedded Node moves from 24.18.0 to 24.20.0, which
  carries npm 11.19.0 and its `min-release-age-exclude` setting. The npm that shipped before
  ignored the exclusion, so a package published in the last day reported `ENOVERSIONS` and read as
  if it did not exist.

## [1.3.2] - 2026-09-02

### Added

- **What a server costs the editors that connect to it.** Every client wired to a profile is sent
  every tool definition before it can call one, and holds them for the whole conversation. That is
  the largest fixed charge a shared gateway imposes, and nothing reported it: _Test_ already asked
  each server what it exposes and threw the size away. It now says. `prod/appstore-connect` is 85
  tools and about 26.2k tokens per connect with writes on; `prod/reddit` is 14 and about 3.3k.

  The step line and the profile row carry the total, and the check sheet gains a _Context cost_
  card naming the five heaviest tools — because what a reader can act on is which few tools carry
  the largest schemas, and a list of eighty-five buries that.

  Counted from the entry as it arrived on the wire, at four bytes to the token, with the profile's
  write gate already applied. Deliberately not compared against the ungated list: Bastion could
  compute that for a remote server and not for a child without restarting it, and a figure that
  appears on one transport and not the other is worse than one that appears on neither. A paginated
  list says "at least" rather than "about", since the check reads one page of an unknown number.

  This is not the number the Chat pane shows. That one measures what Bastion hands the on-device
  model after trimming each description, which is a smaller and different object; the card says so
  rather than leaving two token counts to be reconciled.

### Changed

- **`x-api` and `ovh-api` are now `x` and `ovh`.** Both upstream repos dropped the `-api` suffix
  and the catalog follows, down to the package names and binaries. X's variables lose it too:
  `X_API_BEARER_TOKEN` is `X_BEARER_TOKEN`, `X_API_CONFIG` is `X_CONFIG`, and so on through the
  write gate. OVHcloud's were already `OVH_*` and are untouched.

  Nothing migrates an existing install across the change, and the failure is quiet on both sides.
  A profile created under the old id keeps its directory and its Keychain entries under that name,
  with no catalog entry left to match it to; a client still pointing at `/s/<profile>/x-api` gets
  the gateway's own refusal, `no server 'x-api'`, which reads like the server was never installed.
  Install the server again under its new id, set its credentials, re-wire the clients, and then
  delete the profile left behind.

## [1.3.1] - 2026-09-01

### Fixed

- **A switched-off server is no longer written into client configs.** Switching a server off has
  always left the entries already in a client's config alone, deliberately: rewriting somebody's
  `.claude.json` on a toggle is a much larger action than the toggle looks, and an entry that fails
  with Bastion's own sentence beats one that silently vanished. But _Configure_ wrote from every
  profile regardless, so wiring a client for one server put every switched-off server back — and
  the pane audited a client as half-written, down to an amber dot in the sidebar, over an entry the
  gateway refuses to serve.

  `wire_client` had filtered these out since it shipped and the pane had not, so the app disagreed
  with its own tool about the same file. One rule now, used by both, plus `list_clients`: a client
  is wired to the servers that are switched on.

  An entry already in the file for a switched-off server keeps its row, dimmed and marked, because
  it is in the file whether the pane draws it or not and this is the only screen that reads the
  file. _Remove Bastion's entries_ still takes it out.

## [1.3.0] - 2026-09-01

### Added

- **npm joins the catalog.** Packages, versions, downloads, advisories, dist-tags, orgs, tokens and
  trusted publishing. It is the one server here with no auth modes to choose between, and not
  because it has a single credential: it starts with nothing configured and every packument, search
  and advisory read is public. So the choice is not among named modes but between setting
  `NPM_TOKEN` and letting it read the token `npm login` already wrote to `~/.npmrc`.

  `NPM_CONFIG_USERCONFIG` is offered as state for that reason. A profile that names no token
  quietly borrows the machine's own login, and two profiles are then one npm user wearing two
  names — the audit line would say which profile called, not who published.

  The writes are irreversible in npm's own terms, so the gate is not the only thing in front of
  them: publish and unpublish each offer a dry run, everything irreversible also wants an explicit
  `confirm: true`, and npm demands a fresh one-time password on every trusted-publisher call.

- **A variable that is a switch is offered as one.** Servers that read a boolean environment
  variable all parse it with the same four-word allowlist, so free text like `y` or `yeah` silently
  read as false — and on `UNIFI_PROTECT_VERIFY_TLS` that direction quietly stops checking a
  console's certificate. The catalog can now mark a variable boolean with a stated default, and the
  profile editor renders it as a three-way picker rather than a text field.

  Three ways rather than two because unset is a real state and not a synonym for off: it falls
  through to the server's own configuration, and only then to the default the picker names.

### Changed

- **Updates is its own pane in Settings, instead of the fourth card down General.** General is
  where the gateway port and the npm minimum release age live, and the update controls were below
  all of it. Automatic checking is off until asked for, so Check Now is the only way an unopted
  build ever looks at all — and it was the part hardest to find. The pane sits next to About, the
  two answering halves of one question: which build is this, and is there a newer one. It repeats
  the version in its first row and now says when the last check happened, which `UpdateController`
  had always recorded and nothing had ever shown.

- **The write gate is no longer a text field in the profile editor.** It has to stay in a server's
  variable list so the manifest generator can validate it, but it is owned by the profile's Writes
  toggle — so offering it as an ordinary field was a dead control whose value is overwritten at
  spawn, and one that could leave `profiles.json` reading as writes-on while the child actually ran
  with writes off. It is now excluded from the editor, `set_credential` and `upsert_profile` refuse
  to write it directly, and a value stored by an older build is dropped on load.

- **`recent_activity` had no ceiling on what it handed back.** One default call on a profile that
  records results measured 96 KB, roughly 24k tokens — more than this server's entire tool list. It
  now spends a 16 KB budget filling rows newest-first, truncates each echoed argument and result to
  1 KB, and says how many older entries it left out rather than silently cutting the reply. The
  default limit drops from 50 to 20 to match.

  Its own result is also no longer captured. The result _is_ the log, so recording it stored a copy
  of the log inside the log, and each call inflated the next: three consecutive calls measured 106,
  110 and 115 KB, climbing.

- **Builtin replies are no longer pretty-printed.** The pretty printer writes `"key" : "value"`
  with a space either side of the colon and spreads an empty array over three lines, measured at
  roughly a fifth of every response this server sends. Key order stays sorted, so what a caller
  reads is unchanged apart from the whitespace. The tool list itself is trimmed the same way: an
  empty `required` array and a `destructiveHint` that only ever restated `readOnlyHint` are no
  longer sent on every connect.

- **The menu bar glyph's hill runs under the wall again.** The fort's feet stopped 0.35 units
  inside the ridge, close enough to nothing that the hill read as cut to fit the wall rather than
  passing behind it. Narrowing the fort opens that clearance to 0.90.

### Fixed

- **Wiring a client could quietly undo a change made while Bastion was writing.** Every write into
  a client's configuration was a plain read-modify-write, free to land a merge computed from bytes
  a concurrent writer had already replaced — and one of the five configurations has a documented
  concurrent writer, since the ChatGPT app rewrites `~/.codex/config.toml` on launch. Because
  Bastion's entries carry a bearer token, a lost write does not merely drop a server: it leaves the
  client still pointing at the endpoint and failing to authenticate, which reads as Bastion being
  broken. Each write now records the file's size and modification date before reading, refuses if
  either moved, and re-reads and re-runs the whole operation — collision check included — rather
  than landing a stale merge.

- **OVHcloud and Keycloak had no documentation link.** Both are public repositories, but their
  catalog entries carried none, so the servers table rendered their names as plain text while every
  other server's linked. X API was also still marked unpublished after it went out to npm — an
  entry in that state makes Bastion refuse the install without ever contacting the registry.

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
