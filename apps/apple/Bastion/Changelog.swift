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
/// The list is capped — see `SHOWN` in `scripts/generate-changelog.mjs`
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
  static let releases: [Release] = [v1_37_0, v1_36_1, v1_36_0, v1_35_0, v1_34_0]

  // swift-format-ignore
  private static let v1_37_0: Release = Release(
    version: "1.37.0",
    date: "2026-11-07",
    sections: [
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Only Bastion follows servers added outside Bastion.",
            body: [
              "With the switch on, a server another app writes into the profile's `.claude.json` (Cupertino switching on a surface, `claude mcp add`) was refused by the allowlist until Bastion next launched or its own servers changed, and Claude Code left it out of `/mcp` without saying why. Bastion now watches that file and adds the server to the list about a second after it lands. Only a list that is missing a server it should allow is rewritten: one you edited by hand is left alone, as before, and a write that keeps failing is logged once rather than on every Claude Code session.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_36_1: Release = Release(
    version: "1.36.1",
    date: "2026-11-06",
    sections: [
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A sign-in the server no longer accepts is dropped, and the profile asks to be authorized again.",
            body: [
              "When a server's token endpoint refuses a refresh with `invalid_grant` (Cloudflare says \"Grant not found\", Stripe \"Invalid refresh token\"), the grant behind it is gone and no refresh can succeed. Bastion kept the dead tokens, so the profile went on reading as authorized, every request tried the same refresh again, and clients saw only the provider's wording. Now the tokens are discarded, the profile shows as needing authorization, and the error names it and says to authorize it again in Bastion. A sign-in completed while the refused request was in flight is kept. Any other refusal, such as a server that is briefly down, still leaves the tokens in place for the next try.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_36_0: Release = Release(
    version: "1.36.0",
    date: "2026-11-04",
    sections: [
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A custom server can no longer declare `PATH`, `HOME`, `NODE_*`, `NPM_CONFIG_*`, `DYLD_*` or `XDG_*`.",
            body: [
              "Each of them changes what code a server runs: `NODE_OPTIONS` loads code before the server's first line, and a `PATH` puts another `npm` in front of the bundled one. A custom entry could already name only a package or an endpoint, never a command line, and these were the same hole by another door. Saving a definition that lists one, or names one as its write gate, is refused with the variable's name. A custom server saved with one by an earlier version still starts without it, and the log says which it left out. Remote servers are unaffected: their variables are headers. `NODE_EXTRA_CA_CERTS`, for a company certificate authority, is the one most likely to be missed. Catalog servers are unaffected.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Credentials move to the data protection keychain on first launch.",
            body: [
              "Every profile credential, OAuth sign-in, gateway token, the audit signing key and the internal-host list move out of the login keychain, each one copied, read back and only then deleted. macOS may ask once per item. An item that cannot be read yet stays where it is and keeps working, and the next launch tries again. They no longer show in Keychain Access, and going back to 1.35.0 or earlier afterwards finds none, because they were moved, not copied. They also no longer follow Migration Assistant to a new Mac: they belong to this Mac until iCloud sync arrives, and on a new one they are entered again.",
            ]),
          Entry(
            ordinal: 2,
            headline: "The app carries four entitlements",
            body: [
              ", after shipping with none: its identity, its team, its keychain group and its iCloud key-value store, which the data protection keychain and sync need. `make audit` asserts the set is exactly those four, in the file and in the signed app.",
            ]),
        ]),
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "Sync with iCloud",
            body: [
              ", in Settings › General, off by default. Your servers and whether each is on, your profiles and their values, your workspaces and your skill sources and choices follow you to every Mac signed in to the same iCloud account. A value that names a file, a launch argument or a device on one Mac stays on that Mac. A server you added by hand on another Mac arrives waiting, and runs only once you allow it on this one; a catalog server arrives ready. Credentials are not synced yet: enter them on each Mac. A profile removed on one Mac is removed on the others, with its credentials there. If Bastion's data disappears from iCloud, or the iCloud account changes, sync pauses and asks rather than deleting anything.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Settings › General › Export to the Debug Build",
            body: [
              ", for working on Bastion itself. It writes the Debug build's import file with every profile, its credentials and the gateway tokens, after a click; `make dev-clone` can no longer read them from the data protection keychain.",
            ]),
          Entry(
            ordinal: 5,
            headline: "Variables whose value belongs to one Mac are marked as such",
            body: [
              "in the server docs: paths to a key file or a kubeconfig, launch arguments, `NPM_BIN`, and every per-profile state path. It is the list iCloud sync leaves out, so a path set on one Mac never chooses code on another.",
            ]),
          Entry(
            ordinal: 6,
            headline: "Loki is in the catalog",
            body: [
              ": LogQL log and metric queries merged across streams, labels, detected fields, volume, stats and patterns, with results shaped to fit a context window. Read-only: its push, delete and ruler endpoints are not wrapped.",
            ]),
          Entry(
            ordinal: 7,
            headline: "Apple Ads installs.",
            body: [
              "It was listed as not published; its package is now on npm, with a provenance attestation tying it to its source.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_35_0: Release = Release(
    version: "1.35.0",
    date: "2026-10-31",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Internal hosts, under Settings › General.",
            body: [
              "A remote server had to be on a public host, which also refused a company MCP server whose name resolves to `10.x` over a VPN. An entry is the exact host name plus the private networks it may resolve to, and every address it resolves to and every address the connection lands on must be inside them, over https. Look Up fills the networks with what the host resolves to today, the narrowest entry that works. Only 10/8, 172.16/12, 192.168/16 and fc00::/7 can be listed; loopback, link-local, `localhost`, `.local` and single-label names stay refused whatever the list says. An entry covers every port on the host.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Only you change that list.",
            body: [
              "No tool on Bastion's own server reads or writes it and no field of a server definition carries it, so an agent can add a server on a listed host but cannot list one. It lives in the Keychain rather than in a file another process could edit. Signing in follows a URL a server hands back onto an internal host only when that server's own address is listed, so a public server cannot point Bastion inward. A server on a listed host is tagged internal, in orange, in its pane's header.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Prometheus is in the catalog",
            body: [
              ": PromQL instant and range queries, metric and label discovery, alerts, rules, scrape health and cardinality, with results shaped to fit a context window. Basic auth or a bearer token for the proxy in front of it. Its admin tools (deleting series, cleaning tombstones, reloading the config) appear only with writes on.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Grafana is in the catalog",
            body: [
              ": dashboards and the data their panels show with the variables filled in, PromQL and LogQL through its datasources, alerts, rules, silences and annotations. With writes on it can save and delete dashboards, create annotations and create or expire silences; the destructive tools also ask for `confirm: true`.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Langfuse is in the catalog",
            body: [
              ": traces, sessions, observations, scores, metrics and prompts, built for Langfuse v4's events-only mode. One profile can read many projects, from a keys file or a map of keys. Every named tool is a read; `LANGFUSE_ALLOW_WRITES` lets its raw request tool write.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 5,
            headline: "A workspace's sidebar header counts the folders you picked",
            body: [
              ", not every folder below them that Claude Code applies it in, which under a parent folder ran to dozens. The full reach is in the header's tooltip, and a workspace that reaches none still says No folders found, in orange.",
            ]),
          Entry(
            ordinal: 6,
            headline: "A workspace's page says Applies in, not Written into",
            body: [
              ", and notes that the entries live in `~/.claude.json`, one per folder, with nothing written into the folders themselves.",
            ]),
          Entry(
            ordinal: 7,
            headline: "The URL field for a remote server",
            body: [
              "says a private address is let through when its host is listed under Internal hosts.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_34_0: Release = Release(
    version: "1.34.0",
    date: "2026-10-30",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Workspaces live in the sidebar.",
            body: [
              "Once a workspace exists, the server list has a section per workspace and an Everywhere section for the profiles every client gets. Drag a server between sections to move its profiles, or use Move to on its right-click menu to move one profile of a server that has several. A server split between sections shows in each, with its profile names beside it. Sections collapse, and stay collapsed.",
            ]),
          Entry(
            ordinal: 1,
            headline: "New workspace, under Add server.",
            body: [
              "It asks for a name and at least one folder, since a workspace that reaches no folder would take every profile dropped into it out of every client.",
            ]),
          Entry(
            ordinal: 2,
            headline: "A page per workspace",
            body: [
              "in the main window, with its folders, the folders Claude Code is given, its profiles and its skills. Rename and Delete are there and on the section header's menu.",
            ]),
          Entry(
            ordinal: 3,
            headline: "A Scope menu in the profile editor",
            body: [
              "puts a profile in one workspace, or in none.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 4,
            headline: "A workspace now reaches the plain folders between its folder and the repositories below it.",
            body: [
              "Claude Code applies a block outside git to that exact folder only, so a session started in, say, `~/Projects/rgis/rgis-ai` got none of the workspace's servers. It does now.",
            ]),
          Entry(
            ordinal: 5,
            headline: "A repository cloned under a workspace's folder gets its servers within seconds",
            body: [
              ", without pressing Rescan. Bastion watches the workspace folders and rewires when a repository appears or disappears below them.",
            ]),
          Entry(
            ordinal: 6,
            headline: "Settings → Workspaces is gone",
            body: [
              "; everything it held is on the workspace pages.",
            ]),
          Entry(
            ordinal: 7,
            headline: "A custom server at an address on this Mac is tagged local, in blue",
            body: [
              ", rather than custom, in its pane's header.",
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
