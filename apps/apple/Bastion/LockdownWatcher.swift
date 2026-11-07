import Foundation

/// Brings an Only Bastion allowlist current when something other than Bastion
/// adds a server to the profile's `.claude.json`.
///
/// Before this the list was refreshed only by `rewire`, which runs when Bastion
/// launches or its own servers, profiles or workspaces change. Cupertino
/// switching on a surface, or `claude mcp add`, wrote an entry the list did not
/// allow, and Claude Code hides a server its allowlist refuses: it is missing
/// from `/mcp`, with nothing saying why, until Bastion next launched.
///
/// Claude Code rewrites `.claude.json` on every session, so most changes need
/// nothing: `refreshStaleLockdowns` reads both files and writes only for
/// `ClientLockdown.refreshesOnChange`.
enum LockdownWatcher {
  private static let files = ConfigFileWatcher { ClientWiring.refreshStaleLockdowns() }

  /// Watch the config file of every client whose switch is on, and nothing
  /// else. Called at launch and after every `setLockdown`, which is the only
  /// thing that turns a switch on or off. Gated on `autoWires`, as `rewire`
  /// is: a Debug build never rewrites the real profiles unasked.
  static func update() {
    guard ClientWiring.autoWires else {
      files.watch([])
      return
    }
    let records = ClientLockdown.records()
    files.watch(
      Set(
        ClientWiring.all
          .filter { records[$0.id] != nil && ClientWiring.supportsLockdown($0) }
          .map(\.configURL.path)))
  }
}
