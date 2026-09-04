import Foundation

/// Three tools in place of eighty-five, and a way back to the eighty-five.
///
/// Every editor wired to a profile is sent every tool definition before it can
/// call one, and holds them for the whole conversation — `ToolCost` measures
/// what that costs and `prod/appstore-connect` is about 26.2k tokens of it. An
/// agent that never touches App Store Connect pays in full, on every connect.
///
/// The obvious fix is to send the names and let the agent ask for the rest.
/// **MCP has no method for that.** `inputSchema` is required in a `tools/list`
/// entry and clients validate it, so a name-only listing is not a cheap server,
/// it is an empty one — a client cannot call a tool whose schema it never
/// received. The only lazy discovery the protocol permits is to replace the
/// tools with a searchable index and a dispatcher, which is what this is, and
/// what `mcp-sentry` and `mcp-stripe` already ship as servers.
///
/// Bastion doing it rather than the server has one concrete advantage and it is
/// the reason this exists here: **Bastion is the thing performing the dispatch**,
/// so it unwraps `bastion_call_tool` back to the real name before the write gate
/// and the audit log ever see it. A facade bought from a third party cannot do
/// that, and turns a supervised gateway into a bag of anonymous calls.
///
/// What it costs, which `ProfileEditor` has to say out loud: the HOST's own
/// allowlist collapses. Every App Store Connect call reaches Claude Code as
/// `mcp__appstore-connect__bastion_call_tool`, so one permission rule now covers
/// all eighty-five. Bastion's audit stays exact; the editor's gate does not.
/// This is the same shape of caveat as `WriteGate`'s "this filters Bastion, not
/// the server", and it is why the switch is off by default and why a profile can
/// still override the app-wide answer: a profile feeding Claude Code, which
/// defers tool schemas by itself, gains nothing here and pays the whole cost.
///
/// Pure, and taking strings rather than a `BastionServer`, so `make unit` and
/// `scripts/remote-check.swift` can compile it alone. The argument is
/// `WriteGate`'s, for `WriteGate`'s reason: a rule with no test is a rule that
/// gets re-derived somewhere else.
nonisolated enum ToolFacade {
  // MARK: - Names

  /// The `bastion_` prefix is not decoration. It makes a collision with a tool
  /// on the server being fronted impossible rather than unlikely — these three
  /// entries are merged into somebody else's namespace, and a server that
  /// happened to expose its own `search_tools` would silently shadow one of
  /// them — and it tells the model where they came from, which matters when the
  /// answer to "why can I not see the tool I was told about" is "the gateway".
  static let searchName = "bastion_search_tools"
  static let describeName = "bastion_describe_tool"
  static let callName = "bastion_call_tool"

  /// Membership test for the dispatch branch in `Supervisor.Instance.handle`.
  static let names: Set<String> = [searchName, describeName, callName]

  // MARK: - Settings

  /// The app-wide default, for every profile that has expressed no preference.
  ///
  /// A global switch with a per-profile override, which is `CallCapture`'s shape
  /// and is here for a reason that took a round of review to see: a setting that
  /// exists ONLY inside a profile sheet is a setting nobody finds. The saving is
  /// the whole point of this feature and it was reachable only by editing every
  /// profile one at a time, which is the same as not shipping it.
  ///
  /// Off, still. This is the one switch in the app that trades rather than
  /// tightens — it spends the client's own per-tool approval rules — so turning
  /// it on has to be somebody's decision. What changed is where the decision is
  /// made, not that it is made.
  static let defaultsKey = "lazyToolsDefault"

  static var globalDefault: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

  // MARK: - Limits

  /// How much of a tool's own description survives into a search row.
  ///
  /// The index is the thing being paid for, and a server that writes three
  /// paragraphs per tool would rebuild the bill this exists to avoid. Cut at a
  /// sentence boundary when there is one within reach, because a description
  /// truncated mid-clause reads as a bug in Bastion rather than as a summary.
  static let summaryLimit = 160

  /// Rows returned for a query that names something.
  static let searchLimit = 25

  /// Rows returned for the empty query, which means "show me everything".
  ///
  /// Capped anyway. Eighty-five rows is about 1.9k tokens and worth it once; a
  /// server exposing nine hundred is a different question, and answering it in
  /// full would spend more than the listing this replaces.
  static let indexLimit = 200

  // MARK: - The declarations

  /// The three entries a client sees in place of the real list.
  ///
  /// `summary` and `displayName` come from `servers.json`, which already has
  /// both, so the model knows what it is searching before it searches — without
  /// them `bastion_search_tools` is a tool with no subject and a model will not
  /// reach for it. `toolCount` is the honest scale of what is behind the door.
  static func declarations(displayName: String, summary: String, toolCount: Int) -> [[String: Any]]
  {
    let subject = summary.isEmpty ? displayName : "\(displayName) — \(summary)"
    return [
      [
        "name": searchName,
        "description":
          "Find a tool on \(subject). Bastion is showing these three tools in place of the "
          + "\(toolCount) this server really exposes, to keep \(toolCount) schemas out of your "
          + "context; everything is still reachable. Returns names and one-line summaries. "
          + "Call with an empty query to list all \(toolCount).",
        "inputSchema": [
          "type": "object",
          "properties": [
            "query": [
              "type": "string",
              "description":
                "Words to match against tool names and summaries. Empty lists everything.",
            ]
          ],
        ],
        // Genuinely read-only, and said so: a search that a host makes the user
        // confirm is a search nobody runs, and the whole flow starts here.
        "annotations": ["readOnlyHint": true],
      ],
      [
        "name": describeName,
        "description":
          "Read the full input schema for one \(displayName) tool, by the exact name "
          + "\(searchName) returned. Do this before calling anything unfamiliar.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "name": ["type": "string", "description": "The exact tool name."]
          ],
          "required": ["name"],
        ],
        "annotations": ["readOnlyHint": true],
      ],
      [
        "name": callName,
        "description":
          "Call one of \(displayName)'s tools. Look the name up with \(searchName) and read its "
          + "schema with \(describeName) first: arguments are checked by \(displayName), not by "
          + "Bastion, and a guessed argument name comes back as that server's own error.",
        "inputSchema": [
          "type": "object",
          "properties": [
            "name": ["type": "string", "description": "The exact tool name."],
            "arguments": [
              "type": "object",
              "description": "The tool's own arguments, matching the schema \(describeName) gave.",
            ],
          ],
          "required": ["name"],
        ],
        // NO annotations, deliberately. This dispatches to anything, so the
        // truthful `readOnlyHint` is the one belonging to whatever it is asked
        // to call, which is unknowable here. `MCPTool.readOnlyHint` sets the
        // house rule for the gap: a missing mark is never read as a yes. Claiming
        // `readOnlyHint: true` would be a lie that relaxes a host's own
        // confirmation prompt for every write on the server, and claiming
        // `false` would feed `WriteGate.annotatedWriteTools` a name that gates
        // the dispatcher itself, taking the reads down with it.
      ],
    ]
  }

  /// What the three declarations cost the client that receives them.
  ///
  /// So the badge in `ServerDetail` can put the saving beside the bill —
  /// "0.6k of 26.2k" — rather than replacing one with the other. A profile whose
  /// listing silently shrank from 26.2k to 0.6k would hide the one number that
  /// says whether this was worth turning on.
  ///
  /// Computed rather than stored: the declarations are a pure function of three
  /// values the caller already has, so there is nothing here that can go stale
  /// the way `ToolCostStore`'s measurement can.
  static func declarationBytes(displayName: String, summary: String, toolCount: Int) -> Int {
    declarations(displayName: displayName, summary: summary, toolCount: toolCount)
      .reduce(0) { $0 + ToolCost.bytes(of: $1) }
  }

  // MARK: - Search

  /// One row of the index.
  struct Row: Equatable {
    let name: String
    let summary: String
  }

  /// The tools matching `query`, best first.
  ///
  /// Every term has to appear somewhere in the tool's name or summary, and the
  /// rank is then how well they hit the NAME — because a model searching
  /// "version" wants `list_versions` above the six tools whose prose happens to
  /// mention a version. Ties break on the name so the output of two identical
  /// searches is two identical strings, which is what makes this testable at
  /// all.
  static func search(catalog: [[String: Any]], query: String, limit: Int? = nil) -> [Row] {
    let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let cap = limit ?? (terms.isEmpty ? indexLimit : searchLimit)

    // The empty query is the full index, and it comes back in the server's own
    // order rather than sorted. Servers group related tools and put the ones
    // they expect you to reach for first; alphabetising that throws away a
    // judgement the author made and Bastion cannot reconstruct.
    guard !terms.isEmpty else {
      return catalog.prefix(cap).compactMap { entry in
        guard let name = entry["name"] as? String else { return nil }
        return Row(name: name, summary: shorten(description(of: entry)))
      }
    }

    let scored = catalog.compactMap { entry -> (rank: Int, row: Row)? in
      guard let name = entry["name"] as? String else { return nil }
      let summary = shorten(description(of: entry))

      let lowerName = name.lowercased()
      let haystack = "\(lowerName) \(summary.lowercased())"
      guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }

      // Summed, not minimised. Taking the best single term made a two-word
      // query rank on its luckiest word alone: "list version" tied
      // `list_versions` with `list_apps` on "list" and then broke the tie
      // alphabetically, handing back the tool that matches one word ahead of
      // the one that matches both. Adding the ranks makes matching more of the
      // query worth something.
      let rank = terms.reduce(0) { running, term in
        if lowerName == term { return running }
        if lowerName.hasPrefix(term) { return running + 1 }
        if lowerName.contains(term) { return running + 2 }
        return running + 3
      }
      return (rank: rank, row: Row(name: name, summary: summary))
    }

    return
      scored
      .sorted { ($0.rank, $0.row.name) < ($1.rank, $1.row.name) }
      .prefix(cap)
      .map(\.row)
  }

  /// The search result as the text a model reads.
  ///
  /// The trailing sentence is load-bearing: without it a model that has found
  /// `app_store_connect_list_versions` has a name and no way to know it may not
  /// call it directly. Naming the next two tools every time costs a line and
  /// saves a failed call.
  static func searchText(catalog: [[String: Any]], query: String, limit: Int? = nil) -> String {
    let rows = search(catalog: catalog, query: query, limit: limit)
    guard !rows.isEmpty else {
      return "No tool matches '\(query)'. Call \(searchName) with an empty query to see all "
        + "\(catalog.count)."
    }
    let listing = rows.map { $0.summary.isEmpty ? $0.name : "\($0.name) — \($0.summary)" }
      .joined(separator: "\n")
    let shown =
      rows.count < catalog.count
      ? "\(rows.count) of \(catalog.count) tools" : "all \(catalog.count) tools"
    return listing + "\n\n\(shown). Read a schema with \(describeName), then run it with "
      + "\(callName)."
  }

  // MARK: - Describe

  /// One tool's entry, exactly as the server sent it.
  ///
  /// Compact rather than pretty-printed, which is the call `BuiltinTools` already
  /// made for its own responses: indentation is about a third again as many
  /// bytes, models read compact JSON Schema without trouble, and this whole
  /// feature is an argument about bytes.
  ///
  /// Returns nil for a name that is not in the catalog so the caller can answer
  /// with suggestions instead of an error — a model that mistypes a tool name
  /// and gets `-32602` retries the mistype, while one that gets three near
  /// misses picks the right one.
  static func describe(catalog: [[String: Any]], name: String) -> String? {
    guard let entry = catalog.first(where: { $0["name"] as? String == name }),
      let data = try? JSONSerialization.data(withJSONObject: entry),
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }

  /// The describe result as the text a model reads, misses included.
  static func describeText(catalog: [[String: Any]], name: String) -> String {
    if let entry = describe(catalog: catalog, name: name) {
      return entry + "\n\nCall it with \(callName): {\"name\": \"\(name)\", \"arguments\": {…}}."
    }
    let near = nearest(catalog: catalog, name: name, limit: 3)
    guard !near.isEmpty else {
      return "\(name) is not a tool on this server. Call \(searchName) with an empty query to see "
        + "all \(catalog.count)."
    }
    return "\(name) is not a tool on this server. Closest: \(near.joined(separator: ", "))."
  }

  // MARK: - Routing

  /// What Bastion should do with one frame, decided without touching the wire.
  enum Routing: Equatable {
    /// A JSON-RPC `result` payload to answer with. The caller wraps it in an
    /// envelope, because only the caller knows the client's id.
    case answer([String: Any])
    /// The `params` a `bastion_call_tool` frame should be rewritten to, so that
    /// everything downstream sees the ordinary `tools/call` it stood for.
    case rewrite([String: Any])
    /// Not the facade's business.
    case passThrough

    static func == (a: Routing, b: Routing) -> Bool {
      switch (a, b) {
      case (.passThrough, .passThrough): true
      case (.answer(let x), .answer(let y)), (.rewrite(let x), .rewrite(let y)):
        NSDictionary(dictionary: x).isEqual(to: y)
      default: false
      }
    }
  }

  /// Whether `route` would do anything, answerable without a catalog.
  ///
  /// Split out because fetching the catalog can block on the server, and the
  /// overwhelming majority of frames — every `resources/read`, every ordinary
  /// `tools/call` from a client whose list predates the toggle — are none of the
  /// facade's business. Asking first means the walk happens on the frames that
  /// need it and on no others.
  static func handles(method: String, params: [String: Any]?) -> Bool {
    if method == "tools/list" { return true }
    guard method == "tools/call", let name = params?["name"] as? String else { return false }
    return names.contains(name)
  }

  /// The whole decision, as one pure function over a catalog somebody else
  /// fetched.
  ///
  /// Here rather than in `Supervisor.Instance` because `RemoteInstance` needs
  /// the identical behaviour and the two have already been burned once by
  /// keeping a copy each — `WriteGate` exists because the write gate was right
  /// in both places and every *consumer* of it was wrong in six. The wiring is
  /// still duplicated, deliberately; the rule is not.
  ///
  /// `catalog` must already be filtered for the write gate. A search that offers
  /// a tool this profile will then refuse wastes a turn to teach nothing, which
  /// is `WriteGate.visibleTools`'s own argument for hiding rather than refusing.
  static func route(
    method: String, params: [String: Any]?, catalog: [[String: Any]], displayName: String,
    summary: String
  ) -> Routing {
    if method == "tools/list" {
      return .answer([
        "tools": declarations(
          displayName: displayName, summary: summary, toolCount: catalog.count)
      ])
    }
    guard method == "tools/call", let params, let name = params["name"] as? String,
      names.contains(name)
    else {
      // Anything else, a real tool name included. NOT intercepted: a client
      // whose list was cached before the toggle moved is still inside the 60s
      // `ttlMs` and its call has to keep working. Refusing it would break a live
      // session to buy nothing, and the write gate covers it either way.
      return .passThrough
    }
    let arguments = params["arguments"] as? [String: Any] ?? [:]

    switch name {
    case searchName:
      return .answer(
        content(searchText(catalog: catalog, query: arguments["query"] as? String ?? "")))

    case describeName:
      guard let wanted = arguments["name"] as? String, !wanted.isEmpty else {
        return .answer(content("\(describeName) needs a tool name.", isError: true))
      }
      return .answer(content(describeText(catalog: catalog, name: wanted)))

    default:
      guard let unwrapped = unwrap(params: params) else {
        return .answer(content("\(callName) needs the name of the tool to call.", isError: true))
      }
      // A name the model invented, or one the write gate is hiding. Answered
      // here rather than forwarded: the server would reject an unknown tool with
      // a protocol error a model cannot act on, where this comes back with the
      // near misses and the next call succeeds.
      guard catalog.contains(where: { $0["name"] as? String == unwrapped.name }) else {
        return .answer(content(describeText(catalog: catalog, name: unwrapped.name), isError: true))
      }
      return .rewrite(["name": unwrapped.name, "arguments": unwrapped.arguments])
    }
  }

  /// A `tools/call` result carrying one block of text.
  static func content(_ text: String, isError: Bool = false) -> [String: Any] {
    var result: [String: Any] = ["content": [["type": "text", "text": text]]]
    if isError { result["isError"] = true }
    return result
  }

  /// The names closest to one that is not in the catalog.
  ///
  /// `search` cannot do this job: it matches substrings, and a mistyped name is
  /// precisely a string that appears nowhere. `list_appz` would return nothing
  /// at all, so a model that fat-fingered a name would be told only that it does
  /// not exist and would try the same name again.
  ///
  /// Shared underscore-separated words first, then the longest common prefix.
  /// Tool names are overwhelmingly `verb_noun`, so one shared word is a strong
  /// signal and the prefix breaks the ties it leaves — `list_appz` finds
  /// `list_apps` ahead of `list_versions`.
  static func nearest(catalog: [[String: Any]], name: String, limit: Int = 3) -> [String] {
    let wanted = Set(name.lowercased().split(separator: "_").map(String.init))
    let scored = catalog.compactMap { entry -> (shared: Int, prefix: Int, name: String)? in
      guard let candidate = entry["name"] as? String else { return nil }
      let words = Set(candidate.lowercased().split(separator: "_").map(String.init))
      let shared = wanted.intersection(words).count
      let prefix = zip(name.lowercased(), candidate.lowercased()).prefix { $0 == $1 }.count
      guard shared > 0 || prefix >= 4 else { return nil }
      return (shared: shared, prefix: prefix, name: candidate)
    }
    return
      scored
      .sorted { ($1.shared, $1.prefix, $0.name) < ($0.shared, $0.prefix, $1.name) }
      .prefix(limit)
      .map(\.name)
  }

  // MARK: - Unwrapping a call

  /// The real tool name and arguments inside a `bastion_call_tool` frame.
  ///
  /// The single most important function in this file, because everything that
  /// makes an in-gateway facade better than a bought one runs through it: the
  /// write gate re-checks this name, `LogStore` records this name, and the audit
  /// chain and the Activity window quote it. Get it wrong and the feature still
  /// appears to work while quietly flattening every call into `bastion_call_tool`.
  ///
  /// `arguments` missing is a legal call to a tool that takes none, so it
  /// becomes an empty object rather than a failure. An empty or absent `name` is
  /// not: there is nothing to dispatch to.
  static func unwrap(params: [String: Any]) -> (name: String, arguments: [String: Any])? {
    guard let inner = params["arguments"] as? [String: Any],
      let name = inner["name"] as? String, !name.isEmpty
    else { return nil }
    return (name: name, arguments: inner["arguments"] as? [String: Any] ?? [:])
  }

  // MARK: - Helpers

  /// The same order `MCPTool` reads these in, so a tool summarised in the Chat
  /// pane and the same tool summarised here do not disagree about its name.
  private static func description(of entry: [String: Any]) -> String {
    let annotations = entry["annotations"] as? [String: Any]
    return entry["description"] as? String
      ?? annotations?["title"] as? String
      ?? entry["title"] as? String
      ?? ""
  }

  /// First sentence if there is one inside the limit, else a hard cut.
  static func shorten(_ text: String) -> String {
    let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard flat.count > summaryLimit else { return flat }
    let window = flat.prefix(summaryLimit)
    // A floor, because the first "." in "e.g. ..." is not the end of a sentence
    // and returning three characters would be worse than a hard cut. Anything
    // shorter than this is a fragment rather than a summary.
    if let stop = window.lastIndex(of: "."),
      window.distance(from: window.startIndex, to: stop) >= 20
    {
      return String(window[..<stop]) + "."
    }
    return String(window).trimmingCharacters(in: .whitespaces) + "…"
  }
}
