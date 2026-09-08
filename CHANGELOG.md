# Changelog

Notable changes to this repository. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and every published artifact follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

The signed macOS app is tagged per release, `app-v1.15.0` being the newest. GitHub release notes
are taken from this file, which is the curated summary.

## [1.15.0] - 2026-09-08

### Changed

- **X signs you in itself now, rather than asking for a client ID nothing read.** The `x` server's
  OAuth2 profile presented an `X_CLIENT_ID` field, and mcp-x has never read that variable — it holds
  its own token through child OAuth, like the other servers that sign in for themselves. The profile
  is **Sign in with X** now, wired to `x_login`, `x_get_auth_status` and `x_logout`, with no
  environment of its own. Anyone who filled that field in was configuring nothing; the sign-in
  button is what actually grants access.

- **The EULA names Magenta Creations.** It was the last surface still naming an individual, where
  the website's legal pages and the footer name the company throughout. It moves in two steps,
  which is worth stating rather than discovering: the site imports this file at build time, so the
  terms page changed on its next deploy, while the app carries its own copy and only agrees again
  with this release. It is also the document Stripe Checkout links as the terms consented to at
  purchase.

### Fixed

- **The What's New pane broke sentences that run on past the bold part.** Most entries here open
  with a complete bolded sentence, which reads well pulled onto its own line — but some bold only
  the subject and continue straight into the clause that explains it. The pane treated every lead as
  a standalone headline, so it put a line break before the comma and stranded the explanation. It
  tests for sentence-final punctuation to tell the two shapes apart now, and reassembles a flowing
  lead into a single markdown string, so emphasis and code spans still parse across the join.

### Internal

- **The website had no analytics at all, so its absence from every traffic report was a coverage
  gap rather than a zero.** Cloudflare Web Analytics is installed now, registered with
  `auto_install` false so it does not pool into the rest of the `mgcrea.io` zone, and embedded
  `is:inline` so Astro does not bundle it away from Cloudflare's origin. Both content security
  policy directives had to be opened, not only the obvious one: `script-src` to fetch
  `beacon.min.js`, and `connect-src` to let it POST, which is the half that fails silently with the
  tag sitting in the page looking perfect.

  The privacy page needed rewriting rather than a paragraph appended. It claimed the site ran no
  analytics script, and that the policy was `'self'` throughout so a third-party request "would be
  refused by the browser" — two sentences that would have become false on deploy. The app-level
  claim is the stronger one and stays, scoped explicitly to the app now: Bastion itself still sends
  nothing.

- **A keyboard user had no way past the sticky nav.** Every page is one long scroll and none of them
  offered a skip link. The `<main>` elements carry `tabindex="-1"` alongside the id, without which
  Safari and Chrome scroll the page but leave focus where it was — the link appears to work while
  doing nothing for a screen reader. The feedback email field had no `autocomplete` attribute
  either; the only one on the form was on the honeypot.

## [1.14.0] - 2026-09-07

### Added

- **A profile's tools, prompts and resources, in one place.** Every profile row has a `Tools…`
  button beside `Test`, and it opens the listing the app could not previously show: all three
  surfaces, read from the running server through that profile's own write gate, with a count on
  each tab, a filter, a per-tool token cost and the input schema behind a disclosure. Nothing in
  Bastion had ever asked a server for `prompts/list` or `resources/list`. The check sheet reads
  one page of tools and reports the five heaviest, on purpose; the Chat pane's picker is a budget
  control that drops everything the write gate touches. Neither answers "what is in here", and a
  static table in `servers.json` cannot: a Bastion listing is per profile and per client, which
  is the same reason `Dialect.listCacheScope` is `private`.

  It says which of the possible listings it is showing, because a number here can honestly
  disagree with one elsewhere in the app. Whether the gate was on or off; which tools Bastion
  removed, named and struck through, for a remote server whose catalog entry marks them as
  writes — a child server switches its own off at startup and cannot be asked what they were;
  and whether loading on demand means a client is sent three declarations in place of this list.
  Walking every page also hands `ToolCostStore` a better measurement than the check's, which
  stops at page one. `Bastion --capabilities=<profile>/<server>` prints the same three lists from
  a Debug build.

- **What changed, readable after you have already updated.** Release notes existed in exactly one
  place a user could reach: the sheet Sparkle puts up while it asks permission to install. That
  sheet is gone the moment you press Install, which left the one person most likely to want them
  — somebody who has just updated — with nowhere to look but `CHANGELOG.md` on GitHub. Settings
  has a **What's New** pane now, between About and Updates, because the three answer three parts
  of one question in that order: which build is this, what did it change, is there a newer one.

  It is generated, not bundled. `make changelog` compiles the last five releases of
  `CHANGELOG.md` into `Changelog.swift` the same way `make servers` compiles `servers.json` into
  `ServerCatalog.swift`, and `changelog-check` fails CI if the two drift — so the notes in the app
  are the notes in the repository, or the build goes red. `### Internal` sections are dropped at
  generation time rather than hidden at render time, so repo-facing prose about CI never reaches
  the binary at all. `[Unreleased]` is emitted separately and shown only in a Debug build, where
  it is true of what is running.

  The parse behind it is now shared with `changelog-notes.mjs`, which renders the appcast Sparkle
  reads, so the two cannot disagree about what a bullet is. Extracting it turned up a latent bug
  in the renderer's own placeholder scheme, and the tests in `scripts/lib/changelog.test.mjs` are
  written against the awkward shapes this file actually contains rather than tidy examples: a
  bullet with no bold headline, a headline with a code span inside it, and prose sitting between
  a `###` heading and its first bullet.

  Anything that shipped since the version you last read is marked, and says so from the menu bar
  panel and the main window's footer as well as in Settings — once, until you look. A fresh
  install is treated as caught up rather than greeted with five unread releases.

### Fixed

