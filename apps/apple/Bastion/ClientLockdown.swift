import Foundation

/// Only Bastion: what goes into a Claude Code profile's `settings.json`, what
/// state that file is in, and which keys are Bastion's to take back out.
///
/// Policy only, and Foundation only, so `make wiring-check` runs it against
/// fixtures. `ClientWiring+Lockdown` supplies the files and the clients;
/// `ClientSettingsSplice` does the editing. See the "Only Bastion" section of
/// `docs/clients.md`.
///
/// Hygiene rather than a boundary: user-scope `allowedMcpServers` merges with
/// every other settings scope, so a project's settings can widen it.
enum ClientLockdown {
  static let allowedKey = "allowedMcpServers"
  static let connectorsKey = "disableClaudeAiConnectors"
  /// `[client id: [keys Bastion added]]`. An id present, even with an empty
  /// list, is the switch on.
  static let defaultsKey = "clientLockdown"
  /// Written in this order.
  static let managedKeys = [connectorsKey, allowedKey]

  // MARK: - The allowlist

  static func bastionPattern(port: Int) -> [String: Any] {
    ["serverUrl": "http://127.0.0.1:\(port)/s/*"]
  }

  /// Bastion's wildcard on any loopback spelling and any port. Any port on
  /// purpose: a list written before the port changed is stale, not foreign.
  static func isBastionPattern(_ entry: Any) -> Bool {
    guard let url = (entry as? [String: Any])?["serverUrl"] as? String else { return false }
    return url.range(
      of: #"^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/s/\*$"#, options: .regularExpression)
      != nil
  }

  /// Whether a value of one of the two keys is the shape Bastion writes.
  static func isBastionShaped(_ key: String, _ value: Any?) -> Bool {
    switch key {
    case connectorsKey: return (value as? Bool) == true
    case allowedKey: return (value as? [Any])?.contains(where: isBastionPattern) == true
    default: return false
    }
  }

  struct Rule {
    let entry: [String: Any]
    /// "Bastion", or the first config key the rule came from.
    let label: String
  }

  struct Plan {
    let rules: [Rule]
    /// Every config key a rule was made for, duplicates included.
    let kept: [String]
    /// Entries with neither a url nor a command, which Claude Code could not
    /// launch either.
    let skipped: [String]
    var allowed: [[String: Any]] { rules.map(\.entry) }
  }

  /// Bastion's wildcard, then one exact rule per server in the profile's
  /// `.claude.json` that Bastion did not write: global first, then each project
  /// folder in path order, keys sorted within each, duplicates collapsed.
  static func plan(claudeConfig root: [String: Any], port: Int) -> Plan {
    var rules = [Rule(entry: bastionPattern(port: port), label: "Bastion")]
    var seen: Set<String> = [canonical(rules[0].entry)]
    var kept: [String] = []
    var skipped: [String] = []
    var blocks = [root["mcpServers"] as? [String: Any] ?? [:]]
    if let projects = root["projects"] as? [String: Any] {
      for folder in projects.keys.sorted() {
        if let servers = (projects[folder] as? [String: Any])?["mcpServers"] as? [String: Any] {
          blocks.append(servers)
        }
      }
    }
    for servers in blocks {
      for key in servers.keys.sorted() {
        let entry = servers[key]
        if ClientWiringMerge.isOurs(entry) { continue }
        guard let entry = entry as? [String: Any], let rule = rule(for: entry) else {
          if !skipped.contains(key) { skipped.append(key) }
          continue
        }
        if seen.insert(canonical(rule)).inserted { rules.append(Rule(entry: rule, label: key)) }
        kept.append(key)
      }
    }
    return Plan(rules: rules, kept: kept, skipped: skipped)
  }

  /// An exact `serverUrl` for a server with a URL, an exact `serverCommand`
  /// (command and args, never env) for one with a command.
  private static func rule(for entry: [String: Any]) -> [String: Any]? {
    if let url = entry["url"] as? String { return ["serverUrl": url] }
    if let command = entry["command"] as? String {
      return ["serverCommand": [command] + (entry["args"] as? [String] ?? [])]
    }
    return nil
  }

  static func canonical(_ value: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: - State

  enum State: Equatable {
    case off
    case on
    /// Ours, but the config gained a server (`missing`) or lost one (`extra`),
    /// or the port moved.
    case stale(missing: [String], extra: Int)
    /// Switched on, and these keys are no longer the shape Bastion writes.
    case drifted([String])
    /// Switched off, and the file still holds Bastion's wildcard.
    case leftBehind
    case unreadable(String)

    var summary: String {
      switch self {
      case .off: return "off"
      case .on: return "on"
      case .stale(let missing, _) where !missing.isEmpty:
        let shown = missing.prefix(4).joined(separator: ", ")
        let more = missing.count > 4 ? " and \(missing.count - 4) more" : ""
        return "stale — \(shown)\(more) not allowed"
      case .stale(_, let extra):
        return "stale — allows \(extra) server\(extra == 1 ? "" : "s") no longer configured"
      case .drifted(let keys):
        return "drifted — \(keys.joined(separator: ", ")) edited by hand"
      case .leftBehind:
        return "left behind — Bastion's allowlist is still in settings.json"
      case .unreadable(let why):
        return "unreadable — \(why)"
      }
    }

    var isUnreadable: Bool {
      if case .unreadable = self { return true }
      return false
    }
  }

  static func state(settings: [String: Any], plan: Plan, enabled: Bool) -> State {
    let allowed = settings[allowedKey]
    let ours = isBastionShaped(allowedKey, allowed)
    guard enabled else { return ours ? .leftBehind : .off }
    let drifted = managedKeys.filter { !isBastionShaped($0, settings[$0]) }
    if !drifted.isEmpty { return .drifted(drifted) }
    let current = Set((allowed as? [Any] ?? []).map(canonical))
    let wanted = plan.rules.map { canonical($0.entry) }
    let missing = zip(plan.rules, wanted).filter { !current.contains($0.1) }.map(\.0.label)
    let extra = current.subtracting(wanted).count
    return missing.isEmpty && extra == 0 ? .on : .stale(missing: missing, extra: extra)
  }

  // MARK: - Writing and removing

  enum Refusal: LocalizedError, Equatable {
    /// Keys the file already sets to something Bastion did not write.
    case collision([String])
    /// Keys Bastion wrote that were edited since.
    case drifted([String])

    var errorDescription: String? {
      switch self {
      case .collision(let keys):
        return "settings.json already sets \(keys.joined(separator: " and ")) to something "
          + "Bastion did not write. Replacing it keeps the old value in settings.json.bastion-backup."
      case .drifted(let keys):
        return "\(keys.joined(separator: " and ")) in settings.json was edited after Bastion "
          + "wrote it. Removing it would drop that edit."
      }
    }
  }

  /// The edits that turn the switch on or bring it current, and the keys
  /// Bastion owns afterwards.
  ///
  /// A key already holding exactly the wanted value is adopted, not recorded,
  /// so it outlives the switch. An allowlist of Bastion's shape is Bastion's
  /// (stale, or left behind) and is rewritten without `force`. Anything else
  /// already there is a collision unless `force`.
  static func enabling(
    current: [String: Any], plan: Plan, recorded: Set<String>, force: Bool
  ) throws -> (edits: [ClientSettingsSplice.Edit], owned: Set<String>) {
    let wanted: [(String, Any)] = [(connectorsKey, true), (allowedKey, plan.allowed)]
    var edits: [ClientSettingsSplice.Edit] = []
    var owned = recorded
    var collisions: [String] = []
    for (key, value) in wanted {
      guard let existing = current[key] else {
        edits.append((key, value))
        owned.insert(key)
        continue
      }
      if canonical(existing) == canonical(value) { continue }
      if (key == allowedKey && isBastionShaped(key, existing)) || force {
        edits.append((key, value))
        owned.insert(key)
        continue
      }
      collisions.append(key)
    }
    if !collisions.isEmpty { throw Refusal.collision(collisions) }
    return (edits, owned)
  }

  /// The edits that turn the switch off: each recorded key still in Bastion's
  /// shape is removed; one edited out of it refuses unless `force`.
  static func disabling(
    current: [String: Any], recorded: Set<String>, force: Bool
  ) throws -> [ClientSettingsSplice.Edit] {
    var edits: [ClientSettingsSplice.Edit] = []
    var drifted: [String] = []
    for key in managedKeys where recorded.contains(key) {
      guard let existing = current[key] else { continue }
      if isBastionShaped(key, existing) || force {
        edits.append((key, nil))
      } else {
        drifted.append(key)
      }
    }
    if !drifted.isEmpty { throw Refusal.drifted(drifted) }
    return edits
  }

  // MARK: - The record

  static func records(_ defaults: UserDefaults = .standard) -> [String: [String]] {
    defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
  }

  /// The keys Bastion added for this client, or nil when the switch is off.
  static func recorded(_ id: String, _ defaults: UserDefaults = .standard) -> Set<String>? {
    records(defaults)[id].map(Set.init)
  }

  static func record(_ id: String, owned: Set<String>, _ defaults: UserDefaults = .standard) {
    var all = records(defaults)
    all[id] = managedKeys.filter(owned.contains)
    defaults.set(all, forKey: defaultsKey)
  }

  static func forget(_ id: String, _ defaults: UserDefaults = .standard) {
    var all = records(defaults)
    all[id] = nil
    defaults.set(all, forKey: defaultsKey)
  }
}
