import Foundation

/// What a server's `tools/list` costs the client that receives it.
///
/// Every editor wired to a profile is sent every tool definition before it can
/// call one, and holds them for the whole conversation. That is the largest
/// fixed charge a shared gateway imposes on its clients and nothing in Bastion
/// reported it: `ServerCheck` already asks each server what it exposes and threw
/// the size away.
///
/// **Bytes over four, not a tokenizer.** `LanguageModelSession.tokenCount(for:)`
/// is exact, but it counts with Apple's tokenizer, and the context being spent
/// here belongs to whatever model the editor runs. An exact count of the wrong
/// tokenizer reads as authoritative while being no better than the ratio, so the
/// ratio is used and every sentence built from it says "about". The precedent is
/// already in the tree: `BuiltinTools.activityBudget` sizes itself the same way.
///
/// **The raw entry, not the parsed `MCPTool`.** `MCPTool` keeps `name`,
/// `description` and `inputSchema` and drops `outputSchema`, `title` and the
/// `annotations` object; `ToolProbe.summary` then truncates the description at
/// 300 characters. Weighing that would measure Bastion's parser rather than the
/// server, and it would under-report by the fields a client is nonetheless sent.
/// This is also why the figure here and the budget in the Chat pane differ and
/// must go on being separate: `ChatSession.cost` honestly measures the trimmed
/// object handed to the on-device model, which is a different artifact.
///
/// Two known under-counts, both small and both in the safe direction: a
/// re-serialized entry writes non-ASCII as raw UTF-8 where the server may have
/// sent `é`, and `WriteGate.visibleTools` forwards nameless entries that
/// `MCPTool.init(json:)` drops, so a client can pay for something never counted.
///
/// Its own file with no dependency on anything in the app, so `make unit` can
/// compile it alone and feed it real entries — the argument `WriteGate` makes
/// for `remote-check`, for the same reason: a rule with no test is a rule that
/// gets re-derived somewhere else.
nonisolated enum ToolCost {
  /// The ratio every figure here is built on.
  static let bytesPerToken = 4

  /// What one `tools/list` entry occupies, serialized.
  ///
  /// Bytes rather than tokens, because callers sum these. Tokens floor per tool,
  /// and forty-seven floored parts do not add up to the whole the card claims.
  ///
  /// The zero on failure is unreachable for a real entry: this is handed the
  /// output of `JSONSerialization.jsonObject`, so it is always re-encodable.
  static func bytes(of entry: [String: Any]) -> Int {
    (try? JSONSerialization.data(withJSONObject: entry))?.count ?? 0
  }

  /// Floors, so a partial token is never billed.
  static func tokens(bytes: Int) -> Int { bytes / bytesPerToken }

  /// "870", "1k", "15.8k".
  ///
  /// Integer arithmetic rather than a formatter: this appears in a sentence
  /// beside a tool count, one decimal place is the whole requirement, and a
  /// locale that writes "15,8k" would make the unit test a lie about the build
  /// machine rather than about the code.
  static func short(_ tokens: Int) -> String {
    guard tokens >= 1000 else { return "\(tokens)" }
    let tenths = (tokens + 50) / 100
    return tenths % 10 == 0 ? "\(tenths / 10)k" : "\(tenths / 10).\(tenths % 10)k"
  }

  /// Whether a stored measurement still describes what a client would be sent.
  ///
  /// The rule that decides whether a figure is shown at all, kept here as a
  /// pure function so `make unit` can hold it: `ToolCostStore` reaches the
  /// Keychain, the profile store and the filesystem, and cannot be compiled
  /// alone. This is the `WriteGate` split again, for the reason given there.
  ///
  /// Both terms move the tool list and neither tells this store it moved. An
  /// npm update rewrites the package under a profile nobody edited, and the
  /// write gate changes the list without touching the code on disk. A remote
  /// server has no package, so nil on both sides matches and it ages out on the
  /// gate alone.
  static func isCurrent(
    measuredVersion: String?, measuredAllowWrites: Bool, version: String?, allowWrites: Bool
  ) -> Bool {
    measuredVersion == version && measuredAllowWrites == allowWrites
  }

  /// The clause every caller says, so they cannot disagree about the hedge.
  ///
  /// `partial` is the paginated list, where the check has read one page of an
  /// unknown number and "about" would be a straight lie.
  static func phrase(bytes: Int, partial: Bool = false) -> String {
    "\(partial ? "at least" : "about") \(short(tokens(bytes: bytes))) tokens"
  }
}