- **A server that shells out to `npm` could not find it.** Children are spawned with a
  deliberately minimal `PATH`, which was `/usr/bin:/bin` — so `mcp-npm`'s publish tool, whose
  `npm pack` runs the package's own prepare script, died several layers down with
  `sh: npm: command not found`. Neither `Resources` nor `Resources/npm/bin` fixes it: the first
  holds an `npm` that is a directory, and the shims in the second locate npm relative to node's
  prefix (`<prefix>/bin/node` plus `<prefix>/lib/node_modules/npm`), which the flat bundle layout
  is not, so they fail with "Could not determine Node.js install directory". `make node` now
  stages a `Resources/bin` of symlinks to the `-cli.js` entrypoints, which skips prefix detection
  entirely, and every child gets that directory in front of `/usr/bin:/bin`. What is added is
  exactly node, npm and npx from this bundle — never the developer's shell PATH, and nothing a
  profile can point elsewhere.

  `scripts/verify-servers.sh` now asserts it before signing, with `env -i` so an inherited PATH
  cannot pass the check on the developer's own npm. Every existing step ran the two binaries by
  absolute path, which is how a bundle that no child could shell out from passed all of them.

### Changed

- **The npm catalog entry documents the variables it always read.** `NPM_BIN`, `NPM_TOTP_LABEL`,
  `NPM_TOTP_SECRET` and `NPM_TOTP_KEYCHAIN_SERVICE` are now in the profile editor, and
  `NPM_OTP_MODE` lists `totp` — the only mode that answers npm's second factor without a human,
  and therefore the only one an unattended publish or trusted-publisher batch can use. It was
  missing from the description, which made the mode undiscoverable from Bastion.

## [1.13.0] - 2026-09-07

### Added

- **A shield in front of the provenance badge, and a seventeenth package behind it.** The badge
  1.12.0 introduced now carries `checkmark.shield.fill` at its own teal tint, both in a server's
  pane and in the catalog row. `Badge` gained an optional glyph to do it, defaulted to nothing, so
  every other call site renders exactly as it did.

  `@mgcrea/mcp-x` published 0.3.0 from GitHub Actions in the meantime, and its attestation names
  the repository the entry already links, so seventeen of the twenty-three npm entries carry the
  badge rather than sixteen. Checked against the registry rather than assumed, which is the only
  way the claim is worth anything.

### Fixed

This release is mostly a hardening pass over the gateway, the supervisor and the purchase path. Several of the entries below are reachable by anything that can open a connection to the port, so they are worth reading before deciding to defer the update.

- **One crafted request could take the whole app down, before it was ever asked who was sending
  it.** `Int("-1")` parses. The fill loop was then skipped, `body.count >= declared` passed, and
  `body.prefix(-1)` hit `Collection.prefix`'s own precondition — which kills the process, not the
  connection. It ran on the connection thread BEFORE the Host, Origin and bearer-token checks, so
  it needed nothing but the ability to reach the port: every client session and every supervised
  child went down with it. Reproduced with a single request against a running build. The gateway
  now answers 400 and keeps serving.

- **A progress frame could be written into a different client's response.** A frame is looked up
  under the supervisor's lock and delivered outside it, from the child's reader thread. If the
  reaper expired the waiter and resumed the connection thread in that window, the connection's own
  `defer` could `close(2)` the socket before the reader's write landed — and a free descriptor
  number is one the kernel is entitled to hand to the next accepted connection. The write then
  landed in somebody else's response.

  `HTTPStream` now tracks a closed flag under its own lock, set by that `defer` before the close
  runs and checked by every write. A frame is either written in full to a descriptor that is still
  ours, or not written at all.

- **A double-spawn race could leave an orphaned server holding a profile's credentials.**
  `ensureRunning()` was check-then-act, so two connection threads that both found a dead child
  could both start one; nothing ever terminated the loser. Worse, the orphan's eventual exit tore
  down the child that had won, because `childExited` cleared the pending state unconditionally.

  A semaphore now serialises start-and-handshake, and `childExited` is a no-op unless the exiting
  process is the instance's current one. The idle-sweep timer moves under the same lock, since
  `stop()` is reached from three threads and every other field there was already guarded.

- **Four gaps in the remote-server OAuth flow.** `PKCE.init` and `randomState` discarded
  `SecRandomCopyBytes`' status, so a CSPRNG failure produced an all-zero verifier or state in
  silence — a predictable challenge and a predictable CSRF token. That is now fatal, matching
  `GatewayToken.mint`. The callback checked `error` before `state`, so anything that could reach
  the ephemeral loopback port could abort an authorization in flight and have it read as the
  provider's refusal; state is checked first now. `resourceMetadataURL` split a 401 challenge on
  every comma, truncating a quoted `resource_metadata` value containing one, and is now a
  quote-aware scan. And the callback's accept loop polled with a deadline while the one-byte `recv`
  after `accept` had none, so a browser's speculative pre-connect that sent nothing parked the
  authorization until the app restarted. Each fix ships with a `scripts/remote-check.swift` case
  that fails without it.

- **The SSE parser would buffer without limit, and rescanned from the start on every chunk.** Every
  other reader in the app bounds what it will take from an untrusted source; this one, fed straight
  from `URLSession` by a remote server, did not — and its rescan made a long stream quadratic. Both
  are now handled the way `Supervisor.readLoop` already handled its own: a 32MB ceiling, and a scan
  that resumes two bytes before the last cut.

- **A client config backup kept the previous bearer token at the original file's permissions.** The
  backup written ahead of a rewrite inherited the source's mode, so re-wiring a world-readable
  config left a sibling `.bastion-backup` holding the OLD token, readable by anyone, indefinitely.
  It is now `chmod`'ed 0600 like the file it backs up.

- **An install could hang forever, and the row could never be retried.** Both the install and the
  update-check subprocess read to EOF with no deadline, so a registry that accepted the connection
  and then said nothing parked the call indefinitely. Because `running[server.id]` is cleared only
  when the task returns, every retry was refused for the life of the app while the row sat on
  "Installing…" with no way to dismiss it. A watchdog now SIGTERMs after five minutes and the call
  surfaces a named timeout.

