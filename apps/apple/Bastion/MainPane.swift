import Foundation

/// What the sidebar selects.
///
/// Servers and clients carry an **id** rather than the value itself, and the
/// detail pane re-resolves it. A `BastionServer` captured in the selection
/// would be a copy of a generated table, and a `ClientWiring.Client` captured
/// there would be a snapshot of somebody else's config file — which is exactly
/// the thing `ClientDetail` refuses to cache.
enum MainPane: Hashable {
  case server(String)
  /// A server's row in a workspace's section. A server whose profiles are
  /// split between sections has a row in each, and each row needs a tag of
  /// its own, or clicking one would highlight both.
  case scopedServer(workspace: String, server: String)
  case workspace(String)
  case client(String)
  case running
  case stats
  case log
  case chat

  /// The server either kind of server row opens.
  var serverID: String? {
    switch self {
    case .server(let id), .scopedServer(_, let id): id
    default: nil
    }
  }
}

/// `RawRepresentable` so the selection can live in `@AppStorage`. See
/// `MainView.pane` for why it has to.
extension MainPane: RawRepresentable {
  static let defaultsKey = "mainPane"

  init?(rawValue: String) {
    switch rawValue {
    case "running": self = .running
    case "stats": self = .stats
    case "log": self = .log
    case "chat": self = .chat
    default:
      guard let separator = rawValue.firstIndex(of: ":") else { return nil }
      let id = String(rawValue[rawValue.index(after: separator)...])
      guard !id.isEmpty else { return nil }
      switch rawValue[..<separator] {
      case "server": self = .server(id)
      case "client": self = .client(id)
      case "workspace": self = .workspace(id)
      // A workspace name is kebab-case and never holds a slash, so the first
      // one is the boundary.
      case "scoped-server":
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let workspace = String(id[..<slash])
        let server = String(id[id.index(after: slash)...])
        guard !workspace.isEmpty, !server.isEmpty else { return nil }
        self = .scopedServer(workspace: workspace, server: server)
      default: return nil
      }
    }
  }

  var rawValue: String {
    switch self {
    case .server(let id): "server:\(id)"
    case .scopedServer(let workspace, let server): "scoped-server:\(workspace)/\(server)"
    case .workspace(let name): "workspace:\(name)"
    case .client(let id): "client:\(id)"
    case .running: "running"
    case .stats: "stats"
    case .log: "log"
    case .chat: "chat"
    }
  }
}
