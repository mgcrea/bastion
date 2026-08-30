import Foundation

/// The definition of one MCP server: what it is, what it reads, and which npm
/// package it comes out of.
///
/// **This is no longer a closed table, and the distinction matters.** v1 fixed
/// the whole list at compile time and called that a security property. It was
/// two properties wearing one coat, and only one of them was load-bearing:
///
/// - **Kept.** A caller selects a server by *name*, never by path or command
///   line. A gateway that spawned whatever binary it was handed would be a way
///   for any local process — or any web page that got past the Origin check —
///   to run arbitrary code with the user's credentials attached. That is still
///   true: `ServerStore` resolves a name to a definition the *user* installed,
///   and nothing arriving over the wire can name a package, a path or an argv.
/// - **Dropped.** That the list was fixed at build time. It bought no safety
///   the rule above does not already buy — the person choosing was always the
///   user — and it cost Bastion the ability to run anything mgcrea had not
///   written.
///
/// So there are two lists now, and they are not the same thing:
///
/// - `ServerCatalog.all` — the catalog, generated from `servers.json` by
///   `make servers`. A starting point. Nothing here is installed until someone
///   asks for it.
/// - `ServerStore.shared.servers` — what this install actually runs. Held in
///   Application Support, edited by the user, and the only list the gateway,
///   the supervisor and the profile store ever consult.
///
/// A definition reaching the store from the catalog is re-resolved by id on
/// every load rather than copied, so a catalog fix — a new variable, a dialect
/// that finally flipped — reaches an install that was set up months ago. A
/// custom definition has no catalog to re-resolve against and is stored whole.
nonisolated struct BastionServer: Identifiable, Hashable {
  /// The wire name. It is a URL path segment (`/s/<profile>/<server>`), a
  /// profile directory name and a `bastion-bridge --server=` argument, which is
  /// why the manifest constrains it to kebab-case and nothing else.
  let id: String
  let displayName: String
  /// One line, shown in the menu and on the server's row in the main window.
  let summary: String
  /// The npm package to install. Catalog entries are always
  /// `@mgcrea/mcp-<id>` and the generator enforces that; a custom entry names
  /// somebody else's package and is held only to npm's own naming rules.
  let npmName: String
  /// The `bin` entry to run out of that package. `<id>-mcp` for everything in
  /// the catalog, and looked up in the installed `package.json` rather than
  /// assumed — a package is free to put its entry point anywhere.
  let binName: String
  /// Whether the package is actually published.
  ///
  /// Not decoration now that installs happen on demand: `.local` is the
  /// difference between an entry a stranger can install and one that resolves
  /// only against a checkout named by `dev.json`. Four of the nine catalog
  /// entries are `.local` today.
  let distribution: Distribution
  /// Directory name in the mgcrea-ai checkout, for `.local` and for DEBUG
  /// overrides of `.npm`.
  let localPath: String
  let docsURL: URL?
  /// The dialect the server itself speaks.
  ///
  /// Every entry is legacy today, and that is the whole reason `Dialect.swift`
  /// exists: Bastion fronts them with the 2026-07-28 stateless protocol and
  /// translates. The field is not decoration — when a server is upgraded,
  /// flipping it here is what turns the translation off for that one server,
  /// and the day the last entry flips is the day the layer can go.
  ///
  /// A custom entry defaults to the newest legacy revision, because that is
  /// what an SDK built this year negotiates and because guessing *modern* for a
  /// server that turns out to be legacy breaks it outright, while guessing the
  /// other way costs a translation layer that was already written.
  let dialect: Dialect
  /// The env var that turns destructive tools on, or `nil` when the server has
  /// no write path at all.
  ///
  /// Set **per profile**, never globally. This is Bastion's answer to the third
  /// reason `ServerHost.swift` gives for one process per connection: write
  /// permissions do not have to be shared just because a process is.
  let writeGate: String?
  /// Env vars that would turn writes on **independently of `writeGate`**.
  /// Bastion always forces these to `"0"`.
  ///
  /// Found by migrating a real config rather than by design. mcp-tastytrade
  /// computes `allowTrading` as `ALLOW_TRADING || DANGEROUSLY_ALLOW_TRADING`,
  /// so a profile able to set the second would have live order entry on while
  /// its own toggle, and the Activity window, both showed the gate as off.
  ///
  /// Never settable — only neutralised. That is why these are not in `env`, and
  /// the generator fails if one appears in both.
  let gateBypass: [String]
  /// Credential shapes the server accepts, when it accepts more than one. A
  /// profile fills exactly one; empty means there is only one shape.
  let authModes: [AuthMode]
  /// Env vars naming **on-disk state**.
  ///
  /// These are the reason a naive singleton is wrong. Two profiles of
  /// `mcp-reddit` sharing one token file are two identities sharing one login.
  /// Bastion redirects each of these into the profile's own directory.
  let stateEnv: [String]
  /// Env vars naming a **loopback OAuth callback URL**. Two profiles collide
  /// on the default port, so Bastion assigns one per profile and rewrites the
  /// URL — and then has to say so, because the upstream app registration has to
  /// match and only the user can change that.
  ///
  /// Deliberately not the servers' own `*_HTTP_PORT` variables: those select a
  /// standalone HTTP transport Bastion never uses. Bastion *is* the HTTP front;
  /// it speaks stdio to the child.
  let callbackEnv: [String]
  let env: [EnvVar]
  /// Where this definition came from. Last, and defaulted, so the generated
  /// catalog below does not have to say `.catalog` nine times.
  var origin: Origin = .catalog

  /// Which of the two lists a definition was born in.
  ///
  /// Only the UI and `ServerStore`'s persistence care. Everything downstream —
  /// the supervisor, the profile store, the environment builder — treats the
  /// two identically on purpose: a custom server is not a second-class server,
  /// it is a server whose definition the user typed.
  enum Origin: Hashable {
    /// Generated from `servers.json`. Re-resolved by id on every load.
    case catalog
    /// Typed by the user. Stored whole, because nothing else remembers it.
    case custom
  }

  enum Distribution: Hashable {
    /// Published; installable from the registry.
    case npm
    /// A private checkout. Named here rather than hidden so the difference is
    /// visible in the UI: a server nobody else can install is a different
    /// promise from one they can.
    case local
  }

  /// An MCP protocol revision.
  ///
  /// The 2026-07-28 spec divides these into two eras, and the distinction is
  /// the whole reason `Dialect.swift` exists:
  ///
  /// - **legacy** (`2025-11-25` and earlier) opens with an `initialize`
  ///   handshake and carries version, identity and capabilities in the session
  ///   it establishes.
  /// - **modern** (`2026-07-28` and later) has no handshake at all. Every
  ///   request declares its own version, client identity and capabilities in
  ///   `_meta`, so any request can be served by any instance.
  ///
  /// Bastion is what the spec calls a **dual-era server**: it selects its
  /// behaviour from how the client opens, and fronts legacy children either
  /// way.
  enum Dialect: String, Hashable, Comparable, CaseIterable {
    case v2024_11_05 = "2024-11-05"
    case v2025_03_26 = "2025-03-26"
    case v2025_06_18 = "2025-06-18"
    case v2025_11_25 = "2025-11-25"
    case v2026_07_28 = "2026-07-28"

    /// Modern versions convey version, identity and capabilities as
    /// per-request metadata; legacy ones establish a session.
    var isModern: Bool { self >= .v2026_07_28 }

    /// Date-ordered, which is what the version strings are for.
    static func < (a: Dialect, b: Dialect) -> Bool { a.rawValue < b.rawValue }
  }

  struct AuthMode: Identifiable, Hashable {
    let id: String
    let displayName: String
    let env: [String]
  }

  struct EnvVar: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isRequired: Bool
    /// Kept in the Keychain, never written to a client config file, never
    /// echoed into the Activity window or a log line.
    let isSecret: Bool
    let summary: String
  }
}

