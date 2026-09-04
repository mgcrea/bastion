import AppKit
import SwiftUI

/// Which Settings pane is showing.
///
/// A source list rather than a toolbar of tabs. Tabs price every pane at one
/// icon and one word across the top, which is survivable at two and is the
/// reason nothing can ever be added to them; a sidebar costs a column once and
/// then stays free.
enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case audit
  case about
  case updates
  case licence

  var id: String { rawValue }
  static let defaultsKey = "settingsPane"

  /// What the app is and how it behaves…
  ///
  /// Updates sits last, next to About, because the two answer halves of one
  /// question: which build is this, and is there a newer one. It is a pane
  /// rather than the Section in General it used to be — General is where the
  /// gateway port and the npm minimum age live, and the only manual check the
  /// app has was the fourth card down a page nobody scrolls to look for it.
  static let application: [SettingsPane] = [.general, .audit, .about, .updates]

  /// …and what was bought, which is a different question and the only reason the
  /// sidebar is in two groups rather than one list of three. Somebody opens
  /// Licence because of a refusal or a receipt, never because they are tuning
  /// something — the same split cupertino makes, for the same reason.
  static let entitlement: [SettingsPane] = [.licence]

  var title: String {
    switch self {
    case .general: "General"
    case .audit: "Activity"
    case .about: "About"
    case .updates: "Updates"
    case .licence: "Licence"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .audit: "list.bullet.rectangle"
    case .about: "info.circle"
    case .updates: "arrow.down.circle"
    case .licence: "key"
    }
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
  /// the selection lives in `@AppStorage`, which observes this write.
  static func show(_ pane: SettingsPane) {
    UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.defaultsKey)
    hosted.show()
  }
}

struct SettingsView: View {
  @AppStorage(SettingsPane.defaultsKey) private var selection = SettingsPane.general.rawValue

  private var pane: Binding<SettingsPane?> {
    Binding(
      get: { current },
      set: { if !DemoSeed.isEnabled { selection = ($0 ?? .general).rawValue } })
  }

  private var current: SettingsPane {
    if DemoSeed.isEnabled, case .settings(let staged) = DemoSeed.stage.subject { return staged }
    return SettingsPane(rawValue: selection) ?? .general
  }

  private func row(_ pane: SettingsPane) -> some View {
    Label(pane.title, systemImage: pane.symbol).tag(pane)
  }

  var body: some View {
    NavigationSplitView {
      List(selection: pane) {
        Section {
          ForEach(SettingsPane.application) { row($0) }
        }
        Section {
          ForEach(SettingsPane.entitlement) { row($0) }
        }
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 176, max: 220)
    } detail: {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          // The pane title in content rather than in the title bar, which keeps
          // the window called "Bastion Settings" in ⌘-Tab and in the Window
          // menu while the heading still says which page this is.
          Text(current.title)
            .font(.title2).bold()
            .padding(.horizontal, 20).padding(.top, 20)

          switch current {
          case .general: GeneralPane()
          case .audit: AuditPane()
          case .about: AboutPane()
          case .updates: UpdatesPane()
          case .licence: LicencePane()
          }
        }
      }
    }
    .frame(minWidth: 620, minHeight: 400)
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

private struct AboutPane: View {
  var body: some View {
    Form {
      Section {
        LabeledContent("Version", value: AppInfo.version)
        LabeledContent("Build", value: AppInfo.build)
        LabeledContent("Identifier", value: AppSupport.identifier)
        if AppInfo.isDebugBuild {
          // Two menu bar icons that look identical and hold different
          // credentials is otherwise a confusing afternoon.
          Text(
            "A debug build. It has its own bundle identifier, and therefore its own Keychain "
              + "items, its own profiles and its own port."
          )
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("This build")
      }

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
    .formStyle(.grouped)
  }
}

// MARK: - Updates

/// The update check, and the only outbound connection in the app.
///
/// Its own pane rather than a Section in General for the reason
/// `SettingsPane.application` gives: it is the only manual check Bastion has,
/// automatic checking is off until asked for, and a build with the toggle off
/// had no way to look that anyone could find. The pane also has room to say
/// what the check sends in plain terms, which is a claim the rest of the app's
/// loopback-only story rests on — see `UpdateController`.
private struct UpdatesPane: View {
  /// Mirrored rather than read through the binding: `automatic` is computed
  /// from an updater that does not exist until somebody says yes, so there is
  /// nothing for `@Observable` to have tracked before the first write.
  @State private var automatic = UpdateController.shared.automatic
  private var updates = UpdateController.shared

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
        Text(
          "Off until you say otherwise. This is the only network connection Bastion makes, and it "
            + "makes none at all until you turn this on or press Check Now. It reads one file, the "
            + "appcast at bastion.mgcrea.io/appcast.xml, which redirects to the GitHub release, "
            + "and sends no identifier with it: not your licence key, not a machine id."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
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
