import Foundation

/// One MCP server Bastion is allowed to supervise.
///
/// This is a **closed table fixed at compile time**, and it carries the same
/// invariant as cupertino's `Surface`: a caller selects a server by *name*,
/// never by path or command line. A gateway that spawned whatever binary it was
/// handed would be a way for any local process — or any web page that got past
/// the Origin check — to run arbitrary code with the user's credentials
/// attached. v1 ships no catalog and no third-party code execution, and this
/// table is where that promise is actually kept.
///
/// **`ServerCatalog.all` below is generated from `servers.json`** by
/// `make servers`. Edit the manifest, not the array — CI regenerates and fails
/// on any drift.
struct BastionServer: Identifiable, Hashable {
  /// The wire name. It is a URL path segment (`/s/<profile>/<server>`), a
  /// profile directory name and a `bastion-bridge --server=` argument, which is
  /// why the manifest constrains it to kebab-case and nothing else.
  let id: String
  let displayName: String
  /// One line, shown in the menu and on the server's row in the main window.
  let summary: String
  /// npm package name. Always `@mgcrea/mcp-<id>`; carried explicitly so the
  /// file reads without a rule in the reader's head, and validated as derived.
  let npmName: String
  /// The executable inside the package. Always `<id>-mcp`, same reasoning.
  let binName: String
  /// Where the code comes from.
  let distribution: Distribution
  /// Directory name in the mgcrea-ai checkout, for `.local` and for DEBUG
  /// overrides of `.npm`.
  let localPath: String
  let docsURL: URL?
  /// The dialect the server itself speaks.
  ///
  /// Every entry is `.v2025_06_18` today, and that is the whole reason
  /// `Dialect.swift` exists: Bastion fronts them with the 2026-07-28 stateless
  /// protocol and translates. The field is not decoration — when a server is
  /// upgraded, flipping it here is what turns the translation off for that one
  /// server, and the day the last entry flips is the day the layer can go.
  let dialect: Dialect
  /// The env var that turns destructive tools on, or `nil` when the server has
  /// no write path at all.
  ///
  /// Set **per profile**, never globally. This is Bastion's answer to the third
  /// reason `ServerHost.swift` gives for one process per connection: write
  /// permissions do not have to be shared just because a process is.
  let writeGate: String?
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

  enum Distribution: Hashable {
    /// Published; installable from the registry.
    case npm
    /// A private checkout. Named here rather than hidden so the difference is
    /// visible in the UI: a server nobody else can install is a different
    /// promise from one they can.
    case local
  }

