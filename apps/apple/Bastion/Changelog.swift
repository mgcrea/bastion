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
  static let releases: [Release] = [v1_32_0, v1_31_0, v1_30_0, v1_29_0, v1_28_0]

  // swift-format-ignore
  private static let v1_32_0: Release = Release(
    version: "1.32.0",
    date: "2026-10-28",
    sections: [
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Loading tools on demand is on by default, and Bastion decides which servers it applies to.",
            body: [
              "The per-server Default/On/Off picker is gone. Every server goes through the size check that already existed: a listing is replaced by Bastion's search, describe and call tools only when it has at least twice as many tools as they are, and costs at least twice as many tokens. So App Store Connect's listing is replaced and Context7's two tools are not, and a server that grows past the bar starts being fronted with nobody touching anything. The one switch left is in Settings › General.",
              "On a Mac where that switch was never touched, it is now on. Claude Code and Claude Desktop are unaffected, because they load tool schemas on demand themselves and Bastion never fronts them. Cursor, VS Code, Codex and LM Studio are, and the trade is the one the switch has always carried: their per-tool approval rules then see `bastion_call_tool` for a server's reads and `bastion_call_write_tool` for its writes, rather than each tool. Turn the switch off in Settings › General, or set a client to \"defers schemas\" in its own pane, to keep the full listings there. Anybody who had turned the switch off keeps it off.",
              "A choice made per server before this release is dropped, on or off. Bastion's own MCP server follows: `list_servers`, `get_server` and `list_profiles` no longer report `lazy_tools`, `status` reports the switch instead, and `upsert_profile` refuses a `lazy_tools` argument and says where the switch is rather than ignoring it.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "A failing server's red mark lines up with the green dots.",
            body: [
              "It sat a few points off the dots in the sidebar rows around it. Every status mark there now centres on one column.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_31_0: Release = Release(
    version: "1.31.0",
    date: "2026-10-25",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A server on this Mac looks like one.",
            body: [
              "A remote server at `127.0.0.1` or `::1` shows a computer in the sidebar, labelled \"Endpoint on this Mac\", rather than the cloud of a server somebody else runs.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: "A remote server whose calls fail no longer shows green.",
            body: [
              "Bastion counted a remote server as running for as long as it held a session with it, so a profile whose refresh token the vendor had revoked read green while every call through it failed. A failed exchange now turns the server's sidebar row, its profile, its Activity row and its dot in the menu bar red, with the reason, and the next call that is answered turns them back.",
            ]),
        ]),
      Section(
        name: "Security",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "The embedded Node runtime is 24.22.1",
            body: [
              ", up from 24.20.0, for Node's October 2026 security release: an out-of-bounds write in the Brotli decoder, three ways around TLS hostname and IP checks, and HTTP keep-alive response confusion, with undici, OpenSSL and the CA bundle updated. Every server Bastion downloads runs on this runtime, holding its profile's credentials. npm moves to 11.19.1.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_30_0: Release = Release(
    version: "1.30.0",
    date: "2026-10-16",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A right-click menu on each server in the sidebar",
            body: [
              ", with Edit…, Enable or Disable, and Remove Server…. Each item appears only where the server's own page offers it: Edit… on a server you added yourself, Remove Server… on anything but Bastion's own server. Removing still asks first, and says what goes with the server: its profiles, their credentials in the Keychain and its downloaded code.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_29_0: Release = Release(
    version: "1.29.0",
    date: "2026-10-15",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Rename a profile.",
            body: [
              "Rename… on a profile's row, and `rename_profile` on Bastion's own server, give a profile a new name. Its credentials and OAuth sign-in, the state its server keeps (a child's own login, its callback port), its workspaces and its usage history move with it, and every client Bastion configured is rewired to the new endpoint. The client's tool names change with the entry, so permission rules naming the old ones stop matching. The audit log keeps the old name, since its lines are hash-chained.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Shopify can write, behind the writes switch.",
            body: [
              "From mcp-shopify 0.7.0, a profile with writes on can set and delete metafields, update a product's and its variants' content, and adjust or set inventory. None of these deletes a product. `SHOPIFY_ALLOW_RAW_MUTATIONS` adds `shopify_graphql_mutation`, which runs any mutation the app's access scopes allow, deletes and refunds included. The switch decides which tools the server offers, not what the credential can do, so grant `write_*` scopes only to an app whose profile is meant to write. A server still on 0.6.0 stays read-only.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Shopify Dev is in the catalog",
            body: [
              ": the server from Shopify's AI Toolkit that searches shopify.dev and validates generated GraphQL, Liquid and UI code, with no credential. It reports usage to Shopify by default, and its profile offers `OPT_OUT_INSTRUMENTATION` to stop that.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_28_0: Release = Release(
    version: "1.28.0",
    date: "2026-10-13",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Only Bastion.",
            body: [
              "Each Claude Code client's pane has a switch that writes `disableClaudeAiConnectors` and an `allowedMcpServers` list into that profile's `settings.json`: Bastion's endpoint, plus every server already in its `.claude.json` that Bastion did not write. Servers added by plugins (the ones synced from a claude.ai account included), claude.ai connectors and a repository's `.mcp.json` are then filtered out. Only those two keys change, the rest of the file is kept byte for byte, a backup is written first, and a file with comments or a trailing comma is left alone. Entries you add to the list by hand stay. The list is refreshed when a server is added or the port moves, and lifted when the client is unwired; turning it off removes only what Bastion added, and asks before discarding a hand edit. It is hygiene rather than a boundary: a project's own settings can widen the list. `set_client_lockdown` on Bastion's own server does the same, and `list_clients` reports each Claude Code row's state.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 1,
            headline: nil,
            body: [
              "\"Measured …\" in a remote server's pane dates from when its context figure last changed, as it already did for a server Bastion runs, rather than from the last call.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "A first call can no longer outrun turning writes off.",
            body: [
              "A call racing the edit could start the server from the old profile and keep writes on for up to 30 minutes. Turning a profile's capture off, or a server's _Load tools on demand_, likewise reaches a server that is already running instead of waiting for its idle stop, so a running server no longer goes on logging arguments and results.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Editing a custom server keeps what the form does not show.",
            body: [
              "A server handed over by `bastion://add-server` lost its list of write tools, so those were forwarded with writes off; a server set to load its tools on demand went back to Default; and the edit reached a running server only after a relaunch. The _Write gate_ field is now offered only for a server Bastion runs, since a remote one has nowhere to put it.",
            ]),
          Entry(
            ordinal: 4,
            headline: "Remote servers recover from an expired session or token on every request.",
            body: [
              "After an upstream session expired, every read on a writes-off profile was refused with \"writes are off\", and a token revoked before its expiry broke the profile even with a refresh token held. A refresh token is now sent only to the authorization server that issued it, a token whose `expires_in` arrives as a string is refreshed before it expires, a lowercase `bearer` challenge is read, and an OAuth sign-in no longer times out behind a browser's idle speculative connection.",
            ]),
          Entry(
            ordinal: 5,
            headline: "Client wiring.",
            body: [
              "`~/.claude.json` is no longer reformatted, and its backup replaced, on every launch. A workspace-scoped profile's rewire keeps a server you disabled disabled and keeps your timeout, as the global block already did. A repository reached through a symlink is filed under its real path, where Claude Code reads it. Two workspace-scoped profiles that would share a key in a folder are refused rather than taking turns. A string with a CRLF or DEL no longer writes an invalid Codex `config.toml`.",
            ]),
          Entry(
            ordinal: 6,
            headline: "Moving between two servers or two clients builds a fresh pane.",
            body: [
              "A profile editor open on one server could survive a menu bar reveal of another and save its fields there.",
            ]),
          Entry(
            ordinal: 7,
            headline: "A crashed server is no longer counted as running.",
            body: [
              "Opening its profile editor restarted it, `list_servers` reported it running, and a failed handshake could hold off an update's relaunch.",
            ]),
          Entry(
            ordinal: 8,
            headline: nil,
            body: [
              "`list_profiles` no longer returns a value typed before its variable became secret.",
            ]),
          Entry(
            ordinal: 9,
            headline: nil,
            body: [
              "A gateway port outside 0–65535 in Settings is read as unset; it crashed every launch.",
            ]),
          Entry(
            ordinal: 10,
            headline: nil,
            body: [
              "A latency percentile is never reported above the maximum beside it.",
            ]),
          Entry(
            ordinal: 11,
            headline: nil,
            body: [
              "Stats and a server's pane say three Bastion tools, or four where a server's writes can be told apart, rather than always four.",
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
