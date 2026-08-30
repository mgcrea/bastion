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
  case about
  case licence

  var id: String { rawValue }
  static let defaultsKey = "settingsPane"

  /// What the app is and how it behaves…
  static let application: [SettingsPane] = [.general, .about]

  /// …and what was bought, which is a different question and the only reason the
  /// sidebar is in two groups rather than one list of three. Somebody opens
  /// Licence because of a refusal or a receipt, never because they are tuning
  /// something — the same split cupertino makes, for the same reason.
  static let entitlement: [SettingsPane] = [.licence]

  var title: String {
    switch self {
    case .general: "General"
    case .about: "About"
    case .licence: "Licence"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .about: "info.circle"
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
  private static let hosted = HostedWindow(
    title: "Bastion Settings",
    autosaveName: "settings-panes",
    // Named explicitly, unlike the main window. SwiftUI's fitting size for a
    // grouped `Form` is the width the longest footer sentence would like to
    // avoid wrapping, which is a settings window half again as wide as it has
    // any reason to be.
    contentSize: NSSize(width: 660, height: 420)
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
      get: { SettingsPane(rawValue: selection) ?? .general },
      set: { selection = ($0 ?? .general).rawValue })
  }

  private var current: SettingsPane { SettingsPane(rawValue: selection) ?? .general }

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
          case .about: AboutPane()
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
  @State private var automatic = UpdateController.shared.automatic

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
            + "names the old one.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if port != Int(Gateway.shared.port) {
          Label(
            "Currently serving on \(String(Gateway.shared.port)). Quit and reopen Bastion to move it.",
            systemImage: "exclamationmark.triangle.fill")
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
            + "server name alone, which is the default.")
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
            systemImage: "exclamationmark.triangle.fill")
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
            + "taken by one of them is refused rather than overwritten.")
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
            + "Bastion reads that setting from your ~/.npmrc and leaves it alone by default.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if releaseAge >= 0 {
          Label(
            releaseAge == 0
              ? "Bastion will install a version published seconds ago. Your ~/.npmrc still applies "
                + "to everything else."
              : "Bastion will only install versions at least \(releaseAge) day\(releaseAge == 1 ? "" : "s") "
                + "old, whatever ~/.npmrc says.",
            systemImage: releaseAge == 0 ? "exclamationmark.triangle.fill" : "info.circle")
            .font(.caption)
            .foregroundStyle(releaseAge == 0 ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } header: {
        Text("Installing servers")
      }

      Section {
        // Only the standing question lives here. "Check for Updates…" stays in
        // the menu bar, where somebody who wants one now would reach for it.
        Toggle(
          "Check for updates automatically",
          isOn: Binding(
            get: { automatic },
            set: {
              UpdateController.shared.setAutomatic($0)
              automatic = $0
            }))
        Text("Off until you say otherwise. Bastion sends no identifier with the check.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("Updates")
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
              + "items, its own profiles and its own port.")
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
            + "spawning children and binding loopback need none.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text(
          "The audit log records which profile, which method and which tool — never arguments and "
            + "never results. It does not see what a server then does over the network or on disk.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } header: {
        Text("What it does")
      }
    }
    .formStyle(.grouped)
  }
}
