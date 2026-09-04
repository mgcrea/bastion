import AppKit
import SwiftUI

/// Screenshot mode: the app photographed instead of the app used.
///
/// Everything here is inert unless `-ScreenshotMode YES` is on the command
/// line, which `appshot capture` passes and nothing else does. Launch
/// arguments land in `NSArgumentDomain`, so they are readable through
/// `UserDefaults` with no plumbing at all and they apply to that launch only —
/// a developer's normal runs are untouched, and none of this can ship enabled.
///
/// It exists because a screenshot of this app is otherwise a screenshot of
/// *this machine*. Bastion is the worst possible subject for a naive capture:
/// the server list is whatever the developer installed, the profile rows name
/// their real accounts, the licence pane puts a real 240-character key in a
/// text editor, and `ClientDetail` opens `~/.claude.json` and renders every
/// hand-configured server's argv — tokens included — above one heading per
/// project folder they have ever opened.
///
/// The rule for anything added here: a fact the screen shows must be *fixed*,
/// never merely *plausible*. Two runs a week apart have to produce comparable
/// images, or the golden gate in `make screenshots-check` is decorative.
///
/// **`DemoSeed` is not `DevSeed`, and the two must never merge.** `DevSeed` is
/// a Debug-only credential *importer*: it mints a real gateway token, writes
/// secrets to the Keychain and persists `profiles.json`. The rule that keeps
/// them apart is one sentence — *`DevSeed` only writes; `DemoSeed` never
/// writes.* Not a Keychain item, not a file in `AppSupport.directory`, and not
/// even a `UserDefaults` key, because a capture runs against the user's real
/// preference domain. See the autosave guard in `HostedWindow`, which is what
/// that last clause was learned from.
///
/// Deliberately **not** `#if DEBUG`. The plates are captured from a Release
/// build — `AppInfo.isDebugBuild` says why — so this has to compile into one.
/// What keeps it inert is the launch argument, not the configuration.
///
/// Deliberately **not** `@MainActor` as a whole, either. Several of its callers
/// are nonisolated — `AppInfo.version`, `CredentialStore.storedVariables`,
/// `ClientWiring.prefix`'s neighbours, `ServerInstaller`'s three static
/// lookups — and isolating the type would push `await` into all of them for
/// values that are a `UserDefaults` read and a table lookup. The members that
/// touch AppKit carry the annotation individually.
enum DemoSeed {

  // MARK: - Launch arguments

  /// The names `appshot` passes by default. Changing one means changing the
  /// Makefile's `--extra-args` in the same commit.
  nonisolated private enum Key {
    static let mode = "ScreenshotMode"
    static let stage = "ScreenshotStage"
    static let appearance = "ScreenshotAppearance"
    static let readyFile = "ScreenshotReadyFile"
  }

  /// The argument domain only, never `UserDefaults.standard` as a whole.
  ///
  /// `standard` also reads the persisted domain, so one `defaults write` of
  /// `ScreenshotMode` would put a release build into demo mode on every launch
  /// — and `stage`, which traps on a value it does not know, would then trap on
  /// every launch after it. Launch arguments are the only place these belong,
  /// and they apply to one launch, which is the property the header describes.
  nonisolated private static func argument(_ key: String) -> String? {
    let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    switch arguments[key] {
    case let value as String: return value
    case let value as Bool: return value ? "YES" : "NO"
    case let value as NSNumber: return value.stringValue
    default: return nil
    }
  }

  nonisolated static var isEnabled: Bool {
    guard let raw = argument(Key.mode)?.lowercased() else { return false }
    return ["yes", "true", "1"].contains(raw)
  }

  // MARK: - Stages

  /// Which screen this launch is for.
  ///
  /// The staged driver reaches a screen by relaunching rather than by
  /// navigating, so there is one process per screen and this is read once.
  /// That is the trade: six launches instead of one, in exchange for a pipeline
  /// that never touches the accessibility tree and therefore cannot be broken
  /// by renaming a label.
  ///
  /// The names match `MainPane`'s own raw values wherever there is one, so
  /// `pane` below is a near-identity switch and a mismatch is visible at a
  /// glance rather than by reading two files.
  nonisolated enum Stage: String, CaseIterable {
    case server
    case running
    case log
    case client
    case chat
    case licence

    static var allNames: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// Which window the shutter is aimed at.
    ///
    /// `licence` is the stage that is not the main window, and it is the one
    /// most likely to fail *silently*: appshot photographs the largest ordinary
    /// window, so leaving the main window on screen captures that instead — at
    /// exactly the right size, showing a real screen, with nothing in the run
    /// saying a word. `openStagedWindow()` below is what stops it: the main
    /// window is simply never opened on this stage.
    var subject: Subject {
      switch self {
      case .licence: .settings(.licence)
      case .server, .running, .log, .client, .chat: .main
      }
    }

    /// Where the main window's sidebar selection starts.
    var pane: MainPane {
      switch self {
      // Shopify rather than any other: it is the only fixture server with two
      // profiles, which is what makes the Profiles card show a complete row and
      // an incomplete one together — the pairing the caption is about.
      case .server: .server("shopify")
      case .running: .running
      case .log: .log
      // Claude Code rather than Claude Desktop, and the choice is the plate:
      // this is the client whose config carries hand-configured servers and
      // project blocks, so it is the only one where the "other servers in this
      // file" card has anything in it.
      case .client: .client("claude-code")
      case .chat: .chat
      // Never seen: `openStagedWindow()` never builds `MainView` on this stage,
      // so this exists only because the switch must be exhaustive.
      case .licence: .running
      }
    }

    /// Which view's `.task` is allowed to report readiness for this stage.
    var readySource: ReadySource {
      switch self {
      case .licence: .settings
      case .server, .running, .log, .client, .chat: .main
      }
    }
  }

