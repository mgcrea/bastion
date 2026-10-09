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
  static let releases: [Release] = [v1_27_0, v1_26_0, v1_25_0, v1_24_0, v1_23_0]

  // swift-format-ignore
  private static let v1_27_0: Release = Release(
    version: "1.27.0",
    date: "2026-10-09",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A server another app hands over.",
            body: [
              "An app serving MCP on this Mac can open a `bastion://add-server` link (swift-mcp-kit 1.2's `BastionLink`) to offer Bastion its endpoint and bearer token. Nothing is added until a sheet shows which app asked, the endpoint, the URL it replaces when the server is already listed, and which of its tools change data; you pick the profile (`local`, or the server's existing one) and whether writes are allowed, off by default. The token goes into the Keychain and is sent as `Authorization: Bearer`. Only `127.0.0.1` and `[::1]` endpoints are accepted, and a link cannot take the name of a catalog server or Bastion's own, or replace a server that runs a package.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "Yahoo Finance's writes switch covers portfolios and trades.",
            body: [
              "From 0.5.0 the server opens create, add, remove and delete to manual portfolios and adds tools to record, edit and delete trades, all behind the same switch, which the profile editor described as covering watchlists only. Removing a position or a portfolio that holds lots or transactions is refused unless the call asks for that history to go with it.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_26_0: Release = Release(
    version: "1.26.0",
    date: "2026-10-06",
    sections: [
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Yahoo Finance's watchlist tools are writes.",
            body: [
              "The server's newer versions add four tools that change a signed-in account's watchlists (create, add, remove and delete), and the catalog still described it as having nothing it could change: on 0.3.0 they ran as reads, without confirmation, and from 0.4.0 no profile could turn them on. They now follow the profile's writes switch, and need the cookie of a signed-in finance.yahoo.com tab; the crumb is derived from that cookie, so it rarely needs setting.",
            ]),
          Entry(
            ordinal: 1,
            headline: "The menu bar panel closes when it opens a window.",
            body: [
              "Settings, Logs, About, What's New, a server's row and the licence notice's key button could each leave the panel open over the window they had just opened, since opening one of the app's own windows never closes it. The server rows also highlight under the pointer, where they used to give no sign of being clickable until the click.",
            ]),
        ]),
    ])

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

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