/// The list Bastion ships with, and installs nothing from.
///
/// Generated from `servers.json` by `make servers` — edit the manifest, not the
/// array, and CI fails on any drift. What an install actually runs is
/// `ServerStore`, which is seeded from here and then belongs to the user.
nonisolated enum ServerCatalog {
  // <generated:servers> generated from servers.json by `make servers` — do not edit by hand
  static let all: [BastionServer] = [
    // The inline key is why `secret` is a manifest field rather than a UI
    // guess. `.mcp.json` in mcp-appstore-connect currently holds this key in
    // plaintext; migrating it into a Bastion profile is the first dogfood
    // task in the build order.
    BastionServer(
      id: "appstore-connect",
      displayName: "App Store Connect",
      summary: "App Store Connect API: apps, versions, builds, TestFlight, listings, analytics, sales.",
      npmName: "@mgcrea/mcp-appstore-connect",
      binName: "appstore-connect-mcp",
      distribution: .npm,
      localPath: "mcp-appstore-connect",
      docsURL: URL(string: "https://github.com/mgcrea/mcp-appstore-connect"),
      dialect: .v2025_11_25,
      writeGate: "APP_STORE_CONNECT_ALLOW_WRITES",
      gateBypass: [],
      authModes: [
        .init(
          id: "inline-key",
          displayName: "Inline private key",
          env: ["APP_STORE_CONNECT_P8"]),
        .init(
          id: "key-file",
          displayName: "Private key file",
          env: ["APP_STORE_CONNECT_P8_PATH"]),
      ],
      stateEnv: ["APP_STORE_CONNECT_CONFIG"],
      callbackEnv: [],
      env: [
        .init(
          name: "APP_STORE_CONNECT_KEY_ID",
          isRequired: true,
          isSecret: false,
          summary: "The 10-character API key id."),
        .init(
          name: "APP_STORE_CONNECT_ISSUER_ID",
          isRequired: true,
          isSecret: false,
          summary: "Issuer UUID from the Keys page."),
        .init(
          name: "APP_STORE_CONNECT_P8",
          isRequired: false,
          isSecret: true,
          summary: "The .p8 private key, inline PEM. Preferred: Bastion keeps it in the Keychain and never writes it to disk."),
        .init(
          name: "APP_STORE_CONNECT_P8_PATH",
          isRequired: false,
          isSecret: false,
          summary: "Path to a .p8 file on disk. The legacy shape — it leaves the key readable outside the Keychain."),
        .init(
          name: "APP_STORE_CONNECT_VENDOR_NUMBER",
          isRequired: false,
          isSecret: false,
          summary: "Vendor number, needed only for sales and finance reports."),
        .init(
          name: "APP_STORE_CONNECT_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion points this at the profile's own directory."),
        .init(
          name: "APP_STORE_CONNECT_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables the mutating tools: version metadata, screenshots, submissions, pricing."),
      ]),
    // The clearest case for stateEnv and portEnv. This server logs a user in
    // over a local callback and keeps the refresh token in a file — both of
    // which are per-identity, so both must be per-profile.
    BastionServer(
      id: "reddit",
      displayName: "Reddit",
      summary: "Reddit API: subreddits, posts, comments, search, and the user's own history.",
      npmName: "@mgcrea/mcp-reddit",
      binName: "reddit-mcp",
      distribution: .local,
      localPath: "mcp-reddit",
      docsURL: URL(string: "https://github.com/mgcrea/mcp-reddit"),
      dialect: .v2025_11_25,
      writeGate: "REDDIT_ALLOW_WRITES",
      gateBypass: [],
      authModes: [],
      stateEnv: ["REDDIT_TOKEN_PATH"],
      callbackEnv: ["REDDIT_REDIRECT_URI"],
      env: [
        .init(
          name: "REDDIT_CLIENT_ID",
          isRequired: false,
          isSecret: false,
          summary: "App client id. Anonymous app-only reads work without it; anything user-scoped does not."),
        .init(
          name: "REDDIT_CLIENT_SECRET",
          isRequired: false,
          isSecret: true,
          summary: "App client secret. Empty for an installed app, set for a web or script app."),
        .init(
          name: "REDDIT_USER_AGENT",
          isRequired: false,
          isSecret: false,
          summary: "platform:app-id:version (by /u/username). Reddit throttles generic agents regardless of rate limit."),
        .init(
          name: "REDDIT_REDIRECT_URI",
          isRequired: false,
          isSecret: false,
          summary: "Loopback OAuth callback. Per-profile, or two profiles race for one port — and the URL must be registered with the Reddit app."),
        .init(
          name: "REDDIT_TOKEN_PATH",
          isRequired: false,
          isSecret: false,
          summary: "Where the refresh token is stored. Per-profile, or two profiles share one login."),
        .init(
          name: "REDDIT_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables posting, commenting and voting."),
      ]),
    // Two write gates, not one: X_API_ALLOW_WRITES governs posting and
    // X_ADS_ALLOW_WRITES governs spending money. The manifest names the
    // first as the gate because that is the one the Activity window badges;
    // the second is an ordinary env entry that a profile sets deliberately.
    //
    // X_API_MONTHLY_BUDGET_USD is here for the same reason a write gate is:
    // on this API a read has a price, so an unbounded profile is a bill.
    BastionServer(
      id: "x-api",
      displayName: "X",
      summary: "X (Twitter) API v2: posts, threads, timelines, search, bookmarks, and the Ads API.",
      npmName: "@mgcrea/mcp-x-api",
      binName: "x-api-mcp",
      distribution: .local,
      localPath: "mcp-x-api",
      docsURL: URL(string: "https://github.com/mgcrea/mcp-x-api"),
      dialect: .v2025_11_25,
      writeGate: "X_API_ALLOW_WRITES",
      gateBypass: [],
      authModes: [
        .init(
          id: "bearer",
          displayName: "App-only bearer token",
          env: ["X_API_BEARER_TOKEN"]),
        .init(
          id: "oauth2",
          displayName: "OAuth2 user context",
          env: ["X_API_CLIENT_ID"]),
      ],
      stateEnv: ["X_API_CONFIG", "X_API_TOKEN_FILE"],
      callbackEnv: ["X_API_REDIRECT_URI"],
      env: [
        .init(
          name: "X_API_BEARER_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "App-only bearer token. Reads only; the Ads API rejects it outright."),
        .init(
          name: "X_API_CLIENT_ID",
          isRequired: false,
          isSecret: false,
          summary: "OAuth2 client id. Required for a user context, and therefore for writes and for Ads."),
        .init(
          name: "X_API_CLIENT_SECRET",
          isRequired: false,
          isSecret: true,
          summary: "OAuth2 client secret, for a confidential client."),
        .init(
          name: "X_API_REDIRECT_URI",
          isRequired: false,
          isSecret: false,
          summary: "Loopback OAuth callback. Per-profile, or two profiles race for one port — and the URL must be registered with the X app."),
        .init(
          name: "X_API_TOKEN_FILE",
          isRequired: false,
          isSecret: false,
          summary: "Where the user token is stored. Per-profile, or two accounts share one login."),
        .init(
          name: "X_API_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion points this at the profile's own directory."),
        .init(
          name: "X_API_MONTHLY_BUDGET_USD",
          isRequired: false,
          isSecret: false,
          summary: "Spend ceiling. X bills per read, so this is a real safety control, not a preference."),
        .init(
          name: "X_API_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables posting through the API rather than returning an intent URL."),
        .init(
          name: "X_ADS_ENABLED",
          isRequired: false,
          isSecret: false,
          summary: "Registers the Ads API tools. Needs a user context."),
        .init(
          name: "X_ADS_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables campaign mutations. No effect without X_ADS_ENABLED."),
      ]),
    // Two auth shapes that are not interchangeable, which is why they are auth
    // modes rather than a pile of optional variables. A console API key is
    // refused by the private API this server reads history from, so a LAN-only
    // deployment genuinely needs a username and password; a cloud key reaches
    // the same API through api.ui.com and needs no local account at all.
    //
    // Three state variables, all per-profile. The session file is an identity,
    // and the snapshot directory is camera footage — sharing either between two
    // profiles is the leak this app exists to prevent.
    BastionServer(
      id: "unifi-protect",
      displayName: "UniFi Protect",
      summary: "UniFi Protect: cameras, event history, recordings, snapshots and NVR status.",
      npmName: "@mgcrea/mcp-unifi-protect",
      binName: "unifi-protect-mcp",
      distribution: .npm,
      localPath: "mcp-unifi-protect",
      docsURL: URL(string: "https://github.com/mgcrea/mcp-unifi-protect"),
      dialect: .v2025_11_25,
      writeGate: "UNIFI_PROTECT_ALLOW_WRITES",
      gateBypass: [],
      authModes: [
        .init(
          id: "cloud",
          displayName: "Cloud API key",
          env: ["UNIFI_PROTECT_API_KEY", "UNIFI_PROTECT_CONSOLE_ID"]),
        .init(
          id: "local",
          displayName: "Local account",
          env: ["UNIFI_PROTECT_HOST", "UNIFI_PROTECT_USERNAME", "UNIFI_PROTECT_PASSWORD"]),
      ],
      stateEnv: ["UNIFI_PROTECT_CONFIG", "UNIFI_PROTECT_SESSION_FILE", "UNIFI_PROTECT_SNAPSHOT_DIR"],
      callbackEnv: [],
      env: [
        .init(
          name: "UNIFI_PROTECT_HOST",
          isRequired: false,
          isSecret: false,
          summary: "Console IP or hostname. https:// is assumed and a :port is preserved."),
        .init(
          name: "UNIFI_PROTECT_USERNAME",
          isRequired: false,
          isSecret: false,
          summary: "Console login. Use a Local-Access-Only account with View Only rights."),
        .init(
          name: "UNIFI_PROTECT_PASSWORD",
          isRequired: false,
          isSecret: true,
          summary: "That account's password."),
        .init(
          name: "UNIFI_PROTECT_API_KEY",
          isRequired: false,
          isSecret: true,
          summary: "unifi.ui.com API key. Selects cloud mode, which needs no local account."),
        .init(
          name: "UNIFI_PROTECT_CONSOLE_ID",
          isRequired: false,
          isSecret: false,
          summary: "Console id from api.ui.com/v1/hosts. Cloud mode only."),
        .init(
          name: "UNIFI_PROTECT_MODE",
          isRequired: false,
          isSecret: false,
          summary: "cloud or local. Inferred as cloud when a key and a console id are both set."),
        .init(
          name: "UNIFI_PROTECT_TOTP",
          isRequired: false,
          isSecret: true,
          summary: "2FA code. Expires in ~30s, so prefer the server's own login tool."),
        .init(
          name: "UNIFI_PROTECT_VERIFY_TLS",
          isRequired: false,
          isSecret: false,
          summary: "Verify the console certificate. Needs a hostname, not an IP."),
        .init(
          name: "UNIFI_PROTECT_SESSION_FILE",
          isRequired: false,
          isSecret: false,
          summary: "Cached session, mode 600. Per-profile, or two identities share one session."),
        .init(
          name: "UNIFI_PROTECT_SNAPSHOT_DIR",
          isRequired: false,
          isSecret: false,
          summary: "Where snapshots and exports are written. Per-profile, or one profile reads another's footage."),
        .init(
          name: "UNIFI_PROTECT_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion points this at the profile's own directory."),
        .init(
          name: "UNIFI_PROTECT_MAX_RETRIES",
          isRequired: false,
          isSecret: false,
          summary: "Retries on 401 / 429 / 5xx. Defaults to 3."),
        .init(
          name: "UNIFI_PROTECT_MAX_DOWNLOAD_BYTES",
          isRequired: false,
          isSecret: false,
          summary: "Refuse a download larger than this. Defaults to 200000000."),
        .init(
          name: "UNIFI_PROTECT_DEVICE_CACHE_TTL",
          isRequired: false,
          isSecret: false,
          summary: "Camera id-to-name cache lifetime in seconds. Defaults to 60."),
        .init(
          name: "UNIFI_PROTECT_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Registers the mutating tools: recording settings, PTZ, device configuration."),
      ]),
    // The write gate here reaches network configuration, so a profile with it
    // on can take a site off the air. Two profiles - one read-only for asking
    // questions, one gated for changes - is the shape this is built for.
    BastionServer(
      id: "unifi-network",
      displayName: "UniFi Network",
      summary: "UniFi Network API: sites, devices, clients, WLANs, port and firewall configuration.",
      npmName: "@mgcrea/mcp-unifi-network",
      binName: "unifi-network-mcp",
      distribution: .npm,
      localPath: "mcp-unifi-network",
      docsURL: URL(string: "https://github.com/mgcrea/mcp-unifi-network"),
      dialect: .v2025_11_25,
      writeGate: "UNIFI_ALLOW_WRITES",
      gateBypass: [],
      authModes: [
        .init(
          id: "console",
          displayName: "Console API key",
          env: ["UNIFI_HOST", "UNIFI_API_KEY"]),
        .init(
          id: "cloud",
          displayName: "Cloud API key",
          env: ["UNIFI_API_KEY", "UNIFI_CONSOLE_ID"]),
        .init(
          id: "legacy",
          displayName: "Local admin account",
          env: ["UNIFI_HOST", "UNIFI_USERNAME", "UNIFI_PASSWORD"]),
      ],
      stateEnv: ["UNIFI_CONFIG"],
      callbackEnv: [],
      env: [
        .init(
          name: "UNIFI_HOST",
          isRequired: false,
          isSecret: false,
          summary: "The console. A pasted browser URL is accepted and split."),
        .init(
          name: "UNIFI_API_KEY",
          isRequired: false,
          isSecret: true,
          summary: "Settings, Control Plane, Integrations, Create API Key."),
        .init(
          name: "UNIFI_CONSOLE_ID",
          isRequired: false,
          isSecret: false,
          summary: "Console id from unifi.ui.com. Cloud mode only."),
        .init(
          name: "UNIFI_MODE",
          isRequired: false,
          isSecret: false,
          summary: "unifios, cloud or classic. Inferred from what is set."),
        .init(
          name: "UNIFI_SITE",
          isRequired: false,
          isSecret: false,
          summary: "Default site: UUID, legacy name or display name."),
        .init(
          name: "UNIFI_USERNAME",
          isRequired: false,
          isSecret: false,
          summary: "Legacy tier fallback only. A local admin, not an SSO account."),
        .init(
          name: "UNIFI_PASSWORD",
          isRequired: false,
          isSecret: true,
          summary: "That admin's password."),
        .init(
          name: "UNIFI_INSECURE_TLS",
          isRequired: false,
          isSecret: false,
          summary: "Disable certificate verification, for this server only."),
        .init(
          name: "UNIFI_ENABLE_LEGACY",
          isRequired: false,
          isSecret: false,
          summary: "Registers the unifi_legacy_* tools."),
        .init(
          name: "UNIFI_APP_VERSION",
          isRequired: false,
          isSecret: false,
          summary: "Pin the controller version instead of probing it at startup."),
        .init(
          name: "UNIFI_PAGE_LIMIT",
          isRequired: false,
          isSecret: false,
          summary: "Page size. Defaults to 50."),
        .init(
          name: "UNIFI_MAX_PAGES",
          isRequired: false,
          isSecret: false,
          summary: "Pagination ceiling. Defaults to 20."),
        .init(
          name: "UNIFI_MAX_RETRIES",
          isRequired: false,
          isSecret: false,
          summary: "Retries on a transient failure. Defaults to 3."),
        .init(
          name: "UNIFI_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion points this at the profile's own directory."),
        .init(
          name: "UNIFI_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables the mutating tools: WLANs, port profiles, firewall rules, device adoption."),
      ]),
    // PLACEHOLDER. @mgcrea/mcp-stripe is not published and there is no checkout
    // for it yet, so installing this entry fails with 'not published'. It is in
    // the catalog because the catalog is a starting point rather than a promise
    // about what is installed - which is exactly the distinction this file lost
    // when it was a closed list.
    //
    // Money moves through this one, so the gate is not a formality. Prefer a
    // restricted key scoped to reads and let the profile stay gated off.
    BastionServer(
      id: "stripe",
      displayName: "Stripe",
      summary: "Stripe API: customers, subscriptions, invoices, charges, payouts and balance.",
      npmName: "@mgcrea/mcp-stripe",
      binName: "stripe-mcp",
      distribution: .local,
      localPath: "mcp-stripe",
      docsURL: nil,
      dialect: .v2025_11_25,
      writeGate: "STRIPE_ALLOW_WRITES",
      gateBypass: [],
      authModes: [],
      stateEnv: ["STRIPE_CONFIG"],
      callbackEnv: [],
      env: [
        .init(
          name: "STRIPE_SECRET_KEY",
          isRequired: true,
          isSecret: true,
          summary: "Restricted or secret API key. A restricted key is the right one here: the write gate cannot take back a permission the key already grants."),
        .init(
          name: "STRIPE_ACCOUNT_ID",
          isRequired: false,
          isSecret: false,
          summary: "Connected account to act on behalf of, sent as Stripe-Account."),
        .init(
          name: "STRIPE_API_VERSION",
          isRequired: false,
          isSecret: false,
          summary: "Pin the API version instead of using the account default."),
        .init(
          name: "STRIPE_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion points this at the profile's own directory."),
        .init(
          name: "STRIPE_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables the mutating tools: refunds, subscription changes, invoice actions."),
      ]),
    // No write gate because there is no write path: every tool is a read.
    // That is why the build order takes this one end-to-end first — a bug in
    // the supervisor or the dialect layer cannot cost anybody data here.
    BastionServer(
      id: "shopify",
      displayName: "Shopify",
      summary: "Shopify Admin GraphQL API: products, variants, collections, metafields, locations.",
      npmName: "@mgcrea/mcp-shopify",
      binName: "shopify-mcp",
      distribution: .npm,
      localPath: "mcp-shopify",
      docsURL: URL(string: "https://github.com/mgcrea/mcp-shopify"),
      dialect: .v2025_11_25,
      writeGate: nil,
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "SHOPIFY_STORE_DOMAIN",
          isRequired: true,
          isSecret: false,
          summary: "Store handle or *.myshopify.com domain. A bare handle is expanded."),
        .init(
          name: "SHOPIFY_CLIENT_ID",
          isRequired: true,
          isSecret: false,
          summary: "Custom app client id."),
        .init(
          name: "SHOPIFY_CLIENT_SECRET",
          isRequired: true,
          isSecret: true,
          summary: "Custom app client secret. Used as the Admin API access token."),
        .init(
          name: "SHOPIFY_API_VERSION",
          isRequired: false,
          isSecret: false,
          summary: "Admin API version, e.g. 2026-04. Defaults to the server's pinned version."),
      ]),
    // Three auth modes, inferred from what is set. The signature triplet is
    // the only one of the three where every part is a secret, which is
    // exactly the sort of detail a hand-written profile form gets wrong.
    BastionServer(
      id: "ovh-api",
      displayName: "OVHcloud",
      summary: "OVHcloud API, focused on Object Storage: containers, objects, policies, regions.",
      npmName: "@mgcrea/mcp-ovh-api",
      binName: "ovh-api-mcp",
      distribution: .npm,
      localPath: "mcp-ovh-api",
      docsURL: nil,
      dialect: .v2025_11_25,
      writeGate: "OVH_ALLOW_WRITES",
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "OAuth2 service account",
          env: ["OVH_CLIENT_ID", "OVH_CLIENT_SECRET"]),
        .init(
          id: "signature",
          displayName: "Application key triplet",
          env: ["OVH_APPLICATION_KEY", "OVH_APPLICATION_SECRET", "OVH_CONSUMER_KEY"]),
        .init(
          id: "accessToken",
          displayName: "Access token",
          env: ["OVH_ACCESS_TOKEN"]),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "OVH_ENDPOINT",
          isRequired: false,
          isSecret: false,
          summary: "Region endpoint: ovh-eu, ovh-ca, ovh-us. Defaults to ovh-eu."),
        .init(
          name: "OVH_CLIENT_ID",
          isRequired: false,
          isSecret: false,
          summary: "OAuth2 client id."),
        .init(
          name: "OVH_CLIENT_SECRET",
          isRequired: false,
          isSecret: true,
          summary: "OAuth2 client secret."),
        .init(
          name: "OVH_APPLICATION_KEY",
          isRequired: false,
          isSecret: false,
          summary: "Application key, from https://eu.api.ovh.com/createToken/."),
        .init(
          name: "OVH_APPLICATION_SECRET",
          isRequired: false,
          isSecret: true,
          summary: "Application secret."),
        .init(
          name: "OVH_CONSUMER_KEY",
          isRequired: false,
          isSecret: true,
          summary: "Consumer key, which carries the granted scopes."),
        .init(
          name: "OVH_ACCESS_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "A pre-minted access token."),
        .init(
          name: "OVH_CLOUD_PROJECT",
          isRequired: false,
          isSecret: false,
          summary: "Default public cloud project id, a 32-character hex string."),
        .init(
          name: "OVH_REGION",
          isRequired: false,
          isSecret: false,
          summary: "Default storage region, e.g. GRA, SBG, UK."),
        .init(
          name: "OVH_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables uploading, deleting and re-policying objects and containers."),
      ]),
    // The profile split is the whole point here: rgis and ivalis are two
    // realms on two servers with two admin identities, and a single global
    // instance could hold only one of them.
    BastionServer(
      id: "keycloak",
      displayName: "Keycloak",
      summary: "Keycloak Admin REST API: realms, clients, users, roles, sessions.",
      npmName: "@mgcrea/mcp-keycloak",
      binName: "keycloak-mcp",
      distribution: .local,
      localPath: "mcp-keycloak",
      docsURL: nil,
      dialect: .v2025_11_25,
      writeGate: "KEYCLOAK_ALLOW_WRITES",
      gateBypass: [],
      authModes: [
        .init(
          id: "client_credentials",
          displayName: "Client credentials",
          env: ["KEYCLOAK_CLIENT_SECRET"]),
        .init(
          id: "password",
          displayName: "Username and password",
          env: ["KEYCLOAK_USERNAME", "KEYCLOAK_PASSWORD"]),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "KEYCLOAK_URL",
          isRequired: true,
          isSecret: false,
          summary: "Base URL of the Keycloak server, e.g. https://sso.example.com."),
        .init(
          name: "KEYCLOAK_REALM",
          isRequired: false,
          isSecret: false,
          summary: "Realm to administer. Defaults to master."),
        .init(
          name: "KEYCLOAK_AUTH_REALM",
          isRequired: false,
          isSecret: false,
          summary: "Realm to authenticate against, when it differs from the one being administered."),
        .init(
          name: "KEYCLOAK_CLIENT_ID",
          isRequired: false,
          isSecret: false,
          summary: "Client id. Defaults to admin-cli."),
        .init(
          name: "KEYCLOAK_CLIENT_SECRET",
          isRequired: false,
          isSecret: true,
          summary: "Client secret. Selects the client_credentials grant."),
        .init(
          name: "KEYCLOAK_USERNAME",
          isRequired: false,
          isSecret: false,
          summary: "Admin username. Selects the password grant."),
        .init(
          name: "KEYCLOAK_PASSWORD",
          isRequired: false,
          isSecret: true,
          summary: "Admin password."),
        .init(
          name: "KEYCLOAK_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables creating and modifying realms, clients, users and roles."),
      ]),
  ]
  // </generated:servers>

  /// Lookup by wire name, for re-resolving an installed catalog entry against
  /// the version of the catalog this build ships.
  ///
  /// **Not** the gateway's lookup. That is `ServerStore.lookup(_:)`, and the
  /// difference is the whole point: resolving a request through *this* table
  /// would run a server the user never installed.
  static let byID: [String: BastionServer] = Dictionary(
    uniqueKeysWithValues: all.map { ($0.id, $0) })
}
