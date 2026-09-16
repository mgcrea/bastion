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
  static let releases: [Release] = [v1_19_0, v1_18_0, v1_17_1, v1_17_0, v1_16_0]

  // swift-format-ignore
  private static let v1_19_0: Release = Release(
    version: "1.19.0",
    date: "2026-09-16",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Launch at login",
            body: [
              ", at the top of Settings ▸ General. Until now nothing started Bastion when you logged in, so a client configured with a URL found nothing listening until somebody opened the app; one that launches its own bridge still starts Bastion on demand either way. The choice is kept apart from what macOS reports, so an update that drops the registration has it put back on the next launch. A copy running from outside Applications says why it cannot be added instead of registering a path that will vanish, and one waiting on your approval in System Settings says so.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "An npm install could hang with nothing left to wait for.",
            body: [
              "The installer read npm's output until the pipe closed, and the pipe stays open for as long as anything holds its write end — so a lifecycle script or a git dependency fetch that outlived npm kept the install spinning after npm itself had exited, where the timeout could not reach it. Reading now stops once npm is gone and its output has gone quiet, and an install that times out escalates to killing npm if it ignores the request to stop.",
            ]),
          Entry(
            ordinal: 2,
            headline: "A custom server at an `http://` URL was refused as a bad npm package name.",
            body: [
              "Only `https` URLs were recognised as remote, so anything else fell through to the npm branch with an empty package name, and the error was about the wrong transport entirely. Any URL is a remote server now, and a non-https one is refused for what it is. A URL field that is not a URL at all gets its own message.",
            ]),
          Entry(
            ordinal: 3,
            headline: "A stdio client could wait forever for Bastion to start.",
            body: [
              "When the app is not running, the bridge a client launches opens it and waits; nothing bounded how long `open` itself could take, so a wedged LaunchServices or a first-launch prompt nobody could see left the client showing a server that never starts. `open` gets ten seconds now, after which the bridge goes on waiting for the gateway the way it always did.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 4,
            headline: "Settings groups its sidebar into three sections",
            body: [
              ", as Cupertino and Armada do: General and Activity; What's New, Updates, About and Help; then Licence on its own.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_18_0: Release = Release(
    version: "1.18.0",
    date: "2026-09-14",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A Stats pane, and the number nobody could see.",
            body: [
              "Every server pane already quoted its own tool list cost, and each one looked survivable alone; nothing added them up. The new pane ranks what each server costs a client on every connect, says what the write gate and loading on demand keep out of a context, and then — under a time range, because the two are different kinds of fact — shows calls, failures, response times and restarts over the last 7, 30 or 90 days. `ServerDetail` and `ClientDetail` grew the same figures scoped to one server and one client.",
            ]),
          Entry(
            ordinal: 1,
            headline: "A usage rollup, on disk and on by default.",
            body: [
              "Per day, per profile and per tool: how many calls, how many bytes came back, how long they took, how many failed, how many times a server restarted. Counts only, with no arguments, no results, no resource paths and no identifiers — which is what lets it be on by default where the activity log is not. Tens of kilobytes a day on a busy machine, kept ninety days, never uploaded. Settings ▸ Activity turns it off and deletes the file.",
            ]),
          Entry(
            ordinal: 2,
            headline: "`server_stats`",
            body: [
              ", a built-in tool returning the same figures for the calling profile, scoped the way `recent_activity` is and held to the same 16 KB reply budget. `status` gained one key saying whether counting is on and how much history stands behind it.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Adding or removing a profile updates every client already wired to Bastion.",
            body: [
              "A client's config used to be written only by _Configure_ and the `wire_client` tool, so a profile added anywhere else left every client holding the previous list with nothing on screen to say so. A client Bastion was never configured into is still left alone, and a rewrite that cannot land — a read-only file, somebody else's entry in the way — is logged rather than failing the save. The Clients pane goes on reporting what each file actually holds.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Click a server row in the menu bar to find its profile.",
            body: [
              "The panel lists what is running as `<profile> / <server>`; a click opens the main window on that server, scrolls the profile's row into view and lights it briefly.",
            ]),
          Entry(
            ordinal: 5,
            headline: "A Help pane in Settings, and an About pane with more in it.",
            body: [
              "Bastion lives in the menu bar, so the Help menu's links only existed while a window happened to be open; they have a pane of their own now. About gained the app icon, the System and Model rows, and a button that copies all of it for a bug report.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 6,
            headline: "A second profile of a server renamed the first one's entry in every client config.",
            body: [
              "The key was a bare `<server>` until a second profile appeared, at which point both grew the profile name — and nothing rewrote the configs already holding the old one, so the new profile stayed invisible to every client until _Configure_ was pressed again. Every key is `<profile>-<server>` now, even for a server with one profile, and configs written under the old scheme are renamed in place on launch. The key is part of every tool name a client shows, so `mcp__shopify__…` becomes `mcp__prod-shopify__…` — worth knowing if a client's permission rules name the old one.",
            ]),
          Entry(
            ordinal: 7,
            headline: "A profile name ending in a space could not be saved, and the sheet did not say why.",
            body: [
              "Saving already trimmed the name, but the Save button and the missing-values line judged the raw field, so a pasted handle with a trailing space left Save disabled with nothing on the sheet to explain it. All three judge the trimmed name now.",
            ]),
          Entry(
            ordinal: 8,
            headline: "The EULA said the audit log is never written to disk.",
            body: [
              "That was true of the in-memory activity log the sentence was written about, and not of the durable audit log, which is off by default and writes under Application Support once turned on. §7(c) describes the two separately now, and the privacy page, `llms.txt` and the website's screens section, which carried the same sentence, were corrected with it.",
            ]),
          Entry(
            ordinal: 9,
            headline: "A refused tool call was recorded as a success.",
            body: [
              "A failure reaches the gateway either as a JSON-RPC `error` or as a result carrying `isError: true`, and the cheap pre-filter on the legacy-era path looked for the first spelling only — `isError` contains no lowercase `error`. Tool refusals are counted as failures now, and `make unit` holds the casing.",
            ]),
          Entry(
            ordinal: 10,
            headline: "The client pane's context bill claimed \"about\" for a figure it could not claim that for.",
            body: [
              "A listing read one page at a time makes every total built from it a floor. `partial` was read only as a trigger for the facade and never reached the sentence, which now says \"at least\" and fades the bar out rather than ending it.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 11,
            headline: "Wording, in nine places, because a new file writes to disk by default.",
            body: [
              "\"Nothing recorded is written to disk unless you ask for it\" was true of the activity log and was read as being about the app. It is now \"no arguments and no results\", in the EULA, the README, `docs/servers.md`, the privacy page, two website components, `llms.txt`, the Log pane's own footer and the profile sheet. The EULA's §7(c) has a third paragraph for the rollup — and its existing \"with timings\" is true for the first time, since a per-call duration is measured now rather than a row stamp.",
            ]),
          Entry(
            ordinal: 12,
            headline: "The menu bar's gateway line is caption-sized.",
            body: [
              "It inherited body text and was the largest line in the panel, bigger than the Servers header it sits above; it matches the sidebar and Settings ▸ General now.",
            ]),
          Entry(
            ordinal: 13,
            headline: "Settings reads General, Activity, What's New, Updates, About, Help",
            body: [
              ", and a pane's heading stays put while its cards scroll. The pane you last had open is remembered across the change.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_17_1: Release = Release(
    version: "1.17.1",
    date: "2026-09-11",
    sections: [
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "The menu bar panel came up empty in 1.17.0.",
            body: [
              "Moving the panel's chrome onto swift-support-kit's shared `MenuBarPanel` took the package at 1.2.0, whose panel laid its middle band out at no height — so it drew a header and a footer with nothing between them, and the gateway line and the servers section were rendered below the panel's own bottom edge. Everything the menu bar exists to show was off-panel; the release that introduced the shared chrome is the release that shipped it bodyless. The requirement is 1.2.1 or newer now.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "The menu bar header pins the version to its trailing edge.",
            body: [
              "The name stays at the leading edge and the version goes hard right, which is the arrangement the fleet settled on. Bastion's own suffix placement was one of the two inputs to that decision and lost it.",
            ]),
        ]),
    ])

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

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
