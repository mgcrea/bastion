import SwiftUI

/// What changed, in the build you are running.
///
/// Generated from the repository's `CHANGELOG.md` by `make changelog`, the same
/// way `ServerCatalog` is generated from `servers.json` and for the same reason:
/// a copy nobody regenerates is a copy that rots, and here it would rot into the
/// worst possible shape — release notes that confidently describe a different
/// build.
///
/// **Why generated rather than bundled.** The obvious alternative is to ship
/// `CHANGELOG.md` as a resource and parse it at launch. Bastion's app target has
/// an empty resources build phase — everything in `Contents/Resources` is put
/// there by the Makefile's `bundle` target — so a bundled markdown file would be
/// present in a `make bundle` build and absent from a plain Xcode one. Baking
/// the text in at generation time also means the parse happens once, in Node,
/// where `changelog-check` can assert the result, rather than on every launch
/// where nothing can.
///
/// Every string below is **raw markdown**. The generator does not decide what
/// bold looks like; `markdown(_:_:)` renders it, and the same strings would
/// render differently in another context without being regenerated.
///
/// The list is capped — see `Changelog.shown` in `scripts/generate-changelog.mjs`
/// — because this is the pane you open after updating, not an archive. The full
/// history is a link away, and `CHANGELOG.md` remains the source of truth.
nonisolated enum Changelog {
  /// One released version.
  struct Release: Identifiable, Hashable {
    /// `"1.13.0"`. Compared against `AppInfo.version` and against the seen key.
    let version: String
    /// `"2026-09-07"`. Kept as the ISO string the CHANGELOG wrote rather than a
    /// `Date` literal: a `Date(timeIntervalSince1970:)` in a generated file is
    /// unreadable in a diff, and formatting at generation time would bake the
    /// generating machine's locale into every build.
    let date: String
    let sections: [Section]

    var id: String { version }
  }

  /// One `### Added` / `### Fixed` block.
  struct Section: Identifiable, Hashable {
    let name: String
    /// The prose that can sit between the heading and the first bullet. Rare —
    /// one release in the file has it — and dropping it silently shortens the
    /// notes, which is exactly the kind of loss nothing would report.
    let lead: [String]
    let entries: [Entry]

    var id: String { name }
  }

  /// One bullet.
  struct Entry: Identifiable, Hashable {
    /// Emitted rather than derived, so `ForEach` has a stable identity without
    /// hashing prose or inventing a `UUID` that changes every render.
    ///
    /// Unique across the whole **release**, not within its section. SwiftUI
    /// flattens the section/entry `ForEach` pair inside a `Form`, so
    /// per-section numbering collides as soon as a release has two sections —
    /// and the pane then draws the first section's bullet a second time in
    /// place of the second section's. It looks like a duplicated entry, not
    /// like an identity bug, which is why it is worth a paragraph.
    let ordinal: Int
    /// The leading `**…**`, asterisks removed — or nil. Seven bullets in the
    /// file have no headline at all, so this is an optional by observation
    /// rather than by caution.
    let headline: String?
    /// The rest, one string per paragraph.
    let body: [String]

    var id: Int { ordinal }
  }

  /// Where the full history lives, since only the most recent releases are here.
  static let historyURL = URL(string: "https://github.com/mgcrea/bastion/blob/main/CHANGELOG.md")!

  // MARK: - Seen

  /// The last version whose notes were actually read.
  ///
  /// A marketing version string, not a bool: the question the badge answers is
  /// "did anything ship since you last looked", which needs the comparison.
  static let seenKey = "changelogSeenVersion"

  /// Seed the seen version on a launch that has never set it.
  ///
  /// Without this, a fresh install lights every indicator in the app on first
  /// launch — the key is absent, so everything looks unread, and Bastion greets
  /// somebody who has never run it with "five new releases". An upgrade from a
  /// build that predates this pane is indistinguishable from that fresh install
  /// (neither wrote the key), so both are treated as caught up. The cost is that
  /// the indicator does nothing until the *next* release; the alternative costs
  /// every new user a false badge.
  static func markSeenIfUnset() {
    guard UserDefaults.standard.string(forKey: seenKey) == nil else { return }
    markSeen()
  }

  /// Record that the notes for this build have been read.
  static func markSeen() {
    UserDefaults.standard.set(AppInfo.version, forKey: seenKey)
  }

  /// Releases newer than the last one whose notes were read.
  ///
  /// Empty rather than everything when the key is unset — see
  /// `markSeenIfUnset()`.
  static var unseen: [Release] {
    guard let seen = UserDefaults.standard.string(forKey: seenKey), !seen.isEmpty else { return [] }
    // `ServerInstaller.isVersion(_:newerThan:)` rather than a second comparator.
    // It already exists, it is already the app's answer to "is this one newer",
    // and two semver comparisons that disagree would be a bug nobody could see.
    return releases.filter { ServerInstaller.isVersion($0.version, newerThan: seen) }
  }

  /// Whether to draw an indicator anywhere.
  ///
  /// False under a screenshot capture, unconditionally. The indicator depends on
  /// a defaults value the capture run does not set, so without this guard a dot
  /// appears on the golden plates depending on what the developer's machine
  /// happened to have read — drift with no code change behind it, which is the
  /// hardest kind to explain.
  static var hasUnseen: Bool {
    if DemoSeed.isEnabled { return false }
    return !unseen.isEmpty
  }

  // MARK: - Rendering

  /// One markdown string as `Text` can draw it.
  ///
  /// `Text` honours `**bold**`, `_italic_` and links from an `AttributedString`
  /// on its own. It does nothing at all for `` `code` `` — the markdown parser
  /// records that as a semantic `inlinePresentationIntent` and applies no font —
  /// so the loop below is the whole of the missing half.
  ///
  /// The style is a parameter because setting `.font` on a run **overrides** the
  /// view's own `.font()` for that run: a body-sized helper used inside a
  /// caption makes one word jump a size. And the emphasis has to be reapplied,
  /// because every headline in this file that contains a code span contains it
  /// inside the bold — `**A server that shells out to `npm` could not find
  /// it.**` — and assigning a plain monospaced font would silently un-bold it.
  ///
  /// Note that `Text("**bold**")` renders markdown only for string *literals*,
  /// through the `LocalizedStringKey` overload. Every string here is a variable,
  /// which takes the `StringProtocol` overload and draws the asterisks. So this
  /// is not an embellishment; without it the pane shows raw markdown.
  static func markdown(_ source: String, _ style: Font.TextStyle = .body) -> AttributedString {
    guard
      var text = try? AttributedString(
        markdown: source,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    else {
      // Literal asterisks are ugly and honest. Nothing here is worth a crash.
      return AttributedString(source)
    }
    for run in text.runs {
      guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
      var font = Font.system(style, design: .monospaced)
      if intent.contains(.stronglyEmphasized) { font = font.bold() }
      if intent.contains(.emphasized) { font = font.italic() }
      text[run.range].font = font
    }
    return text
  }

  // MARK: - Generated

  // <generated:changelog> generated from CHANGELOG.md by `make changelog` — do not edit by hand

  /// The most recent 5 releases, newest first.
  ///
  /// Split into one `let` per release rather than a single nested literal.
  /// Swift's expression type-checker is superlinear in the depth of an array
  /// literal, and this one is releases of sections of entries of strings — the
  /// exact shape that turns into a multi-second type-check with no diagnostic.
  // swift-format-ignore
  static let releases: [Release] = [v1_15_0, v1_14_0, v1_13_0, v1_12_0, v1_11_0]

  // swift-format-ignore
  private static let v1_15_0: Release = Release(
    version: "1.15.0",
    date: "2026-09-08",
    sections: [
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "X signs you in itself now, rather than asking for a client ID nothing read.",
            body: [
              "The `x` server's OAuth2 profile presented an `X_CLIENT_ID` field, and mcp-x has never read that variable — it holds its own token through child OAuth, like the other servers that sign in for themselves. The profile is **Sign in with X** now, wired to `x_login`, `x_get_auth_status` and `x_logout`, with no environment of its own. Anyone who filled that field in was configuring nothing; the sign-in button is what actually grants access.",
            ]),
          Entry(
            ordinal: 1,
            headline: "The EULA names Magenta Creations.",
            body: [
              "It was the last surface still naming an individual, where the website's legal pages and the footer name the company throughout. It moves in two steps, which is worth stating rather than discovering: the site imports this file at build time, so the terms page changed on its next deploy, while the app carries its own copy and only agrees again with this release. It is also the document Stripe Checkout links as the terms consented to at purchase.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "The What's New pane broke sentences that run on past the bold part.",
            body: [
              "Most entries here open with a complete bolded sentence, which reads well pulled onto its own line — but some bold only the subject and continue straight into the clause that explains it. The pane treated every lead as a standalone headline, so it put a line break before the comma and stranded the explanation. It tests for sentence-final punctuation to tell the two shapes apart now, and reassembles a flowing lead into a single markdown string, so emphasis and code spans still parse across the join.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_14_0: Release = Release(
    version: "1.14.0",
    date: "2026-09-07",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A profile's tools, prompts and resources, in one place.",
            body: [
              "Every profile row has a `Tools…` button beside `Test`, and it opens the listing the app could not previously show: all three surfaces, read from the running server through that profile's own write gate, with a count on each tab, a filter, a per-tool token cost and the input schema behind a disclosure. Nothing in Bastion had ever asked a server for `prompts/list` or `resources/list`. The check sheet reads one page of tools and reports the five heaviest, on purpose; the Chat pane's picker is a budget control that drops everything the write gate touches. Neither answers \"what is in here\", and a static table in `servers.json` cannot: a Bastion listing is per profile and per client, which is the same reason `Dialect.listCacheScope` is `private`.",
              "It says which of the possible listings it is showing, because a number here can honestly disagree with one elsewhere in the app. Whether the gate was on or off; which tools Bastion removed, named and struck through, for a remote server whose catalog entry marks them as writes — a child server switches its own off at startup and cannot be asked what they were; and whether loading on demand means a client is sent three declarations in place of this list. Walking every page also hands `ToolCostStore` a better measurement than the check's, which stops at page one. `Bastion --capabilities=<profile>/<server>` prints the same three lists from a Debug build.",
            ]),
          Entry(
            ordinal: 1,
            headline: "What changed, readable after you have already updated.",
            body: [
              "Release notes existed in exactly one place a user could reach: the sheet Sparkle puts up while it asks permission to install. That sheet is gone the moment you press Install, which left the one person most likely to want them — somebody who has just updated — with nowhere to look but `CHANGELOG.md` on GitHub. Settings has a **What's New** pane now, between About and Updates, because the three answer three parts of one question in that order: which build is this, what did it change, is there a newer one.",
              "It is generated, not bundled. `make changelog` compiles the last five releases of `CHANGELOG.md` into `Changelog.swift` the same way `make servers` compiles `servers.json` into `ServerCatalog.swift`, and `changelog-check` fails CI if the two drift — so the notes in the app are the notes in the repository, or the build goes red. `### Internal` sections are dropped at generation time rather than hidden at render time, so repo-facing prose about CI never reaches the binary at all. `[Unreleased]` is emitted separately and shown only in a Debug build, where it is true of what is running.",
              "The parse behind it is now shared with `changelog-notes.mjs`, which renders the appcast Sparkle reads, so the two cannot disagree about what a bullet is. Extracting it turned up a latent bug in the renderer's own placeholder scheme, and the tests in `scripts/lib/changelog.test.mjs` are written against the awkward shapes this file actually contains rather than tidy examples: a bullet with no bold headline, a headline with a code span inside it, and prose sitting between a `###` heading and its first bullet.",
              "Anything that shipped since the version you last read is marked, and says so from the menu bar panel and the main window's footer as well as in Settings — once, until you look. A fresh install is treated as caught up rather than greeted with five unread releases.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "A server that shells out to `npm` could not find it.",
            body: [
              "Children are spawned with a deliberately minimal `PATH`, which was `/usr/bin:/bin` — so `mcp-npm`'s publish tool, whose `npm pack` runs the package's own prepare script, died several layers down with `sh: npm: command not found`. Neither `Resources` nor `Resources/npm/bin` fixes it: the first holds an `npm` that is a directory, and the shims in the second locate npm relative to node's prefix (`<prefix>/bin/node` plus `<prefix>/lib/node_modules/npm`), which the flat bundle layout is not, so they fail with \"Could not determine Node.js install directory\". `make node` now stages a `Resources/bin` of symlinks to the `-cli.js` entrypoints, which skips prefix detection entirely, and every child gets that directory in front of `/usr/bin:/bin`. What is added is exactly node, npm and npx from this bundle — never the developer's shell PATH, and nothing a profile can point elsewhere.",
              "`scripts/verify-servers.sh` now asserts it before signing, with `env -i` so an inherited PATH cannot pass the check on the developer's own npm. Every existing step ran the two binaries by absolute path, which is how a bundle that no child could shell out from passed all of them.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "The npm catalog entry documents the variables it always read.",
            body: [
              "`NPM_BIN`, `NPM_TOTP_LABEL`, `NPM_TOTP_SECRET` and `NPM_TOTP_KEYCHAIN_SERVICE` are now in the profile editor, and `NPM_OTP_MODE` lists `totp` — the only mode that answers npm's second factor without a human, and therefore the only one an unattended publish or trusted-publisher batch can use. It was missing from the description, which made the mode undiscoverable from Bastion.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_13_0: Release = Release(
    version: "1.13.0",
    date: "2026-09-07",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A shield in front of the provenance badge, and a seventeenth package behind it.",
            body: [
              "The badge 1.12.0 introduced now carries `checkmark.shield.fill` at its own teal tint, both in a server's pane and in the catalog row. `Badge` gained an optional glyph to do it, defaulted to nothing, so every other call site renders exactly as it did.",
              "`@mgcrea/mcp-x` published 0.3.0 from GitHub Actions in the meantime, and its attestation names the repository the entry already links, so seventeen of the twenty-three npm entries carry the badge rather than sixteen. Checked against the registry rather than assumed, which is the only way the claim is worth anything.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [
          "This release is mostly a hardening pass over the gateway, the supervisor and the purchase path. Several of the entries below are reachable by anything that can open a connection to the port, so they are worth reading before deciding to defer the update.",
        ],
        entries: [
          Entry(
            ordinal: 1,
            headline: "One crafted request could take the whole app down, before it was ever asked who was sending it.",
            body: [
              "`Int(\"-1\")` parses. The fill loop was then skipped, `body.count >= declared` passed, and `body.prefix(-1)` hit `Collection.prefix`'s own precondition — which kills the process, not the connection. It ran on the connection thread BEFORE the Host, Origin and bearer-token checks, so it needed nothing but the ability to reach the port: every client session and every supervised child went down with it. Reproduced with a single request against a running build. The gateway now answers 400 and keeps serving.",
            ]),
          Entry(
            ordinal: 2,
            headline: "A progress frame could be written into a different client's response.",
            body: [
              "A frame is looked up under the supervisor's lock and delivered outside it, from the child's reader thread. If the reaper expired the waiter and resumed the connection thread in that window, the connection's own `defer` could `close(2)` the socket before the reader's write landed — and a free descriptor number is one the kernel is entitled to hand to the next accepted connection. The write then landed in somebody else's response.",
              "`HTTPStream` now tracks a closed flag under its own lock, set by that `defer` before the close runs and checked by every write. A frame is either written in full to a descriptor that is still ours, or not written at all.",
            ]),
          Entry(
            ordinal: 3,
            headline: "A double-spawn race could leave an orphaned server holding a profile's credentials.",
            body: [
              "`ensureRunning()` was check-then-act, so two connection threads that both found a dead child could both start one; nothing ever terminated the loser. Worse, the orphan's eventual exit tore down the child that had won, because `childExited` cleared the pending state unconditionally.",
              "A semaphore now serialises start-and-handshake, and `childExited` is a no-op unless the exiting process is the instance's current one. The idle-sweep timer moves under the same lock, since `stop()` is reached from three threads and every other field there was already guarded.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Four gaps in the remote-server OAuth flow.",
            body: [
              "`PKCE.init` and `randomState` discarded `SecRandomCopyBytes`' status, so a CSPRNG failure produced an all-zero verifier or state in silence — a predictable challenge and a predictable CSRF token. That is now fatal, matching `GatewayToken.mint`. The callback checked `error` before `state`, so anything that could reach the ephemeral loopback port could abort an authorization in flight and have it read as the provider's refusal; state is checked first now. `resourceMetadataURL` split a 401 challenge on every comma, truncating a quoted `resource_metadata` value containing one, and is now a quote-aware scan. And the callback's accept loop polled with a deadline while the one-byte `recv` after `accept` had none, so a browser's speculative pre-connect that sent nothing parked the authorization until the app restarted. Each fix ships with a `scripts/remote-check.swift` case that fails without it.",
            ]),
          Entry(
            ordinal: 5,
            headline: "The SSE parser would buffer without limit, and rescanned from the start on every chunk.",
            body: [
              "Every other reader in the app bounds what it will take from an untrusted source; this one, fed straight from `URLSession` by a remote server, did not — and its rescan made a long stream quadratic. Both are now handled the way `Supervisor.readLoop` already handled its own: a 32MB ceiling, and a scan that resumes two bytes before the last cut.",
            ]),
          Entry(
            ordinal: 6,
            headline: "A client config backup kept the previous bearer token at the original file's permissions.",
            body: [
              "The backup written ahead of a rewrite inherited the source's mode, so re-wiring a world-readable config left a sibling `.bastion-backup` holding the OLD token, readable by anyone, indefinitely. It is now `chmod`'ed 0600 like the file it backs up.",
            ]),
          Entry(
            ordinal: 7,
            headline: "An install could hang forever, and the row could never be retried.",
            body: [
              "Both the install and the update-check subprocess read to EOF with no deadline, so a registry that accepted the connection and then said nothing parked the call indefinitely. Because `running[server.id]` is cleared only when the task returns, every retry was refused for the life of the app while the row sat on \"Installing…\" with no way to dismiss it. A watchdog now SIGTERMs after five minutes and the call surfaces a named timeout.",
            ]),
          Entry(
            ordinal: 8,
            headline: "A locked keychain told every client to re-wire itself.",
            body: [
              "`identify(_:)` ran on every request ahead of everything else, doing a `SecItemCopyMatching` over the whole account namespace plus a decrypting read per issued client. That set changes only when a client is wired or unwired, so it is cached for 60 seconds now and invalidated explicitly on issue and revoke.",
              "The cache also separates two states the old `Optional` collapsed into one: a token Bastion does not know (the client's problem, still 401) and a keychain that will not answer at all (this app's problem, and usually transient). The second answers 503 now, instead of sending the owner of a locked keychain off to re-wire every client they have.",
            ]),
          Entry(
            ordinal: 9,
            headline: "A revoked licence could be mailed out again, and a dispute could restore the wrong one.",
            body: [
              "Five gaps in the purchase webhook, with the schema to support them. `fulfil` re-sent a revoked licence's key on any redelivery past the cooldown — or on a dashboard \"Resend\" — under a note promising a refund that had already been paid. `charge.dispute.closed` with status `won` restored ANY revoked licence for that payment intent, including one revoked by an unrelated refund; it is scoped to `revoked_reason = 'disputed'` now. The only idempotency key was `stripe_session_id`, which stops a second licence but not a second email, so every webhook event id is recorded once handled and a duplicate delivery is a no-op. `checkout.session.async_payment_succeeded` and its failed twin were unhandled, so a delayed-notification method — SEPA and its relatives — could charge a customer and mint nothing; both route to the same path. And `/thanks` served a licence key with no cache-control, while the 404 page hardcoded the site's host instead of reading the `SITE_URL` binding that was declared and never read.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_12_0: Release = Release(
    version: "1.12.0",
    date: "2026-09-06",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "The iOS Simulator joins the catalog.",
            body: [
              "Thirty-four entries now, twenty-three children and eleven remote. It drives a booted simulator — screenshots, the accessibility tree, taps, swipes, typing, app lifecycle and the staged environment — and installs from `@mgcrea/mcp-ios-simulator`.",
              "Two lanes reach it and they fail independently. `xcrun simctl` covers app lifecycle, the staged environment and the screen itself; only the accessibility tree and synthetic touches go through a WebDriverAgent runner, reached over the HOST's own loopback because a simulator shares the host network stack. That split is the real difference from the iOS Device server, where seeing anything at all requires the runner: here `simctl io screenshot` needs none, so everything except `ui_tree` works before one has ever started — and once writes are on, the server can start the runner itself. `ios_simulator_diagnostics` reports the two lanes separately.",
              "It takes no credentials, so it has no auth modes, and unlike the device server there is barely any setup either: a simulator needs no pairing and no Developer Mode toggle, so there is nothing for a profile to hold. `IOS_SIMULATOR_ALLOW_WRITES` gates the fourteen tools that actually drive it.",
              "The package itself defaults writes ON, the only entry here that does, reasoning that a phone belongs to a real person while a simulator is disposable and holds nobody's data. That default is never reached under Bastion, which writes the gate value explicitly on every spawn: the profile toggle is what decides, and a profile with writes off spawns a server that has not registered the driving tools at all.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Catalog entries say which packages npm can tie back to the repository they link to.",
            body: [
              "A `provenance` badge now sits beside the package name in a server's pane and in the catalog list, and the website marks the same entries. Sixteen of the twenty-three published packages carry a SLSA build attestation from GitHub Actions; the seven that do not are not suspect, they publish the older way, so the badge is only ever shown and never negated.",
              "The claim is deliberately narrower than \"attested\". A bare attestation says some CI somewhere built the tarball, which is a thing a typosquat of a popular package can have too. What is checked is that the workflow's repository matches the `docsUrl` the entry already advertises, so the badge means the bytes trace to the source the reader can go and look at. All sixteen match today, which makes the check a drift detector rather than a one-off audit.",
              "It is a smaller claim than a review, and it is placed to say so: under the paragraph in a third-party server's Package card that finishes explaining nobody here read the code. Provenance ties a package to a source; it does not vouch for what is in it.",
              "`make provenance` prints what the registry currently holds, and `make provenance-check` fails when a claim in `servers.json` no longer does. Neither runs in CI, and neither belongs to the generator: it has to stay offline and deterministic because `servers-check` is a drift gate, and somebody else publishing overnight must not turn an unrelated pull request red. The two directions of drift are not treated alike — a stale `true` is a hard failure, because Bastion must never claim provenance it cannot show to someone deciding whether to run code on their machine, while a stale `false` is only advice, because a third party improving their release process is good news and good news must not fail a build.",
              "`list_catalog` returns the flag too, so a model choosing between two servers that do the same job has one trust signal it can actually act on.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "A listing too small to be worth searching is no longer fronted, whatever the switch says.",
            body: [
              "Loading tools on demand now resolves a third term beside the server's switch and the client's own deferral, and this one is measured rather than configured: a listing is fronted only when it has at least twice as many tools as the facade would send in its place, and costs at least twice as many tokens. Both have to hold.",
              "The count is the term that decides the real cases, and it is not a proxy for the bytes. What this feature sells is not compression, it is selection — eighty-five schemas go unsent because an agent needed two of them. A server exposing three tools offers no selection to make, so the index costs two round trips to learn what one listing already said.",
              "That is most of the remote catalog's shape. Cloudflare's hosted endpoint exposes `search`, `execute` and `docs`; Stripe ships a read and a write dispatcher beside its own search. They are already this design, and their listings are not small in bytes — Cloudflare's three descriptions measure about 1.7k tokens — so a floor counting bytes alone would front them and buy nothing. Nor can Bastion recover what a vendor's dispatcher already took away: the real tool name upstream _is_ `execute`, so the audit row says `execute` either way, and the one advantage of doing this in the gateway does not apply.",
              "Measured rather than listed, deliberately. A set of vendors known to front their own tools would rot the first time one unpacked its dispatcher, and would do nothing for the small child server with the same problem and no vendor to name. Where the floor holds, the server's card says which half held instead of rendering a saving of nothing, the client's context bill counts the real listing, and `get_server` reports it as `lazy_tools_note`. It governs what is ADVERTISED only — a client still holding a fronted list goes on calling through it, which is the rule a pre-toggle tool name has always followed.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_11_0: Release = Release(
    version: "1.11.0",
    date: "2026-09-06",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "The writes get their own dispatcher, so an editor's approval rule stops collapsing.",
            body: [
              "The facade's one real cost was that every call reached the client as `bastion_call_tool`, so a rule covering `app_store_connect_list_builds` ended up covering `..._update_app` too. A profile whose server Bastion can classify is now served a fourth tool, `bastion_call_write_tool`, and the ordinary dispatcher REFUSES anything Bastion knows to mutate — naming the other one, so the next call succeeds. Allowlisting `bastion_call_tool` in an editor can no longer run a write, and that is a property Bastion holds up rather than a hint it asserts and hopes the host respects. The two are disjoint in both directions, so nothing downstream has to check the split twice.",
              "`bastion_call_tool` still carries no `readOnlyHint`, and that is deliberate. A tool in neither the manifest's `writeTools` nor the server's own annotations is UNCLASSIFIED, and the house rule is that silence is not a no. Bastion already bets that way for its own gating, but that bet only decides Bastion's refusal; putting it in an annotation moves it into the editor's confirmation prompt, where being wrong means a mutation nobody was asked about. Refusing the writes it knows is honest and checkable. Claiming to be read-only would be neither.",
              "Classification comes from the manifest's `writeTools` ORed with what the server annotates, so a server that says nothing either way keeps exactly the three tools it had rather than gaining a fourth that would be a guess — and a profile with writes off has nothing to dispatch to, so it keeps three as well. Seven catalog entries declare `writeTools` today; Bastion's own server annotates every tool it exposes.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Every client now says what it is actually being sent.",
            body: [
              "Each server pane already quoted its own figure and each one looks survivable alone; a client wired to five of them pays the sum on every connect, and nothing in the app added them up. The Clients pane does now, under Context, and it resolves both axes into the one number that matters: a server loading on demand counts as its three or four declarations rather than its full listing, and a client that defers schemas is told it is sent everything but holds only the names — no alarm, and no false comfort either.",
              "It says \"measured\", and names how many of the wired profiles have a figure, because `tool-costs.json` holds one only for a profile something has actually listed. The total is a floor, and a floor that says so.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "\"Load tools on demand\" moved from the profile to the server.",
            body: [
              "It was stored per profile, with the control on a server writing through to every one of its rows — which is why that control needed a \"Mixed\" position at all. Mixed was never a state anybody set out to reach; it was the shape of the storage showing through the window.",
              "The question the switch answers is _is this listing big enough to be worth the trade_, and a listing is a property of the server: `appstore-connect` is 85 tools, `reddit` is 14, and two profiles of one server differ in credentials and in the write gate rather than in whether eighty-five is a lot. The one disagreement that genuinely was per profile — \"this one feeds Claude Code, which defers by itself\" — is the client axis above, where a profile feeding two clients can be answered honestly instead of averaged.",
              "A `lazyTools` already written on a profile is carried onto its server once, on the first launch after upgrading, and the key then leaves `profiles.json` on the next save. `upsert_profile` still accepts `lazy_tools` and now writes it through to the server: an argument that starts being silently ignored is worse than one that was renamed, and the schema says out loud that it moves every profile of that server. `list_servers` and `get_server` report it, which is where it lives now.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "The cost figure stopped rounding in its own favour.",
            body: [
              "A measurement now records how many of its tools Bastion could tell were writes, so a view can distinguish \"no writes here\" from \"Bastion cannot tell\". Without it `ServerDetail` had no way to see a server that classifies by annotation alone — the manifest is all a view has — and understated the facade by the fourth declaration on every one of them. The same figure drives a new caveat: where load-on-demand is on and Bastion could classify nothing, the pane says so, because that is the case where one approval rule in the editor still covers every call including the writes.",
            ]),
        ]),
    ])

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
