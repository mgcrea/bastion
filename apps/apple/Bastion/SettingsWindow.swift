import AppKit
import SupportKit
import SupportKitSettings
import SwiftUI

/// Which Settings pane is showing.
///
/// A source list rather than a toolbar of tabs. Tabs price every pane at one
/// icon and one word across the top, which is survivable at two and is the
/// reason nothing can ever be added to them; a sidebar costs a column once and
/// then stays free.
/// The protocol is qualified because this enum has the same name as it, which
/// is the fleet's convention.
///
/// Two pairs after the configuration panes, then what was bought.
///
/// What's New and Updates are the version pair: what did this build change, and
/// is there a newer one. Updates is a pane rather than the Section in General it
/// used to be — General is where the gateway port and the npm minimum age live,
/// and the only manual check the app has was the fourth card down a page nobody
/// scrolls to look for it.
///
/// About and Help are the identity pair, and they sit last because that is
/// where a settings window's footer material belongs. About used to lead the
/// version pair, on the reading "which build is this, what did it change, is
/// there a newer one" — but that was written when there was no Help pane, and
/// About earns its place beside Help now: both are where somebody goes when
/// something is wrong rather than when they are tuning something.
///
/// Help is a pane at all because Bastion is `LSUIElement`, so the Help menu
/// carrying these same three links only exists while a window happens to be
/// open.
enum SettingsPane: String, SupportKitSettings.SettingsPane {
  case general
  case audit
  case whatsNew
  case updates
  case about
  case help
  case licence

  var title: LocalizedStringKey {
    switch self {
    case .general: "General"
    case .audit: "Activity"
    case .about: "About"
    case .whatsNew: "What's New"
    case .updates: "Updates"
    case .help: "Help"
    case .licence: "Licence"
    }
  }

  var systemImage: String {
    switch self {
    case .general: "gearshape"
    case .audit: "list.bullet.rectangle"
    case .about: "info.circle"
    case .whatsNew: "sparkles"
    case .updates: "arrow.down.circle"
    case .help: "questionmark.circle"
    case .licence: "key"
    }
  }

  /// Licence is its own group, and the only reason the sidebar is in two rather
  /// than one list. Somebody opens it because of a refusal or a receipt, never
  /// because they are tuning something — the same split cupertino makes.
  var group: SettingsPaneGroup { self == .licence ? .entitlement : .configuration }

  /// Only ever on What's New, and only while something is genuinely unread. The
  /// package draws nothing for 0, so the read case needs no branch of its own.
  var badge: Int { self == .whatsNew && Changelog.hasUnseen ? Changelog.unseen.count : 0 }

  static var defaultPane: SettingsPane { .general }

  /// The pane a screenshot stage asks for — and nil every other time.
  ///
  /// Non-nil outside a capture would be a disaster rather than a cosmetic bug:
  /// `SettingsScaffold` lets a staged pane override the stored one AND drops
  /// every selection write, so a sidebar that answered here on an ordinary
  /// launch would be frozen for real users.
  static var staged: SettingsPane? {
    guard DemoSeed.isEnabled, case .settings(let pane) = DemoSeed.stage.subject else { return nil }
    return pane
  }
}

/// Settings.
///
/// Not a SwiftUI `Settings` scene, which does not work here at all: it opens
/// via `showSettingsWindow:`, routed through an app menu that an `LSUIElement`
/// app does not have. The ⌘, that reaches this is declared as a `CommandGroup`
/// in `BastionApp` instead — see the comment there for why inserting the item
/// into `NSApp.mainMenu` by hand does not survive.
@MainActor
enum SettingsWindowController {
  /// A `static let` rather than the inline string it was, so `DemoSeed.pin`
  /// can match a window on it. Matching on the title instead would be matching
  /// on a localizable string, and matching on "the first window that is not the
  /// main one" is the secondary-window trap.
  static let autosaveName = "settings-panes"

  private static let hosted = HostedWindow(
    title: "Bastion Settings",
    autosaveName: autosaveName,
    // Named explicitly, unlike the main window. SwiftUI's fitting size for a
    // grouped `Form` is the width the longest footer sentence would like to
    // avoid wrapping, which is a settings window half again as wide as it has
    // any reason to be.
    contentSize: DemoSeed.isEnabled ? DemoSeed.settingsContentSize : NSSize(width: 660, height: 420)
  ) {
    SettingsView()
  }

