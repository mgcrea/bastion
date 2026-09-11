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

  /// The marketing version alone: no build number, no demo override.
  ///
  /// `AppInfo.version` will not do. It returns `DemoSeed.version` under a
  /// capture, and `DemoSeed`'s own header forbids writing anything to the user's
  /// preference domain — "not even a `UserDefaults` key, because a capture runs
  /// against the user's real preference domain".
  ///
  /// Both of `markSeen()`'s callers are already guarded (`AppDelegate` returns
  /// before `markSeenIfUnset()` under a capture, and `WhatsNewPane` guards its
  /// own call), so nothing writes a demo version today. That is exactly when to
  /// fix it: the line that would make this a real write is one line, and it
  /// would go in somewhere nobody reads as capture-sensitive. Cupertino reached
  /// the same conclusion first and documents it on its own `marketingVersion`.
  static var marketingVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
  }

  /// Record that the notes for this build have been read.
  static func markSeen() {
    UserDefaults.standard.set(marketingVersion, forKey: seenKey)
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
  static let releases: [Release] = [v1_17_0, v1_16_0, v1_15_0, v1_14_0, v1_13_0]

  // swift-format-ignore
  private static let v1_17_0: Release = Release(
    version: "1.17.0",
    date: "2026-09-11",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Help ▸ Report an Issue, Send Feedback and Bastion Support.",
            body: [
              "The Help menu opens the issue tracker, a feedback form on the website and a new support page, from the same shared package the other mgcrea apps use. The app still sends nothing: each item hands your browser a URL, and the app version, macOS version, Mac model and language it carries are in the address bar and editable on the form before anything goes anywhere. The tracker stays the primary channel; the form is for reports that quote your own servers, profiles or activity log.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "The app icon's fort sits behind the ridge instead of on top of it.",
            body: [
              "Standing in front of both hills at 580 wide, the fort's 90% ink laid a pale translucent band across the ridge wherever the two crossed, and at 16px the two shapes merged into one. The fort is 24/29 of that size now and takes the ridge itself as its base — the same curve, re-expressed between its two feet — so fort and hill share one edge and never overlap. The `.icon` bundle, the lockup and every website favicon, touch icon and card are regenerated from the new mark. The menu bar glyphs are deliberately untouched: they still draw the fort standing on the ridge, recorded in `design/README.md` as a known divergence rather than quietly changed.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "A gateway that had died went on showing green.",
            body: [
              "`Gateway` keeps its state behind a lock and is `Sendable`, with nothing for SwiftUI to subscribe to, so `Gateway.shared.port` read inside a view body was a value sampled once and never revisited. The menu bar panel got away with it because `MenuBarExtra` rebuilds its content every time it opens; the main window has no such rebuild, so the sidebar's status row could sit on \"Serving on 127.0.0.1:…\" indefinitely — the one line whose whole job is to beat a client's \"connection refused\" to you. Both read an observable projection now, published by `Gateway.start()` on the failure path as well as the success one.",
            ]),
          Entry(
            ordinal: 3,
            headline: "The menu bar panel had a phantom gap above the gateway line when licensed.",
            body: [
              "The licensed case returned an empty view from inside a `TimelineView`, which measures zero but remains a laid-out child, so the stack allocated spacing on both sides of nothing and the header sat 24pt above the line instead of 12. It also ran a fifteen-second timer for the lifetime of every panel open with no countdown to show for it. The licensed case contributes no view at all now, and only the trial and refused states build the timer.",
            ]),
          Entry(
            ordinal: 4,
            headline: "The menu bar's trial banner offered a licence the rest of the app would not sell.",
            body: [
              "Its buy button was not gated on `isSelling`, which the Settings licence pane has always gated its identical button on — so a build made while the store is closed answered the same question two ways depending on where you asked it.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_16_0: Release = Release(
    version: "1.16.0",
    date: "2026-09-08",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A reply can be stopped, and the chat says which tool it is waiting on.",
            body: [
              "The Send button becomes Stop while an answer is arriving rather than a second control appearing beside it, so the thing you reach for does not move. Stopping drops that question from what the model remembers — said in the transcript rather than left to be inferred — and rebuilds the session from the last complete answer, so an abandoned half-turn cannot sit in the context poisoning everything after it.",
              "Beside the spinner is the name of the tool currently in flight. A call is allowed three minutes before Bastion gives up on it, and a bare spinner for three minutes is indistinguishable from a hang. One question is also capped at six tool calls now: every call's output can be 2000 characters, so a handful is the rest of the window, and a model looping on a failing tool could otherwise spend six timeouts before anybody could type again.",
            ]),
          Entry(
            ordinal: 1,
            headline: "One press asks about every installed server, and the sidebar says which ones answered.",
            body: [
              "Whether a server had a newer version was a fact you could only collect one server at a time: open its pane, press the button, read the badge, go back, repeat. The Servers header carries a check-all control now, rows npm would move get an orange dot beside whatever else they were already saying, and Settings ▸ Updates has grown a Servers section listing every npm-installed server with its state — with Update All behind a confirmation that counts the running processes it is about to stop.",
              "Still not a timer. Nothing checks on launch, on a window appearing, or on a schedule; an answer is as fresh as the last press and is forgotten when Bastion quits rather than shown stale. What changed is that one press now covers nine servers instead of one.",
              "The Sparkle pane's caption was corrected on the way: it claimed the appcast was \"the only network connection Bastion makes\", which was never quite what was meant and stopped being defensible with an npm check sitting under it. It says \"the only connection Bastion opens on its own\" now, which is the claim `UpdateController` and `ServerInstaller` have both always actually made.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "Leaving the chat pane threw the conversation away.",
            body: [
              "The pane was one arm of the window's `switch`, so a trip to the Log and back destroyed it — the transcript, the tools it was started with, the live session, and a reply that was still arriving with nobody left to receive it. The conversation is owned by the window now rather than by the view, so it survives navigating away, closing the window, and reopening it.",
            ]),
          Entry(
            ordinal: 3,
            headline: "The transcript scrolled to the wrong place, or not at all.",
            body: [
              "It followed the last message's text, which a tool call is not — so a call arriving mid-answer grew the transcript under the fold and moved nothing. It also fought anyone scrolling up to re-read, dragging them back on every token. It follows the tail until you scroll away, stops, and offers **Jump to latest** while a reply is still arriving; asking something new starts following again.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Shift-Return did nothing in the composer.",
            body: [
              "Return was bound twice — once by the text field and once as the Send button's key equivalent — and removing the duplicate was not enough on its own: Shift-Return was then swallowed outright, no newline and no send, so the field never had the multiline behaviour its own line limit advertised. It inserts a newline now, and plain Return still sends.",
              "The tool picker is also disabled while a reply is arriving, with a note saying why. Changing the selection rebuilds the session, which would have discarded the answer being written into it.",
            ]),
          Entry(
            ordinal: 5,
            headline: "A streamed token re-rendered the whole pane.",
            body: [
              "Every token re-ran the profile picker's pass over every server crossed with every profile, plus the budget arithmetic and the banners, because one view body read the messages. The header, transcript and composer are three views now, and only the transcript reads them.",
            ]),
          Entry(
            ordinal: 6,
            headline: "Claude Desktop was being fronted with the facade it never needed.",
            body: [
              "\"Load tools on demand\" replaces a server's listing with a search tool and a dispatcher, and it is skipped for clients that already fetch a schema only when something reaches for it — a list that had one entry, Claude Code, because Claude Code documents the mechanism. Claude Desktop sat outside it on the grounds that no equivalent was documented for it, and `docs/clients.md` and the client pane both went further and stated as fact that Desktop takes the whole listing on connect. Nobody had checked.",
              "It was checked on 2026-09-08, and it defers. A one-tool server was wired into `claude_desktop_config.json` beside the usual surface, carrying two freshly generated tokens: one in the tool's description, one as the only allowed value of its required argument. Asked to quote either from context, Desktop 1.46388.4 produced neither, named the tool under a deferred listing, and then called it with the correct passphrase — a value nothing but the schema carried, fetched on the already-open connection with no second `tools/list`. Chat and Cowork behaved the same way.",
              "So the facade was costing these users rather than saving them anything: Desktop never held the schemas it buys back, and being fronted took its own tool search away, leaving three generic entries indexed where eighty-five specific ones used to be. `claude-desktop` joins the list, the website's figures say which clients they do not describe, and the flat claims in the docs and the pane are gone.",
            ]),
          Entry(
            ordinal: 7,
            headline: "The per-client escape hatch was withheld from the clients that needed it.",
            body: [
              "The Context pane offered \"set this to No\" only for clients Bastion already believed defer. The reverse case — a client that starts deferring before Bastion learns it has — is the one nobody can report, and it is exactly what just happened. Both directions are offered now, and the pane says what Bastion has watched rather than asserting what a client does.",
            ]),
        ]),
    ])

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

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
