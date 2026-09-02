import Foundation
import Observation

/// What each profile's tool list was last measured to cost, across launches.
///
/// `ServerCheck.runs` is deliberately never persisted, and the reason given
/// there holds: a check result on disk becomes a confident claim about a machine
/// state that has since moved on. This is the same fact one step removed, and it
/// survives the objection by carrying what would falsify it. A cost is a
/// property of a package version and a write gate, not of a moment — so the
/// version and the gate are stored beside it, and `current(for:server:)` returns
/// nothing at all once either has moved. A figure that cannot go stale silently
/// is a different object from a cached verdict.
///
/// Keyed by `profile.id` rather than by server, because the tool surface is not
/// always a property of the package: `mcp-stripe` varies its tools by auth mode,
/// so two profiles on one server can honestly disagree about what they cost.
@Observable
final class ToolCostStore {
  static let shared = ToolCostStore()

  struct Measurement: Codable, Sendable {
    var bytes: Int
    var toolCount: Int
    /// Whether the list was paginated, so every sentence built from `bytes`
    /// goes on hedging the way the check sheet does.
    var partial: Bool
    /// The installed package version when this was taken, and nil for a remote
    /// server, which has none. Nil matching nil is intentional: there is nothing
    /// to compare, so a remote figure ages out on the write gate alone.
    var version: String?
    var allowWrites: Bool
    var measuredAt: Date
  }

  private(set) var measurements: [String: Measurement] = [:]

  private var fileURL: URL { AppSupport.directory.appendingPathComponent("tool-costs.json") }

  init() { load() }

  /// What is still true about this profile, or nothing.
  ///
  /// The gate and the version are both checked because both move the figure and
  /// neither announces itself to this store: installing rewrites the package
  /// under a profile that never changed, and flipping the gate changes the tool
  /// list without touching the code on disk.
  func current(for profile: Profile, server: BastionServer) -> Measurement? {
    guard let measurement = measurements[profile.id] else { return nil }
    guard
      ToolCost.isCurrent(
        measuredVersion: measurement.version, measuredAllowWrites: measurement.allowWrites,
        version: ServerInstaller.installedVersion(of: server),
        allowWrites: profile.allowWrites)
    else { return nil }
    return measurement
  }

  func record(
    profileID: String, bytes: Int, toolCount: Int, partial: Bool, version: String?,
    allowWrites: Bool
  ) {
    measurements[profileID] = Measurement(
      bytes: bytes, toolCount: toolCount, partial: partial, version: version,
      allowWrites: allowWrites, measuredAt: Date())
    save()
  }

  /// Drop a profile's figure outright.
  ///
  /// For the change the stamp cannot see: editing a profile's values can move
  /// the tool surface with the gate and the package version both unchanged.
  func forget(_ profileID: String) {
    guard measurements.removeValue(forKey: profileID) != nil else { return }
    save()
  }

  private func load() {
    if DemoSeed.isEnabled {
      measurements = [:]
      return
    }
    guard let data = try? Data(contentsOf: fileURL),
      let rows = try? JSONDecoder().decode([String: Measurement].self, from: data)
    else {
      measurements = [:]
      return
    }
    measurements = rows
  }

  private func save() {
    if DemoSeed.isEnabled { return }
    AppSupport.ensureDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? encoder.encode(measurements).write(to: fileURL, options: .atomic)
  }
}
