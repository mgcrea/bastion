import SwiftUI

/// Wiring, with the file it is about to touch named on screen.
///
/// The whole feature writes into files somebody else owns — `~/.claude.json`
/// here holds nine global servers and ninety-eight project blocks — so the
/// window's job is as much reassurance as action: it says which file, what is
/// in it now, and where the backup went. "Reveal" is there so anyone who would
/// rather look than trust can, before pressing anything.
struct ClientsWindow: View {
  @State private var lastResult: String?

  var body: some View {
    let profiles = ProfileStore.shared.profiles

    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        // No heading: the title bar already says "MCP Clients", and a window
        // that says its own name twice is one line further from the sentence
        // that matters.
        if profiles.isEmpty {
          Text("No profiles yet. A client can only be wired to something that exists.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text(
            "Wiring writes \(profiles.count) server\(profiles.count == 1 ? "" : "s") into the "
              + "client's own config, backs the original up first, and never touches a key it "
              + "did not write.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(16)

      Divider()

      ScrollView {
        VStack(spacing: 0) {
          ForEach(ClientWiring.all) { client in
            ClientRow(client: client, profiles: profiles, result: $lastResult)
            Divider().padding(.leading, 16)
          }
        }
      }

      if let lastResult {
        Divider()
        Text(lastResult)
          .font(.caption).foregroundStyle(.secondary)
          .padding(.horizontal, 16).padding(.vertical, 8)
          .textSelection(.enabled)
      }
    }
    .frame(minWidth: 520, minHeight: 380)
  }
}

private struct ClientRow: View {
  let client: ClientWiring.Client
  let profiles: [Profile]
  @Binding var result: String?

  // Recomputed on every redraw rather than cached. The file belongs to another
  // application that may have rewritten it a second ago, so a remembered status
  // is a claim about a file this app does not own and did not watch.
  private var status: ClientWiring.Status {
    ClientWiring.status(of: client, profiles: profiles)
  }

  /// Whether the config currently holds anything `isOurs` recognises —
  /// including entries for a profile that no longer exists, which is exactly
  /// the case worth being able to clean up.
  private var hasOurEntries: Bool {
    guard client.isInstalled,
      let root = try? ClientWiringMerge.readJSON(client.configURL),
      let servers = root[client.rootKey] as? [String: Any]
    else { return false }
    return servers.values.contains { ClientWiringMerge.isOurs($0) }
  }

  var body: some View {
    let status = status
    HStack(alignment: .top, spacing: 10) {
      Circle().fill(tint(status)).frame(width: 7, height: 7).padding(.top, 6)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(client.displayName).bold()
          Text(status.summary).font(.caption).foregroundStyle(.secondary)
        }
        // The path, always. Someone about to let an app write to a config is
        // owed the name of the file.
        Text(client.configURL.path)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(1).truncationMode(.middle)
        if let caveat = client.caveat {
          Text(caveat).font(.caption2).foregroundStyle(.secondary)
        }
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 4) {
        Button("Configure") { wire() }
          .disabled(profiles.isEmpty || !client.isInstalled)
        HStack(spacing: 8) {
          // Offered only when there is something of ours to take out. A
          // "Remove" that rewrites a config to make no change is a write to
          // somebody else's file for nothing.
          Button("Remove") { unwire() }
            .disabled(!hasOurEntries)
          Button("Reveal") { ClientWiring.reveal(client) }
            .disabled(!client.isInstalled)
        }
        .font(.caption)
        .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func tint(_ status: ClientWiring.Status) -> Color {
    switch status {
    case .audited(.configured): .green
    case .audited(.notConfigured), .notInstalled: .secondary
    case .audited(.incomplete): .orange
    case .audited(.stale), .unreadable: .red
    }
  }

  private func wire() {
    do {
      let backup = try ClientWiring.wire(client, profiles: profiles)
      result =
        "Wrote \(profiles.count) entr\(profiles.count == 1 ? "y" : "ies") to \(client.configURL.path)."
        + (backup.map { " Previous version saved as \($0.lastPathComponent)." } ?? "")
        + " Restart \(client.displayName) to pick them up."
    } catch {
      result = "Could not write \(client.configURL.path): \(error.localizedDescription)"
    }
  }

  private func unwire() {
    do {
      let backup = try ClientWiring.unwire(client)
      result =
        "Removed Bastion's entries from \(client.configURL.path)."
        + (backup.map { " Previous version saved as \($0.lastPathComponent)." } ?? "")
    } catch {
      result = "Could not write \(client.configURL.path): \(error.localizedDescription)"
    }
  }
}