  enum Subject {
    case main
    case settings(SettingsPane)
  }

  /// Which view reported that its screen is ready.
  ///
  /// `MainView` and `LicencePane` both call `signalReady(from:)` from their own
  /// `.task`, and only the one matching the current stage's `readySource` is
  /// honoured. `openStagedWindow()` means only one of the two is built on any
  /// given stage, so today the check never fires — it is here because the
  /// failure it prevents is silent and the cost is a switch. The moment
  /// anything opens both windows, whichever view rendered first would report a
  /// screen the shutter is not aimed at.
  enum ReadySource {
    case main
    case settings
  }

  /// Deliberately non-optional, with no fallback to a default screen.
  ///
  /// A stage argument that does not parse must be loud. The silent version of
  /// this bug produces a valid, correctly sized, good-looking capture of the
  /// *wrong* screen, filed under the right name — which is the one screenshot
  /// failure that is genuinely hard to see by eye, and the reason
  /// `appshot accept` refuses a set containing two identical images.
  nonisolated static var stage: Stage {
    let raw = argument(Key.stage) ?? ""
    guard let stage = Stage(rawValue: raw) else {
      fatalError("-\(Key.stage) was '\(raw)' — expected one of \(Stage.allNames)")
    }
    return stage
  }

  // MARK: - Entry points

  /// Called from `applicationDidFinishLaunching`, before anything real starts.
  ///
  /// Order matters: the appearance and the ambient formatting are pinned before
  /// any view is built, the stores are seeded before the window that reads them
  /// opens, and the window observers are installed before the window exists.
  @MainActor static func apply() {
    pinAppearance()
    pinFormatting()
    seedStores()
    observeWindows()
  }

  /// The one window this launch opens, chosen by the stage.
  ///
  /// Opening the *right* window is the whole of the secondary-window problem,
  /// and it is worth saying why it is solved here rather than by hiding the
  /// wrong one later. appshot photographs the largest ordinary window, so the
  /// obvious approach — open both, then `orderOut` the main one before the
  /// shutter — has to run at activation time, and that is exactly when appshot
  /// is resolving its window list in two steps (`CGWindowListCopyWindowInfo`
  /// for ids and z-order, then `SCShareableContent` for the images). Reordering
  /// windows between those two steps makes the ids stop matching and kills the
  /// run on a random shot.
  ///
  /// It also deadlocks against `--ready-file`: appshot waits for the readiness
  /// signal *before* it activates, so a presentation driven off
  /// `didBecomeActive` never runs and the run fails with "the app never
  /// signalled ready" on the settings shot.
  ///
  /// Never opening the second window is strictly simpler than hiding it, and
  /// there is nothing left to race.
  @MainActor static func openStagedWindow() {
    switch stage.subject {
    case .main: MainWindowController.show()
    case .settings: SettingsWindowController.show()
    }
  }

  // MARK: - Ambient state

  /// The appearance is forced per launch rather than left to System Settings,
  /// which is what makes `--appearances` mean anything: appshot launches once
  /// per appearance and the *app* decides, not the Mac.
  @MainActor private static func pinAppearance() {
    switch argument(Key.appearance) {
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    default: break
    }
  }

  /// `LogPane` renders `HH:mm:ss` through a `DateFormatter`, which reads the
  /// process's default time zone. Fixed instants are therefore only half of
  /// determinism — the same `Date` prints 09:41 in Paris and 08:41 in London,
  /// so a golden accepted here fails on a machine one time zone over, in a way
  /// that looks like a UI change.
  ///
  /// Pinning the default zone rather than each formatter keeps this in one
  /// place. The locale is pinned from the Makefile instead, because
  /// `Text(_:format:)` reads `Locale.current` rather than anything settable
  /// here.
  nonisolated private static func pinFormatting() {
    if let utc = TimeZone(identifier: "UTC") { NSTimeZone.default = utc }
  }

  // MARK: - The two clocks

  /// An absolute instant, for anything rendered as a wall-clock time.
  ///
  /// 2026-01-15 09:41:00 UTC. 09:41 is Apple's own convention for a product
  /// shot, and it is already the time `apps/website/src/components/Hero.astro`
  /// draws in its menu bar — so the real capture and the hand-drawn mock beside
  /// it agree rather than reading as two different products.
  nonisolated private static func at(_ minute: Int, _ second: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 15
    components.hour = 9
    components.minute = minute
    components.second = second
    components.timeZone = TimeZone(identifier: "UTC")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    // The components are a literal above, so this cannot fail; a crash here
    // beats seeding `Date()` and quietly reintroducing the clock.
    return calendar.date(from: components)!
  }

  /// Launch-relative, for anything rendered as an ELAPSED duration.
  ///
  /// The second clock exists because `InstanceRow.uptime` computes
  /// `Date().timeIntervalSince(startedAt)` under a one-second `TimelineView`. A
  /// fixed absolute `startedAt` would read "up 4h 12m" today and "up 9h 3m"
  /// tomorrow, so the `running` golden would break every single day with no
  /// code change.
  ///
  /// Callers must pick offsets **away from the unit boundaries** the row
  /// formats at. `ago(2 * 3600 + 14 * 60)` always renders "up 2h 14m";
  /// `ago(3599)` is a coin flip between "up 59m" and "up 1h 0m".
  ///
  /// The two clocks never meet on one pane today — `RunningPane` shows only
  /// elapsed, `LogPane` only absolute — and the first thing that would break
  /// that is adding a "last call at" line to `InstanceRow`.
  nonisolated private static func ago(_ seconds: TimeInterval) -> Date {
    Date().addingTimeInterval(-seconds)
  }

  // MARK: - Identity

