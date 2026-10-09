import AppKit
import MCPKitWiring
import SwiftUI

/// A server another app on this Mac hands over with a `bastion://add-server` link, held until
/// the person says yes.
///
/// The link is how a sandboxed app reaches Bastion at all: it cannot write `servers.json`, and
/// should not. What it hands over is a loopback endpoint and its bearer token, which is exactly
/// a remote server with one secret, so accepting it goes through the same three calls the
/// Add Server sheet and `add_custom_server` make, in `ProfileEditor`'s order: the definition,
/// the Keychain, then the profile.
///
/// Never accepted without the sheet. Any process can open a URL, and a link that added servers
/// silently would let one point a profile at whatever port it liked.
@MainActor
@Observable
final class ServerHandoff {
  static let shared = ServerHandoff()

  /// Who opened the link, when the Apple event says.
  struct Sender: Hashable {
    var name: String
    var bundleIdentifier: String?
  }

  struct Request: Identifiable {
    let id = UUID()
    let link: BastionLink
    let sender: Sender?
    /// The endpoint the same id points at now, when it is already in the list.
    let replacing: String?
    /// Why it cannot be added, shown in place of the Add button.
    let refusal: String?
  }

  var pending: Request?

  /// Reads a link the app was opened with, and shows the sheet for it.
  func receive(_ url: URL, from sender: Sender?) {
    let request: Request
    do {
      let link = try BastionLink(link: url)
      request = Self.request(for: link, from: sender)
    } catch {
      hostLog("handoff", .info, "refused a bastion:// link: \(error.localizedDescription)")
      let alert = NSAlert()
      alert.messageText = "Bastion cannot add this server"
      alert.informativeText = error.localizedDescription
      NSApp.activate()
      alert.runModal()
      return
    }
    MainWindowController.show()
    pending = request
  }

  private static func request(for link: BastionLink, from sender: Sender?) -> Request {
    var refusal: String?
    var replacing: String?
    if link.id == BuiltinServer.id || ServerCatalog.all.contains(where: { $0.id == link.id }) {
      refusal = "“\(link.id)” is one of Bastion's own servers, so another app cannot take its name."
    } else if let existing = ServerStore.shared.server(id: link.id) {
      if case .remote(let endpoint) = existing.transport {
        replacing = endpoint.absoluteString == link.url ? nil : endpoint.absoluteString
      } else {
        refusal =
          "A server called “\(link.id)” is already in your list and runs a package, so it is left as it is."
      }
    }
    return Request(link: link, sender: sender, replacing: replacing, refusal: refusal)
  }

  /// The variable the token is kept under: `POCHETTE_TOKEN` for `pochette`.
  static func variable(for id: String) -> String {
    id.uppercased().replacingOccurrences(of: "-", with: "_") + "_TOKEN"
  }

  /// Adds the server, or brings an existing one up to date, and gives `profile` the token.
  func accept(_ request: Request, profile name: String, allowWrites: Bool) throws {
    let link = request.link
    let variable = Self.variable(for: link.id)
    let senderName = request.sender?.name ?? "another app"
    let definition = ServerStore.Definition(
      displayName: link.displayName,
      summary: link.summary ?? "Handed over by \(senderName).",
      npmName: nil, binName: nil, url: link.url, docsUrl: nil,
      dialect: BastionServer.Dialect.v2025_11_25.rawValue,
      writeGate: nil, writeTools: link.writeTools.isEmpty ? nil : link.writeTools,
      stateEnv: [],
      env: [
        .init(
          name: variable, required: true, secret: true,
          description: "The bearer token from \(link.displayName)'s settings.",
          header: .init(name: "Authorization", format: "Bearer {value}"))
      ])
    try ServerStore.shared.upsert(
      custom: link.id, definition: definition,
      replacing: ServerStore.shared.contains(link.id) ? link.id : nil)

    // The Keychain before the profile, as `ProfileEditor` saves: a profile on disk whose secret
    // is not reads as configured and cannot connect.
    try CredentialStore.write(
      .profile,
      account: CredentialStore.account(profile: name, server: link.id, variable: variable),
      value: link.token)
    let existing = ProfileStore.shared.profile(named: name, server: link.id)
    try ProfileStore.shared.upsert(
      Profile(
        name: name, serverID: link.id, values: existing?.values ?? [:],
        allowWrites: allowWrites, captureMode: existing?.captureMode))
    // A connection opened with the old token would otherwise keep using it.
    Supervisor.shared.stop(profile: name, server: link.id)
    hostLog(
      "handoff", .info,
      "added '\(link.id)' at \(link.url) for profile '\(name)', handed over by \(senderName)")
    pending = nil
    MainWindowController.show(.server(link.id))
  }

  /// The profile a request fills in: the server's own when it already has one, else `local`,
  /// the name Bastion's own server goes by on this Mac.
  static func suggestedProfile(for id: String) -> Profile? {
    ProfileStore.shared.profiles.first { $0.serverID == id }
  }
}

/// What the person sees before anything is added: who asked, what it points at, and which of
/// its tools change data.
struct ServerHandoffSheet: View {
  let request: ServerHandoff.Request

  @Environment(\.dismiss) private var dismiss
  @State private var profile = "local"
  @State private var allowWrites = false
  @State private var error: String?

  private var link: BastionLink { request.link }
  private var existing: Profile? { ServerHandoff.suggestedProfile(for: link.id) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Add \(link.displayName) to Bastion?").font(.title3.bold())
        Text(
          "\(request.sender?.name ?? "An app on this Mac") asks Bastion to stand in front of its MCP server. Its token goes into your Keychain, and clients reach it through Bastion."
        )
        .fixedSize(horizontal: false, vertical: true)

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
          row("Server", link.id)
          row("Endpoint", link.url)
          if let replacing = request.replacing { row("Replaces", replacing) }
          if let sender = request.sender {
            row(
              "Sent by",
              [sender.name, sender.bundleIdentifier].compactMap { $0 }.joined(separator: " · "))
          }
          if !link.writeTools.isEmpty {
            row("Write tools", link.writeTools.joined(separator: ", "))
          }
        }
        .font(.callout)

        if request.refusal == nil {
          Divider()
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Profile").frame(width: 96, alignment: .leading).font(.callout)
            TextField("local", text: $profile).textFieldStyle(.roundedBorder)
              .disabled(existing != nil)
          }
          if !link.writeTools.isEmpty {
            Toggle(isOn: $allowWrites) {
              Text("Allow writes")
              Text("Off, Bastion holds back the write tools above, whatever the app allows.")
            }
          }
        }
      }
      .padding(20)

      Divider()
      HStack(spacing: 10) {
        if let message = request.refusal ?? error {
          Text(message)
            .font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        if request.refusal == nil {
          Button(request.replacing == nil && existing == nil ? "Add" : "Update") { add() }
            .keyboardShortcut(.defaultAction)
            .disabled(!Profile.isValidName(profile))
        }
      }
      .padding(16)
    }
    .frame(width: 520)
    .onAppear {
      if let existing {
        profile = existing.name
        allowWrites = existing.allowWrites
      }
    }
  }

  @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label).foregroundStyle(.secondary)
      Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func add() {
    do {
      try ServerHandoff.shared.accept(request, profile: profile, allowWrites: allowWrites)
      dismiss()
    } catch {
      self.error = "Could not add it: \(error.localizedDescription)"
    }
  }
}
