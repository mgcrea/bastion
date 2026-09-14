import Foundation

/// What a wired profile costs a client on every connect.
///
/// One computation, three readers: the client pane's sentence, the statistics
/// pane's ranking, and whatever asks next. It was one reader and a loop inside
/// `ClientDetail.contextBill` until the ranking needed the same arithmetic — and
/// two copies of this rule would disagree the first time the facade's floor
/// moved, in a product whose pitch is that the number is trustworthy.
///
/// **A forecast, not a measurement.** Every figure here comes from
/// `ToolCostStore`, which holds what a profile's `tools/list` was last measured
/// to weigh. What actually crossed the gateway is `CallStats`, and the two are
/// deliberately never added together: one says what a client is sent before it
/// asks anything, the other says what it pulled through afterwards.
@MainActor
enum ContextBill {
  struct Row: Identifiable, Sendable {
    var profileID: String
    var serverID: String
    var displayName: String
    /// What the server's whole listing weighs.
    var fullBytes: Int
    /// What this client is actually sent, which is the facade's declarations
    /// instead when the facade applies to it.
    var sentBytes: Int
    var toolCount: Int
    /// The listing was read one page at a time, so `fullBytes` is a floor and
    /// every sentence built from it says "at least".
    var partial: Bool
    /// The facade stood in front of this listing for this client.
    var isFronted: Bool
    var id: String { profileID }

    var savedBytes: Int { Swift.max(0, fullBytes - sentBytes) }
  }

  /// One profile's row, or nothing at all when it has never been measured.
  ///
  /// Nothing rather than a zero, for the reason `ToolCostStore.current` returns
  /// nothing once a figure goes stale: a server nobody has listed yet has an
  /// unknown cost, and an unknown cost rendered as zero is a different and
  /// wrong claim. Callers count what they got and say so.
  static func row(profile: Profile, server: BastionServer, defers: Bool) -> Row? {
    guard let cost = ToolCostStore.shared.current(for: profile, server: server) else { return nil }

    let facade = ToolFacade.declarationBytes(
      displayName: server.displayName, summary: server.summary, toolCount: cost.toolCount,
      hasWriteDispatcher: (cost.writeToolCount ?? 0) > 0)
    // Three axes, and the third is measured rather than configured: a listing
    // the declarations would not meaningfully shrink is forwarded whole, so
    // counting the facade for it would understate what this client is sent.
    // `partial` counts as fronted — the gateway decides on the whole list, and
    // this figure stopped at page one.
    let fronted =
      server.loadsToolsOnDemand && !defers
      && (cost.partial
        || ToolFacade.worthFronting(
          listingBytes: cost.bytes, listingCount: cost.toolCount, facadeBytes: facade,
          facadeCount: ToolFacade.declarationCount(
            hasWriteDispatcher: (cost.writeToolCount ?? 0) > 0)))

    return Row(
      profileID: profile.id, serverID: server.id, displayName: server.displayName,
      fullBytes: cost.bytes, sentBytes: fronted ? facade : cost.bytes, toolCount: cost.toolCount,
      partial: cost.partial, isFronted: fronted)
  }

  static func row(profile: Profile, defers: Bool = false) -> Row? {
    guard let server = ServerStore.shared.server(id: profile.serverID) else { return nil }
    return row(profile: profile, server: server, defers: defers)
  }

  /// Every measured profile, ranked by what it costs, heaviest first.
  ///
  /// Keyed by profile because the cost is: `allowWrites` filters the catalogue
  /// and `mcp-stripe` varies its tools by auth mode, so two profiles of one
  /// server can honestly disagree about the number. The statistics pane folds
  /// them per server for display using `representative`, which takes one rather
  /// than summing, for the reason `ServerDetail.lazyToolsMeasurement` gives.
  static func ranked(defers: Bool = false) -> [Row] {
    ProfileStore.shared.profiles
      .compactMap { row(profile: $0, defers: defers) }
      .sorted { ($0.sentBytes, $0.profileID) > ($1.sentBytes, $1.profileID) }
  }

  /// One row per server, taking the heaviest profile rather than summing.
  ///
  /// Summing would answer a question nobody asked: a client is wired to one
  /// profile of a server, not to all of them, so the total across `prod` and
  /// `staging` is a cost nothing actually pays. `ServerDetail` already takes the
  /// first current measurement for the same reason; this takes the largest so
  /// the ranking cannot be reordered by which profile happened to be measured
  /// first.
  static func perServer(defers: Bool = false) -> [Row] {
    var best: [String: Row] = [:]
    for row in ranked(defers: defers) where (best[row.serverID]?.sentBytes ?? -1) < row.sentBytes {
      best[row.serverID] = row
    }
    return best.values.sorted { ($0.sentBytes, $0.serverID) > ($1.sentBytes, $1.serverID) }
  }

  /// How many profiles of this server are wired and measured, so a row can say
  /// that the figure is one of several rather than the only one.
  static func measuredProfiles(ofServer serverID: String) -> Int {
    ProfileStore.shared.profiles.filter { $0.serverID == serverID }
      .compactMap { row(profile: $0) }.count
  }
}
