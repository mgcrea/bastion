import Foundation

/// Only Bastion for the Claude Code rows: where each profile's `settings.json`
/// is, what state it is in, and the one path that writes it. The policy is
/// `ClientLockdown`; the editing is `ClientSettingsSplice`.
extension ClientWiring {
  enum LockdownError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
      switch self {
      case .unsupported(let name):
        return "\(name) is not a Claude Code profile. Only Bastion writes Claude Code's "
          + "settings.json and nothing else."
      }
    }
  }

  /// Claude Code and its config directories, and nothing else: no other client
  /// has a setting that filters MCP servers by source.
  static func supportsLockdown(_ client: Client) -> Bool {
    client.family == ClaudeProfiles.family && client.format == .json
  }

  /// `<config dir>/settings.json`.
  ///
  /// The default profile is the asymmetry `ClaudeProfiles.configName` warns
  /// about, the other way round: its `.claude.json` sits OUTSIDE `~/.claude`,
  /// its `settings.json` INSIDE. A profile row's config file is already inside
  /// its directory, so the two sit side by side.
  static func settingsURL(for client: Client) -> URL? {
    guard supportsLockdown(client) else { return nil }
    let directory =
      ClientIdentity.suffix(of: client.id) == nil
      ? client.configURL.deletingLastPathComponent().appendingPathComponent(".claude")
      : client.configURL.deletingLastPathComponent()
    return directory.appendingPathComponent("settings.json")
  }

  struct Lockdown {
    let state: ClientLockdown.State
    /// Nil when either file could not be read.
    let plan: ClientLockdown.Plan?
    let settingsURL: URL
  }

  /// The allowlist this client's `.claude.json` calls for right now.
  static func lockdownPlan(of client: Client) throws -> ClientLockdown.Plan {
    let root = hasConfig(client) ? try ClientWiringMerge.readJSON(client.configURL) : [:]
    return ClientLockdown.plan(claudeConfig: root, port: Int(Gateway.shared.port))
  }

  /// Re-read on every call, like `status(of:)`: both files are Claude Code's.
  static func lockdown(of client: Client) -> Lockdown? {
    guard let url = settingsURL(for: client) else { return nil }
    let enabled = ClientLockdown.recorded(client.id) != nil
    do {
      let plan = try lockdownPlan(of: client)
      let data =
        FileManager.default.fileExists(atPath: url.path)
        ? try ClientWiringMerge.settledContents(of: url) : Data()
      let values = try ClientSettingsSplice.parse(data).values
      return Lockdown(
        state: ClientLockdown.state(settings: values, plan: plan, enabled: enabled), plan: plan,
        settingsURL: url)
    } catch {
      return Lockdown(state: .unreadable(error.localizedDescription), plan: nil, settingsURL: url)
    }
  }

  /// Turn Only Bastion on (or bring it current), or off.
  ///
  /// Refusals are `ClientLockdown.Refusal`, and `force` is the override for
  /// both, as `wire`'s is for a collision. The record is updated only after a
  /// write succeeded, or when there was nothing to write.
  @discardableResult
  static func setLockdown(_ client: Client, on: Bool, force: Bool = false) throws -> URL? {
    guard let url = settingsURL(for: client) else {
      throw LockdownError.unsupported(client.displayName)
    }
    let plan = on ? try lockdownPlan(of: client) : nil
    var owned: Set<String> = []
    let backup = try retryingIfChanged(url) {
      try ClientSettingsSplice.rewrite(url, backupSuffix: "bastion-backup") { current in
        let recorded = ClientLockdown.recorded(client.id)
        if let plan {
          let result = try ClientLockdown.enabling(
            current: current, plan: plan, recorded: recorded ?? [], force: force)
          owned = result.owned
          return result.edits
        }
        // Left behind: no record, so only the allowlist is known to be ours.
        let keys =
          recorded
          ?? (ClientLockdown.isBastionShaped(
            ClientLockdown.allowedKey, current[ClientLockdown.allowedKey])
            ? [ClientLockdown.allowedKey] : [])
        return try ClientLockdown.disabling(current: current, recorded: keys, force: force)
      }
    }
    if on {
      ClientLockdown.record(client.id, owned: owned)
    } else {
      ClientLockdown.forget(client.id)
    }
    ClientConfigRevision.shared.bump()
    hostLog(
      "wiring", .info,
      "\(client.displayName): Only Bastion \(on ? "on" : "off")"
        + (backup.map { " (backup at \($0.lastPathComponent))" } ?? ""))
    return backup
  }

  /// For `rewire`: bring every switched-on profile's allowlist up to date.
  /// Logged, never raised, for the same reason `rewire` is silent.
  static func refreshLockdowns() {
    let records = ClientLockdown.records()
    for client in all where records[client.id] != nil {
      do {
        try setLockdown(client, on: true)
      } catch {
        hostLog(
          "wiring", .error,
          "\(client.displayName): Only Bastion left unchanged — \(error.localizedDescription)")
      }
    }
  }
}
