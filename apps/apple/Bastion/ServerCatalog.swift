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
  /// How Bastion reaches this server, and the field the rest of the app
  /// branches on.
  ///
  /// An enum with a payload rather than four optionals: a remote server has no
  /// package, no bin name and nothing to install, and expressing that as four
  /// `nil`s would make "is this one set?" a question every call site has to
  /// remember to ask. This way the compiler asks it. Same standard as the
  /// entitlements file — a property that is true by construction is checkable,
  /// one arrived at by deletion is not.
  let transport: Transport
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
  /// The remote counterpart to `writeGate`: tool names the gate hides.
  ///
  /// A child gets an environment variable that switches its destructive tools
  /// off inside the server. A remote server has no environment, so the only
  /// thing Bastion controls is what it forwards — and it forwards these only
  /// with the profile's write gate on. Absent from `tools/list` rather than
  /// offered and refused, exactly as `BuiltinTools` already does it, so a model
  /// never plans around a tool it cannot use.
  ///
  /// **This filters Bastion, not the server.** Anyone holding the credential
  /// can call the same API directly; the real boundary is the scopes the
  /// credential itself carries. The UI has to say so rather than let a switch
  /// imply a promise the switch cannot keep.
  ///
  /// Bastion additionally gates any tool the server annotates as not read-only,
  /// so a mutating tool added after this list was written is still caught.
  let writeTools: [String]
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
  /// Whether this server answers at all.
  ///
  /// A property of the *install*, not of the definition — which is why it lives
  /// here as a defaulted `var` alongside `origin` rather than in the catalog
  /// table: `ServerStore` sets it from the row on disk, and it has to travel
  /// with the definition because the gateway and the supervisor read servers off
  /// a snapshot rather than off the store.
  ///
  /// Disabling is the middle setting the app was missing. Removing a server
  /// takes its profiles, their Keychain entries and its downloaded code with it,
  /// which is far too much to mean "not right now".
  var isEnabled: Bool = true

  /// The package, or `nil` when there is nothing to install.
  ///
  /// The one unwrap a child-only path needs, so that "what does this do for a
  /// remote server?" is answered explicitly and in one place per function.
  var package: Package? {
    if case .child(let package) = transport { package } else { nil }
  }

  /// Where a remote server lives, or `nil` for a child.
  var endpoint: URL? { transport.endpoint }

  /// Whether a profile's write toggle means anything for this server.
  ///
  /// **Not `writeGate != nil`.** That was the whole answer while every server
  /// was a child with an environment variable to set, and six places across the
  /// app came to spell it out independently — the profile editor's toggle, the
  /// chat pane's confirmation rule, two `read-only` badges, the line explaining
  /// the gate, and the website's count. A remote server has no variable to
  /// name, so every one of them quietly decided Stripe could not write.
  ///
  /// It gates by tool NAME instead, and the names are not only `writeTools`:
  /// `RemoteInstance.isWriteTool` ORs that list with whatever the server
  /// annotates as not read-only, which is not known until a handshake has
  /// happened. So `!writeTools.isEmpty` would be the same bug one field along —
  /// a remote entry with an empty list can still gate tools it has not met yet.
  /// "Read-only" is not a claim that can be made about a remote server in
  /// advance, and the honest default is that it has a write path.
  var hasWritePath: Bool {
    writeGate != nil || transport.isRemote
  }

  /// Which list a definition was born in.
  ///
  /// Only the UI and `ServerStore`'s persistence care. Everything downstream —
  /// the supervisor, the profile store, the environment builder — treats
  /// catalog and custom identically on purpose: a custom server is not a
  /// second-class server, it is a server whose definition the user typed.
  ///
  /// `.builtin` is the one that does change behaviour downstream, because there
  /// is no package to install and no child to spawn.
  enum Origin: Hashable {
    /// Generated from `servers.json`. Re-resolved by id on every load.
    case catalog
    /// Typed by the user. Stored whole, because nothing else remembers it.
    case custom
    /// Bastion itself. Runs in-process, installs nothing, and cannot be
    /// removed — only switched off.
    case builtin
  }

  /// A package Bastion runs, or an endpoint somebody else operates.
  enum Transport: Hashable {
    /// An npm package, installed on demand and spoken to over stdio. The
    /// original and still the only kind that gets supervised: one process, N
    /// clients, backoff, a circuit breaker and an idle stop.
    case child(Package)
    /// An https endpoint. Nothing is installed and no process is started, so
    /// none of the supervision above applies — what does is the credential in
    /// the Keychain, the audit line, and the per-profile identity, which is
    /// three of the four reasons to put a gateway in front of a server at all.
    ///
    /// The URL is always the user's, resolved by id out of the installed list.
    /// Nothing arriving over the wire can name one — the same rule that keeps
    /// a request from naming a package, applied to the thing that replaces a
    /// package. `RemoteEndpoint` enforces the rest.
    case remote(endpoint: URL)
    /// Bastion's own server, answered inside this process. No package, no
    /// child, no endpoint, and nothing to install.
    ///
    /// This is the transport question — *how is it reached* — and `origin` is
    /// the provenance one. They coincide for exactly one server, and the
    /// distinction earns its keep at the point of dispatch: `Supervisor` used
    /// to branch on `origin == .builtin`, which asked where a definition came
    /// from in order to work out how to reach it. It branches here now.
    case inProcess

    var isRemote: Bool { if case .remote = self { true } else { false } }

    /// The endpoint, or nil for a child. Named rather than pattern-matched at
    /// every call site that only wants to show a host.
    var endpoint: URL? { if case .remote(let url) = self { url } else { nil } }
  }

  /// Everything needed to install and run a child, and nothing a remote server
  /// has any answer for.
  ///
  /// Grouped rather than spread across four cases of the enum so that a call
  /// site which only works on children says so **once** — `guard let package =
  /// server.package else { … }` — instead of unwrapping the same fact four
  /// times. The guard is the point: it makes every one of them state what it
  /// does when there is no package, which is the question the old shape let
  /// them all skip.
  struct Package: Hashable {
    /// Catalog entries are always `@mgcrea/mcp-<id>` and the generator
    /// enforces that; a custom entry names somebody else's package and is held
    /// only to npm's own naming rules.
    let npmName: String
    /// The `bin` entry to run out of that package. Looked up in the installed
    /// `package.json` rather than assumed — a package is free to put its entry
    /// point anywhere.
    let binName: String
    /// Whether the package is actually published. `.local` is the difference
    /// between an entry a stranger can install and one that resolves only
    /// against a checkout named by `dev.json`.
    let distribution: Distribution
    /// Directory name in the mgcrea-ai checkout, for `.local` and for DEBUG
    /// overrides of `.npm`.
    let localPath: String
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
    /// How the credential is obtained.
    ///
    /// Defaulted so the generated table below does not have to say `.env` for
    /// every mode that has always worked that way.
    var kind: Kind = .env
    let env: [String]

    enum Kind: Hashable {
      /// The user fills the named variables and Bastion sends them.
      case env
      /// Bastion runs an OAuth 2.1 flow and holds the token itself. Names no
      /// variables, because there are none: the token lives in its own Keychain
      /// scope and is never offered to the profile editor as an editable field.
      case oauth
    }
  }

  struct EnvVar: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let isRequired: Bool
    /// Kept in the Keychain, never written to a client config file, never
    /// echoed into the Activity window or a log line.
    let isSecret: Bool
    let summary: String
    /// Where the value goes on a **remote** server.
    ///
    /// Every variable used to land in one place — an environment variable on a
    /// child — so there was nothing to say. A remote server has no
    /// environment, and a variable with nowhere to land is one collected from
    /// the user, stored in the Keychain, and then silently never sent.
    ///
    /// `nil` for every child variable, and the generator refuses the
    /// mismatch either way.
    var header: HeaderSink?
  }

  /// A variable's landing place on a remote request.
  ///
  /// `format` is a template over `{value}` so that `Bearer` lives in the
  /// manifest and not in the profile: a user pastes a key, not a scheme, and a
  /// credential rotated later does not have to be re-prefixed by hand.
  struct HeaderSink: Hashable {
    let name: String
    let format: String

    func rendered(_ value: String) -> String {
      format.replacingOccurrences(of: "{value}", with: value)
    }
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
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-appstore-connect",
          binName: "appstore-connect-mcp",
          distribution: .npm,
          localPath: "mcp-appstore-connect")),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-appstore-connect"),
      dialect: .v2025_11_25,
      writeGate: "APP_STORE_CONNECT_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "inline-key",
          displayName: "Inline private key",
          kind: .env,
          env: ["APP_STORE_CONNECT_P8"]),
        .init(
          id: "key-file",
          displayName: "Private key file",
          kind: .env,
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
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-reddit",
          binName: "reddit-mcp",
          distribution: .local,
          localPath: "mcp-reddit")),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-reddit"),
      dialect: .v2025_11_25,
      writeGate: "REDDIT_ALLOW_WRITES",
      writeTools: [],
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
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-x-api",
          binName: "x-api-mcp",
          distribution: .local,
          localPath: "mcp-x-api")),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-x-api"),
      dialect: .v2025_11_25,
      writeGate: "X_API_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "bearer",
          displayName: "App-only bearer token",
          kind: .env,
          env: ["X_API_BEARER_TOKEN"]),
        .init(
          id: "oauth2",
          displayName: "OAuth2 user context",
          kind: .env,
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
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-unifi-protect",
          binName: "unifi-protect-mcp",
          distribution: .npm,
          localPath: "mcp-unifi-protect")),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-unifi-protect"),
      dialect: .v2025_11_25,
      writeGate: "UNIFI_PROTECT_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "cloud",
          displayName: "Cloud API key",
          kind: .env,
          env: ["UNIFI_PROTECT_API_KEY", "UNIFI_PROTECT_CONSOLE_ID"]),
        .init(
          id: "local",
          displayName: "Local account",
          kind: .env,
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
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-unifi-network",
          binName: "unifi-network-mcp",
          distribution: .npm,
          localPath: "mcp-unifi-network")),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-unifi-network"),
      dialect: .v2025_11_25,
      writeGate: "UNIFI_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "console",
          displayName: "Console API key",
          kind: .env,
          env: ["UNIFI_HOST", "UNIFI_API_KEY"]),
        .init(
          id: "cloud",
          displayName: "Cloud API key",
          kind: .env,
          env: ["UNIFI_API_KEY", "UNIFI_CONSOLE_ID"]),
        .init(
          id: "legacy",
          displayName: "Local admin account",
          kind: .env,
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
    // REMOTE. This entry used to be a placeholder for @mgcrea/mcp-stripe, a
    // package that was never written and never published. Stripe operates a
    // real MCP server, so Bastion fronts that one instead: the part worth
    // building here was never a Stripe client, it was the runtime underneath
    // one - identity, credentials in the Keychain, and a record of every call.
    //
    // The id is unchanged on purpose. Anyone who made a profile against the
    // placeholder keeps it.
    //
    // DIALECT MEASURED 2026-08-31, and it is the oldest in this file. A live
    // handshake negotiates 2025-03-26 - two revisions behind the default an
    // unmeasured entry would have carried, which is exactly why the default is
    // never left in place. serverInfo reports stripe-mcp 1.0.0.
    //
    // WRITE TOOLS ARE TWO LISTS, and the measurement is why. Of the four tools
    // hidden with writes off, only stripe_api_write is named below; the other
    // three - stripe_analytics, stripe_implementation_planner and
    // send_stripe_mcp_feedback - were caught solely by Stripe's own
    // readOnlyHint:false annotation. A hand-written denylist would have missed
    // three quarters of them, so the annotation is not a belt-and-braces extra
    // here, it is the half that works.
    //
    // create_refund and stripe_report are named below and were NOT offered by
    // the account this was measured against. Kept rather than deleted: they
    // are in Stripe's published tool table, an account that exposes them wants
    // them gated, and a name that is never offered costs nothing.
    //
    // Money moves through this one, so the gate is not a formality. Prefer a
    // restricted key scoped to reads and let the profile stay gated off - the
    // write gate cannot take back a permission the key already grants.
    BastionServer(
      id: "stripe",
      displayName: "Stripe",
      summary: "Stripe's own remote MCP server: the API surface, plus documentation and knowledge-base search.",
      transport: .remote(endpoint: URL(string: "https://mcp.stripe.com")!),
      docsURL: URL(string: "https://docs.stripe.com/mcp"),
      dialect: .v2025_03_26,
      writeGate: nil,
      writeTools: ["stripe_api_write", "create_refund", "stripe_report"],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Stripe",
          kind: .oauth,
          env: []),
        .init(
          id: "bearer",
          displayName: "Restricted API key",
          kind: .env,
          env: ["STRIPE_SECRET_KEY"]),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "STRIPE_SECRET_KEY",
          isRequired: false,
          isSecret: true,
          summary: "Restricted API key, sent as the bearer token. A restricted key is the right one here: the write gate filters what Bastion forwards, it cannot take back a permission the key already grants.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
        .init(
          name: "STRIPE_ACCOUNT_ID",
          isRequired: false,
          isSecret: false,
          summary: "Connected account to act on behalf of, sent as Stripe-Account. Stripe does not support OAuth in this mode, so a profile using it must authenticate with a restricted key.",
          header: .init(name: "Stripe-Account", format: "{value}")),
        .init(
          name: "STRIPE_API_VERSION",
          isRequired: false,
          isSecret: false,
          summary: "Pin the API version instead of using the account default, sent as Stripe-Version.",
          header: .init(name: "Stripe-Version", format: "{value}")),
      ]),
    // No write gate because there is no write path: every tool is a read.
    // That is why the build order takes this one end-to-end first — a bug in
    // the supervisor or the dialect layer cannot cost anybody data here.
    BastionServer(
      id: "shopify",
      displayName: "Shopify",
      summary: "Shopify Admin GraphQL API: products, variants, collections, metafields, locations.",
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-shopify",
          binName: "shopify-mcp",
          distribution: .npm,
          localPath: "mcp-shopify")),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-shopify"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
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
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-ovh-api",
          binName: "ovh-api-mcp",
          distribution: .npm,
          localPath: "mcp-ovh-api")),
      docsURL: nil,
      dialect: .v2025_11_25,
      writeGate: "OVH_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "OAuth2 service account",
          kind: .env,
          env: ["OVH_CLIENT_ID", "OVH_CLIENT_SECRET"]),
        .init(
          id: "signature",
          displayName: "Application key triplet",
          kind: .env,
          env: ["OVH_APPLICATION_KEY", "OVH_APPLICATION_SECRET", "OVH_CONSUMER_KEY"]),
        .init(
          id: "accessToken",
          displayName: "Access token",
          kind: .env,
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
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-keycloak",
          binName: "keycloak-mcp",
          distribution: .local,
          localPath: "mcp-keycloak")),
      docsURL: nil,
      dialect: .v2025_11_25,
      writeGate: "KEYCLOAK_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "client_credentials",
          displayName: "Client credentials",
          kind: .env,
          env: ["KEYCLOAK_CLIENT_SECRET"]),
        .init(
          id: "password",
          displayName: "Username and password",
          kind: .env,
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
