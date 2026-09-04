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
  /// Which way `writeGate` points. `true` — the default and every server we
  /// write — means the variable ENABLES writes, so the toggle sends `"1"` for
  /// on. `false` means it is a read-only switch and the values invert.
  ///
  /// Defaulted so the generated catalog does not repeat the common case, and
  /// stated in `servers.json` rather than guessed from the name, because the
  /// name cannot be read: of the third-party gates measured so far
  /// `MDB_MCP_READ_ONLY`, `READONLY` and `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS`
  /// are all inverted, and the last one contains the word ALLOW. Any heuristic
  /// over the name gets Kubernetes exactly backwards.
  ///
  /// Read only through `gateValue(allowWrites:)`. Nothing else should compare
  /// this to anything.
  var writeGateEnablesWrites: Bool = true
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
  /// Env vars naming a **loopback OAuth callback URL**. Two profiles would
  /// collide on one default port, so the second one onwards is assigned a port
  /// of its own — the first keeps the server's documented default, because the
  /// upstream app registration has to match byte for byte and only the user can
  /// change that. See `ProfileEnvironment.callbackPort`.
  ///
  /// Deliberately not the servers' own `*_HTTP_PORT` variables: those select a
  /// standalone HTTP transport Bastion never uses. Bastion *is* the HTTP front;
  /// it speaks stdio to the child.
  let callbackEnv: [CallbackVar]
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
  ///
  /// A child gated by tool NAME counts too. That shape exists because Bastion
  /// passes no argv, so a server whose own read-only switch is a CLI flag has
  /// no variable to set — and declaring `writeGate: nil` for one would say
  /// "every tool is a read" about a server that can drop a table.
  var hasWritePath: Bool {
    writeGate != nil || transport.isRemote || !writeTools.isEmpty
  }

  /// The literal a profile's write toggle resolves to, or `nil` when there is
  /// no gate to set.
  ///
  /// The one place polarity is applied. It lives here, on the definition,
  /// rather than at the single call site in `ProfileEnvironment.build` for a
  /// reason that is not style: `make unit` compiles this file and not that one,
  /// so a rule written here is asserted on every catalog entry for free, and
  /// the same rule written there cannot be tested at all. Getting a gate
  /// backwards spawns a server with writes ON while its profile, the editor and
  /// the Activity window all read as off — a failure with no other detector.
  func gateValue(allowWrites: Bool) -> String? {
    guard writeGate != nil else { return nil }
    return allowWrites == writeGateEnablesWrites ? "1" : "0"
  }

  /// The variables a profile actually fills in, which is **not** `env`.
  ///
  /// The gate is in `env` because the manifest generator requires it there — a
  /// gate the server never reads gates nothing, so the name is checked against
  /// the declared variables. But the gate is owned by the profile's toggle and
  /// written last by `ProfileEnvironment.build`, unconditionally and in both
  /// directions. Offering it as a text field as well gives one wire two
  /// switches, and the text one does nothing: whatever is typed there is
  /// accepted, saved to `profiles.json`, and then overwritten at spawn.
  ///
  /// That is not only a dead control. A profile that stored `"1"` here and
  /// whose toggle is later turned off keeps the `"1"` on disk, so the file
  /// reads as if writes were on while the child is spawned with `"0"`.
  var editableEnv: [EnvVar] {
    guard let gate = writeGate else { return env }
    return env.filter { $0.name != gate }
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

    /// The glyph for this transport, which is the only place in a sidebar row
    /// where the difference is visible at all.
    ///
    /// The row used to ask `origin`, and got the wrong question's answer: every
    /// non-builtin server drew a shipping box, so a remote endpoint appeared as
    /// a package that had been downloaded — the one thing it never is. The
    /// question the row is answering is whether this server runs on the
    /// reader's machine or on somebody else's, and that is the question
    /// `transport` is, so it is the one asked here.
    var symbolName: String {
      switch self {
      case .child: "shippingbox"
      case .remote: "cloud"
      case .inProcess: "gearshape.2"
      }
    }

    /// What that glyph means, spelled out. A three-way icon nobody has seen
    /// before is a quiz until something answers it, and the badges beside it
    /// already take this shape.
    var summaryLabel: String {
      switch self {
      case .child: "Local package"
      case .remote: "Remote endpoint"
      case .inProcess: "Built in"
      }
    }

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
    /// A catalog entry marked `.mgcrea` is always `@mgcrea/mcp-<id>` and the
    /// generator enforces that. A `.thirdParty` entry — catalog or custom —
    /// names somebody else's package and is held only to npm's own naming
    /// rules, because `@acme/mcp-foo` shipping a `foo` binary is nobody's
    /// mistake.
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
    /// overrides of `.npm`. Derived from `npmName` for a `.thirdParty` entry,
    /// where it is a convenience for anyone who happens to have the package
    /// cloned beside the others and never a claim that they do — a miss in
    /// `ServerLocator.developmentBinaries` falls through rather than failing.
    let localPath: String
    /// Who publishes this package, and therefore whose rules it is held to.
    ///
    /// Deliberately not defaulted. A forgotten `vendor` would silently claim
    /// first-party provenance, and that claim is what `ServerDetail` renders to
    /// somebody deciding whether to run the thing.
    let vendor: Vendor
  }

  /// Who publishes a child's package.
  enum Vendor: Hashable {
    /// Written here. Held to the `@mgcrea/mcp-<id>` naming rule, and its
    /// declared variables are checked against its own TypeScript source.
    case mgcrea
    /// Somebody else's package, which Bastion installs from npm and runs on the
    /// user's machine with the profile's credentials in its environment. The
    /// higher-trust ask of the two, and the reason it is said out loud in the UI
    /// rather than left to be inferred from a package name.
    case thirdParty

    /// The vendor of a package nobody vetted, read off its npm scope.
    ///
    /// Inference is refused in `servers.json` — a stated `vendor` is what makes
    /// a misspelled scope like `@mgcre/mcp-reddit` fail loudly instead of being
    /// waved through as somebody else's package. That argument does not carry
    /// here: a CUSTOM entry is typed by the user, there is no expected name to
    /// check it against, and the scope is the only evidence there is. `@mgcrea`
    /// is a scope we control, so a package inside it is ours by construction.
    static func inferred(fromPackage npmName: String) -> Vendor {
      npmName.hasPrefix("@mgcrea/") ? .mgcrea : .thirdParty
    }
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
  ///
  /// The case names carry underscores so each one reads as the wire version it
  /// equals. lowerCamelCase would spell `v20241105`, which no longer matches
  /// the string beside it or anything in the spec, so the rule is off for this
  /// declaration only rather than for the repo.
  // swift-format-ignore: AlwaysUseLowerCamelCase
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
    /// The child's own login tool. `.childOAuth` only, `nil` everywhere else.
    ///
    /// Named in the manifest rather than derived from `id`, because these are
    /// somebody else's tool names and a convention guessed here would fail as a
    /// -32601 at the moment a user clicks a button.
    var loginTool: String? = nil
    /// The child's own tool reporting whether it is signed in. `.childOAuth`
    /// only. It is the *only* way Bastion knows: it never sees the token.
    var statusTool: String? = nil
    /// The child's own tool that forgets the stored token. `.childOAuth` only.
    var logoutTool: String? = nil

    enum Kind: Hashable {
      /// The user fills the named variables and Bastion sends them.
      case env
      /// Bastion runs an OAuth 2.1 flow and holds the token itself. Names no
      /// variables, because there are none: the token lives in its own Keychain
      /// scope and is never offered to the profile editor as an editable field.
      ///
      /// **Remote only.** The flow starts by discovering against an endpoint,
      /// and a child has not got one.
      case oauth
      /// The server logs *itself* in. Bastion drives the flow through the
      /// server's own tools and reports what they say, and holds nothing: the
      /// client id is the server's, the browser is opened by the child, the
      /// callback is caught on the child's own socket, and the refresh token
      /// stays in the child's per-profile state file.
      ///
      /// **Child only**, for the mirror of the reason `.oauth` is remote only:
      /// there has to be a child to call the tools on.
      ///
      /// To a user this is the same button as `.oauth`. The difference is
      /// custody, and it is worth keeping the two kinds apart precisely because
      /// the UI cannot show it — treating them as one would put Bastion's
      /// "no tool can read this token back" promise on a token Bastion does
      /// not hold and cannot make that promise about.
      case childOAuth
    }

    /// Whether this mode is satisfied by signing in rather than by typing.
    ///
    /// Both OAuth kinds name no variables, so every "is this profile usable"
    /// site has to treat them alike; only the *mechanism* differs.
    var isInteractive: Bool { kind == .oauth || kind == .childOAuth }
  }

  /// A loopback callback URL Bastion builds for one profile.
  ///
  /// `format` is a template over `{port}` so the path stays in the manifest,
  /// for the same reason `HeaderSink.format` keeps `Bearer` out of a profile.
  struct CallbackVar: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let format: String

    /// The URL for an assigned port.
    func url(port: Int) -> String {
      format.replacingOccurrences(of: "{port}", with: String(port))
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
    /// What the server does when this variable is **unset** — or `nil` when it
    /// is not a boolean and its value is free text.
    ///
    /// Booleans are the one shape where a text field is a trap. Every server
    /// that reads one parses it with the same four-word allowlist, so `y`,
    /// `enable` and `yeah` are all silently false; on `UNIFI_PROTECT_VERIFY_TLS`
    /// that is the direction that stops checking a console's certificate.
    ///
    /// It is a default rather than a `Bool` because these are three-state, not
    /// two. Each server reads them as `parseBool(env.X) ?? file.X`, so unset is
    /// not off: it falls through to the server's own config file and then to
    /// this value. A profile that says nothing must therefore write nothing —
    /// which is only safe to offer once the third state is visible, and that is
    /// what this field makes possible.
    var booleanDefault: Bool?

    /// How every one of these servers reads a boolean, so the editor can show
    /// which way an existing value is actually being read.
    ///
    /// Not a guess: `parseBool` is copied verbatim in each repo that has one —
    /// appstore-connect, keycloak, ovh, reddit, unifi-network,
    /// unifi-protect and x all spell it `["1", "true", "yes", "on"]`, and
    /// Cupertino's `packages/core` agrees. `nil` for unset, which is the state
    /// that is neither.
    static func parseBool(_ raw: String) -> Bool? {
      let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if t.isEmpty { return nil }
      return ["1", "true", "yes", "on"].contains(t.lowercased())
    }
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
  // Generated bytes, and the one place in the repo where swift-format must have
  // no opinion. `make servers` writes this array from servers.json and
  // `make servers-check` asserts it byte for byte; a formatter that rewraps it
  // makes the two rewrite each other forever and fails the drift gate on a file
  // nobody edited. The comment sits outside the marker so regenerating cannot
  // remove it.
  // swift-format-ignore
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
          localPath: "mcp-appstore-connect",
          vendor: .mgcrea)),
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
          env: ["APP_STORE_CONNECT_P8"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "key-file",
          displayName: "Private key file",
          kind: .env,
          env: ["APP_STORE_CONNECT_P8_PATH"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
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
    // A separate service from App Store Connect, not a feature of it: different
    // host (api.icloud.apple.com), different credential (a static management
    // token, not a minted JWT), no field in common. An App Store Connect key
    // gives no access here and this token gives no access there — which is
    // the whole reason this is its own server rather than folded into
    // appstore-connect, where it lived for one commit before the split.
    //
    // The API is undocumented. Every route was read out of the `cktool` binary
    // Xcode ships (`strings $(xcrun -f cktool)`); cloudkit_request is a
    // GET-by-default escape hatch for whatever that reading got wrong. The one
    // route it refuses even with writes on is the container's environment
    // reset — wipes all Development data — which is deliberately not a tool
    // at all, so exposing it through the escape hatch would defeat the point
    // of leaving it out.
    //
    // cloudkit_deploy_schema always fetches and returns the pending diff before
    // promoting Development to Production, and refuses when there is nothing
    // to deploy. Production is additive-only forever once first deployed — a
    // field can be added, never removed, renamed or retyped — so that diff is
    // the one thing worth reading before confirm: true.
    //
    // Published as @mgcrea/mcp-cloudkit 0.1.0 on 2026-09-04, so a stranger
    // can install this one. The scope is covered by a min-release-age-exclude
    // locally, which is the only reason a version this fresh installs at all.
    BastionServer(
      id: "cloudkit",
      displayName: "CloudKit",
      summary: "CloudKit management API: container schema — record types, fields, Development/Production diff and deploy.",
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-cloudkit",
          binName: "cloudkit-mcp",
          distribution: .npm,
          localPath: "mcp-cloudkit",
          vendor: .mgcrea)),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-cloudkit"),
      dialect: .v2025_11_25,
      writeGate: "CLOUDKIT_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: ["CLOUDKIT_CONFIG"],
      callbackEnv: [],
      env: [
        .init(
          name: "CLOUDKIT_MANAGEMENT_TOKEN",
          isRequired: true,
          isSecret: true,
          summary: "CloudKit management token, from icloud.developer.apple.com/dashboard/account/tokens — CloudKit Management Tokens. Can rewrite the container's schema; scope it and revoke when done."),
        .init(
          name: "CLOUDKIT_TEAM_ID",
          isRequired: true,
          isSecret: false,
          summary: "10-character Apple Developer team id, e.g. 75QE9PRT3V. Also in the app's exportOptions.plist."),
        .init(
          name: "CLOUDKIT_CONTAINER_ID",
          isRequired: false,
          isSecret: false,
          summary: "Default container, e.g. iCloud.io.mgcrea.Balise, so it need not be passed on every call. cloudkit_list_containers finds it if unset."),
        .init(
          name: "CLOUDKIT_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion points this at the profile's own directory."),
        .init(
          name: "CLOUDKIT_MAX_RETRIES",
          isRequired: false,
          isSecret: false,
          summary: "Retry budget for 429/5xx responses. Defaults to 3."),
        .init(
          name: "CLOUDKIT_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables cloudkit_deploy_schema and cloudkit_import_schema. Both additionally require confirm: true on every call."),
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
          distribution: .npm,
          localPath: "mcp-reddit",
          vendor: .mgcrea)),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-reddit"),
      dialect: .v2025_11_25,
      writeGate: "REDDIT_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Reddit",
          kind: .childOAuth,
          env: [],
          loginTool: "reddit_auth_login",
          statusTool: "reddit_auth_status",
          logoutTool: "reddit_auth_logout"),
      ],
      stateEnv: ["REDDIT_TOKEN_PATH"],
      callbackEnv: [.init(name: "REDDIT_REDIRECT_URI", format: "http://127.0.0.1:{port}/callback")],
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
    // Two write gates, not one: X_ALLOW_WRITES governs posting and
    // X_ADS_ALLOW_WRITES governs spending money. The manifest names the
    // first as the gate because that is the one the Activity window badges;
    // the second is an ordinary env entry that a profile sets deliberately.
    //
    // X_MONTHLY_BUDGET_USD is here for the same reason a write gate is:
    // on this API a read has a price, so an unbounded profile is a bill.
    BastionServer(
      id: "x",
      displayName: "X",
      summary: "X (Twitter) API v2: posts, threads, timelines, search, bookmarks, and the Ads API.",
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-x",
          binName: "x-mcp",
          distribution: .npm,
          localPath: "mcp-x",
          vendor: .mgcrea)),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-x"),
      dialect: .v2025_11_25,
      writeGate: "X_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "bearer",
          displayName: "App-only bearer token",
          kind: .env,
          env: ["X_BEARER_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "oauth2",
          displayName: "OAuth2 user context",
          kind: .env,
          env: ["X_CLIENT_ID"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: ["X_CONFIG", "X_TOKEN_FILE"],
      callbackEnv: [.init(name: "X_REDIRECT_URI", format: "http://127.0.0.1:{port}/callback")],
      env: [
        .init(
          name: "X_BEARER_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "App-only bearer token. Reads only; the Ads API rejects it outright."),
        .init(
          name: "X_CLIENT_ID",
          isRequired: false,
          isSecret: false,
          summary: "OAuth2 client id. Required for a user context, and therefore for writes and for Ads."),
        .init(
          name: "X_CLIENT_SECRET",
          isRequired: false,
          isSecret: true,
          summary: "OAuth2 client secret, for a confidential client."),
        .init(
          name: "X_REDIRECT_URI",
          isRequired: false,
          isSecret: false,
          summary: "Loopback OAuth callback. Per-profile, or two profiles race for one port — and the URL must be registered with the X app."),
        .init(
          name: "X_TOKEN_FILE",
          isRequired: false,
          isSecret: false,
          summary: "Where the user token is stored. Per-profile, or two accounts share one login."),
        .init(
          name: "X_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion points this at the profile's own directory."),
        .init(
          name: "X_MONTHLY_BUDGET_USD",
          isRequired: false,
          isSecret: false,
          summary: "Spend ceiling. X bills per read, so this is a real safety control, not a preference."),
        .init(
          name: "X_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables posting through the API rather than returning an intent URL."),
        .init(
          name: "X_ADS_ENABLED",
          isRequired: false,
          isSecret: false,
          summary: "Registers the Ads API tools. Needs a user context.",
          booleanDefault: false),
        .init(
          name: "X_ADS_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables campaign mutations. No effect without X_ADS_ENABLED.",
          booleanDefault: false),
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
          localPath: "mcp-unifi-protect",
          vendor: .mgcrea)),
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
          env: ["UNIFI_PROTECT_API_KEY", "UNIFI_PROTECT_CONSOLE_ID"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "local",
          displayName: "Local account",
          kind: .env,
          env: ["UNIFI_PROTECT_HOST", "UNIFI_PROTECT_USERNAME", "UNIFI_PROTECT_PASSWORD"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
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
          summary: "Verify the console certificate. Needs a hostname, not an IP.",
          booleanDefault: true),
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
          localPath: "mcp-unifi-network",
          vendor: .mgcrea)),
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
          env: ["UNIFI_HOST", "UNIFI_API_KEY"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "cloud",
          displayName: "Cloud API key",
          kind: .env,
          env: ["UNIFI_API_KEY", "UNIFI_CONSOLE_ID"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "legacy",
          displayName: "Local admin account",
          kind: .env,
          env: ["UNIFI_HOST", "UNIFI_USERNAME", "UNIFI_PASSWORD"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
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
          summary: "Disable certificate verification, for this server only.",
          booleanDefault: false),
        .init(
          name: "UNIFI_ENABLE_LEGACY",
          isRequired: false,
          isSecret: false,
          summary: "Registers the unifi_legacy_* tools.",
          booleanDefault: false),
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
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "bearer",
          displayName: "Restricted API key",
          kind: .env,
          env: ["STRIPE_SECRET_KEY"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
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
          localPath: "mcp-shopify",
          vendor: .mgcrea)),
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
      id: "ovh",
      displayName: "OVHcloud",
      summary: "OVHcloud API, focused on Object Storage: containers, objects, policies, regions.",
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-ovh",
          binName: "ovh-mcp",
          distribution: .npm,
          localPath: "mcp-ovh",
          vendor: .mgcrea)),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-ovh"),
      dialect: .v2025_11_25,
      writeGate: "OVH_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "OAuth2 service account",
          kind: .env,
          env: ["OVH_CLIENT_ID", "OVH_CLIENT_SECRET"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "signature",
          displayName: "Application key triplet",
          kind: .env,
          env: ["OVH_APPLICATION_KEY", "OVH_APPLICATION_SECRET", "OVH_CONSUMER_KEY"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "accessToken",
          displayName: "Access token",
          kind: .env,
          env: ["OVH_ACCESS_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
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
          distribution: .npm,
          localPath: "mcp-keycloak",
          vendor: .mgcrea)),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-keycloak"),
      dialect: .v2025_11_25,
      writeGate: "KEYCLOAK_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "client_credentials",
          displayName: "Client credentials",
          kind: .env,
          env: ["KEYCLOAK_CLIENT_SECRET"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "password",
          displayName: "Username and password",
          kind: .env,
          env: ["KEYCLOAK_USERNAME", "KEYCLOAK_PASSWORD"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
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
    // No auth modes, and not because there is only one credential. This
    // server starts with NOTHING configured — every packument, search and
    // advisory read is public — and a mode has to name at least one
    // variable, which the zero-config path has not got. So the choice is
    // not a mode: either NPM_TOKEN is set, or the server reads ~/.npmrc.
    //
    // Which is exactly why NPM_CONFIG_USERCONFIG is state. HOME is the real
    // home, so a profile that names no token quietly borrows the machine's
    // `npm login` — two profiles are then one npm user wearing two names,
    // and the audit line says which profile called, not who published. A
    // second identity points this at its own file, or sets NPM_TOKEN.
    //
    // The writes worth naming are irreversible in npm's own terms, and the
    // gate is not the only thing standing in front of them: publish and
    // unpublish both offer a dry run, and everything irreversible also
    // wants an explicit `confirm: true`. npm demands a fresh one-time
    // password on every trusted-publisher endpoint, the READ included, so
    // unattended trust configuration is impossible by construction rather
    // than by policy.
    BastionServer(
      id: "npm",
      displayName: "npm",
      summary: "npm registry: packages, versions, downloads, advisories, dist-tags, orgs, tokens and trusted publishing.",
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-npm",
          binName: "npm-mcp",
          distribution: .npm,
          localPath: "mcp-npm",
          vendor: .mgcrea)),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-npm"),
      dialect: .v2025_11_25,
      writeGate: "NPM_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: ["NPM_CONFIG_USERCONFIG", "NPM_MCP_CONFIG"],
      callbackEnv: [],
      env: [
        .init(
          name: "NPM_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "npm access token. Optional: with none set the server falls back to the token `npm login` wrote to ~/.npmrc. A granular token with 'Bypass 2FA' enabled is refused by every trusted-publisher write."),
        .init(
          name: "NPM_REGISTRY",
          isRequired: false,
          isSecret: false,
          summary: "Registry to talk to. Defaults to https://registry.npmjs.org, and the .npmrc token is looked up for whichever host this names, never sent to another."),
        .init(
          name: "NPM_CONFIG_USERCONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Which .npmrc the fallback token is read from. Unset means the machine's own ~/.npmrc, which every profile would then share."),
        .init(
          name: "NPM_MCP_CONFIG",
          isRequired: false,
          isSecret: false,
          summary: "Config file path. Bastion already points the default at the profile's own directory; set this only to name a file elsewhere."),
        .init(
          name: "NPM_OTP_MODE",
          isRequired: false,
          isSecret: false,
          summary: "How the one-time password npm demands on every trusted-publisher call is obtained: web opens npm's confirmation page and waits, static uses NPM_OTP, none refuses with instructions. Defaults to web."),
        .init(
          name: "NPM_OTP",
          isRequired: false,
          isSecret: true,
          summary: "A one-time password, and the only thing NPM_OTP_MODE=static will start without complaining about. Rarely right: a code lasts about five minutes, so one set at spawn is dead before anything calls a tool."),
        .init(
          name: "NPM_AUTO_OPEN_BROWSER",
          isRequired: false,
          isSecret: false,
          summary: "Whether the one-time-password flow launches a browser, or only prints the authorization URL.",
          booleanDefault: true),
        .init(
          name: "NPM_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Registers the write tools: publish and unpublish, dist-tags, deprecation, package access, org and team membership, tokens, and trusted-publisher changes."),
      ]),
    // REMOTE. GitHub operates this one; Bastion holds the credential and the
    // audit line and forwards the call.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // WRITE TOOLS TAKEN FROM THE PUBLISHED TOOL TABLE, not from a live
    // tools/list - the endpoint 401s before it will enumerate. Thirty-three
    // names, and delete_repository is the one worth reading twice. The list is
    // belt and braces either way: Bastion also gates anything the server
    // annotates readOnlyHint:false, which is the half that caught three
    // quarters of Stripe's write surface.
    //
    // The token is the real boundary, not the gate. A classic PAT with repo
    // scope reaches every repository the account can see, including private
    // ones in other organisations. Prefer a fine-grained token.
    BastionServer(
      id: "github",
      displayName: "GitHub",
      summary: "GitHub's own remote MCP server: repositories, issues, pull requests, Actions, code scanning and Dependabot alerts.",
      transport: .remote(endpoint: URL(string: "https://api.githubcopilot.com/mcp/")!),
      docsURL: URL(string: "https://github.com/github/github-mcp-server"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: ["actions_run_trigger", "add_comment_to_pending_review", "add_issue_comment", "add_reply_to_pull_request_comment", "assign_copilot_to_issue", "assign_copilot_to_issue_with_intent", "create_branch", "create_gist", "create_or_update_file", "create_pull_request", "create_pull_request_with_copilot", "create_repository", "delete_file", "delete_repository", "discussion_comment_write", "dismiss_notification", "fork_repository", "issue_write", "label_write", "manage_notification_subscription", "manage_repository_notification_subscription", "mark_all_notifications_read", "merge_pull_request", "projects_write", "pull_request_review_write", "push_files", "request_copilot_review", "star_repository", "sub_issue_write", "unstar_repository", "update_gist", "update_pull_request", "update_pull_request_branch"],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with GitHub",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "pat",
          displayName: "Personal access token",
          kind: .env,
          env: ["GITHUB_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "GITHUB_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Personal access token, sent as the bearer token. Scope it to the repositories you actually want reachable: the write gate filters what Bastion forwards, it cannot take back a permission the token already grants.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. Its own discovery document calls it "Notion MCP (Beta)", so
    // expect the tool surface to move.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // NO writeTools LIST. The endpoint 401s before it will enumerate and
    // Notion publishes no stable tool table, so naming tools here would be
    // guesswork that silently matches nothing. Writes are gated by the
    // server's own readOnlyHint:false annotations instead. Say that out loud
    // in the UI rather than implying a hand-checked denylist exists.
    BastionServer(
      id: "notion",
      displayName: "Notion",
      summary: "Notion's own remote MCP server: search, read and update pages, databases and comments.",
      transport: .remote(endpoint: URL(string: "https://mcp.notion.com/mcp")!),
      docsURL: URL(string: "https://developers.notion.com/docs/mcp"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Notion",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "token",
          displayName: "Integration token",
          kind: .env,
          env: ["NOTION_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "NOTION_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Internal integration token, sent as the bearer token. A Notion integration reaches only the pages explicitly shared with it, so the sharing list is the real boundary here.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. The cleanest OAuth story in this file: discovery advertises a
    // registration_endpoint, PKCE, and scopes_supported [read, write], so
    // Bastion's dynamic registration has everything it needs.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // THERE IS A READ-ONLY URL and this entry does not use it. Linear also
    // serves https://mcp.linear.app/mcp/readonly, where the SERVER enforces
    // what writeTools can only filter. One url per entry, so this is a real
    // fork in the road: point a second entry at it, or tell people who want
    // writes off to use a key scoped to read. Worth deciding rather than
    // leaving to whoever reads this next.
    //
    // NO writeTools LIST - 401 before enumeration, same as the others. The
    // annotation gate carries it.
    BastionServer(
      id: "linear",
      displayName: "Linear",
      summary: "Linear's own remote MCP server: issues, projects, cycles, comments and documents.",
      transport: .remote(endpoint: URL(string: "https://mcp.linear.app/mcp")!),
      docsURL: URL(string: "https://linear.app/docs/mcp"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Linear",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "api-key",
          displayName: "API key",
          kind: .env,
          env: ["LINEAR_API_KEY"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "LINEAR_API_KEY",
          isRequired: false,
          isSecret: true,
          summary: "Linear API key, sent as the bearer token. Linear issues read and write as separate OAuth scopes, so a key minted for reads is a stronger control than the write gate.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. docs.sentry.io/product/sentry-mcp/ 301s to mcp.sentry.dev,
    // which is both the server and its documentation, so docsUrl points
    // there.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // NO writeTools LIST. Sentry documents permission scopes rather than a
    // tool table, so there is nothing to copy that would not be invented.
    // The annotation gate is what is actually holding writes here.
    BastionServer(
      id: "sentry",
      displayName: "Sentry",
      summary: "Sentry's own remote MCP server: issues, events, releases and Seer analysis across your organisations.",
      transport: .remote(endpoint: URL(string: "https://mcp.sentry.dev/mcp")!),
      docsURL: URL(string: "https://mcp.sentry.dev/"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Sentry",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "token",
          displayName: "User auth token",
          kind: .env,
          env: ["SENTRY_ACCESS_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "SENTRY_ACCESS_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Sentry user auth token, sent as the bearer token. Its own scopes decide what is reachable; project:write and event:write are the ones to leave off unless something needs them.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. v2 is the current path - anything still pointing at
    // mcp.atlassian.com/v1/sse is on a version Atlassian has retired.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // ONLY THE SERVICE ACCOUNT KEY IS OFFERED, and that is deliberate.
    // Atlassian takes two token shapes: a service account API key as
    // `Authorization: Bearer <key>`, which fits a header format cleanly, and
    // a personal API token as `Authorization: Basic <base64(email:token)>`,
    // which would make the user paste a base64 blob they had to build
    // themselves. Personal-token users should sign in with OAuth instead.
    //
    // Permissions are grouped upstream (read_jira, write_jira, delete_jira
    // and so on) and delete_jira and manage_jira are admin-enabled and off by
    // default, so most accounts cannot reach the destructive half at all.
    BastionServer(
      id: "atlassian",
      displayName: "Atlassian",
      summary: "Atlassian's own Rovo MCP server: Jira, Confluence, Jira Service Management, Bitbucket and Compass.",
      transport: .remote(endpoint: URL(string: "https://mcp.atlassian.com/v2/mcp")!),
      docsURL: URL(string: "https://github.com/atlassian/atlassian-mcp-server"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Atlassian",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "api-key",
          displayName: "Service account API key",
          kind: .env,
          env: ["ATLASSIAN_API_KEY"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "ATLASSIAN_API_KEY",
          isRequired: false,
          isSecret: true,
          summary: "Service account API key, sent as the bearer token. An organisation admin must enable API token authentication before any key works; if that is off, OAuth is the only way in.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. Figma also ships a local server that talks to the desktop app;
    // this entry is the hosted one, which is the one Figma recommends.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // THE TOKEN HEADER IS THE UNCERTAIN PART. Figma's REST API authenticates
    // with X-Figma-Token, not a bearer token, and the MCP endpoint's own
    // challenge asks for Bearer. Bearer is what is written here because that
    // is what the endpoint asked for, but it is untested against a real
    // token. If it is refused, the fix is one header format, not an entry.
    //
    // NO writeTools LIST. Mostly a read surface, and 401 before enumeration.
    BastionServer(
      id: "figma",
      displayName: "Figma",
      summary: "Figma's own remote MCP server: design file context, components and variables for coding agents.",
      transport: .remote(endpoint: URL(string: "https://mcp.figma.com/mcp")!),
      docsURL: URL(string: "https://developers.figma.com/docs/figma-mcp-server/"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Figma",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "token",
          displayName: "Personal access token",
          kind: .env,
          env: ["FIGMA_ACCESS_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "FIGMA_ACCESS_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Figma personal access token, sent as the bearer token. Note that Figma's REST API takes its tokens in X-Figma-Token instead; if this path is refused, sign in with OAuth.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. Its discovery document points authorization_servers at
    // vercel.com rather than at itself, so the OAuth dance leaves the MCP
    // host entirely.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // VERCEL SAYS IT SUPPORTS 2026-07-28. Their changelog announces it, which
    // would make this the first entry in the file that is modern rather than
    // legacy. It is NOT written into dialect above, because a handshake that
    // proposes a version the server does not take fails the connection, and
    // nothing here has proved it. Measure it, then raise this field - that
    // order round the wrong way is an outage.
    //
    // THIS ONE SPENDS MONEY. buy_pro, buy_credits, buy_addon and buy_domain
    // are real tools on a real payment method, and deploy_to_vercel and
    // use_vercel_cli change what is serving production. All eleven are named
    // in writeTools, taken from Vercel's published tool table.
    //
    // VERCEL ALLOWLISTS CLIENTS. Their documentation says the server "only
    // supports AI clients that have been reviewed and approved by Vercel" and
    // names twelve; Bastion is not among them. Dynamic registration may
    // simply be refused, in which case the access-token mode is the way in
    // and this is worth an approach to Vercel rather than a workaround.
    BastionServer(
      id: "vercel",
      displayName: "Vercel",
      summary: "Vercel's own remote MCP server: projects, deployments, runtime logs, Web Analytics and documentation search.",
      transport: .remote(endpoint: URL(string: "https://mcp.vercel.com")!),
      docsURL: URL(string: "https://vercel.com/docs/agent-resources/vercel-mcp"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: ["deploy_to_vercel", "use_vercel_cli", "import-claude-design-from-url", "buy_pro", "buy_credits", "buy_addon", "buy_domain", "change_toolbar_thread_resolve_status", "reply_to_toolbar_thread", "edit_toolbar_message", "add_toolbar_reaction"],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Vercel",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "token",
          displayName: "Access token",
          kind: .env,
          env: ["VERCEL_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "VERCEL_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Vercel access token, sent as the bearer token. Scope it to one team if you can - this server can deploy code and spend money, and the token's own scopes are the only thing that stops it.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. Cloudflare runs seventeen separate hosted endpoints rather than
    // one; three of them are in this catalog - the API surface here, the
    // documentation search, and observability. The other fourteen (Radar,
    // Workers Bindings, Workers Builds, Browser Run, AI Gateway, Logpush,
    // GraphQL, DNS Analytics, Audit Logs, Container, AI Search, DEX, CASB and
    // the Agents SDK docs) are the same shape if anyone wants them.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // THE BROADEST SURFACE IN THE FILE. Cloudflare advertises this one as
    // 2,500+ API endpoints, which is most of an account behind a single
    // credential. The token's permissions are the boundary; the gate is not.
    //
    // NO writeTools LIST - 401 before enumeration. The annotation gate holds
    // writes, and on a surface this wide that is worth stating plainly to
    // anyone about to turn the gate off.
    BastionServer(
      id: "cloudflare",
      displayName: "Cloudflare",
      summary: "Cloudflare's own remote MCP server: the API surface across zones, DNS, Workers, R2 and the rest of the account.",
      transport: .remote(endpoint: URL(string: "https://mcp.cloudflare.com/mcp")!),
      docsURL: URL(string: "https://developers.cloudflare.com/agents/model-context-protocol/cloudflare/servers-for-cloudflare/"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Cloudflare",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "api-token",
          displayName: "API token",
          kind: .env,
          env: ["CLOUDFLARE_API_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "CLOUDFLARE_API_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Cloudflare API token, sent as the bearer token. Mint it against the specific zones and permissions you want reachable rather than reusing an account-wide token.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE, and the only entry in this file that needs no credential at
    // all. A POST of `initialize` with no Authorization header returns 200.
    // So authModes is empty, the way Shopify's is, and for the same reason:
    // there is nothing to authenticate.
    //
    // DIALECT MEASURED 2026-09-02, and it is the only one in this batch that
    // is. An unauthenticated handshake negotiates 2025-11-25 and serverInfo
    // reports docs-ai-search 0.4.13. Every other endpoint added alongside it
    // 401s before it will say, and carries a seeded value instead.
    //
    // TOOL LIST MEASURED 2026-09-02 as well, and it is read-only: exactly two
    // tools, search_cloudflare_documentation and migrate_pages_to_workers_guide,
    // both annotated readOnlyHint:true. There is no write surface to gate.
    //
    // Bastion still counts this entry as HAVING a write path, and that is not a
    // bug - "read-only" is not a claim the app can make about a remote server in
    // advance, so hasWritePath says yes for every remote entry. Over-reporting is
    // the safe direction and this note is the only place the difference is
    // written down.
    BastionServer(
      id: "cloudflare-docs",
      displayName: "Cloudflare Docs",
      summary: "Cloudflare's documentation search, as a remote MCP server. Needs no credential.",
      transport: .remote(endpoint: URL(string: "https://docs.mcp.cloudflare.com/mcp")!),
      docsURL: URL(string: "https://github.com/cloudflare/mcp-server-cloudflare/tree/main/apps/docs-ai-search"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "CLOUDFLARE_DOCS_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Not needed. This server answers unauthenticated, and a remote entry has to declare at least one variable somewhere for a value to land; leave it empty.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // REMOTE. A narrow read surface next to the full Cloudflare API entry:
    // Workers logs, analytics and traces, which is what you want open during
    // an incident without opening the account with it.
    //
    // DIALECT UNMEASURED. Seeded at 2025-11-25, which is what the one endpoint
    // in this family that answers unauthenticated actually negotiates. Every
    // other one 401s before it will say, so this number is a starting point and
    // not a measurement - RemoteInstance logs `dialect drift` on the first real
    // handshake and Activity shows what was negotiated. Correct this field from
    // that line. Stripe is the reason the distinction is written down: it was
    // carried at the default until a handshake proved it two revisions older.
    //
    // Its own variable rather than sharing CLOUDFLARE_API_TOKEN with the API
    // entry, because these are separate profiles against separate servers and
    // a token minted for reading logs should not have to be the token that
    // can edit DNS.
    BastionServer(
      id: "cloudflare-observability",
      displayName: "Cloudflare Observability",
      summary: "Cloudflare Workers logs and analytics, as a remote MCP server: query invocations, errors and traces.",
      transport: .remote(endpoint: URL(string: "https://observability.mcp.cloudflare.com/mcp")!),
      docsURL: URL(string: "https://github.com/cloudflare/mcp-server-cloudflare/tree/main/apps/workers-observability"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "oauth2",
          displayName: "Sign in with Cloudflare",
          kind: .oauth,
          env: [],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "api-token",
          displayName: "API token",
          kind: .env,
          env: ["CLOUDFLARE_OBSERVABILITY_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "CLOUDFLARE_OBSERVABILITY_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Cloudflare API token with Workers Observability read access, sent as the bearer token.",
          header: .init(name: "Authorization", format: "Bearer {value}")),
      ]),
    // No credentials, so no auth modes. What authorises this server is the trust
    // relationship between this Mac and the phone - pairing, Developer Mode, and
    // the separate Enable UI Automation toggle - none of which passes through a
    // profile. That is also why there is no auth_status tool to name here.
    //
    // Two lanes reach the device and they fail independently. `xcrun devicectl`
    // covers app lifecycle and needs nothing installed on the phone; everything
    // that sees or touches the screen goes through a WebDriverAgent runner the
    // user builds and starts themselves, reached over the IPv6 tunnel CoreDevice
    // already maintains. ios_device_diagnostics reports both separately, so
    // 'the device is fine, the runner is not up' is a distinguishable answer.
    //
    // The write gate is unusually load-bearing here. With it on, a model can tap
    // anything on an unlocked phone in someone's hand. IOS_DEVICE_LAUNCH_ARGS is
    // the mitigation worth setting beside it: it pins the app under test into a
    // fixture mode by default rather than its owner's real account.
    //
    // Published 2026-09-04 at 0.1.0, with a SLSA provenance attestation from the
    // tag-triggered CI job over OIDC. A 0.0.0 placeholder sits below it on npm:
    // OIDC cannot create a package name, so the name had to be claimed by hand
    // before CI could publish anything. Do not install that one.
    //
    // The package ships a second binary, ios-device-wda, which builds and starts
    // the WebDriverAgent runner. Bastion does not run it - it is a one-off the user
    // invokes themselves, and the screen tools stay unavailable, and say so, until
    // they have.
    BastionServer(
      id: "ios-device",
      displayName: "iOS Device",
      summary: "Drive a physical iPhone or iPad: screenshot, accessibility tree, tap, swipe, type, and app lifecycle.",
      transport: .child(
        .init(
          npmName: "@mgcrea/mcp-ios-device",
          binName: "ios-device-mcp",
          distribution: .npm,
          localPath: "mcp-ios-device",
          vendor: .mgcrea)),
      docsURL: URL(string: "https://github.com/mgcrea/mcp-ios-device"),
      dialect: .v2025_11_25,
      writeGate: "IOS_DEVICE_ALLOW_WRITES",
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: ["IOS_DEVICE_OUTPUT_DIR"],
      callbackEnv: [],
      env: [
        .init(
          name: "IOS_DEVICE_ID",
          isRequired: false,
          isSecret: false,
          summary: "CoreDevice identifier, UDID or name of the device to drive. Unset uses the only connected device; two connected and no value is an error that names them."),
        .init(
          name: "IOS_DEVICE_WDA_URL",
          isRequired: false,
          isSecret: false,
          summary: "Explicit WebDriverAgent URL. Unset derives it from the device's CoreDevice tunnel, which is the normal path and needs no port forwarding."),
        .init(
          name: "IOS_DEVICE_LAUNCH_ARGS",
          isRequired: false,
          isSecret: false,
          summary: "Launch arguments applied when a launch passes none, e.g. -CanopyDemoMode to open fixtures instead of the owner's real account."),
        .init(
          name: "IOS_DEVICE_OUTPUT_DIR",
          isRequired: false,
          isSecret: false,
          summary: "Where saved screenshots and pulled app containers land. Defaults to a directory under TMPDIR."),
        .init(
          name: "IOS_DEVICE_ALLOW_WRITES",
          isRequired: false,
          isSecret: false,
          summary: "Enables the nine tools that drive the device: tap, tap_element, swipe, type, press_button, install, launch, terminate, pull_container."),
      ]),
    // The first entry in this catalog that mgcrea did not write. Everything Bastion adds to it is the same as for any other child - one process instead of one per editor, the credential in the Keychain rather than in four config files, and a line in the audit log per call - and the one thing it does not add is any review of the code. `transport.vendor` says so out loud, and ServerDetail renders that rather than leaving it to be guessed from the package name.
    //
    // THE WRITE GATE IS INVERTED, and it is the reason `writeGateSense` exists. Every server written here names its gate `*_ALLOW_WRITES` and treats "1" as on. This one's switch is `MDB_MCP_READ_ONLY`, where "1" means the opposite, so a profile with writes off would have spawned a server with writes on - and the toggle, the profile editor and the Activity window would all have read as off while it happened. Bastion resolves the value through `BastionServer.gateValue(allowWrites:)`, which is the only place polarity is applied.
    //
    // Two auth modes because there are two different things to address. A connection string points at one deployment and carries its own password; an Atlas API key pair points at an account and is what the cluster-management tools use. Neither is required, because requiring either would make the other unsatisfiable.
    //
    // The variables are checked against the PUBLISHED TARBALL rather than against source, because there is no checkout of somebody else's repo to read. That check is by name rather than by read: this server hands its whole schema to a config library with `envPrefix: "MDB_MCP_"`, so `MDB_MCP_READ_ONLY` is never read by name anywhere in the shipped code - it is assembled at runtime. A rename upstream still takes the old name out of the bundle, which is the failure worth catching.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client. Asking for 2025-06-18 instead gets 2025-06-18 back from every one of these, which measures nothing.
    BastionServer(
      id: "mongodb",
      displayName: "MongoDB",
      summary: "MongoDB and Atlas: collections, documents, indexes, aggregations, and cluster administration.",
      transport: .child(
        .init(
          npmName: "mongodb-mcp-server",
          binName: "mongodb-mcp-server",
          distribution: .npm,
          localPath: "mongodb-mcp-server",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/mongodb-js/mongodb-mcp-server"),
      dialect: .v2025_11_25,
      writeGate: "MDB_MCP_READ_ONLY",
      writeGateEnablesWrites: false,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "connection-string",
          displayName: "Connection string",
          kind: .env,
          env: ["MDB_MCP_CONNECTION_STRING"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "atlas-api",
          displayName: "Atlas API key",
          kind: .env,
          env: ["MDB_MCP_API_CLIENT_ID", "MDB_MCP_API_CLIENT_SECRET"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "MDB_MCP_CONNECTION_STRING",
          isRequired: false,
          isSecret: true,
          summary: "The full MongoDB connection string, including its password. Addresses one deployment; the Atlas API key addresses an account."),
        .init(
          name: "MDB_MCP_API_CLIENT_ID",
          isRequired: false,
          isSecret: false,
          summary: "Atlas API public key, for the tools that manage clusters rather than query one."),
        .init(
          name: "MDB_MCP_API_CLIENT_SECRET",
          isRequired: false,
          isSecret: true,
          summary: "Atlas API private key."),
        .init(
          name: "MDB_MCP_READ_ONLY",
          isRequired: false,
          isSecret: false,
          summary: "Set from the profile's write toggle, never typed. Inverted: this server's switch turns writes OFF, so Bastion sends \"1\" when writes are off and \"0\" when they are on."),
      ]),
    // One entry for five database engines, because the server picks its driver from the DSN's scheme rather than from a setting. A profile per database is the unit that matters here, and that is what Bastion was already for: two DSNs are two credentials, and they have no business sharing a process or a Keychain entry.
    //
    // The gate is inverted - `READONLY` turns writes OFF - so `writeGateSense` is `disables` and the toggle's meaning is reversed for it. It is also the most consequential gate in this catalog: with writes on, this server will run whatever SQL a model composes.
    //
    // The DSN is the credential AND the address, which is why it is the only variable offered. The server also reads a `DB_*` set and an `SSH_*` tunnel group, left out because a profile editor with eleven connection fields is worse than one with a connection string - and the DSN is the form every one of these engines already documents.
    //
    // `READONLY` is a generic name for an environment shared with everything else the user runs, and that is the server's choice rather than Bastion's. It is set per profile and never globally, so nothing outside this server's own process sees it.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client. Asking for 2025-06-18 instead gets 2025-06-18 back from every one of these, which measures nothing. Worth having measured this one: it builds on @modelcontextprotocol/server 2.0.0, which KNOWS 2026-07-28, and still negotiates legacy. The newest revision an SDK knows is not the one a server speaks.
    BastionServer(
      id: "dbhub",
      displayName: "DBHub",
      summary: "SQL databases behind one server: PostgreSQL, MySQL, MariaDB, SQL Server and SQLite, over a single DSN.",
      transport: .child(
        .init(
          npmName: "@bytebase/dbhub",
          binName: "dbhub",
          distribution: .npm,
          localPath: "bytebase-dbhub",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/bytebase/dbhub"),
      dialect: .v2025_11_25,
      writeGate: "READONLY",
      writeGateEnablesWrites: false,
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "DSN",
          isRequired: true,
          isSecret: true,
          summary: "The whole connection string, including the password: postgres://user:pass@host:5432/db. Which database engine is being spoken to is read from its scheme."),
        .init(
          name: "READONLY",
          isRequired: false,
          isSecret: false,
          summary: "Set from the profile's write toggle, never typed. Inverted: this is a read-only switch, so Bastion sends \"1\" when writes are off."),
      ]),
    // A kubeconfig is not one credential, it is all of them: the default file names every cluster the user has ever touched, and a model asking for "the deployment" gets whichever context happened to be current. `K8S_CONTEXT` per profile is the point of this entry - one profile per cluster, each pinned, each with its own write toggle, so staging and production stop being one keystroke apart.
    //
    // The gate is inverted. `ALLOW_ONLY_READONLY_TOOLS` restricts rather than permits, so `writeGateSense` is `disables` and Bastion sends "1" for writes OFF. The server also reads `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS`, a middle setting that permits create and update but not delete. It is not offered: it sits between the two states the toggle has, and a second switch on the same wire is how the two drift apart. The stricter of the two is the one wired up.
    //
    // `K8S_SKIP_TLS_VERIFY` is read by the server and deliberately not offered. It is a boolean, third-party entries cannot declare booleans - nothing can check what their default is - and a free-text field for one is a trap: every server parsing these reads `yes` and `enable` as FALSE without complaining, which on a certificate check is the insecure direction.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client. Asking for 2025-06-18 instead gets 2025-06-18 back from every one of these, which measures nothing.
    BastionServer(
      id: "kubernetes",
      displayName: "Kubernetes",
      summary: "A Kubernetes cluster through kubectl and Helm: pods, deployments, services, logs, events and manifests.",
      transport: .child(
        .init(
          npmName: "mcp-server-kubernetes",
          binName: "mcp-server-kubernetes",
          distribution: .npm,
          localPath: "mcp-server-kubernetes",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/Flux159/mcp-server-kubernetes"),
      dialect: .v2025_11_25,
      writeGate: "ALLOW_ONLY_READONLY_TOOLS",
      writeGateEnablesWrites: false,
      writeTools: [],
      gateBypass: [],
      authModes: [
        .init(
          id: "kubeconfig",
          displayName: "Kubeconfig file",
          kind: .env,
          env: ["KUBECONFIG_PATH"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
        .init(
          id: "service-account",
          displayName: "Service account token",
          kind: .env,
          env: ["K8S_SERVER", "K8S_TOKEN"],
          loginTool: nil,
          statusTool: nil,
          logoutTool: nil),
      ],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "KUBECONFIG_PATH",
          isRequired: false,
          isSecret: false,
          summary: "Path to a kubeconfig file. Unset falls through to the server's own default of ~/.kube/config, which is every cluster the user has."),
        .init(
          name: "K8S_SERVER",
          isRequired: false,
          isSecret: false,
          summary: "API server URL, for reaching a cluster with a token instead of a kubeconfig."),
        .init(
          name: "K8S_TOKEN",
          isRequired: false,
          isSecret: true,
          summary: "Service account bearer token, paired with K8S_SERVER."),
        .init(
          name: "K8S_CONTEXT",
          isRequired: false,
          isSecret: false,
          summary: "Which context in the kubeconfig to use. The difference between staging and production is usually this one string."),
        .init(
          name: "K8S_NAMESPACE",
          isRequired: false,
          isSecret: false,
          summary: "Default namespace for operations that do not name one."),
        .init(
          name: "ALLOW_ONLY_READONLY_TOOLS",
          isRequired: false,
          isSecret: false,
          summary: "Set from the profile's write toggle, never typed. Inverted: this restricts the server to reads, so Bastion sends \"1\" when writes are off."),
      ]),
    // No write gate because there is no write path: every tool resolves a library name or fetches documentation. That claim is load-bearing rather than cosmetic - Bastion reads it as "every tool is a read" and stops asking for confirmation - so it is made only for a server where it is true.
    //
    // No auth modes, because "no credential at all" is not a mode that can be written down: a mode has to name at least one variable, and this server works without one. The key raises a rate limit rather than unlocking anything, so the honest shape is one optional variable and no modes.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client. Asking for 2025-06-18 instead gets 2025-06-18 back from every one of these, which measures nothing. Like DBHub, this one builds on the 2.0 SDK that knows 2026-07-28 and negotiates legacy anyway.
    BastionServer(
      id: "context7",
      displayName: "Context7",
      summary: "Up-to-date documentation and code examples for public libraries, fetched per version.",
      transport: .child(
        .init(
          npmName: "@upstash/context7-mcp",
          binName: "context7-mcp",
          distribution: .npm,
          localPath: "upstash-context7-mcp",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/upstash/context7"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "CONTEXT7_API_KEY",
          isRequired: false,
          isSecret: true,
          summary: "Raises the rate limit. The server answers without one, at a lower limit, which is why this is not required."),
      ]),
    // No write gate: nothing here changes anything the user owns. It does SPEND, though - a crawl bills per page - and that is a limit a write toggle was never going to express. The real bound is the key's own plan, which is the same thing the remote entries say about scopes.
    //
    // The server reads a long `FIRECRAWL_MCP_*` group for running itself as a hosted HTTP service with its own OAuth. None of it is offered: Bastion speaks stdio to a child it spawned, so a server configuring its own listener is configuring something Bastion does not use. `FIRECRAWL_API_URL`, which points at a self-hosted instance, is left out for the same reason the other base-URL overrides are.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client. Asking for 2025-06-18 instead gets 2025-06-18 back from every one of these, which measures nothing. This one does not use the official SDK at all - it is built on fastmcp - so a reading of its dependencies would have said nothing, and the handshake was the only way to know.
    BastionServer(
      id: "firecrawl",
      displayName: "Firecrawl",
      summary: "Web scraping and crawling as structured content: scrape a page, crawl a site, extract fields, search.",
      transport: .child(
        .init(
          npmName: "firecrawl-mcp",
          binName: "firecrawl-mcp",
          distribution: .npm,
          localPath: "firecrawl-mcp",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/firecrawl/firecrawl-mcp-server"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "FIRECRAWL_API_KEY",
          isRequired: true,
          isSecret: true,
          summary: "Firecrawl API key. The server will not start without one."),
      ]),
    // No write gate: every tool is a search or a fetch.
    //
    // This package declares no `license` field in its package.json, unlike every other entry here. The repository states MIT; the published artefact does not say so, and anyone whose review depends on the manifest should know that before installing it rather than after.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client. Asking for 2025-06-18 instead gets 2025-06-18 back from every one of these, which measures nothing. The declared @modelcontextprotocol/sdk range is ^1.12.1, but the package ships a bundled copy, so the declaration was never going to be the answer.
    BastionServer(
      id: "exa",
      displayName: "Exa",
      summary: "Exa neural search: web search, company and people research, and full page contents.",
      transport: .child(
        .init(
          npmName: "exa-mcp-server",
          binName: "exa-mcp-server",
          distribution: .npm,
          localPath: "exa-mcp-server",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/exa-labs/exa-mcp-server"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "EXA_API_KEY",
          isRequired: true,
          isSecret: true,
          summary: "Exa API key."),
      ]),
    // No write gate: every tool is a search or a fetch.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client. Asking for 2025-06-18 instead gets 2025-06-18 back from every one of these, which measures nothing.
    BastionServer(
      id: "tavily",
      displayName: "Tavily",
      summary: "Tavily search: web search built for agents, plus page extraction, site mapping and crawling.",
      transport: .child(
        .init(
          npmName: "tavily-mcp",
          binName: "tavily-mcp",
          distribution: .npm,
          localPath: "tavily-mcp",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/tavily-ai/tavily-mcp"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: [],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "TAVILY_API_KEY",
          isRequired: true,
          isSecret: true,
          summary: "Tavily API key."),
      ]),
    // The most-installed MCP server on npm, and the entry that makes the point of the app rather than the point of the catalog: a browser is expensive to start and stateful once it is running, so one supervised instance shared by every editor is the difference this app exists for. Four clients pointed at the same profile drive one browser, not four.
    //
    // `PLAYWRIGHT_MCP_USER_DATA_DIR` is in `stateEnv` for the reason mcp-reddit's token file is: a browser profile holds cookies and live sessions, so two Bastion profiles sharing one directory are two identities sharing one login. Each gets its own.
    //
    // GATED BY TOOL NAME, not by an environment variable, and it is the second shape of write gate rather than a weaker one. Most children read a `*_ALLOW_WRITES` variable at startup and never register the tool at all, which is stronger than anything Bastion can do from outside. This server's own read-only switch is a COMMAND-LINE FLAG, and Bastion passes no argv - that is the KEPT rule, and it is not being reopened for a convenience. So the gate moves to the only thing Bastion controls: what it forwards. The named tools are absent from tools/list with writes off, and refused if a client names one from a cached list.
    //
    // The alternative was `writeGate: null`, and that would have been the worst of the three: ToolProbe reads a null gate as "every tool is a read" and stops asking for confirmation. A server that can act on the world must never be written down that way.
    //
    // SAY THE LIMIT OUT LOUD. This filters Bastion, not the server. Anything holding this credential can call the same API directly; the real boundary is the scopes the credential itself carries.
    //
    // The list was read off the server's own annotations rather than invented: every tool it ships carries a `readOnlyHint`, and these seventeen are the ones marked false. Bastion gates annotated tools anyway, so a mutating tool added after this list was written is still caught - the list is the floor, not the ceiling.
    //
    // It holds no credential of its own, which does not make it safe: it drives a browser that is already logged into things. `PLAYWRIGHT_MCP_ALLOWED_ORIGINS` is offered for that, and left unset means everywhere.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client.
    BastionServer(
      id: "playwright",
      displayName: "Playwright",
      summary: "Drive a real browser: navigate, snapshot the accessibility tree, click, type, fill forms and read network traffic.",
      transport: .child(
        .init(
          npmName: "@playwright/mcp",
          binName: "playwright-mcp",
          distribution: .npm,
          localPath: "playwright-mcp",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/microsoft/playwright-mcp"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: ["browser_click", "browser_close", "browser_drag", "browser_drop", "browser_evaluate", "browser_file_upload", "browser_fill_form", "browser_handle_dialog", "browser_hover", "browser_navigate", "browser_navigate_back", "browser_press_key", "browser_resize", "browser_run_code_unsafe", "browser_select_option", "browser_tabs", "browser_type"],
      gateBypass: [],
      authModes: [],
      stateEnv: ["PLAYWRIGHT_MCP_USER_DATA_DIR"],
      callbackEnv: [],
      env: [
        .init(
          name: "PLAYWRIGHT_MCP_BROWSER",
          isRequired: false,
          isSecret: false,
          summary: "Which browser to drive: chrome, firefox, webkit, msedge. Unset uses the server's own default of chrome."),
        .init(
          name: "PLAYWRIGHT_MCP_USER_DATA_DIR",
          isRequired: false,
          isSecret: false,
          summary: "The browser profile directory, which holds cookies and logged-in sessions. Redirected per profile by Bastion."),
        .init(
          name: "PLAYWRIGHT_MCP_ALLOWED_ORIGINS",
          isRequired: false,
          isSecret: false,
          summary: "Semicolon-separated origins the browser may reach. Unset means all of them, which is the setting worth thinking about before a model drives this."),
      ]),
    // GATED BY TOOL NAME, not by an environment variable, and it is the second shape of write gate rather than a weaker one. Most children read a `*_ALLOW_WRITES` variable at startup and never register the tool at all, which is stronger than anything Bastion can do from outside. This server's own read-only switch is a COMMAND-LINE FLAG, and Bastion passes no argv - that is the KEPT rule, and it is not being reopened for a convenience. So the gate moves to the only thing Bastion controls: what it forwards. The named tools are absent from tools/list with writes off, and refused if a client names one from a cached list.
    //
    // The alternative was `writeGate: null`, and that would have been the worst of the three: ToolProbe reads a null gate as "every tool is a read" and stops asking for confirmation. A server that can act on the world must never be written down that way.
    //
    // SAY THE LIMIT OUT LOUD. This filters Bastion, not the server. Anything holding this credential can call the same API directly; the real boundary is the scopes the credential itself carries.
    //
    // The eleven names were read off the server's own `readOnlyHint` annotations, which it sets on all twenty-nine of its tools.
    //
    // PROJECT SCOPING IS NOT AVAILABLE PER PROFILE. The server takes `--project-ref` as a command-line flag and reads no environment variable for it, so a profile cannot pin one project the way the Kubernetes entry pins one context. The token reaches the whole account, and `apply_migration` and `execute_sql` are in the list above for a reason. A token scoped narrowly by Supabase is the only real limit.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client.
    BastionServer(
      id: "supabase",
      displayName: "Supabase",
      summary: "Supabase projects: tables, migrations, SQL, edge functions, branches, logs and advisors.",
      transport: .child(
        .init(
          npmName: "@supabase/mcp-server-supabase",
          binName: "mcp-server-supabase",
          distribution: .npm,
          localPath: "supabase-mcp-server-supabase",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/supabase/mcp"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: ["apply_migration", "create_branch", "create_project", "delete_branch", "deploy_edge_function", "execute_sql", "merge_branch", "pause_project", "rebase_branch", "reset_branch", "restore_project"],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "SUPABASE_ACCESS_TOKEN",
          isRequired: true,
          isSecret: true,
          summary: "Supabase personal access token. It reaches every project in the account, which is why the scope of the token is the real boundary here."),
      ]),
    // The counterpart to the Vercel entry, and a good illustration of the two shapes: Vercel operates a remote endpoint, so Bastion relays to it and gates by tool name; Netlify publishes an npm package, so Bastion runs it here - and gates by tool name anyway, because it has no environment switch either.
    //
    // GATED BY TOOL NAME, not by an environment variable, and it is the second shape of write gate rather than a weaker one. Most children read a `*_ALLOW_WRITES` variable at startup and never register the tool at all, which is stronger than anything Bastion can do from outside. This server's own read-only switch is a COMMAND-LINE FLAG, and Bastion passes no argv - that is the KEPT rule, and it is not being reopened for a convenience. So the gate moves to the only thing Bastion controls: what it forwards. The named tools are absent from tools/list with writes off, and refused if a client names one from a cached list.
    //
    // The alternative was `writeGate: null`, and that would have been the worst of the three: ToolProbe reads a null gate as "every tool is a read" and stops asking for confirmation. A server that can act on the world must never be written down that way.
    //
    // SAY THE LIMIT OUT LOUD. This filters Bastion, not the server. Anything holding this credential can call the same API directly; the real boundary is the scopes the credential itself carries.
    //
    // This server splits its surface into readers and updaters by name, so the three gated tools are the three ending in `-updater`, and its own annotations agree.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client.
    BastionServer(
      id: "netlify",
      displayName: "Netlify",
      summary: "Netlify projects and deploys: read teams, projects and deploy state, and update them.",
      transport: .child(
        .init(
          npmName: "@netlify/mcp",
          binName: "netlify-mcp",
          distribution: .npm,
          localPath: "netlify-mcp",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/netlify/netlify-mcp"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: ["netlify-deploy-services-updater", "netlify-extension-services-updater", "netlify-project-services-updater"],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "NETLIFY_PERSONAL_ACCESS_TOKEN",
          isRequired: true,
          isSecret: true,
          summary: "Netlify personal access token."),
      ]),
    // GATED BY TOOL NAME, not by an environment variable, and it is the second shape of write gate rather than a weaker one. Most children read a `*_ALLOW_WRITES` variable at startup and never register the tool at all, which is stronger than anything Bastion can do from outside. This server's own read-only switch is a COMMAND-LINE FLAG, and Bastion passes no argv - that is the KEPT rule, and it is not being reopened for a convenience. So the gate moves to the only thing Bastion controls: what it forwards. The named tools are absent from tools/list with writes off, and refused if a client names one from a cached list.
    //
    // The alternative was `writeGate: null`, and that would have been the worst of the three: ToolProbe reads a null gate as "every tool is a read" and stops asking for confirmation. A server that can act on the world must never be written down that way.
    //
    // SAY THE LIMIT OUT LOUD. This filters Bastion, not the server. Anything holding this credential can call the same API directly; the real boundary is the scopes the credential itself carries.
    //
    // `call-actor` is the one that matters, and it is gated for a reason that is not quite "writes": running an Actor executes somebody else's code in Apify's cloud and BILLS for it. The write toggle is the closest control this catalog has to "may spend money", and the mapping is worth saying out loud rather than leaving to be discovered on an invoice.
    //
    // DIALECT MEASURED. A live `initialize` that asks for 2026-07-28 - a revision no server here supports - is answered with this server's own newest, which is how a server is made to name it rather than echo the client.
    BastionServer(
      id: "apify",
      displayName: "Apify",
      summary: "Apify Actors: search the store, inspect an Actor, run one, and read its dataset and key-value store.",
      transport: .child(
        .init(
          npmName: "@apify/actors-mcp-server",
          binName: "actors-mcp-server",
          distribution: .npm,
          localPath: "apify-actors-mcp-server",
          vendor: .thirdParty)),
      docsURL: URL(string: "https://github.com/apify/apify-mcp-server"),
      dialect: .v2025_11_25,
      writeGate: nil,
      writeTools: ["abort-actor-run", "call-actor", "report-problem"],
      gateBypass: [],
      authModes: [],
      stateEnv: [],
      callbackEnv: [],
      env: [
        .init(
          name: "APIFY_TOKEN",
          isRequired: true,
          isSecret: true,
          summary: "Apify API token."),
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