  /// The version the plates claim.
  ///
  /// Pinned rather than read, so a release does not churn every golden. Bump it
  /// deliberately, in the commit that re-captures.
  nonisolated static let version = "1.4.1"

  /// A licence that is rendered and never verified. See `LicenseStore.demoKey`.
  nonisolated static let license = License(
    id: "lic_demo", email: "you@example.com", major: 1, issuedAt: "2026-01-04")

  /// Where a shipped bridge lives, rather than where this build's happens to.
  nonisolated static let bridgePath = "/Applications/Bastion.app/Contents/Helpers/bastion-bridge"

  // MARK: - Fixture hosts

  /// Every hostname in the fixtures is unreachable by construction.
  ///
  /// `acme` is the universal fiction marker, and `.example` is reserved by
  /// RFC 2606 — so none of these can ever turn out to be somebody's real box,
  /// which a plausible-looking `unifi.local` or a real-looking store handle
  /// very much could. `Hero.astro` names "a screenshot of a Debug build with
  /// somebody's real store domain in it" as the thing to avoid; this is the
  /// clause that avoids it.
  nonisolated private enum Host {
    static let shopify = "acme.myshopify.com"
    static let keycloak = "https://auth.acme.example"
    static let unifi = "unifi.acme.example"
  }

  // MARK: - Servers

  /// The installed list, resolved through the real catalog.
  ///
  /// Resolved rather than hand-built, so the Environment table on the `server`
  /// plate is the *product's* env list: a variable added to Shopify shows up in
  /// the golden diff, where a typed-out copy would go stale in silence.
  ///
  /// `reddit` is here specifically to be **not installed** — see
  /// `isInstalled(_:)` — so the sidebar's orange badge and `ServerDetail`'s
  /// Install button both get a picture.
  nonisolated static var servers: [BastionServer] {
    [BuiltinServer.definition]
      + ["shopify", "keycloak", "unifi-network", "stripe", "reddit"]
      .compactMap { ServerCatalog.byID[$0] }
  }

  /// What is on disk for each, or nil for the one that is not.
  nonisolated static func installedVersion(of server: BastionServer) -> String? {
    switch server.id {
    case "shopify": "1.4.2"
    case "keycloak": "0.9.1"
    case "unifi-network": "2.1.0"
    default: nil
    }
  }

  /// The protocol the installed code speaks, and the SDK that decides it.
  ///
  /// Deliberately the *agreeing* case on every entry. The disagreeing branch
  /// renders an orange `arrow.triangle.branch` warning saying the installed
  /// code speaks a newer protocol than the manifest — which is true and useful
  /// in the product, and reads as a bug in a marketing image.
  nonisolated static func protocolCeiling(of server: BastionServer)
    -> (protocol: String, sdk: String)?
  {
    guard installedVersion(of: server) != nil else { return nil }
    return (protocol: "2025-11-25", sdk: "1.20.0")
  }

  nonisolated static func isInstalled(_ server: BastionServer) -> Bool {
    // The same rule the real one applies: nothing to install means nothing
    // missing, which covers Bastion's own server and the remote Stripe entry.
    guard server.package != nil else { return true }
    return installedVersion(of: server) != nil
  }

  // MARK: - Profiles

  /// The profiles, and the authority is the website.
  ///
  /// `apps/website/src/components/Hero.astro` already names five
  /// `<profile>/<server>` pairs in its `MENU` array, and its `Marquee.astro`
  /// puts them on the page beside these images. This is a hand-kept mirror of
  /// that list, the way cupertino's `heroTurnLogLines` mirrors its site's
  /// `HERO_TURN`. **Nothing enforces the mirror** — change the two together.
  ///
  /// Each row earns a distinct state on the `server` plate:
  /// `prod/shopify` complete, `staging/shopify` one secret short.
  nonisolated static var profiles: [Profile] {
    [
      Profile(
        name: "prod", serverID: "shopify",
        values: ["SHOPIFY_STORE_DOMAIN": Host.shopify, "SHOPIFY_CLIENT_ID": "acme-admin"],
        allowWrites: false, captureMode: nil),
      Profile(
        name: "staging", serverID: "shopify",
        values: [
          "SHOPIFY_STORE_DOMAIN": "acme-staging.myshopify.com",
          "SHOPIFY_CLIENT_ID": "acme-staging-admin",
        ],
        allowWrites: false, captureMode: nil),
      Profile(
        name: "acme", serverID: "keycloak",
        values: ["KEYCLOAK_URL": Host.keycloak, "KEYCLOAK_REALM": "engineering"],
        allowWrites: false, captureMode: nil),
      Profile(
        name: "home", serverID: "unifi-network",
        values: ["UNIFI_HOST": Host.unifi],
        allowWrites: false, captureMode: nil),
      // The one profile with writes on, so the orange `writes` badge on the
      // `running` plate has a picture. `unifi-network` declares
      // `UNIFI_ALLOW_WRITES`, so `hasWritePath` is true and the toggle means
      // something — which it would not on `shopify`, whose write gate is nil.
      Profile(
        name: "lab", serverID: "unifi-network",
        values: ["UNIFI_HOST": Host.unifi],
        allowWrites: true, captureMode: nil),
    ]
  }

  /// Which secrets each profile holds, standing in for the Keychain.
  ///
  /// One deliberate omission — `staging/shopify` has no `SHOPIFY_CLIENT_SECRET`
  /// — and that single gap is the entire "what a profile still needs" claim on
  /// the `server` plate. `ProfileRow` renders it as
  /// "cannot start — missing SHOPIFY_CLIENT_SECRET" in orange, beside a `prod`
  /// row that is ready.
  nonisolated static func storedVariables(profile: String, server: String) -> Set<String> {
    switch "\(profile)/\(server)" {
    case "prod/shopify": ["SHOPIFY_CLIENT_SECRET"]
    case "staging/shopify": []
    case "acme/keycloak": ["KEYCLOAK_CLIENT_SECRET"]
    case "home/unifi-network", "lab/unifi-network": ["UNIFI_API_KEY"]
    default: []
    }
  }

