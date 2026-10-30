import Foundation

/// A section of the sidebar's server list.
///
/// `.servers` is the only one there is while no workspace exists, so a Mac that
/// never made one sees the sidebar it always had. Once one does, each workspace
/// is a section and `.everywhere`, the profiles every client gets, comes last.
nonisolated enum ServerSectionKind: Hashable, Codable {
  case servers
  case workspace(String)
  case everywhere

  /// The section's key in the collapsed set, or nil for the one that never
  /// collapses.
  var collapseKey: String? {
    switch self {
    case .servers: nil
    case .workspace(let name): "workspace:\(name)"
    case .everywhere: "everywhere"
    }
  }

  /// The workspace a move into or out of this section changes, nil for
  /// Everywhere.
  var workspaceName: String? {
    if case .workspace(let name) = self { return name }
    return nil
  }
}

/// One server's row in one section.
nonisolated struct ServerRow: Hashable, Identifiable {
  let serverID: String
  /// The profiles of this server this section holds, sorted. What a drag of
  /// this row moves. Empty for a server with no profile at all.
  let profileIDs: [String]
  /// Which of the server's profiles these are, for a server shown in more than
  /// one section. Nil otherwise, so the usual one-profile row reads as before.
  let caption: String?
  let pane: MainPane
  var id: String { serverID }
}

nonisolated struct ServerSection: Identifiable {
  let kind: ServerSectionKind
  let rows: [ServerRow]
  var id: ServerSectionKind { kind }
}

/// What the sidebar's server list shows, worked out from plain values so
/// `wiring-check` can assert it.
///
/// The rows stay servers although a workspace holds profiles: most servers have
/// one profile, and the sidebar is where somebody looks for a server. A server
/// whose profiles sit in different sections gets a row in each.
nonisolated enum WorkspaceSidebar {
  static func sections(
    servers: [String], profiles: [(id: String, serverID: String)], workspaces: [Workspace]
  ) -> [ServerSection] {
    var byServer: [String: [String]] = [:]
    for profile in profiles { byServer[profile.serverID, default: []].append(profile.id) }

    if workspaces.isEmpty {
      let rows = servers.map { server in
        ServerRow(
          serverID: server, profileIDs: (byServer[server] ?? []).sorted(), caption: nil,
          pane: .server(server))
      }
      return [ServerSection(kind: .servers, rows: rows)]
    }

    // Rows before captions: whether a server needs one depends on how many
    // sections it ended up in.
    var drafts: [(kind: ServerSectionKind, rows: [(server: String, profiles: [String])])] = []
    for workspace in workspaces.sorted(by: { $0.name < $1.name }) {
      let members = Set(workspace.profiles)
      let rows = servers.compactMap { server -> (String, [String])? in
        let held = (byServer[server] ?? []).filter(members.contains).sorted()
        return held.isEmpty ? nil : (server, held)
      }
      drafts.append((.workspace(workspace.name), rows))
    }
    let scoped = WorkspaceScope.scopedIDs(workspaces)
    let everywhere = servers.compactMap { server -> (String, [String])? in
      let all = byServer[server] ?? []
      let held = all.filter { !scoped.contains($0) }.sorted()
      return all.isEmpty || !held.isEmpty ? (server, held) : nil
    }
    drafts.append((.everywhere, everywhere))

    var appearances: [String: Int] = [:]
    for draft in drafts {
      for row in draft.rows { appearances[row.server, default: 0] += 1 }
    }
    return drafts.map { draft in
      let rows = draft.rows.map { row in
        let caption =
          appearances[row.server, default: 0] > 1
          ? row.profiles.map(profileName).sorted().joined(separator: ", ") : nil
        let pane: MainPane =
          switch draft.kind {
          case .workspace(let name): .scopedServer(workspace: name, server: row.server)
          case .servers, .everywhere: .server(row.server)
          }
        return ServerRow(
          serverID: row.server, profileIDs: row.profiles, caption: caption, pane: pane)
      }
      return ServerSection(kind: draft.kind, rows: rows)
    }
  }

  /// The row a selection highlights.
  ///
  /// `.server(id)` is what every deep link names, the menu bar's and the demo
  /// stages' included, and it has no row once all of that server's profiles are
  /// in workspaces. A `.scopedServer` goes stale the moment its profile moves.
  /// Either way the server's first row stands in, so what is highlighted and
  /// what is open agree.
  static func rowPane(for pane: MainPane, in sections: [ServerSection]) -> MainPane {
    guard let server = pane.serverID else { return pane }
    let rows = sections.flatMap(\.rows)
    if rows.contains(where: { $0.pane == pane }) { return pane }
    return rows.first { $0.serverID == server }?.pane ?? pane
  }

  /// `rgis` for `rgis/ovh`.
  private static func profileName(_ id: String) -> String {
    id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
  }
}

/// Which server sections are collapsed, as the comma-separated string
/// `@AppStorage` can hold. Per Mac: it is a view preference, not a setting.
nonisolated enum CollapsedServerSections {
  static let defaultsKey = "sidebar.collapsedServerSections"

  /// Unknown keys are kept: a workspace deleted and made again under the same
  /// name comes back as it was, and nothing reads a key it does not ask for.
  static func decode(_ raw: String) -> Set<String> {
    Set(raw.split(separator: ",").map(String.init).filter { !$0.isEmpty })
  }

  static func encode(_ keys: Set<String>) -> String { keys.sorted().joined(separator: ",") }

  static func setting(_ kind: ServerSectionKind, expanded: Bool, in raw: String) -> String {
    guard let key = kind.collapseKey else { return raw }
    var keys = decode(raw)
    if expanded { keys.remove(key) } else { keys.insert(key) }
    return encode(keys)
  }
}