  static func show() { hosted.show() }

  /// Open onto a particular pane, including on a window that is already up —
  /// the scaffold reads the selection through `@AppStorage`, which observes
  /// this write. Writing first is what makes a deep link land on a window that
  /// was already open.
  static func show(_ pane: SettingsPane) {
    Support.settings.select(pane)
    hosted.show()
  }
}

struct SettingsView: View {
  var body: some View {
    SettingsScaffold(selection: Support.settings, staged: SettingsPane.staged) { pane in
      switch pane {
      case .general: GeneralPane()
      case .audit: AuditPane()
      case .about: AboutPane()
      case .whatsNew: WhatsNewPane()
      case .updates: UpdatesPane()
      case .help:
        // A replacement intro rather than the package default, which invites
        // bugs, ideas and questions but deliberately stops short of inviting a
        // pull request — true only where the tracker is the source. Bastion's
        // is: `Support.app.trackerURL` is this project's own repository.
        HelpSettingsPane(
          app: Support.app,
          preferIssueTracker: Support.preferIssueTracker,
          intro: """
            Bugs, ideas and questions are all welcome, and none of them is a bother. \
            Bastion is built in the open, so an issue or a pull request lands where the \
            code does. The feedback form and the issue template arrive with your version, \
            macOS, Mac model and language already filled in, where you can read them \
            before anything is sent.
            """
        )
      case .licence: LicensePane()
      }
    }
    // Sized for the content, never the window: a sidebar spends up to 240pt
    // before a pane sees any width, so the 620 this carried as a bare frame was
    // measured against a narrower sidebar than the package draws.
    .settingsWindowSize(minWidth: 660, idealWidth: 700, minHeight: 400, idealHeight: 460)
  }
}

// MARK: - General

private struct GeneralPane: View {
  @AppStorage("gatewayPort") private var port = Int(Gateway.defaultPort)
  /// -1 is "leave npm alone", which is not the same as 0. See
  /// `ServerInstaller.releaseAgeOverride`.
  @AppStorage(ServerInstaller.releaseAgeKey) private var releaseAge = -1
  /// Empty by default: the prefix is opt-in. See `ClientWiring.prefix`.
  @AppStorage(ClientWiring.prefixKey) private var keyPrefix = ""
  /// Off. See `ToolFacade.defaultsKey` — this is the one setting in the app
  /// that trades rather than tightens, so it is somebody's decision to make.
  @AppStorage(ToolFacade.defaultsKey) private var lazyTools = false

  /// What the current prefix does to the keys that would actually be written,
  /// rather than to an invented example — the profiles are right there.
  private var sampleKeys: String {
    let profiles = ProfileStore.shared.profiles
    guard !profiles.isEmpty else { return keyPrefix + "shopify" }
    let all = ClientWiring.keys(for: profiles).values.sorted()
    let shown = all.prefix(3).joined(separator: ", ")
    return all.count > 3 ? "\(shown), …" : shown
  }

