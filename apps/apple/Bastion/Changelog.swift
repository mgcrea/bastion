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
  static let releases: [Release] = [v1_23_0, v1_22_0, v1_21_0, v1_20_0, v1_19_0]

  // swift-format-ignore
  private static let v1_23_0: Release = Release(
    version: "1.23.0",
    date: "2026-09-22",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Workspaces scope profiles to folders.",
            body: [
              "A workspace is a set of folders and the profiles that belong there. A profile in one is left out of every client's global list and written into Claude Code's per-folder project blocks instead, so a session in an `rgis` repository sees the `rgis` servers and nothing from another account. A folder inside a git repository means the whole repository, its subfolders and its worktrees, which is how Claude Code itself files project blocks; a parent folder is expanded to every repository below it. Managed in Settings → Workspaces, or with the new `list_workspaces`, `upsert_workspace` and `remove_workspace` tools. Claude Code only for now.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "Usage stats count what you asked for, not what the client's SDK sent on its own.",
            body: [
              "The handshake and listing methods a client sends by itself on every connect (`initialize`, `tools/list` and the other listings, `ping`, `logging/setLevel`) were recorded as calls, so `tools/list` topped every ranking, the call totals measured how often clients reconnected, and the median latency was mostly that of a cached listing. They are no longer recorded, and days already on disk are filtered when read. The per-client totals have no method to filter on, so they keep counting old handshakes until those days age out of the window.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_22_0: Release = Release(
    version: "1.22.0",
    date: "2026-09-18",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Claude Code's other config directories are offered as clients of their own.",
            body: [
              "Claude Code reads `CLAUDE_CONFIG_DIR`, so one Mac can run several profiles side by side with separate server lists — and Bastion knew about exactly one of them, `~/.claude.json`. The other was left to be kept in step by hand, which meant copying entries between files and inheriting the first profile's token with them: one revocation signed out both, and nothing on screen said the second had fallen behind. Bastion now finds `~/.claude-<name>` directories and gives each a row with its own gateway token, its own audit trail and its own Configure button. Detection is a switch in Settings, beside a list for a config directory that lives somewhere no scan would look. The default profile's file is deliberately not discovered but named outright, because Claude Code keeps it _outside_ its config directory — `~/.claude.json`, not `~/.claude/.claude.json`, and the latter does exist, holding first-run bookkeeping and no servers at all.",
            ]),
          Entry(
            ordinal: 1,
            headline: "A config directory Bastion has not written is left alone until you ask.",
            body: [
              "Automatic rewiring decides what is wired by looking for entries shaped like Bastion's, and never at the token — so a second Claude profile filled in by copying entries out of the first passes that test without Bastion having touched the file. Such a row is now kept out of automatic updates until Configure has been pressed on it once, and says so. Pressing it renames the entries to the current scheme in place, issues that profile its own token, and leaves a backup beside the file. Clients with a single config file are unaffected.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "A window resize could take the app down.",
            body: [
              "AppKit's frame autosave writes from inside the `setFrame` that prompted it, so a resize SwiftUI drives itself meant writing to `UserDefaults` in the middle of the window's own layout pass — and that write was enough to abort the process. Persisting posts `NSUserDefaultsDidChange`, SwiftUI's `@AppStorage` observer reads it as a settings change and dirties the hosting view, and the constraint update that follows lands inside the layout pass still running; AppKit throws rather than re-enter, and nothing catches it. It needed no bad frame and no bad window — one `@AppStorage` anywhere in the app was fuel enough. Window frames are now restored with `setFrameUsingName` and written back on a turn of their own, and only for a resize or a move you performed. A frame remembered by an earlier version still restores.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_21_0: Release = Release(
    version: "1.21.0",
    date: "2026-09-18",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Entries Bastion left behind can be cleaned up without unwiring the client.",
            body: [
              "An entry Bastion wrote for a profile that no longer exists went on sitting in the config, sending requests the gateway refuses, and it was invisible on the client pane: `isOurs` claimed it, so it was not listed among the servers Bastion did not write, and no profile matched it, so it earned no row either. The only remedy was _Remove Bastion's entries_, which took out the working ones too. A **Stale entries** card now lists each one with the profile it points at, and one button removes all of them in a single write. It stays narrow on purpose: an entry filed under an older key is a rename, one pointing at a stale port is _points elsewhere_ and Configure rewrites it, and a profile whose server is merely switched off still exists — none of the three is touched. Removal is a button rather than something Bastion does on its own, because the instance most likely to misjudge which profiles exist is a second copy of Bastion, which is where these came from — and for that same reason a Debug build, which keeps its own profiles and shares these configs with the installed app, draws the card but refuses the removal.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_20_0: Release = Release(
    version: "1.20.0",
    date: "2026-09-17",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A server running on this Mac can be added as a remote server.",
            body: [
              "A remote URL had to be https to a public host, which shut out an MCP server you run yourself on this Mac over plain http. A URL typed with the literal `127.0.0.1` or `[::1]` is now accepted over http or https, on any port but Bastion's own gateway. The credential never leaves the machine, so the reason for https does not apply. It stays narrow on purpose: `localhost`, the rest of `127/8` and any name that resolves to loopback are still refused, because a name can be rebound and a literal cannot. Typing `localhost` gets a message pointing at `127.0.0.1` instead. The same rule applies to `add_custom_server`, whose description now says so.",
            ]),
        ]),
    ])

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

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