  // MARK: - The activity log

  /// The log fixture, and the rule that shapes it is Bastion's own footer.
  ///
  /// `LogPane` says, underneath this list, that Bastion records *what a tool
  /// was called with* — and that credentials are never among it. That is the
  /// opposite of cupertino's promise, so it is the opposite fixture: arguments
  /// and results are on the rows here rather than kept off them, because a
  /// plate with none would contradict the sentence printed under it. The
  /// `«redacted»` row is the other half of the same claim, and it is not
  /// decoration: `CallCapture` is what puts that string there in production.
  ///
  /// Long enough to fill the pane. A log with a dozen lines and six hundred
  /// points of empty below it photographs as a product nobody uses. All three
  /// levels appear, since `FeedRow` tints them differently and a fixture that
  /// only exercises `.call` shows none of that.
  ///
  /// Exactly one `arguments` payload is over `FeedRow.preview`'s 160 characters,
  /// so the `Show all N characters` link renders once. It is a real affordance,
  /// and a plate that never shows it undersells the pane.
  private struct Line {
    let origin: String
    let level: LogStore.Level
    let text: String
    var arguments: String?
    var result: String?
    var failed = false
  }

  private static let logLines: [Line] = [
    Line(origin: "gateway", level: .info, text: "listening on http://127.0.0.1:8720"),
    Line(origin: "prod/shopify", level: .info, text: "initialize"),
    Line(origin: "prod/shopify", level: .info, text: "handshake complete (protocol 2025-11-25)"),
    Line(origin: "prod/shopify", level: .info, text: "tools/list — 24 tools"),
    Line(
      origin: "prod/shopify", level: .call, text: "shopify_list_products",
      arguments: #"{"first":20,"sortKey":"UPDATED_AT"}"#,
      result: #"{"products":[{"id":"gid://shopify/Product/81…","title":"Trail Cap"},…]}"#),
    Line(
      origin: "prod/shopify", level: .call, text: "shopify_get_order",
      arguments: #"{"id":"gid://shopify/Order/5512004"}"#,
      // Two hashes: the order name starts `#`, and `"#` inside a single-hash raw
      // string is its terminator.
      result: ##"{"name":"#1042","displayFulfillmentStatus":"FULFILLED"}"##),
    Line(origin: "acme/keycloak", level: .info, text: "started (pid 41883)"),
    Line(origin: "acme/keycloak", level: .info, text: "allowWrites=false"),
    Line(
      origin: "acme/keycloak", level: .call, text: "keycloak_list_realms",
      arguments: "{}", result: #"{"realms":["master","engineering"]}"#),
    // The redaction claim, pictured. `CallCapture.redacted` is the same string
    // the production path substitutes, and it is spelled through the constant
    // rather than typed so the two cannot drift.
    Line(
      origin: "acme/keycloak", level: .call, text: "keycloak_get_client",
      arguments: #"{"clientId":"bastion","client_secret":"\#(CallCapture.redacted)"}"#,
      result: #"{"enabled":true,"protocol":"openid-connect"}"#),
    Line(
      origin: "acme/keycloak", level: .call, text: "keycloak_list_users",
      arguments: #"{"realm":"engineering","max":10}"#,
      result: #"{"users":[{"username":"ada"},{"username":"grace"}]}"#),
    Line(origin: "home/unifi-network", level: .info, text: "initialize"),
    Line(origin: "home/unifi-network", level: .info, text: "allowWrites=false"),
    Line(
      origin: "home/unifi-network", level: .call, text: "unifi_list_devices",
      arguments: #"{"site":"default"}"#,
      result: #"{"devices":[{"name":"Dream Machine","state":"ONLINE"},…]}"#),
    Line(
      origin: "home/unifi-network", level: .call, text: "unifi_list_clients",
      arguments: #"{"site":"default","limit":50}"#,
      result: #"{"clients":[{"hostname":"studio-imac","ip":"192.168.1.24"},…]}"#),
    // The one over-long payload, so `Show all N characters` renders exactly
    // once in the pane.
    Line(
      origin: "prod/shopify", level: .call, text: "shopify_search_products",
      arguments:
        #"{"query":"status:active AND inventory_total:>0 AND product_type:'Outerwear'","first":50,"sortKey":"INVENTORY_TOTAL","reverse":true,"savedSearchId":null,"includeMetafields":true}"#,
      result: #"{"products":[…31 matches…]}"#),
    Line(origin: "lab/unifi-network", level: .info, text: "started (pid 42104)"),
    Line(origin: "lab/unifi-network", level: .info, text: "allowWrites=true"),
    Line(
      origin: "lab/unifi-network", level: .call, text: "unifi_get_port_profile",
      arguments: #"{"site":"lab","id":"pf_7"}"#,
      result: #"{"name":"Uplink","poeMode":"auto"}"#),
    // A failed call, so `FeedRow`'s warning triangle has a picture.
    Line(
      origin: "lab/unifi-network", level: .call, text: "unifi_update_wlan",
      arguments: #"{"site":"lab","id":"wl_2","enabled":true}"#,
      result: #"{"error":"device is adopting, try again"}"#, failed: true),
    // And an error line, which is tinted red and is a different fact from a
    // call that came back with an error in it.
    Line(
      origin: "lab/unifi-network", level: .error,
      text: "child exited (status 1) — restarting in 2s"),
    Line(origin: "lab/unifi-network", level: .info, text: "started (pid 42104)"),
    Line(
      origin: "prod/shopify", level: .call, text: "shopify_list_collections",
      arguments: #"{"first":10}"#, result: #"{"collections":[{"title":"New in"},…]}"#),
    Line(
      origin: "prod/shopify", level: .call, text: "shopify_get_inventory_level",
      arguments: #"{"inventoryItemId":"gid://shopify/InventoryItem/440021"}"#,
      result: #"{"available":18}"#),
    Line(
      origin: "acme/keycloak", level: .call, text: "keycloak_list_sessions",
      arguments: #"{"realm":"engineering","clientId":"bastion"}"#,
      result: #"{"sessions":[]}"#),
    Line(
      origin: "prod/shopify", level: .call, text: "shopify_get_product",
      arguments: #"{"id":"gid://shopify/Product/8112"}"#,
      result: #"{"title":"Trail Cap","totalInventory":42}"#),
  ]

  // MARK: - What is running

  /// Four supervised instances for five profiles, each earning a distinct
  /// visual state.
  ///
  /// **`staging/shopify` is deliberately absent, and that is a consistency rule
  /// rather than an omission.** It is the profile whose `SHOPIFY_CLIENT_SECRET`
  /// is missing, so `ServerDetail` renders it "cannot start" on the `server`
  /// plate — and a supervised instance of it on the `running` plate would have
  /// the two images contradicting each other. A profile that cannot start has
  /// never run. `apps/website/src/components/Hero.astro` draws the same five
  /// rows and says the same thing about this one.
  ///
  /// The two-client row is the one that matters most. `InstanceRow.subtitle`
  /// was written for the case where the *token identity* and the self-reported
  /// `clientInfo` name disagree — the whole reason both are recorded — and a
  /// fixture where they always agree photographs a distinction the product
  /// spent code on and never shows it. `cursor (cursor-vscode)` is that case.
  ///
  /// Uptimes go through `ago`, and every offset is well clear of the minute and
  /// hour boundaries `InstanceRow.uptime` formats at.
  @MainActor private static func seedInstances() {
    let activity = Activity.shared
    func client(_ id: String, _ reported: String?, _ calls: Int, _ seenAgo: TimeInterval)
      -> Activity.Client
    {
      Activity.Client(id: id, reportedName: reported, calls: calls, lastSeen: ago(seenAgo))
    }

    activity.startDemo(
      profile: "prod", server: "shopify", pid: 41207, startedAt: ago(2 * 3600 + 14 * 60),
      dialect: "2025-11-25", allowWrites: false,
      clients: [
        client("claude-code", "claude-code", 38, 42),
        client("cursor", "cursor-vscode", 12, 190),
      ],
      calls: 50, restarts: 0, lastExit: nil)

    activity.startDemo(
      profile: "acme", server: "keycloak", pid: 41883, startedAt: ago(47 * 60),
      dialect: "2025-11-25", allowWrites: false,
      clients: [client("claude-code", "claude-code", 21, 96)],
      calls: 21, restarts: 0, lastExit: nil)

    // Stopped, so the grey dot and the `lastExit` line have a picture. `-1`
    // means "had a process and it exited", which `isLive` reads as not running
    // and `InstanceRow` renders as "stopped — exit 0". The string is exactly
    // what `Supervisor.childExited` builds; it has no other shape.
    activity.startDemo(
      profile: "home", server: "unifi-network", pid: -1, startedAt: ago(3 * 3600 + 2 * 60),
      dialect: "2025-11-25", allowWrites: false,
      clients: [client("claude-code", "claude-code", 4, 2 * 3600)],
      calls: 4, restarts: 0, lastExit: "exit 0")

    // Writes on and restarted twice: the two badges that turn "it feels flaky"
    // into a fact, on the one profile whose write gate means anything.
    activity.startDemo(
      profile: "lab", server: "unifi-network", pid: 42104, startedAt: ago(3600 + 6 * 60),
      dialect: "2025-11-25", allowWrites: true,
      clients: [client("claude-code", "claude-code", 16, 61)],
      calls: 16, restarts: 2, lastExit: nil)
  }

  // MARK: - Clients

  /// The same seven clients the real list holds, rooted somewhere that is
  /// nobody's home directory.
  ///
  /// `/Users/you` is the whole trick. `ClientDetail.fileCard` prints
  /// `configURL.path` verbatim and `abbreviate` shortens it with
  /// `abbreviatingWithTildeInPath`, which resolves against `NSHomeDirectory()`
  /// — so a fixture rooted at the real home would render as `~/…` on the
  /// capturing Mac and as a full path everywhere else. Rooting it away from
  /// home makes it render in full, always, and makes it obviously not a real
  /// machine's path while it does so.
  ///
  /// The bundle ids ride along for parity with the real list rather than for
  /// use: `ClientIconView` draws the declared symbol for every row under a
  /// capture, precisely so the plate does not depend on which editors the
  /// capturing Mac has.
  @MainActor static var clients: [ClientWiring.Client] {
    let home = URL(fileURLWithPath: "/Users/you", isDirectory: true)
    let support = home.appendingPathComponent("Library/Application Support")
    return [
      ClientWiring.Client(
        id: "claude-code", displayName: "Claude Code",
        configURL: home.appendingPathComponent(".claude.json"),
        rootKey: "mcpServers", transport: .http, caveat: nil, symbol: "terminal"),
      ClientWiring.Client(
        id: "claude-desktop", displayName: "Claude Desktop",
        configURL: support.appendingPathComponent("Claude/claude_desktop_config.json"),
        rootKey: "mcpServers", transport: .bridge,
        caveat: "spawns bastion-bridge, which starts Bastion on demand",
        bundleID: "com.anthropic.claudefordesktop", symbol: "sparkles"),
      ClientWiring.Client(
        id: "vscode", displayName: "VS Code",
        configURL: support.appendingPathComponent("Code/User/mcp.json"),
        rootKey: "servers", transport: .http, caveat: nil,
        bundleID: "com.microsoft.VSCode", symbol: "chevron.left.forwardslash.chevron.right"),
      ClientWiring.Client(
        id: "cursor", displayName: "Cursor",
        configURL: home.appendingPathComponent(".cursor/mcp.json"),
        rootKey: "mcpServers", transport: .http, caveat: nil,
        bundleID: "com.todesktop.230313mzl4w4u92", symbol: "cursorarrow"),
      ClientWiring.Client(
        id: "lm-studio", displayName: "LM Studio",
        configURL: home.appendingPathComponent(".lmstudio/mcp.json"),
        rootKey: "mcpServers", transport: .bridge,
        caveat: "spawns bastion-bridge; LM Studio's header shape is unverified",
        bundleID: "ai.elementlabs.lmstudio", symbol: "cpu"),
      ClientWiring.Client(
        id: "windsurf", displayName: "Windsurf",
        configURL: home.appendingPathComponent(".codeium/windsurf/mcp_config.json"),
        rootKey: "mcpServers", transport: .bridge,
        caveat:
          "spawns bastion-bridge; Windsurf's remote shape is a serverUrl, which this does not write",
        bundleID: "com.exafunction.windsurf", symbol: "wind"),
      ClientWiring.Client(
        id: "codex", displayName: "ChatGPT & Codex",
        configURL: home.appendingPathComponent(".codex/config.toml"),
        rootKey: ClientWiringTOML.rootKey, transport: .http,
        caveat: "the ChatGPT app, the Codex CLI and the IDE extension all read this one file, "
          + "and the ChatGPT app rewrites it on launch",
        format: .toml, bundleID: "com.openai.codex", symbol: "terminal"),
    ]
  }

  /// A stand-in for `~/.claude.json`, built as a document and handed to the
  /// real audit.
  ///
  /// Deliberately raw `[String: Any]` rather than a pre-computed `Snapshot`:
  /// `ClientWiringMerge.state`, `.audit`, `.isOurs`, `.foreignEntries` and
  /// `.foreignProjectEntries` all then execute for real against it, so a change
  /// to the audit logic shows up in the golden diff instead of leaving a stale
  /// badge that nothing recomputes.
  ///
  /// Four of the five entries are ours and correct; `lab-unifi-network` is
  /// absent, so one row reads `not written`. Deliberately no `points elsewhere`
  /// row: it is a real state and a red badge, and a marketing plate whose point
  /// is "this is what Bastion writes into your editor" should not lead with an
  /// error somebody has to read twice.
  ///
  /// The key shapes are `ClientWiring.keys(for:)`'s own output and worth
  /// knowing before editing: a server with one profile gets a bare `<server>`
  /// key, and a server with two gets `<profile>-<server>` for both.
  nonisolated static func config(for client: ClientWiring.Client) -> ClientWiring.Config {
    guard client.id == "claude-code" else {
      // Every other client is unconfigured, which is a true and unremarkable
      // state — and none of them is staged, so none is photographed. The
      // sidebar dots read from this too.
      return ClientWiring.Config(servers: [:], root: [:], disabled: [])
    }

    /// The token is a literal ellipsis rather than a plausible string. Nothing
    /// renders it — `ClientDetail` deliberately never prints a header — but a
    /// fixture holding something that LOOKS like a token is a fixture somebody
    /// will one day copy into a bug report.
    func ours(_ profile: String, _ server: String) -> [String: Any] {
      [
        "type": "http",
        "url": "http://127.0.0.1:8720/s/\(profile)/\(server)",
        "headers": ["Authorization": "Bearer …"],
      ]
    }

    let servers: [String: Any] = [
      "prod-shopify": ours("prod", "shopify"),
      "staging-shopify": ours("staging", "shopify"),
      "keycloak": ours("acme", "keycloak"),
      "home-unifi-network": ours("home", "unifi-network"),
      // `lab-unifi-network` is deliberately absent — the `not written` row.

      // The migration story, and the reason this card exists: these carry no
      // token, no per-profile write gate and no line in the activity log.
      // `foreignRow` renders `identity` verbatim, so neither argv may hold
      // anything that reads as a credential.
      "linear": ["command": "npx", "args": ["-y", "linear-mcp-server"]],
      "postgres": [
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/appdb"],
      ],
    ]

    // Three folders, not seven, and that is a layout decision rather than a
    // shortage of imagination: `projectsCard` renders its filter `TextField`
    // only above six, and an empty search box is a control with nothing to do
    // in a marketing image — and a text field that might take first responder
    // and blink a caret into the capture.
    let root: [String: Any] = [
      "mcpServers": servers,
      "projects": [
        "/Users/you/Projects/acme-api": [
          "mcpServers": [
            "sentry": ["command": "npx", "args": ["-y", "@sentry/mcp-server"]],
            "postgres": [
              "command": "npx", "args": ["-y", "@modelcontextprotocol/server-postgres"],
            ],
          ]
        ],
        "/Users/you/Projects/weekly-report": [
          "mcpServers": [
            "notion": ["command": "npx", "args": ["-y", "notion-mcp-server"]]
          ]
        ],
        "/Users/you/Projects/atlas": [
          "mcpServers": [
            "filesystem": [
              "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."],
            ]
          ]
        ],
      ],
    ]

    return ClientWiring.Config(servers: servers, root: root, disabled: [])
  }

  // MARK: - Chat

  /// A chat pane with one completed exchange in it.
  ///
  /// `prod/shopify` deliberately, and the profile choice is load-bearing:
  /// shopify's `writeGate` is nil, so `hasWritePath` is false, so
  /// `ToolProbe.eligibility` is `.anyTool` and the orange confirmation banner
  /// with its unresolved "I understand" button does not eat the top of the
  /// pane.
  @MainActor static func chatSession() -> ChatSession {
    let session = ChatSession()
    guard let server = ServerCatalog.byID["shopify"],
      let profile = profiles.first(where: { $0.id == "prod/shopify" })
    else { return session }

    /// Built through `MCPTool.init(json:)` rather than by hand, so the schemas
    /// are the shape the real path parses — which is what makes `cost(of:)`
    /// compute a budget the header can honestly report.
    func tool(_ name: String, _ summary: String, required: [String], properties: [String: Any])
      -> MCPTool?
    {
      MCPTool(json: [
        "name": name,
        "description": summary,
        "annotations": ["readOnlyHint": true],
        "inputSchema": [
          "type": "object", "properties": properties, "required": required,
        ] as [String: Any],
      ])
    }

    let count: [String: Any] = ["type": "integer", "description": "How many to return."]
    let id: [String: Any] = ["type": "string", "description": "Global id of the resource."]
    let query: [String: Any] = ["type": "string", "description": "Search query."]

    let tools = [
      tool(
        "shopify_list_products", "List products, newest first.", required: [],
        properties: ["first": count]),
      tool(
        "shopify_list_collections", "List collections.", required: [], properties: ["first": count]),
      tool("shopify_list_locations", "List inventory locations.", required: [], properties: [:]),
      tool(
        "shopify_list_orders", "List orders, newest first.", required: [],
        properties: ["first": count]),
      tool(
        "shopify_search_products", "Search products by query.", required: ["query"],
        properties: ["query": query, "first": count]),
      tool("shopify_get_product", "One product by id.", required: ["id"], properties: ["id": id]),
      tool("shopify_get_order", "One order by id.", required: ["id"], properties: ["id": id]),
      tool(
        "shopify_get_collection", "One collection by id.", required: ["id"], properties: ["id": id]),
      tool("shopify_get_customer", "One customer by id.", required: ["id"], properties: ["id": id]),
      tool(
        "shopify_get_inventory_level", "Stock for one inventory item.",
        required: ["inventoryItemId"], properties: ["inventoryItemId": id]),
      tool(
        "shopify_list_metafields", "Metafields on one resource.", required: ["ownerId"],
        properties: ["ownerId": id]),
      tool(
        "shopify_list_variants", "Variants of one product.", required: ["productId"],
        properties: ["productId": id, "first": count]),
      tool("shopify_get_shop", "The shop's own settings.", required: [], properties: [:]),
      tool(
        "shopify_list_price_rules", "Discount price rules.", required: [],
        properties: ["first": count]),
    ].compactMap { $0 }

    // Chosen the way `finishLoading` chooses: callable-cold first, then
    // cheapest, greedily up to the budget. Spelled out rather than recomputed
    // so the plate does not silently change shape when a schema is edited.
    let selected: Set<String> = [
      "shopify_list_products", "shopify_list_collections", "shopify_list_locations",
      "shopify_list_orders", "shopify_get_shop", "shopify_search_products",
    ]

    let listing = ToolProbe.Call(
      tool: "shopify_list_products",
      arguments: #"{"first":5}"#,
      output: #"""
        {"products":[
          {"title":"Trail Cap","totalInventory":42},
          {"title":"Field Jacket","totalInventory":7},
          {"title":"Wool Beanie","totalInventory":0}
        ]}
        """#,
      failed: false, seconds: 0.084)

    let locations = ToolProbe.Call(
      tool: "shopify_list_locations",
      arguments: "{}",
      output: #"""
        {"locations":[
          {"name":"Rotterdam warehouse","isActive":true},
          {"name":"Pop-up, Utrecht","isActive":false}
        ]}
        """#,
      failed: false, seconds: 0.061)

    // Two turns rather than one, and not only to fill the pane: the second is
    // what shows the model reaching for a *different* tool off the back of an
    // answer, which is the thing a single call cannot picture.
    session.adoptDemo(
      profile: profile, server: server, tools: tools, selected: selected,
      withheld: [],
      messages: [
        ChatSession.Message(role: .you, text: "Which products are out of stock right now?"),
        ChatSession.Message(
          role: .model,
          text: "Wool Beanie is at zero. Trail Cap has 42 and Field Jacket has 7.",
          calls: [listing]),
        ChatSession.Message(role: .you, text: "Where is that stock held?"),
        ChatSession.Message(
          role: .model,
          text:
            "Two locations, one of them switched off: Rotterdam warehouse is active, "
            + "the Utrecht pop-up is not.",
          calls: [locations]),
      ])
    return session
  }

  // MARK: - Seeding

  @MainActor private static func seedStores() {
    // A trial rather than a licence, and the `licence` plate is why: the
    // licensed state renders three lines and a mostly-empty form, where the
    // trial fills the pane and lets the caption make a claim about a product
    // that is not crippled while you evaluate it.
    LicenseStore.demoLicensed = false
    Trial.demoRemaining = 28 * 60

    // Servers before profiles, the same order and for the same reason
    // `applicationDidFinishLaunching` uses on the real path: `ProfileStore.load`
    // resolves every row against `ServerStore`'s nonisolated snapshot, so a
    // profile store built first would find an empty one.
    _ = ServerStore.shared
    _ = ProfileStore.shared

    for (index, line) in logLines.enumerated() {
      LogStore.shared.appendDemo(
        at: at(41, index), origin: line.origin, level: line.level, line.text,
        arguments: line.arguments, result: line.result, failed: line.failed)
    }

    seedInstances()
  }

  // MARK: - Windows

  /// The size the plates are composed from.
  ///
  /// Tune these against the fixtures rather than trusting the numbers: the two
  /// constraints are `client`, which is the tallest pane, and `log`, which must
  /// not have a lake of empty underneath it. A window that stops three quarters
  /// of the way down photographs as a product nobody uses.
  ///
  /// Both are the size the window is **born** with, passed as `HostedWindow`'s
  /// `contentSize`. Resizing after `show()` does not survive — SwiftUI sizes a
  /// `NavigationSplitView` window from its content on a layout pass that lands
  /// after `show()` has returned, and it loses asymmetrically, so the result is
  /// a plausible-looking capture at the wrong width. Giving the content an
  /// exact `.frame(width:height:)` instead is worse: it conflicts with the
  /// split view's own constraints and AppKit throws from
  /// `_NSSplitViewItemViewWrapper updateConstraints` during the first display
  /// cycle, so the app dies before a window is ever on screen.
  ///
  /// Measured, and the constraint is not the one you would guess. The detail
  /// panes divide into two kinds — `log`, `client` and `server` overflow at any
  /// height this side of a full screen, while `running` and `chat` end a third
  /// of the way down — so the obvious move is to shorten the window until the
  /// short ones stop looking empty.
  ///
  /// **The sidebar is what sets the floor, not the detail pane**, and it is
  /// taller than it looks. Six servers, seven clients and three activity rows,
  /// plus three section headers, is 16 rows at a 32pt pitch and 38pt per
  /// header — about 634pt — and underneath it `sidebarStatus` takes another
  /// 130pt as a `safeAreaInset`. An inset RESERVES space without filling the
  /// scroll view, so the list simply scrolls under it, silently.
  ///
  /// Both failures were measured rather than reasoned about. At 540 the slice
  /// was visible: "ChatGPT & Codex" cut through the middle. At 620 it was
  /// not — the sidebar looked complete, and the Log and Chat rows were sitting
  /// behind the footer, so the `chat` plate had nothing highlighted anywhere on
  /// screen to say which pane the reader was looking at. 700 is the first
  /// height where the whole list clears the inset.
  ///
  /// Adding a seventh server to the fixture pushes this up by another 32, and
  /// so does adding a client — 700 was measured against five of them, and LM
  /// Studio and Windsurf arriving from Cupertino is what took it to 764.
  nonisolated static let contentSize = NSSize(width: 1180, height: 764)
  /// The licence pane is the shortest screen in the app: a status card, a key
  /// field and two sentences. 620 left half the window empty under it.
  nonisolated static let settingsContentSize = NSSize(width: 760, height: 470)

  /// Pin, centre and defocus every window this launch opens.
  ///
  /// `didBecomeKey`, never `didUpdate`. `didUpdate` fires continuously, and
  /// ordering a window front from inside it re-enters the notification until
  /// the app dies by recursion.
  @MainActor private static func observeWindows() {
    NotificationCenter.default.addObserver(
      forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
    ) { note in
      guard let window = note.object as? NSWindow else { return }
      MainActor.assumeIsolated { pin(window) }
    }
  }

  /// Matched on `frameAutosaveName`, not on the title — which is localizable —
  /// and not on "the first window", which is whatever order AppKit opened them
  /// in.
  ///
  /// On size this loses to `HostedWindow`, which has already set the content
  /// size at construction and latched it behind `OpeningResizeGuard`. That is
  /// correct and this is belt and braces. What it uniquely buys is the centring
  /// and the first-responder clear.
  @MainActor private static func pin(_ window: NSWindow) {
    // Sheets are `NSWindow`s too, and forcing a main-window size onto one wrecks
    // its layout. Nothing staged presents a sheet today; this is what stops the
    // first one that does from being a mystery.
    guard !window.isSheet, window.styleMask.contains(.titled) else { return }

    let wanted: NSSize? =
      switch window.frameAutosaveName {
      case MainWindowController.autosaveName: contentSize
      case SettingsWindowController.autosaveName: settingsContentSize
      // A window nothing named. `HostedWindow` skips `setFrameAutosaveName`
      // under demo, so this is in fact EVERY window here — which is why the
      // match below is on the intended size rather than on the name, and why
      // the sizing is `HostedWindow`'s job and not this function's.
      default: nil
      }
    if let wanted, window.contentRect(forFrameRect: window.frame).size != wanted {
      window.setContentSize(wanted)
    }
    window.center()

    // Not optional, and not cosmetic. Bastion has two `List(selection:)`s, and
    // a `List` draws its selected row in the accent colour while it is first
    // responder and in muted grey when it is not. Nothing assigns that focus
    // deliberately, so it is whatever AppKit resolved by the time the shutter
    // fired — a gate that fails about one run in three with no code change.
    // One runloop hop later, so SwiftUI's own assignment does not overwrite it.
    // It also keeps a blinking caret out of `LicencePane`'s `TextEditor`.
    DispatchQueue.main.async { window.makeFirstResponder(nil) }
  }

  // MARK: - Readiness

  /// Tell appshot the screen it asked for has rendered.
  ///
  /// The frame poll sees stillness, not readiness — an empty state and a
  /// half-drawn pane are both perfectly still. This replaces that guess with a
  /// fact, and a signal that never arrives fails the run rather than quietly
  /// reverting to `--settle`.
  ///
  /// What "ready" means here is unusually strong, and worth saying because it
  /// is what lets `--settle` stay at appshot's 0.3 floor: every store is seeded
  /// synchronously in `apply()` before any window is built, and nothing on
  /// these six panes is async. No network, no disk, no model. The body running
  /// *is* the content existing.
  @MainActor static func signalReady(from source: ReadySource) {
    guard isEnabled, source == stage.readySource else { return }
    guard let path = argument(Key.readyFile) else { return }
    // One runloop turn after the body, so the frame this reports has actually
    // been committed rather than merely queued.
    DispatchQueue.main.async {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
  }
}