  var body: some View {
    Form {
      Section {
        // `Gateway` reads this once, in `start()`, and is not `@Observable` —
        // so saying "takes effect on restart" is not politeness, it is the
        // actual behaviour. Claiming otherwise would put a number on screen
        // that no listener is bound to.
        TextField("Port", value: $port, format: .number.grouping(.never))
          .frame(maxWidth: 140)
        Text(
          "Bastion listens on 127.0.0.1 only, and that is not configurable. Changing the port "
            + "takes effect when Bastion next starts, and every client config already written "
            + "names the old one."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if port != Int(Gateway.shared.port) {
          Label(
            "Currently serving on \(String(Gateway.shared.port)). Quit and reopen Bastion to move it.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("Gateway")
      }

      Section {
        Toggle("Load tools on demand", isOn: $lazyTools)
        Text(
          "Clients are sent three Bastion tools — search, describe and call — instead of every "
            + "tool a server exposes, and fetch a schema when they need one. Nothing becomes "
            + "unreachable, and a server with 85 tools costs a client about 0.4k tokens on "
            + "connect instead of 26.2k."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "The cost is on the client's side: every call arrives as bastion_call_tool, so one "
            + "approval rule in an editor covers every tool on that server. Bastion's own "
            + "Activity and audit log go on naming the real one, and the write gate still holds."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        // A statement, not advice. It used to say "override that profile to
        // off", which is now wrong twice over: the gateway already skips these
        // clients, and a profile feeds several at once, so overriding there
        // would have moved the ones that do need fronting.
        Text(
          "Clients that load tool schemas on demand themselves are never fronted, whatever a "
            + "profile says — Claude Code is one, and gets the real list. Each client's own "
            + "settings say which, and can override it."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Tools")
      }

      Section {
        TextField("Entry name prefix", text: $keyPrefix)
          .frame(maxWidth: 200)
        Text(
          "A client config gets one entry per profile, named <prefix><server>. Empty writes the "
            + "server name alone, which is the default."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if ClientWiring.isValidPrefix(keyPrefix) {
          Text("Entries would be named \(sampleKeys).")
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          // Not merely cosmetic: the key goes into somebody else's JSON and then
          // into a tool name, and a client is entitled to reject either.
          Label(
            "Lowercase letters, digits and dashes, starting with a letter or digit. Ignored "
              + "until it is.",
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
        // The cost worth naming before someone changes it: a client's saved
        // permission rules are keyed on the tool name, and the tool name carries
        // this prefix.
        Text(
          "Changing this renames Bastion's entries in each client the next time you configure "
            + "it, and renames the tools the model sees with them — 'mcp__bastion_shopify__…' "
            + "becomes 'mcp__shopify__…'. Any permission rule saved against the old name stops "
            + "matching. Entries Bastion did not write are never touched, and a name already "
            + "taken by one of them is refused rather than overwritten."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("MCP clients")
      }

      Section {
        Picker("Minimum package age", selection: $releaseAge) {
          Text("Whatever npm is configured to do").tag(-1)
          Text("No minimum").tag(0)
          Text("1 day").tag(1)
          Text("3 days").tag(3)
          Text("7 days").tag(7)
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 380)
        Text(
          "npm can be told to refuse versions published too recently, which is a real defence: it "
            + "is the window in which a compromised release tends to get caught and unpulled. "
            + "Bastion reads that setting from your ~/.npmrc and leaves it alone by default."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if releaseAge >= 0 {
          Label(
            releaseAge == 0
              ? "Bastion will install a version published seconds ago. Your ~/.npmrc still applies "
                + "to everything else."
              : "Bastion will only install versions at least \(releaseAge) day\(releaseAge == 1 ? "" : "s") "
                + "old, whatever ~/.npmrc says.",
            systemImage: releaseAge == 0 ? "exclamationmark.triangle.fill" : "info.circle"
          )
          .font(.caption)
          .foregroundStyle(releaseAge == 0 ? .orange : .secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("Installing servers")
      }
    }
    .formStyle(.grouped)
  }
}

// MARK: - About

/// The shared About pane, plus the two things that are Bastion's own.
///
/// Version, System, Model, the identity row and the copy-for-a-bug-report
/// button all come from `AboutSettingsPane`, which is what the fleet's other
/// apps draw. `showsIdentifier` brings the bundle id this pane always had, and
/// with it the package's debug-build notice — worth the row here because two
/// menu bar icons that look identical and hold different credentials is
/// otherwise a confusing afternoon.
///
/// `includesSupport: false` because Help is its own pane now; leaving it on
/// would draw Send Feedback, Report an Issue and Bastion Support in both.
///
/// What stays local is the prose: it describes THIS app's threat posture, and
/// nothing about it would be true of another app in the fleet.
private struct AboutPane: View {
  var body: some View {
    AboutSettingsPane(
      app: Support.app,
      showsIdentifier: true,
      debugNotice:
        "A debug build. It has its own bundle identifier, and therefore its own Keychain items, its own profiles and its own port.",
      includesSupport: false,
      preferIssueTracker: Support.preferIssueTracker
    ) {
      Section {
        Text(
          "Bastion binds 127.0.0.1 and nothing else, validates Origin and Host on every request, "
            + "and requires a per-client bearer token. It ships with no entitlements file at all: "
            + "spawning children and binding loopback need none."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "The audit log records which profile, which method, which tool and the arguments it was "
            + "called with; results too, for a profile that asks for them. Credentials are never "
            + "recorded, and none of it is written to disk unless you keep an audit log. It does "
            + "not see what a server then "
            + "does over the network or on disk."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("What it does")
      }
    }
  }
}

// MARK: - Updates

/// Am I current — asked about the app, and about the servers it runs.
///
/// Its own pane rather than a Section in General for the reason
/// `SettingsPane.application` gives: these are the only manual checks Bastion
/// has, automatic checking is off until asked for, and a build with the toggle
/// off had no way to look that anyone could find. The pane also has room to say
/// what the check sends in plain terms, which is a claim the rest of the app's
/// loopback-only story rests on — see `UpdateController`.
private struct UpdatesPane: View {
  /// Mirrored rather than read through the binding: `automatic` is computed
  /// from an updater that does not exist until somebody says yes, so there is
  /// nothing for `@Observable` to have tracked before the first write.
  @State private var automatic = UpdateController.shared.automatic
  @State private var confirmingUpdateAll = false
  private var updates = UpdateController.shared
  private var installer = ServerInstaller.shared

  var body: some View {
    Form {
      Section {
        // The version is here as well as in About: the question this pane
        // answers is "am I current", and half of that answer is which build
        // this is. Same source, so the two cannot drift.
        LabeledContent("Version", value: AppInfo.version)
        // A sentence either way. Showing nothing before the first check reads
        // as a missing value rather than as the answer.
        LabeledContent {
          // Not gated on the toggle. Asking once by hand is a different act
          // from granting a standing licence to look, and refusing the first
          // because you declined the second would be a checkbox that disables a
          // button nobody consented away.
          Button(updates.isChecking ? "Checking…" : "Check Now…") { updates.checkNow() }
            .disabled(updates.isChecking)
        } label: {
          Text(lastCheck)
        }
      }

      Section {
        Toggle(
          "Check for updates automatically",
          isOn: Binding(
            get: { automatic },
            set: {
              updates.setAutomatic($0)
              automatic = $0
            }))
        // A caption inside the card rather than a section footer, which is what
        // every other pane in this file does.
        // "The only network connection Bastion makes" is what this said until
        // the section below it existed, and the two cannot both be on one
        // screen. The claim that was actually being made — and that
        // `UpdateController` and `ServerInstaller.checkForUpdate` both make — is
        // narrower and survives: this is the only one Bastion opens on its own.
        // npm reaches the registry too, and never without a press.
        Text(
          "Off until you say otherwise. This is the only connection Bastion opens on its own, and "
            + "it opens none at all until you turn this on or press Check Now. It reads one file, "
            + "the appcast at bastion.mgcrea.io/appcast.xml, which redirects to the GitHub "
            + "release, and sends no identifier with it: not your licence key, not a machine id."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      serversSection
    }
    .formStyle(.grouped)
    .confirmationDialog(
      "Update \(installer.updatesAvailable.count) servers?",
      isPresented: $confirmingUpdateAll, titleVisibility: .visible
    ) {
      Button("Update All") { installer.updateAll() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(updateAllWarning)
    }
  }

  /// The same two questions as the section above, asked about the servers.
  ///
  /// Here rather than in a pane of its own because "am I current" is one
  /// question with two halves, and a user who has answered it for the app and
  /// not for the nine packages it runs has not answered it. The check is the
  /// same shape as Sparkle's — a button, a sentence about when it last ran —
  /// which is the shape `ServerDetail` already borrowed for one server.
  @ViewBuilder private var serversSection: some View {
    let checkable = installer.checkableServers
    if !checkable.isEmpty {
      Section {
        LabeledContent {
          Button(installer.isCheckingAll ? "Checking…" : "Check All…") { installer.checkAll() }
            .disabled(installer.isCheckingAll || installer.isUpdatingAll)
        } label: {
          Text(
            checkable.count == 1
              ? "1 server installed from npm" : "\(checkable.count) servers installed from npm")
        }

        ForEach(checkable, id: \.id) { server in
          serverRow(server)
        }

        if !installer.updatesAvailable.isEmpty {
          Button(installer.isUpdatingAll ? "Updating…" : "Update All…") {
            confirmingUpdateAll = true
          }
          .disabled(installer.isUpdatingAll || installer.isCheckingAll)
        }

        // The rule the rest of this app's update story rests on, said where
        // somebody is looking at a button that would be a timer in most
        // software. See `ServerInstaller.checkForUpdate`.
        Text(
          "Nothing here runs on a timer. Bastion asks npm what it would install when you press "
            + "one of these buttons and at no other time, so an answer is only ever as fresh as "
            + "the last press — and it is forgotten when Bastion quits rather than shown stale."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Servers")
      }
    }
  }

  @ViewBuilder private func serverRow(_ server: BastionServer) -> some View {
    LabeledContent {
      if installer.isRunning(server.id) {
        ProgressView().controlSize(.small)
      } else if installer.isChecking(server.id) {
        ProgressView().controlSize(.small)
      } else if case .newer = installer.availability(of: server.id) {
        Button("Update") { Task { await installer.install(server) } }
          .disabled(installer.isUpdatingAll)
      } else if let state = installer.availability(of: server.id) {
        Label(state.shortLabel, systemImage: state.symbol)
          .font(.caption)
          .foregroundStyle(state == .upToDate ? Color.secondary : Color.orange)
          .labelStyle(.titleAndIcon)
      } else {
        // Not "up to date". Nothing has asked, and the difference between those
        // two is the whole reason this pane says anything at all.
        Text("Not checked").font(.caption).foregroundStyle(.tertiary)
      }
    } label: {
      HStack(spacing: 6) {
        Text(server.displayName)
        if case .newer(let latest) = installer.availability(of: server.id) {
          Text("\(ServerInstaller.installedVersion(of: server) ?? "?") → \(latest)")
            .font(.caption).foregroundStyle(.orange).monospacedDigit()
        } else if let installed = ServerInstaller.installedVersion(of: server) {
          Text(installed).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
        }
      }
    }
  }

  /// What Update All costs, counted rather than hedged.
  ///
  /// The number that matters is not how many packages move — it is how many
  /// live processes stop, because `install` stops every child of a server whose
  /// code it replaced and the user is the only one who knows what is mid-call.
  private var updateAllWarning: String {
    let servers = installer.updatesAvailable
    let ids = Set(servers.map(\.id))
    let live = Activity.shared.instances.filter { ids.contains($0.server) && $0.isLive }.count
    let names = servers.map(\.displayName).joined(separator: ", ")
    guard live > 0 else { return "\(names) will be downloaded again at their newest versions." }
    return "\(names) will be downloaded again at their newest versions. This stops \(live) "
      + "running \(live == 1 ? "process" : "processes"), which any attached client will restart "
      + "on its next call."
  }

  private var lastCheck: String {
    guard let last = updates.lastCheck else { return "Not checked yet" }
    return "Last checked \(last.formatted(.relative(presentation: .named)))"
  }
}

/// Everything about what Bastion records.
///
/// A pane of its own because these settings had outgrown a `Section` in
/// General: what the live log keeps, what an agent may read back, whether any
/// of it survives a quit, and — once it does — how long it is kept and how it
/// leaves the machine. Four different questions with one subject.
///
/// The per-profile override stays in `ProfileEditor`, beside that profile's
/// write gate. This pane is the default; a profile is the exception to it.
private struct AuditPane: View {
  @AppStorage(CallCapture.defaultsKey) private var capture = CallCapture.defaultMode.rawValue
  @AppStorage(CallCapture.allProfilesDefaultsKey) private var allProfiles = false
  @AppStorage(AuditLog.enabledKey) private var keepFile = false
  @AppStorage(AuditLog.payloadsKey) private var filePayloads = false
  @AppStorage(AuditLog.maxDaysKey) private var maxDays = AuditLog.defaultMaxDays
  @AppStorage(AuditLog.maxMegabytesKey) private var maxMegabytes = AuditLog.defaultMaxMegabytes

  @State private var summary: AuditLog.Summary?
  @State private var note: String?
  @State private var fingerprint = AuditSigning.currentFingerprint()
  @State private var copied = false

  var body: some View {
    Form {
      Section {
        Picker("Record", selection: $capture) {
          ForEach(CallCapture.Mode.allCases, id: \.self) { mode in
            Text(mode.label).tag(mode.rawValue)
          }
        }
        Text(
          "What every profile records unless it says otherwise. Arguments answer 'what did the "
            + "agent actually send'; results are the unbounded half, so they are opt-in. "
            + "Credentials are never recorded either way."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Toggle("Let an agent read every profile's activity", isOn: $allProfiles)
        Text(
          "Off. An agent asking Bastion for recent activity is answered with its own profile's "
            + "lines — which it already sent and received. Turning this on lets one profile's "
            + "agent read another's, and another profile's lines never carry arguments or "
            + "results whichever way this is set."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("What is recorded")
      }

      Section {
        Toggle("Keep an audit log on disk", isOn: $keepFile)
        Text(
          keepFile
            ? "Records survive a quit, in \(AuditLog.directory.path), readable only by you."
            : "Off. The Activity window is a ring in memory and nothing outlives the app."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Toggle("Include arguments and results in the file", isOn: $filePayloads)
          .disabled(!keepFile)
        Text(
          "Off, and separate from the switch above on purpose: keeping a record of WHICH tools "
            + "ran is a smaller thing to leave on disk than keeping what they were called with. "
            + "Turning both on writes payloads to a file."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        LabeledContent("Keep for") {
          Stepper("\(maxDays) days", value: $maxDays, in: 1...365)
        }
        LabeledContent("At most") {
          Stepper("\(maxMegabytes) MB", value: $maxMegabytes, in: 5...5000, step: 5)
        }
        Text(
          "Whichever runs out first. The log is written in segments and a whole segment is "
            + "dropped at a time — a chain cannot lose a record from the middle and still verify."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("On disk")
      }

      Section {
        HStack {
          Button("Verify") { verify() }
          Button("Export…") { export() }
          Button("Delete the log") { erase() }
            .disabled(summaryIsEmpty)
          Spacer()
        }
        if let summary {
          Text(
            summary.report.isIntact
              ? "\(summary.records) records across \(summary.segments) "
                + "segment\(summary.segments == 1 ? "" : "s"), \(bytes(summary.bytes)). "
                + "The chain verifies."
              : "\(summary.records) records, and the chain does NOT verify: "
                + describe(summary.report.failures)
          )
          .font(.caption)
          .foregroundStyle(summary.report.isIntact ? Color.secondary : .red)
          .fixedSize(horizontal: false, vertical: true)
        }
        if let note {
          Text(note).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(
          "Each record carries a hash of the one before it, so an edited field, a deleted record "
            + "or a truncated file can be detected. That is the whole claim: it catches tampering "
            + "by something that does not know it is a chain. It is not proof against anyone who "
            + "can write the file, because they can recompute it."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("The chain")
      }

      Section {
        if let fingerprint {
          LabeledContent {
            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(
                (try? AuditSigning.publicKey()) ?? "", forType: .string)
              copied = true
            } label: {
              Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy the full public key")
            .task(id: copied) {
              guard copied else { return }
              try? await Task.sleep(for: .seconds(2))
              copied = false
            }
          } label: {
            Text(fingerprint).font(.system(.body, design: .monospaced))
            Text("This Mac's export key")
          }
        } else {
          Text("No key yet — one is made the first time you sign an export.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text(
          "Signing an export proves it came from this Mac and has not been altered since. It "
            + "does not prove the log was not curated before it was signed — you control this "
            + "machine. And it only means anything to someone who already has the key above, "
            + "sent to them some other way: a key that travels only inside the export proves "
            + "nothing, because a forger would include their own."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          "A new Mac makes a new key. Exports already signed keep verifying against the old one."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Signing")
      }
    }
    .formStyle(.grouped)
    .onAppear { summary = AuditLog.verifyAll() }
  }

  private var summaryIsEmpty: Bool { (summary?.records ?? 0) == 0 }

  private func verify() {
    summary = AuditLog.verifyAll()
    note = nil
  }

  private func export() {
    guard let outcome = AuditExport.run() else { return }
    note = outcome.note
    if let written = outcome.summary { summary = written }
    fingerprint = AuditSigning.currentFingerprint()
  }

  private func erase() {
    AuditLog.shared.clear()
    summary = AuditLog.verifyAll()
    note = "The log on disk is gone."
  }

  private func bytes(_ count: Int) -> String {
    count < 1024 * 1024
      ? "\(count / 1024) KB" : String(format: "%.1f MB", Double(count) / 1024 / 1024)
  }

  /// Say what broke, not just that something did — a verifier that reports
  /// "invalid" and stops is a verifier nobody can act on.
  private func describe(_ failures: [AuditChain.Failure]) -> String {
    guard let first = failures.first else { return "no detail" }
    let rest = failures.count > 1 ? " (and \(failures.count - 1) more)" : ""
    switch first {
    case .unreadable(let line): return "line \(line) is not a record\(rest)"
    case .unknownVersion(let line, let version):
      return "line \(line) is format \(version), which this build cannot check\(rest)"
    case .brokenHash(let seq): return "record \(seq) was edited\(rest)"
    case .brokenLink(let seq): return "a record before \(seq) was removed\(rest)"
    case .outOfOrder(let seq): return "record \(seq) is out of sequence\(rest)"
    }
  }

}
