import SwiftUI

/// The Only Bastion switch for one Claude Code profile: an allowlist in that
/// profile's `settings.json` that lets through Bastion and the servers already
/// in its `.claude.json`, and nothing a plugin or claude.ai adds. See the
/// "Only Bastion" section of docs/clients.md.
///
/// Re-read on every redraw, like the rest of `ClientDetail`: both files are
/// Claude Code's, and either may have changed a second ago.
struct ClientLockdownCard: View {
  let client: ClientWiring.Client

  @State private var message: String?
  /// A refused change waiting on "Replace": the direction it was going.
  @State private var pendingForce: Bool?
  @State private var refusal = ""

  private var lockdown: ClientWiring.Lockdown? {
    // Subscribes the card to Bastion's own writes, as in `ClientDetail.read()`.
    _ = ClientConfigRevision.shared.value
    return ClientWiring.lockdown(of: client)
  }

  var body: some View {
    if let lockdown {
      Card(title: "Only Bastion") {
        VStack(alignment: .leading, spacing: 6) {
          Toggle(
            "Allow only Bastion and the servers in this config",
            isOn: Binding(
              get: { Self.isOn(lockdown.state) },
              set: { change(on: $0, force: false) })
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(lockdown.state.isUnreadable)

          HStack(spacing: 8) {
            Text(lockdown.state.summary)
              .font(.callout)
              .foregroundStyle(Self.tint(lockdown.state))
              .fixedSize(horizontal: false, vertical: true)
            switch lockdown.state {
            case .stale, .drifted:
              Button("Update") { change(on: true, force: false) }.controlSize(.small)
            case .leftBehind:
              Button("Remove") { change(on: false, force: false) }.controlSize(.small)
            default:
              EmptyView()
            }
          }

          if let plan = lockdown.plan {
            Text("Allowed: " + (["Bastion"] + plan.kept).joined(separator: ", "))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if !plan.skipped.isEmpty {
              Text("Not allowed, no url or command: " + plan.skipped.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          Text(
            "Writes disableClaudeAiConnectors and allowedMcpServers into "
              + (lockdown.settingsURL.path as NSString).abbreviatingWithTildeInPath
              + ". Servers added by plugins, claude.ai connectors and a repository's .mcp.json "
              + "are blocked; a project's own settings can still widen the list. Start a new "
              + "\(client.displayName) session to apply."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          if let message {
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .alert(
        "settings.json was not written",
        isPresented: Binding(get: { pendingForce != nil }, set: { if !$0 { pendingForce = nil } })
      ) {
        Button("Replace", role: .destructive) {
          let on = pendingForce
          pendingForce = nil
          if let on { change(on: on, force: true) }
        }
        Button("Cancel", role: .cancel) { pendingForce = nil }
      } message: {
        Text(refusal)
      }
    }
  }

  private func change(on: Bool, force: Bool) {
    do {
      let backup = try ClientWiring.setLockdown(client, on: on, force: force)
      message =
        (on ? "Only Bastion is on." : "Only Bastion is off.")
        + (backup.map { " Previous version saved as \($0.lastPathComponent)." } ?? "")
        + " Start a new \(client.displayName) session to apply."
    } catch let refused as ClientLockdown.Refusal {
      refusal = refused.localizedDescription
      message = refusal
      pendingForce = on
    } catch {
      message = "Could not write settings.json: \(error.localizedDescription)"
    }
  }

  static func isOn(_ state: ClientLockdown.State) -> Bool {
    switch state {
    case .on, .stale, .drifted: true
    case .off, .leftBehind, .unreadable: false
    }
  }

  static func tint(_ state: ClientLockdown.State) -> Color {
    switch state {
    case .on: .green
    case .stale: .orange
    case .drifted, .unreadable: .red
    case .off, .leftBehind: .secondary
    }
  }
}
