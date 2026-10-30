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
  static let releases: [Release] = [v1_33_0, v1_32_0, v1_31_0, v1_30_0, v1_29_0]

  // swift-format-ignore
  private static let v1_33_0: Release = Release(
    version: "1.33.0",
    date: "2026-10-30",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "Yahoo Finance takes its cookie from a file.",
            body: [
              "From 0.7.0 the server reads `YAHOO_FINANCE_COOKIE_IMPORT_FILE`, the path of a file holding the same cookie header `YAHOO_FINANCE_COOKIE` takes, at startup. Set one or the other, not both. A missing or empty file stops the server with an error naming the path. Cupertino's Safari server can write that file from a signed-in tab. From 0.6.0 the session Yahoo renews is kept in that profile's own folder, so it survives a restart.",
            ]),
        ]),
    ])

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

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
