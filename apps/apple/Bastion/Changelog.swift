import Foundation
import SupportKitSettings

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
/// Only the data lives here. The types, the seen/unseen bookkeeping, the
/// markdown rendering and the pane are `SupportKitSettings`' `ReleaseNotes` and
/// `WhatsNewSettingsPane`, shared with Armada, Cupertino and Cadence; the
/// typealiases let the generated literals keep their short names. Every string
/// below is **raw markdown**, which `ReleaseNotes.markdown(_:_:)` renders.
///
/// The list is capped — see `Changelog.shown` in `scripts/generate-changelog.mjs`
/// — because this is the pane you open after updating, not an archive. The full
/// history is a link away, and `CHANGELOG.md` remains the source of truth.
nonisolated enum Changelog {
  typealias Release = ChangelogRelease
  typealias Section = ChangelogRelease.Section
  typealias Entry = ChangelogRelease.Entry

  /// The releases, the installed version and the seen key, in one value the
  /// badge, the indicators and the pane all read.
  ///
  /// The seen key stays `changelogSeenVersion`, the package's default and the
  /// key Bastion has always written, so nobody's read releases come back unread.
  ///
  /// Suppressed under a screenshot capture: whether an indicator appears would
  /// otherwise depend on what the capturing Mac last read, which is drift with no
  /// code change behind it, and `DemoSeed`'s header forbids a capture writing
  /// the seen version back into the user's real preference domain.
  static let notes = ReleaseNotes(
    releases: releases,
    unreleased: unreleased,
    showsUnreleased: AppInfo.isDebugBuild,
    isSuppressed: { DemoSeed.isEnabled })

  /// Whether to draw an indicator anywhere. False under a capture, through
  /// `notes`' suppression.
  static var hasUnseen: Bool { notes.badge > 0 }

  /// Where the full history lives, since only the most recent releases are here.
  static let historyURL = URL(string: "https://github.com/mgcrea/bastion/blob/main/CHANGELOG.md")!

  // MARK: - Generated

  // <generated:changelog> generated from CHANGELOG.md by `make changelog` — do not edit by hand

  /// The most recent 5 releases, newest first.
  ///
  /// Split into one `let` per release rather than a single nested literal.
  /// Swift's expression type-checker is superlinear in the depth of an array
  /// literal, and this one is releases of sections of entries of strings — the
  /// exact shape that turns into a multi-second type-check with no diagnostic.
  // swift-format-ignore
  static let releases: [Release] = [v1_25_0, v1_24_0, v1_23_0, v1_22_0, v1_21_0]

  // swift-format-ignore
  private static let v1_25_0: Release = Release(
    version: "1.25.0",
    date: "2026-10-04",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Skills.",
            body: [
              "Settings → Skills links Agent Skills from folders you choose into `~/.agents/skills` (Codex, Cursor, VS Code Copilot, Gemini CLI and others) and every Claude Code config folder, or, per workspace, into each repository's `.claude/skills` and `.agents/skills`. Bastion only ever creates symlinks and never writes into a source; anything it did not create is left alone and shown, a repository link another tool made into a source included, and broken links it owns are removed. Repository links are kept out of git through `.git/info/exclude`. A description over the Agent Skills standard's 1,024 characters but within Claude Code's 1,536 is still linked, with a warning that clients reading `~/.agents/skills` may skip it. Claude Desktop's pane lists the account skills synced to this Mac and exports a ZIP for any that are missing. Five new tools on Bastion's own server manage the same.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Yahoo Finance is in the catalog",
            body: [
              ": prices, fundamentals, financial statements, holders, options, news and analyst ratings, with no account or key, and nothing it can change. Apple Ads is listed too, marked not published until its package is.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: nil,
            body: [
              "`-autoWireClients YES` now turns automatic wiring back on in a Debug build; it was ignored.",
            ]),
          Entry(
            ordinal: 3,
            headline: "A store file that will not decode is kept, not emptied.",
            body: [
              "The server list, profiles, skills and workspaces each keep a `.unreadable` copy and refuse to save over it, and client wiring stands down until it reads again, so one bad edit no longer costs the whole list.",
            ]),
          Entry(
            ordinal: 4,
            headline: "A rewire changes only what Bastion owns.",
            body: [
              "It replaces the keys Bastion writes in its own entries and leaves the rest of each entry alone, writes through a symlinked config instead of replacing the link, reads a config that is empty mid-write again, and never replaces a client token the Keychain failed to read. A Codex `config.toml` shape the splice would corrupt is refused rather than rewritten. `-trustProfilesForStaleEntries YES` is now read.",
            ]),
          Entry(
            ordinal: 5,
            headline: "Supervised servers.",
            body: [
              "A child that fails its handshake, or is stopped, is sent SIGKILL if it outlives a grace period, so none is left running; a server that keeps crashing is restarted with a growing backoff after one immediate retry; frames from concurrent clients no longer interleave on a child's stdin; a client's cancel reaches the child under the id the child was given; stderr is redacted line by line; and a streamed reply sends no progress after its result.",
            ]),
          Entry(
            ordinal: 6,
            headline: "Writes off holds on a fresh server.",
            body: [
              "A `tools/call` that arrives before the server's tool list was ever fetched is judged against the catalog, and refused when the catalog cannot be read.",
            ]),
          Entry(
            ordinal: 7,
            headline: "Remote servers",
            body: [
              "refuse a reply whose peer address was never observed, and one that was stopped no longer starts a request.",
            ]),
          Entry(
            ordinal: 8,
            headline: "Bastion's own server.",
            body: [
              "`add_custom_server` refuses a catalog id, or an id profiles already hold credentials for, and `server_stats` totals count only the servers asked about.",
            ]),
          Entry(
            ordinal: 9,
            headline: "The audit log",
            body: [
              "verifies as truncated, not tampered, once retention has pruned its oldest segments. Retention applies at launch and when the setting changes, a torn last record no longer breaks the chain, a reply that arrives late is still recorded, queued records are written before quit, and the export is the text that was hashed.",
            ]),
          Entry(
            ordinal: 10,
            headline: "Skills.",
            body: [
              "Repository links are kept out of git in submodules and worktrees too, a link to a skill that became invalid is kept and shown instead of removed, a link another tool re-pointed while Bastion was applying a change is put back rather than replaced, and a skill's ZIP leaves `.git`, `.env` and other hidden entries out.",
            ]),
          Entry(
            ordinal: 11,
            headline: nil,
            body: [
              "A licence key a mail client wrapped across lines is accepted, an OAuth sign-in keeps waiting when a stray request reaches its callback, the Log pane follows new entries, the chat drops whole turns when it trims its history, a stuck update check clears, and relaunching to update stops the gateway first.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_24_0: Release = Release(
    version: "1.24.0",
    date: "2026-09-26",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Xcode is in the catalog.",
            body: [
              "Xcode 26.3 and later ship their own MCP server, `xcrun mcpbridge`: read and edit a project, build, run and test it, render previews, and drive a simulator or device. Bastion runs and supervises it like any other server, with nothing to download. Xcode asks you to approve the agent the first time it opens a project, and behind Bastion that agent is Bastion itself, so one approval covers every client. With a profile's writes off, the tools that change a project on disk or run arbitrary code (`RunCodeSnippet`, `InvokeDebuggerCommand`) are hidden; building, running and testing stay available.",
            ]),
          Entry(
            ordinal: 1,
            headline: "A third kind of server: a command that ships with the Mac.",
            body: [
              "Catalog entries can now name a program directly under `/usr/bin`, with fixed plain-word arguments. Only the catalog can: a custom server is still an npm package or a URL, so nothing a person types and nothing a client sends can name a command line.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "The website no longer lists Playwright, Supabase, Netlify and Apify as read-only.",
            body: [
              "They gate writes by tool name, which the site's copy of the rule did not count. The server detail pane now describes that gate for them too, where it used to only for remote servers.",
            ]),
        ]),
    ])

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

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