  enum Dialect: String, Hashable {
    case v2025_06_18 = "2025-06-18"
    case v2026_07_28 = "2026-07-28"
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

enum ServerCatalog {
  // <generated:servers> generated from servers.json by `make servers` — do not edit by hand
  static let all: [BastionServer] = [
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
      dialect: .v2025_06_18,
      writeGate: nil,
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
      dialect: .v2025_06_18,
      writeGate: "APP_STORE_CONNECT_ALLOW_WRITES",
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
      dialect: .v2025_06_18,
      writeGate: "KEYCLOAK_ALLOW_WRITES",
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
      dialect: .v2025_06_18,
      writeGate: "OVH_ALLOW_WRITES",
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
      dialect: .v2025_06_18,
      writeGate: "REDDIT_ALLOW_WRITES",
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
      dialect: .v2025_06_18,
      writeGate: "X_API_ALLOW_WRITES",
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
    // The reason write gates are per-profile rather than global. One
    // tastytrade/cert profile with trading on and one tastytrade/prod
    // profile with trading off is a sane setup; a single global switch
    // makes it unexpressible.
    BastionServer(
      id: "tastytrade",
      displayName: "TastyTrade",
      summary: "TastyTrade brokerage API: accounts, positions, balances, quotes, and order entry.",
      npmName: "@mgcrea/mcp-tastytrade",
      binName: "tastytrade-mcp",
      distribution: .local,
      localPath: "mcp-tastytrade",
      docsURL: nil,
      dialect: .v2025_06_18,
      writeGate: "TASTYTRADE_ALLOW_TRADING",
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "TASTYTRADE_CLIENT_SECRET",
          isRequired: true,
          isSecret: true,
          summary: "OAuth client secret."),
        .init(
          name: "TASTYTRADE_REFRESH_TOKEN",
          isRequired: true,
          isSecret: true,
          summary: "Long-lived refresh token. This is the credential that can move money."),
        .init(
          name: "TASTYTRADE_ENV",
          isRequired: false,
          isSecret: false,
          summary: "prod or cert. cert is the sandbox, and the right default for a first profile."),
        .init(
          name: "TASTYTRADE_SCOPE",
          isRequired: false,
          isSecret: false,
          summary: "OAuth scope. Defaults to `read trade`; narrow it to `read` for a read-only profile."),
        .init(
          name: "TASTYTRADE_ALLOW_TRADING",
          isRequired: false,
          isSecret: false,
          summary: "Enables order entry. The highest-consequence gate in the manifest."),
      ]),
    // Logs in through a real browser session and needs MFA, so a profile of
    // this server is not merely credentials — it is a live session with a
    // timeout. The supervisor's idle-stop policy has to account for that.
    //
    // The session cache is not a secret in the Keychain sense but it is
    // bearer-equivalent while it lasts, which is why it is stateEnv.
    BastionServer(
      id: "boursobank",
      displayName: "BoursoBank",
      summary: "BoursoBank customer API: accounts, transactions, statements, market data.",
      npmName: "@mgcrea/mcp-boursobank",
      binName: "boursobank-mcp",
      distribution: .local,
      localPath: "mcp-boursobank",
      docsURL: nil,
      dialect: .v2025_06_18,
      writeGate: "BOURSOBANK_ALLOW_TRADING",
      authModes: [],
      stateEnv: ["BOURSOBANK_SESSION_PATH", "BOURSOBANK_DOCUMENTS_DIR"],
      callbackEnv: [],
      env: [
        .init(
          name: "BOURSOBANK_CLIENT_NUMBER",
          isRequired: true,
          isSecret: false,
          summary: "Customer number used to log in."),
        .init(
          name: "BOURSOBANK_PASSWORD",
          isRequired: false,
          isSecret: true,
          summary: "Login password. Omit to log in interactively instead."),
        .init(
          name: "BOURSOBANK_SESSION_PATH",
          isRequired: false,
          isSecret: false,
          summary: "Where the authenticated session is cached. Per-profile."),
        .init(
          name: "BOURSOBANK_DOCUMENTS_DIR",
          isRequired: false,
          isSecret: false,
          summary: "Where downloaded statements land. Per-profile."),
        .init(
          name: "BOURSOBANK_ALLOW_TRADING",
          isRequired: false,
          isSecret: false,
          summary: "Enables order entry on the linked brokerage account."),
      ]),
    // Holds no credential at all — it drives a browser. It is in the
    // manifest for supervision and audit, not for secret storage, and it is
    // the one entry that proves those two jobs are separable.
    //
    // It also spawns a browser, so its memory cost is unlike every other
    // entry here. Idle-stop matters more for this one than for any other.
    BastionServer(
      id: "buzzberg",
      displayName: "Buzzberg",
      summary: "Buzzberg market intelligence: speaker calls, timelines and crowd sentiment.",
      npmName: "@mgcrea/mcp-buzzberg",
      binName: "buzzberg-mcp",
      distribution: .local,
      localPath: "mcp-buzzberg",
      docsURL: nil,
      dialect: .v2025_06_18,
      writeGate: nil,
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "BUZZBERG_BROWSER_CHANNEL",
          isRequired: false,
          isSecret: false,
          summary: "Browser channel to drive, e.g. chrome. Defaults to chrome."),
        .init(
          name: "BUZZBERG_BROWSER_EXECUTABLE_PATH",
          isRequired: false,
          isSecret: false,
          summary: "Explicit browser binary, when the channel cannot be found."),
        .init(
          name: "BUZZBERG_BROWSER_HEADLESS",
          isRequired: false,
          isSecret: false,
          summary: "Run the browser headless. On by default."),
      ]),
    // Read-only and normally credential-free: the cookie and crumb are a
    // fallback for when the anonymous path is throttled. Marked secret
    // anyway, because a session cookie is a session cookie.
    BastionServer(
      id: "yahoo-finance",
      displayName: "Yahoo Finance",
      summary: "Yahoo Finance market data: quotes, fundamentals, holders, time series.",
      npmName: "@mgcrea/mcp-yahoo-finance",
      binName: "yahoo-finance-mcp",
      distribution: .local,
      localPath: "mcp-yahoo-finance",
      docsURL: nil,
      dialect: .v2025_06_18,
      writeGate: nil,
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "YAHOO_FINANCE_COOKIE",
          isRequired: false,
          isSecret: true,
          summary: "Session cookie, when the anonymous crumb flow is being refused."),
        .init(
          name: "YAHOO_FINANCE_CRUMB",
          isRequired: false,
          isSecret: true,
          summary: "Matching crumb for the cookie above."),
        .init(
          name: "YAHOO_FINANCE_CONCURRENCY",
          isRequired: false,
          isSecret: false,
          summary: "Parallel requests. Defaults to 4."),
      ]),
  ]
  // </generated:servers>

  /// Lookup by wire name. The gateway resolves `/s/<profile>/<server>` through
  /// this and 404s on a miss — an unknown id must never reach a spawn.
  static let byID: [String: BastionServer] = Dictionary(
    uniqueKeysWithValues: all.map { ($0.id, $0) })
}