- **A locked keychain told every client to re-wire itself.** `identify(_:)` ran on every request
  ahead of everything else, doing a `SecItemCopyMatching` over the whole account namespace plus a
  decrypting read per issued client. That set changes only when a client is wired or unwired, so it
  is cached for 60 seconds now and invalidated explicitly on issue and revoke.

  The cache also separates two states the old `Optional` collapsed into one: a token Bastion does
  not know (the client's problem, still 401) and a keychain that will not answer at all (this
  app's problem, and usually transient). The second answers 503 now, instead of sending the owner
  of a locked keychain off to re-wire every client they have.

- **A revoked licence could be mailed out again, and a dispute could restore the wrong one.**
  Five gaps in the purchase webhook, with the schema to support them. `fulfil` re-sent a revoked
  licence's key on any redelivery past the cooldown — or on a dashboard "Resend" — under a note
  promising a refund that had already been paid. `charge.dispute.closed` with status `won` restored
  ANY revoked licence for that payment intent, including one revoked by an unrelated refund; it is
  scoped to `revoked_reason = 'disputed'` now. The only idempotency key was `stripe_session_id`,
  which stops a second licence but not a second email, so every webhook event id is recorded once
  handled and a duplicate delivery is a no-op. `checkout.session.async_payment_succeeded` and its
  failed twin were unhandled, so a delayed-notification method — SEPA and its relatives — could
  charge a customer and mint nothing; both route to the same path. And `/thanks` served a licence
  key with no cache-control, while the 404 page hardcoded the site's host instead of reading the
  `SITE_URL` binding that was declared and never read.

### Internal

- **CI gates two checks that had only ever run by hand.** `generate-revocations.mjs` claimed in its
  own header that CI checked the committed list was current; nothing did, so a refund with no
  follow-up `make revocations` shipped a stale list with no signal anywhere. That drift check runs
  in the Manifest job now. `make license-check` runs in the App job, compiling the real
  `License.swift` and verifying a Node-minted key against it — the drift between the two signing
  implementations is invisible to either side's own tests. It skips on a fork with a warning, since
  it needs the signing key.

  Both deploy jobs' "no token, skipping" branch now emits a `::warning::` annotation rather than a
  plain echo. A rotated `CLOUDFLARE_API_TOKEN` previously left a green Deploy step on every push
  while production stayed frozen, with nothing anywhere surfacing it.

- **`catalog-check` went blind on an entry and reported the opposite.** Every check assumed a
  literal `env.NAME` or `process.env["NAME"]` read, so when `mcp-x` moved its config to a
  `bool(name)` helper closing over `env[name]`, the detector lost the entry and reported seven
  problems — including "writeGate `X_ALLOW_WRITES` is not read by mcp-x", when the gate had been
  fine the whole time. A helper is recognised only once its own body has been seen indexing `env`
  with its own parameter, which keeps the assertion as strong as the literal case: not "trust any
  one-argument function", but proof that `bool("X")` really is a read of `X`. Helpers routing
  through `parseBool` are tracked separately so the write-gate boolean check still holds, and it is
  verified against two probes that must keep failing.

- **The catalog's counts are gated where they are written as words.** `docs/servers.md`,
  `SECURITY.md` and `llms.txt` each state the catalog's size in words, mid-sentence and outside the
  generated regions `servers-check` covers — which is exactly how they went stale after the iOS
  Simulator entry landed. Twelve claims are asserted against the real counts now: `--check` fails,
  a plain run warns, since a script cannot rewrite prose that reads as prose. The stale figures
  themselves are corrected, along with `README.md`'s description of `catalog-check`, which said it
  "skips, passing" without `MCP_ROOT` when `make catalog-check` runs `--strict` and fails.

- **The push script can no longer put test-mode Stripe credentials on the production Worker.**
  `.test.vars.example` documented a rehearsal against a test-mode deployment, but `wrangler.jsonc`
  declared one Worker and the script passed no `--env`, so `wrangler secret bulk` always targeted
  production: following the documented steps replaced the live `STRIPE_WEBHOOK_SECRET` with a
  test-mode one and refused every real payment as an invalid signature. A test environment is
  declared now, with its own D1 binding, rate limiters and vars, and the script refuses test-mode
  credentials without an explicit `--env`. Five tests cover the refusal paths and none of them
  reach wrangler.

- **Build and script guards.** An interrupted `curl` left a truncated `SHASUMS256` that satisfied
  `[ -f ]` forever while the failure handler deleted only the tarball, so `make node` re-downloaded
  a good archive and failed identically on every later run; it deletes both now. `appcast` gained
  `sparkle` as a prerequisite, having worked in CI only by the accident that `build-release` runs
  `bundle` first. `notarize` checks all three required variables before spending a minute building
  a 60MB zip rather than only `AC_KEY_ID`. `facade`, `provenance` and `provenance-check` were
  missing from `.PHONY`. `mint-license.mjs --out` writes at 0600 like every other secret this repo
  emits, `migrate-mcp-json` names the fix instead of throwing a raw ENOENT at a missing `MCP_ROOT`,
  and `generate-revocations.mjs` escapes licence ids through the same `JSON.stringify` escaper the
  catalog generator uses, rather than interpolating them into Swift.

- **Documentation corrections.** `clients.md` now says what a per-client gateway token actually
  scopes: it identifies which client is asking and revoking it signs out that client, but it is not
  a permission boundary — any valid token reaches every profile and Bastion's own control plane,
  and the file it sits in is the real boundary. `licensing.md` documents the two idempotency keys,
  the scoped dispute restore, delayed-payment handling, and why `POST /license/resend` has no
  caller and is not getting one. `.env.example` drops a described-but-absent "skipped" branch for
  `make revocations` — silently doing nothing after a refund is the exact failure it exists to
  prevent — and documents five load-bearing knobs that had none: `BASTION_PORT`, `MCP_ROOT`,
  `PROFILE`/`SERVER` and `VERIFY_OFFLINE`/`VERIFY_PROBE`. The safety comment on `onMain` now names
  what breaks if the main thread ever waits on a connection thread.

- **Website and repository.** `/checked`'s top section was an `h2`, leaving that page's outline
  starting a level below every other; `terms.astro` hardcoded the source-licence and licensing-doc
  URLs that `config.ts` already exports, so a repository rename would have left two 404s on the
  page a buyer consents to at checkout. `apps/api/.wrangler/` — the local D1 that `migrate:local`
  and the Worker suite rebuild from `migrations/` — is ignored.

## [1.12.0] - 2026-09-06

### Added

- **The iOS Simulator joins the catalog.** Thirty-four entries now, twenty-three children and
  eleven remote. It drives a booted simulator — screenshots, the accessibility tree, taps, swipes,
  typing, app lifecycle and the staged environment — and installs from `@mgcrea/mcp-ios-simulator`.

  Two lanes reach it and they fail independently. `xcrun simctl` covers app lifecycle, the staged
  environment and the screen itself; only the accessibility tree and synthetic touches go through a
  WebDriverAgent runner, reached over the HOST's own loopback because a simulator shares the host
  network stack. That split is the real difference from the iOS Device server, where seeing
  anything at all requires the runner: here `simctl io screenshot` needs none, so everything except
  `ui_tree` works before one has ever started — and once writes are on, the server can start the
  runner itself. `ios_simulator_diagnostics` reports the two lanes separately.

  It takes no credentials, so it has no auth modes, and unlike the device server there is barely
  any setup either: a simulator needs no pairing and no Developer Mode toggle, so there is nothing
  for a profile to hold. `IOS_SIMULATOR_ALLOW_WRITES` gates the fourteen tools that actually drive
  it.

  The package itself defaults writes ON, the only entry here that does, reasoning that a phone
  belongs to a real person while a simulator is disposable and holds nobody's data. That default is
  never reached under Bastion, which writes the gate value explicitly on every spawn: the profile
  toggle is what decides, and a profile with writes off spawns a server that has not registered the
  driving tools at all.

- **Catalog entries say which packages npm can tie back to the repository they link to.** A
  `provenance` badge now sits beside the package name in a server's pane and in the catalog list,
  and the website marks the same entries. Sixteen of the twenty-three published packages carry a
  SLSA build attestation from GitHub Actions; the seven that do not are not suspect, they publish
  the older way, so the badge is only ever shown and never negated.

  The claim is deliberately narrower than "attested". A bare attestation says some CI somewhere
  built the tarball, which is a thing a typosquat of a popular package can have too. What is
  checked is that the workflow's repository matches the `docsUrl` the entry already advertises, so
  the badge means the bytes trace to the source the reader can go and look at. All sixteen match
  today, which makes the check a drift detector rather than a one-off audit.

  It is a smaller claim than a review, and it is placed to say so: under the paragraph in a
  third-party server's Package card that finishes explaining nobody here read the code. Provenance
  ties a package to a source; it does not vouch for what is in it.

  `make provenance` prints what the registry currently holds, and `make provenance-check` fails
  when a claim in `servers.json` no longer does. Neither runs in CI, and neither belongs to the
  generator: it has to stay offline and deterministic because `servers-check` is a drift
  gate, and somebody else publishing overnight must not turn an unrelated pull request red. The two
  directions of drift are not treated alike — a stale `true` is a hard failure, because Bastion
  must never claim provenance it cannot show to someone deciding whether to run code on their
  machine, while a stale `false` is only advice, because a third party improving their release
  process is good news and good news must not fail a build.

  `list_catalog` returns the flag too, so a model choosing between two servers that do the same job
  has one trust signal it can actually act on.

### Changed

- **A listing too small to be worth searching is no longer fronted, whatever the switch says.**
  Loading tools on demand now resolves a third term beside the server's switch and the client's
  own deferral, and this one is measured rather than configured: a listing is fronted only when it
  has at least twice as many tools as the facade would send in its place, and costs at least twice
  as many tokens. Both have to hold.

  The count is the term that decides the real cases, and it is not a proxy for the bytes. What
  this feature sells is not compression, it is selection — eighty-five schemas go unsent because
  an agent needed two of them. A server exposing three tools offers no selection to make, so the
  index costs two round trips to learn what one listing already said.

  That is most of the remote catalog's shape. Cloudflare's hosted endpoint exposes `search`,
  `execute` and `docs`; Stripe ships a read and a write dispatcher beside its own search. They are
  already this design, and their listings are not small in bytes — Cloudflare's three descriptions
  measure about 1.7k tokens — so a floor counting bytes alone would front them and buy nothing.
  Nor can Bastion recover what a vendor's dispatcher already took away: the real tool name
  upstream _is_ `execute`, so the audit row says `execute` either way, and the one advantage of
  doing this in the gateway does not apply.

  Measured rather than listed, deliberately. A set of vendors known to front their own tools would
  rot the first time one unpacked its dispatcher, and would do nothing for the small child server
  with the same problem and no vendor to name. Where the floor holds, the server's card says which
  half held instead of rendering a saving of nothing, the client's context bill counts the real
  listing, and `get_server` reports it as `lazy_tools_note`. It governs what is ADVERTISED only —
  a client still holding a fronted list goes on calling through it, which is the rule a pre-toggle
  tool name has always followed.

## [1.11.0] - 2026-09-06

### Added

- **The writes get their own dispatcher, so an editor's approval rule stops collapsing.** The
  facade's one real cost was that every call reached the client as `bastion_call_tool`, so a rule
  covering `app_store_connect_list_builds` ended up covering `..._update_app` too. A profile whose
  server Bastion can classify is now served a fourth tool, `bastion_call_write_tool`, and the
  ordinary dispatcher REFUSES anything Bastion knows to mutate — naming the other one, so the next
  call succeeds. Allowlisting `bastion_call_tool` in an editor can no longer run a write, and that
  is a property Bastion holds up rather than a hint it asserts and hopes the host respects. The
  two are disjoint in both directions, so nothing downstream has to check the split twice.

  `bastion_call_tool` still carries no `readOnlyHint`, and that is deliberate. A tool in neither
  the manifest's `writeTools` nor the server's own annotations is UNCLASSIFIED, and the house rule
  is that silence is not a no. Bastion already bets that way for its own gating, but that bet only
  decides Bastion's refusal; putting it in an annotation moves it into the editor's confirmation
  prompt, where being wrong means a mutation nobody was asked about. Refusing the writes it knows
  is honest and checkable. Claiming to be read-only would be neither.

  Classification comes from the manifest's `writeTools` ORed with what the server annotates, so a
  server that says nothing either way keeps exactly the three tools it had rather than gaining a
  fourth that would be a guess — and a profile with writes off has nothing to dispatch to, so it
  keeps three as well. Seven catalog entries declare `writeTools` today; Bastion's own server
  annotates every tool it exposes.

- **Every client now says what it is actually being sent.** Each server pane already quoted its
  own figure and each one looks survivable alone; a client wired to five of them pays the sum on
  every connect, and nothing in the app added them up. The Clients pane does now, under Context,
  and it resolves both axes into the one number that matters: a server loading on demand counts as
  its three or four declarations rather than its full listing, and a client that defers schemas is
  told it is sent everything but holds only the names — no alarm, and no false comfort either.

  It says "measured", and names how many of the wired profiles have a figure, because
  `tool-costs.json` holds one only for a profile something has actually listed. The total is a
  floor, and a floor that says so.

### Changed

- **"Load tools on demand" moved from the profile to the server.** It was stored per profile,
  with the control on a server writing through to every one of its rows — which is why that
  control needed a "Mixed" position at all. Mixed was never a state anybody set out to reach; it
  was the shape of the storage showing through the window.

  The question the switch answers is _is this listing big enough to be worth the trade_, and a
  listing is a property of the server: `appstore-connect` is 85 tools, `reddit` is 14, and two
  profiles of one server differ in credentials and in the write gate rather than in whether
  eighty-five is a lot. The one disagreement that genuinely was per profile — "this one feeds
  Claude Code, which defers by itself" — is the client axis above, where a profile feeding two
  clients can be answered honestly instead of averaged.

  A `lazyTools` already written on a profile is carried onto its server once, on the first launch
  after upgrading, and the key then leaves `profiles.json` on the next save. `upsert_profile`
  still accepts `lazy_tools` and now writes it through to the server: an argument that starts
  being silently ignored is worse than one that was renamed, and the schema says out loud that it
  moves every profile of that server. `list_servers` and `get_server` report it, which is where it
  lives now.

### Fixed

- **The cost figure stopped rounding in its own favour.** A measurement now records how many of
  its tools Bastion could tell were writes, so a view can distinguish "no writes here" from
  "Bastion cannot tell". Without it `ServerDetail` had no way to see a server that classifies by
  annotation alone — the manifest is all a view has — and understated the facade by the fourth
  declaration on every one of them. The same figure drives a new caveat: where load-on-demand is
  on and Bastion could classify nothing, the pane says so, because that is the case where one
  approval rule in the editor still covers every call including the writes.

### Internal

- **`make facade` now covers the dispatcher split and the migration under it.** The gate asserted
  three tools and a single dispatcher, so both of this release's changes would have passed it
  without noticing them. It counts four where Bastion can classify the server, drives an
  `upsert_profile` through `bastion_call_write_tool` to exercise the write path end to end, and
  reads `servers.json` back to confirm a `lazyTools` left on a profile was carried onto its server
  row. That carry is the migration's only input and it runs once, so a check that skipped it would
  have had nothing to fail on the second launch.

- **The client guide describes the fourth tool and where the switch now lives.** `docs/clients.md`
  listed three facade tools and located "load tools on demand" on the profile, which is the
  bargain the previous release struck rather than this one. Both are rewritten, including why
  `bastion_call_tool` still carries no `readOnlyHint`.

## [1.10.0] - 2026-09-06

### Changed

- **A client that already defers tool schemas is never fronted.** "Load tools on demand" was a
  decision about a profile alone, and a profile feeds every client wired to it at once. Claude
  Code has loaded MCP schemas on demand by itself since 2.1.191, so turning the facade on for a
  profile it reads spends the whole cost and buys back only the tool _names_ — and it does worse
  than nothing besides: the host's own tool search then indexes Bastion's three generic entries
  instead of the server's eighty-five, so `app_store_connect_list_builds` stops being reachable by
  keyword at the client layer even though `bastion_search_tools` still is. The comment in
  `ToolFacade` has said so since 1.7.0 and nothing acted on it, which left `ServerDetail` quoting a
  67x saving to the one client it was not delivering to.

  The decision is now two switches and an `and`, not one: the profile answers _is this listing big
  enough to be worth the trade_, and the client answers _does this client need the help at all_.
  They are resolved independently and nobody fills in a grid — the gateway already knows which
  client is asking, because the bearer token identifies it, so the second term is a set lookup at
  the line that was already comparing that same string.

  Which clients defer is an allowlist backed by evidence rather than a capability field, and it has
  one entry. An unrecognised client does not defer: the client axis is an exception to something
  the user asked for, and an exception with no evidence behind it is not an exception. Being wrong
  in this direction shows up as a listing that shrank and is one click from fixed; being wrong in
  the other would make a switch somebody turned on quietly do nothing, with no symptom naming the
  cause.

  It is an allowlist rather than a fact because Bastion cannot see the thing that decides it —
  `ENABLE_TOOL_SEARCH=false`, a custom `ANTHROPIC_BASE_URL` or an older build all turn native
  deferral off, and the token only says which config file it was written into. So each client
  carries the same three positions the rest of the app uses, in the Clients pane, and the escape
  hatch has to live there rather than on the profile: overriding a profile to get Claude Code
  fronted again would drag Claude Desktop along with it.

### Internal

- **The website's context-cost section now names the client its figures do not describe.** The 67×
  cut and the token counts beside it are what a client that takes the whole listing pays, and the
  reader likeliest to arrive on that page is running the one client that is never fronted. A number
  promised to somebody it will never reach is worse than a number left out. The paragraph reads
  `CONTEXT.skips` rather than spelling the name out, so the page follows the allowlist when it
  grows instead of depending on somebody remembering this sentence exists, and the config names
  `ToolFacade.clientsDeferringSchemas` as the authority the way it already does for the default.

- **`make dialect` can no longer grade the wrong binary.** `dialect-check.sh` read `BASTION_PORT`
  for its readiness probe and passed it to the checks, but launched the app without
  `-gatewayPort`. So a non-default port could not work at all — nothing ever bound it — and at the
  default the build under test failed to bind against a Bastion running from `/Applications`,
  leaving every check to quietly run against **that** copy and report on its dialect instead. It
  now passes the flag the way `audit-listener.sh` always has, and asserts the listener on the port
  belongs to the pid it just started, refusing with the fix rather than producing a full page of
  passes about someone else's build.

## [1.9.0] - 2026-09-05

### Added

- **Progress on a long call, streamed to the client that asked for it.** A POST to
  `/s/<profile>/<server>` can now be answered with `text/event-stream` carrying the child's
  `notifications/progress` ahead of the result, instead of going silent until the whole thing
  finishes. This is the current transport rather than the deprecated one: still one POST and one
  response, no `Mcp-Session-Id`, no replay, and `GET`/`DELETE` are still 405.

  It is opted into twice — the request must carry a `progressToken` **and** an
  `Accept: text/event-stream`. Every conforming client already sends that header unconditionally,
  so gating on it alone would have changed the shape of every response in the product overnight for
  no gain on the calls that emit nothing. The token requirement is also what keeps the status codes
  intact: an unknown method carries no token, so it never streams and is still a 404 with `-32601`.
  The stream head is written on the first frame, so a call that emits no progress is answered
  byte-for-byte as it was before.

  The token is remapped on the way out, for the same reason ids already were. One pipe carries
  every client of a child and two clients are free to have picked token `1`; the token Bastion
  sends upstream is the internal request id, so `pending` is the token table too and there is no
  second numbering to keep in step. The client's own token, and its type, come back unchanged.

  `bastion-bridge` reads the stream as well, writing each frame to stdout as its own line — so
  Claude Desktop, the one client that cannot be handed a URL, is not left out.

  Still gaps, and now for a sharper reason: `list_changed` and `subscriptions/listen` name no
  request, so a per-request channel cannot carry them. Remote servers still collapse their stream,
  because `RemoteEndpoint.verify` refuses a rebinding answer only while the body is buffered.

- **A search field on the catalog tab.** Thirty-three entries had no way in but scrolling. It
  filters over the id, the display name, the summary, the npm package and the endpoint, because the
  title is the one field somebody searching may not know: `sentry` finds the entry by name,
  `issues` finds it by what it does, and `@sentry/mcp-server` finds it when a package name is what
  was pasted in. Pinned above the list rather than scrolling with it, and the text survives a trip
  to the Custom tab and back — switching tabs to check a package name is not a reason to retype it.

### Internal

- **The three places that said Bastion never streams no longer say it.** The README, the website's
  gap list and this file all claimed a response is a single JSON object and never a stream, which
  the entry above makes false. What replaces it is narrower and still true: a POST carrying a
  `progressToken` and an SSE `Accept` is answered with a stream, and what remains missing is
  `list_changed` and `subscriptions/listen`, which name no request and so cannot travel a
  per-request channel. A remote server's stream is still collapsed, and that gap now carries its
  real reason — `RemoteEndpoint.verify` refuses a rebinding answer only while the body is buffered
  — rather than the routing one it used to share. The README's `make unit` count was 183 against an
  actual 467 before any of this, so both counts were re-derived rather than incremented.

- **`ServerSentEvents.swift` moved to a `Shared` group both targets list**, so the bridge reads a
  stream with the same parser the gateway writes one with, rather than a second copy of it. An
  explicit `PBXBuildFile` pointing into the app's own synchronized group is accepted by the project
  format and then silently ignored at build time, which presents as "cannot find ServerSentEvents
  in scope" with the reference plainly there in the file.

- **The website's Status section became Gaps.** Fourteen rows all tagged _built_ by 1.0.0 was a
  build-order table standing next to four sections that already make the same claims with a demo
  attached, and the nav had dropped it. Only the half with no other home survives: what the app
  does not do yet. The anchor stays `#status`, because the footer and any external link already
  point at it.

- **Baseline security headers on every route.** `Strict-Transport-Security`,
  `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` and `Permissions-Policy`, ahead of
  the per-path caching rules already in `_headers`.

- **Each app's `deploy` script is now `release`**, matching the vocabulary the rest of the repo
  uses, and `ci.yml`'s two deploy jobs follow. The old name also collided with pnpm's own built-in
  `deploy` command, so a hand-deploy needed `pnpm ... run deploy` to avoid
  `ERR_PNPM_INVALID_DEPLOY_TARGET`; `pnpm --filter @mgcrea/bastion-website run release` has no such
  twin.

- Toolchain bumps: oxfmt 0.62.0 → 0.66.0, oxlint 1.77.0 → 1.81.0, and the Astro half — astro,
  tailwindcss, wrangler, sharp and the `@astrojs/*` packages — to their latest patch and minor,
  with `wrangler.jsonc`'s `compatibility_date` alongside.

## [1.8.0] - 2026-09-05

### Added

- **Load tools on demand, app-wide and per server.** 1.7.0 kept the answer on the profile, which
  is where it belongs and not where anybody makes it: a saving reachable only by editing profiles
  one at a time is a saving nobody finds. Two more places to set it, and neither stores a second
  answer of its own.

  Settings › General now carries the default every profile follows. `Profile.lazyTools` goes
  tri-state — no value means "follow the app-wide switch" — so a profile that has disagreed keeps
  its override through an unrelated edit, instead of having the current default frozen into it by
  the next save.

  The server pane carries the tier between the two, under the profile rows it applies to, because
  the decision is almost always about one server: `appstore-connect` is 85 tools and 26.2k tokens,
  `reddit` is 14 and 3.3k, and nobody wants the same answer for both. It writes through to every
  profile of that server rather than storing a third answer — the absent value included, so
  **Default** there still means "follow the app-wide switch" rather than freezing today's answer
  into four rows. Profiles that already disagree read **Mixed**, which is a state somebody arrived
  at from the profile editor and not one to round off; a control that quietly read "Off" there
  would hide the profile that is on. Its caption quotes the measurement one of those profiles
  actually took, so the saving on offer is this server's own rather than the one from the
  changelog.

  Still off by default, and Settings names the client it is wrong for. That matters more than it
  did per profile, because the switch now moves every profile at once and Claude Code is the
  client most people are running — it defers tool schemas by itself, so a profile wired to it
  gains nothing here and still pays the coarser approval rule.

### Fixed

- **`bastion_search_tools` no longer answers "no tool matches" when one does.** A model searching
  `prod/appstore-connect` for `version builds submission` was told nothing matched, out of 85
  tools, because the one that does says "its build and metadata" and the query said "builds".
  Three things were wrong with the matching and all three are fixed: a plural now folds onto the
  singular a description happens to use; a word no tool carries no longer empties the result, which
  instead falls back to the tools that matched the most of the query and says which word missed;
  and matching reads the whole description rather than the 160-character summary it prints, so
  `testflight build` finds `list_builds`, whose description mentions TestFlight only past the cut.
  The index was the only way in, so a query that came back empty sent the model to the full listing
  the feature exists to avoid sending.

### Internal

- **The site measures what a connect costs.** The 67× saving was reachable only from this file. A
  section between _How it works_ and _Audit_ now shows what `prod/appstore-connect` costs a client
  on connect, what the three tools cut it to and what that trades away, with one more line in the
  status list. Its figures sit in `config.ts` beside a note naming the files that are the
  authority, and the ratio is quoted from the unrounded totals rather than recomputed from the two
  rounded figures printed next to it — a reader who does that division and gets a third number
  stops believing both.

- **The hero shows the wiring as a diff.** It was two lines under the caption "no secret in it",
  asking a first-time reader to take on faith that a secret had ever been there. It now strikes out
  `mcp-shopify`'s real invocation and its environment variables and adds the gateway URL in their
  place, so the page shows what wiring removes instead of asserting it.

- **The facade checks cover the tri-state.** `make facade` sets the app-wide switch on and gives
  its three scratch profiles one state each — one following the default, one overriding to off, one
  overriding to on — so every assertion it makes about the facade is also an assertion that the
  app-wide default reaches a profile at all. A default nothing reads is a switch that silently does
  nothing, and it is the one failure the per-profile version could not have had. `make unit` gained
  the search cases behind the fix above.

## [1.7.0] - 2026-09-04

### Added

- **Load a profile's tools on demand.** A profile can now hand its clients three Bastion tools —
  `bastion_search_tools`, `bastion_describe_tool`, `bastion_call_tool` — instead of every tool its
  server exposes. `prod/appstore-connect` goes from 85 tool definitions and about 26.2k tokens on
  every connect to three and about 0.4k, a 67x cut, with the full searchable index costing 3.2k
  only if something asks for it. Off by default, per profile, in the profile editor under Context
  and on `upsert_profile` as `lazy_tools`.

  MCP has no method for fetching a tool's schema later. `inputSchema` is required in a `tools/list`
  entry and clients validate it, so a name-only listing is not a cheap server, it is an empty one.
  Replacing the tools with an index and a dispatcher is the only lazy discovery the protocol
  permits, and it is what `mcp-sentry` and `mcp-stripe` already ship as servers.

  Bastion doing it rather than a server has one advantage, and it is the reason this is worth
  having here: Bastion performs the dispatch, so it opens `bastion_call_tool` back up into the
  ordinary `tools/call` it stands for before anything else sees the frame. The audit chain, the
  Activity window, `CallCapture`'s secret-argument rules and the write gate all go on naming the
  real tool. A facade bought as a server cannot do that, and flattens a supervised gateway into a
  bag of anonymous calls.

  The cost is on the client's side and the toggle says so: every call reaches the editor as
  `bastion_call_tool`, so one approval rule there now covers every tool on that server. This is the
  first switch in the app that trades rather than tightens, which is also why it is per profile —
  a profile feeding Claude Code, which already defers tool schemas by itself, should leave it off
  and lose nothing; a profile feeding a client that cannot has no other way to stop paying.

  On all three transports, because a behaviour that appears on two and not the third is worse than
  one that appears on none. A child's catalog is fetched once and held for the process, following
  `nextCursor` to the end — under a facade a tool reachable only through the dispatcher is a tool
  that has silently ceased to exist if page two goes missing. The badge on the profile row carries
  both figures, "0.4k of 26.2k", rather than replacing the measurement with the saving.

### Internal

- **The facade has checks on both sides of the app.** `make facade` drives it end to end against a
  running Debug build — the saving, the way in, the audit, the gate — and `make unit` gained the
  routing half, which needs no app and no network. The end-to-end half is what asserts the claim
  that matters and cannot be made without a process: that `bastion_call_tool` is opened back into
  the real `tools/call` _before_ the audit chain and the write gate see it. A facade that only
  routed correctly in a unit test would still be able to launder every call through one name.

- **The site's buttons no longer flash blue on first paint.** Colour utilities are references, not
  literals — `color: var(--color-fg)`. The palette sat in a `:root` block appended after Tailwind's
  output, so the literals landed in the last ~13% of the bundle while the utilities reading them
  sat a third of the way in; a browser painting from a partially parsed stylesheet resolved every
  one to invalid-at-computed-value-time and fell back to the UA link blue. The tokens moved into
  `tokens.css` ahead of the utilities, and `public/_headers` now serves `/_astro/*` as `immutable`
  — those filenames carry a content hash, and Workers Assets had been putting a conditional request
  on the render-blocking stylesheet on every refresh, which is the round-trip that opened the
  window.

- **The Apple mark on the Download buttons.** It says what "Download for macOS" says, in the space
  before the words. The sibling sites carry the same glyph on the same button.

## [1.6.0] - 2026-09-04

### Added

- **Eleven more servers in the catalog.** MongoDB, DBHub, Kubernetes, Context7, Firecrawl, Exa,
  Tavily, Playwright, Supabase, Netlify and Apify. These are the first entries published by their
  own maintainers rather than by mgcrea, so each row now says whose it is.

  The write gate had to learn two things to hold across them. MongoDB, DBHub and Kubernetes name
  their switch as the thing it disables rather than the thing it allows, so a profile's write
  toggle is resolved against each server's own polarity instead of one assumed for all. Playwright,
  Supabase, Netlify and Apify take no argv at all, which leaves no variable for Bastion to set:
  those are gated by tool name instead, and the question of whether a server has a write path now
  reads both mechanisms rather than one.

  Their protocol dialect is measured rather than declared. A live handshake asking for 2026-07-28
  makes each server answer with its own newest, where asking for 2025-06-18 would only have echoed
  the request back; all eleven land on 2025-11-25.

- **An update path on Bastion's own server.** The window has had one since the catalog became
  editable — Check for updates, then Update to _x_ — and an agent driving Bastion through
  `bastion` had no way to reach it: `install_server` adds a catalog entry and refuses anything
  already in the list, so a server that was installed was a server nothing could move.

  Two tools, in the order the pane asks in. `check_server_update` runs npm's own `--dry-run`
  against the installed tree and writes nothing, so it sits on the read side of the write gate;
  the answer lands under `update` in `get_server`, and `list_servers` carries `update_available`
  on any row a check found a newer version for. `update_server` resolves the package at `latest`
  again and re-downloads it — which is also the retry for a download that failed and the repair
  for a tree npm would rebuild, because re-resolving is all any of those three ever did.

  Both report the state a version number alone gets wrong. With a minimum package age set, npm
  resolves `latest` to the newest version old _enough_, which can be older than what is installed
  — so `pinned-older` is its own machine-readable state and says which direction pressing on would
  go, rather than offering an update that is a downgrade.

  Neither runs on a timer. Bastion reaches the registry when something asks it to, and `update`
  reads `unchecked` until something has.

### Changed

- **The sidebar lists the clients you actually have.** Every client Bastion knows how to
  configure used to get a row whether or not the Mac had it, so most people were shown a list of
  editors they had never installed, each with a status dot reporting on a file that does not
  exist. The _Clients_ section now shows the installed ones and disappears entirely when there
  are none.

  Installed is asked of LaunchServices first, so an editor in `~/Applications` or on a second
  volume counts, and an editor installed this morning counts before it has written any config.
  The config directory is the fallback, for the two clients that are a command rather than an app.

  **Nothing about what can be wired has narrowed.** `wire_client` still resolves against the
  whole list, and wiring a client that is not installed yet is allowed — it writes the config
  that client will read on first launch. `list_clients` filters the same way the sidebar does but
  then says what it left out, naming the absent ids in `not_installed` rather than dropping them
  silently; `include_not_installed` asks for their full rows, with the paths their configs would
  live at. A window can afford to say nothing about a client you do not have; an agent deciding
  what it may wire cannot.

### Fixed

- **`scripts/builtin-check.sh` honours `BASTION_PORT`.** It read the variable for its own requests
  and never passed `-gatewayPort` to the build it launched, so on a machine already running Bastion
  the build under test failed to bind, every assertion landed on the other copy, and the run failed
  reporting that its own fixture profiles did not exist. `audit-listener.sh` had already been fixed
  for this; this is the same one line.

### Internal

- `scripts/discover-servers.mjs` enumerates what npm has that the catalog does not, ranked by
  last-month downloads with deprecated packages dropped, so the catalog has a way to notice what
  it is missing without somebody doing it by hand.

- A release job in CI. Everything below `make build-release` — build, sign, notarize, checksum,
  sign the update, create the release and attach its three assets — was run by hand on a
  developer's Mac through 1.5.0. The job follows Cupertino's, diverging in three places noted
  where they occur: the checksum is the bare digest because the website serves `/checksum` raw,
  the release body is the top section of this file rather than generated notes, and there is no
  Homebrew cask because there is no tap.

  It gains a version gate Cupertino has no need for. Bastion keeps four hand-edited copies of the
  version — both `project.pbxproj` configurations, the website's `APP_VERSION`, the first section
  of this file and the intro line naming the newest tag — and CI had never seen any of them. All
  four are checked against the tag, so a release commit that missed one is refused while the fix
  is still a commit and a re-tag. `DemoSeed.version` is deliberately not checked: it is the number
  the marketing captures show and is allowed to lag.

## [1.5.0] - 2026-09-04

### Added

- **LM Studio and Windsurf.** Two rows Cupertino had and this did not, which is the whole reason
  they are here: the two apps write into the same seven config files and the lists had drifted
  apart. `~/.lmstudio/mcp.json` and `~/.codeium/windsurf/mcp_config.json`, both strict JSON with
  servers under `mcpServers`.

  Both get the **bridge** rather than a URL, and not for Claude Desktop's reason. LM Studio
  demonstrably reaches remote servers — the config this was added from holds three — but every one
  of them is a bare `url` with no `type` and no header anywhere in the file, so the token-carrying
  half of what `.http` writes is the unverified half. Windsurf was not installed to check at all,
  and its documented remote shape is a `serverUrl` key this app does not write. A bridge entry
  spawns a process, which is a cost; an HTTP entry a client silently ignores is a client that does
  not work with nothing on either side saying why. Either row moves to `.http` once somebody has
  watched a header carry a token into it.

- **Two more servers in the catalog: iOS Device and CloudKit.** The catalog is now twenty-two
  entries, eleven children and eleven remote.

  **iOS Device** drives a physical iPhone or iPad over `xcrun devicectl` and a WebDriverAgent
  runner reached through CoreDevice's tunnel. It takes no credentials, so it has no auth modes,
  and a write gate guards the nine tools that actually touch the device. Bastion never runs the
  runner itself — that stays yours to start. It installs from `@mgcrea/mcp-ios-device`.

  **CloudKit** is split out of App Store Connect rather than folded into it: a separate service
  with its own host and its own credential — a static management token, not a minted JWT — so a
  second write gate on the App Store Connect entry would have described neither well. It installs
  from a local checkout under `MCP_ROOT` until `@mgcrea/mcp-cloudkit` is published, the same way
  iOS Device did until it was.

- **A + at the end of the Servers header.** The labelled button under the list stays the real
  affordance; this is a small unlabelled shortcut where the eye reaches the sidebar first. No ⌘N
  on it, since the button below already claims that, and its accessibility label spells out what
  the glyph alone cannot say to VoiceOver.

### Changed

- **Client and server rows draw real icons.** Each client row now asks LaunchServices for that
  app's actual icon at runtime, rather than bundling artwork that goes stale the next time
  somebody rebrands; a declared SF Symbol is the fallback for CLIs and for rows with no bundle id.
  The demo fixture pins the fallback unconditionally, so a marketing capture does not depend on
  which editors happen to be installed on the Mac that took it.

  Server rows move off origin onto **transport**, which is the question the icon was always
  answering: gears for built-in, a box for a local package, a cloud for somebody else's endpoint.
  Origin only ever drew a box for anything that was not built in, which meant a remote endpoint
  was drawn as a downloaded package.

- **The demo window is 764pt rather than 700.** That number is measured against the sidebar rather
  than chosen, and two more client rows is 64pt more sidebar.

- **The Swift half is under swift-format.** The JavaScript half has been formatted since the
  start and the Swift half had no formatter at all; 30 of its 65 files disagreed with the config
  now committed. The reformat is mechanical and is named in `.git-blame-ignore-revs`, so blame
  still points at whoever wrote each line. Nothing about the app changed.

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
