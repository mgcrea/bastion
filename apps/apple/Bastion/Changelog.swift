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
  static let releases: [Release] = [v1_39_0, v1_38_0, v1_37_0, v1_36_1, v1_36_0]

  // swift-format-ignore
  private static let v1_39_0: Release = Release(
    version: "1.39.0",
    date: "2026-11-18",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "YouTube is in the catalog.",
            body: [
              "Its profiles sign in with Google, and the channel chosen at consent is the one every call acts as. Uploads run as resumable background jobs and default to private, and metadata edits merge rather than overwrite. With writes off, uploading, editing, deleting, thumbnails and playlist changes are hidden, and the sign-in asks Google for read-only access.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Hugging Face is in the catalog",
            body: [
              ", as Hugging Face's own remote server. Its profiles sign in with Hugging Face or take an access token, and search and read models, datasets, Spaces, papers and docs on the Hub. With writes off, the seven tools that create repos, write files, or run Spaces, Jobs and sandboxes (the last two billed to the account) are hidden. Which tools it lists is set per account at huggingface.co/settings/mcp.",
            ]),
          Entry(
            ordinal: 2,
            headline: "Google Search Console is in the catalog.",
            body: [
              "Its profiles sign in with Google, and read clicks, impressions, CTR and position by query, page, country or date, URL Inspection and sitemaps for the properties that account can see. With writes off, submitting and deleting sitemaps is hidden, and the sign-in asks for read-only access; turning writes on later needs a fresh sign-in.",
            ]),
          Entry(
            ordinal: 3,
            headline: "Bing Webmaster Tools is in the catalog.",
            body: [
              "A profile is your Bing Webmaster API key, which reaches every site you have verified there. With writes off, URL and sitemap submission, sitemap removal and fetch are hidden. URL submission spends the site's daily quota.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 4,
            headline: "Updates come through Sparkle 2.10.1",
            body: [
              ", up from 2.9.6. A download whose server sends no size now shows its progress instead of an indeterminate bar, and when Bastion sits in a folder whose name has accented characters, an update no longer installs before the app has quit.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 5,
            headline: "UniFi Network's write switch says what it turns on",
            body: [
              ": device restarts, PoE power-cycles, guest access, vouchers, client blocks and raw requests. It used to list WLANs, port profiles, firewall rules and device adoption, which the server has no dedicated tools for.",
            ]),
        ]),
      Section(
        name: "Security",
        lead: [],
        entries: [
          Entry(
            ordinal: 6,
            headline: "The embedded Node runtime is 24.22.3",
            body: [
              ", up from 24.22.1, for Node's November 2026 security release: a TLS server crash reachable from the network, several http2 stream and memory bugs, and TLS session resumption or renegotiation changing the server name, with undici, llhttp, brotli and SQLite updated. Every server Bastion downloads runs on this runtime, holding its profile's credentials. npm stays at 11.19.1.",
            ]),
        ]),
    ])

  // swift-format-ignore
  private static let v1_38_0: Release = Release(
    version: "1.38.0",
    date: "2026-11-10",
    sections: [
      Section(
        name: "Added",
        lead: [],
        entries: [
          Entry(
            ordinal: 0,
            headline: "A remote server you add yourself can sign in with OAuth.",
            body: [
              "Add Server's remote form has a Sign in with OAuth switch, which turns itself on when the address you type advertises an OAuth sign-in, and never overrides a choice you made. Each profile of that server then gets a Sign in button, as a catalog server's does, and Bastion keeps its tokens in the Keychain. A secret you list without marking it required is offered as the alternative to signing in. Agents can do the same with `add_custom_server` and `oauth: true`.",
            ]),
          Entry(
            ordinal: 1,
            headline: "Product Hunt is in the catalog.",
            body: [
              "Its profiles sign in with Product Hunt, which takes no API key in its place. With writes off, the five tools that start, submit or change a launch, or send feedback, are hidden. Product Hunt answers its discovery tools (leaderboard, search, product profiles) without an account, but in Bastion they still wait for the profile to sign in.",
            ]),
        ]),
      Section(
        name: "Changed",
        lead: [],
        entries: [
          Entry(
            ordinal: 2,
            headline: "A server you add no longer needs a variable.",
            body: [
              "Add Server and `add_custom_server` refused a server with none, so a server that takes no credential, or signs in instead, had to carry a placeholder. With Sync with iCloud on, update every Mac: an earlier version sets such a server aside, and drops the sign-in switch from a server it saves again.",
            ]),
        ]),
      Section(
        name: "Fixed",
        lead: [],
        entries: [
          Entry(
            ordinal: 3,
            headline: "A server that wants a sign-in says so.",
            body: [
              "When a remote server refuses a profile that never signed in and its answer points at an OAuth sign-in, the error now says to sign the profile in, or, for a server you added without the switch, to turn on Sign in with OAuth. It used to read like a key that had stopped working.",
            ]),
        ]),
    ])

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

  /// Work that is written down but not shipped.
  ///
  /// `nil` in any tagged build: CI asserts the CHANGELOG's head section is the
  /// tag's version, so there is no `[Unreleased]` left to emit by then. The
  /// pane shows it in debug builds only, where it is true of what is running.
  static let unreleased: Release? = nil
  // </generated:changelog>
}
