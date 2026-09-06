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
/// allowlist collapses. Every App Store Connect call reaches the editor as
/// `bastion_call_tool`, so one permission rule now covers all eighty-five.
/// Bastion's audit stays exact; the editor's gate does not. This is the same
/// shape of caveat as `WriteGate`'s "this filters Bastion, not the server", and
/// it is why the switch is off by default.
///
/// And why it is not the whole decision. A client that defers schemas ITSELF
/// gains almost nothing here and pays all of that: Claude Code has fetched a
/// tool's schema on demand since 2.1.191, so fronting it buys back the names and
/// nothing else. Worse, it takes something away — the host's own search then
/// indexes these three generic entries instead of the server's eighty-five, so
/// `bastion_search_tools` stays findable by "app store connect" while
/// `app_store_connect_list_builds` stops being findable by "testflight build".
/// `clientDefersSchemas` is that second term, and the gate is the `and` of the
/// two: the profile answers whether the listing is big enough to be worth the
/// trade, the client answers whether it needs the help at all.
///
/// Pure, and taking strings rather than a `BastionServer`, so `make unit` can
/// compile it alone. The argument is `WriteGate`'s, for `WriteGate`'s reason: a
/// rule with no test is a rule that gets re-derived somewhere else.
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

  /// The dispatcher for the tools Bastion knows to mutate.
  ///
  /// The facade's one real cost is that the HOST's per-tool approval collapses:
  /// every call reaches the editor as one name, so a rule covering
  /// `app_store_connect_list_builds` ends up covering `..._update_app` too.
  /// Splitting the dispatcher does not give per-tool rules back, but it gives
  /// back the boundary that the rules were mostly there to protect — a person
  /// can allowlist `bastion_call_tool` and still be asked about every write.
  ///
  /// ENFORCED rather than annotated, which is the whole point. `callName`
  /// refuses a known write and names this instead, so allowlisting it cannot
  /// run one; that is a property Bastion holds up, not a hint it asserts and
  /// hopes the host respects.
  static let callWriteName = "bastion_call_write_tool"

  /// Membership test for the dispatch branch in `Supervisor.Instance.handle`.
  static let names: Set<String> = [searchName, describeName, callName, callWriteName]

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

  // MARK: - Which clients need this

  /// The clients that load a tool's schema on demand by themselves.
  ///
  /// An ALLOWLIST BACKED BY EVIDENCE, not a capability field. Nothing derives
  /// this from `ClientWiring` and adding a client there requires nothing here —
  /// the entry is a claim that somebody watched that client defer, and a client
  /// nobody has watched belongs outside the set rather than inside it on the
  /// grounds that it probably does.
  ///
  /// One entry, and it should stay small. Claude Code is here for
  /// `ENABLE_TOOL_SEARCH`, on by default since 2.1.191: schemas never reach the
  /// model, only names do, and a search tool fetches the rest. Claude Desktop,
  /// the editors and Codex are not here because no equivalent is documented for
  /// any of them, which is the same answer `docs/clients.md` has always given.
  ///
  /// Matched exactly and case-sensitively against the Keychain account the
  /// bearer token was issued to, which `ClientWiring.token(for:)` always writes
  /// from `client.id` — lowercase kebab. A fuzzy identity test on a credential's
  /// account name is worse than a strict one that is occasionally too narrow.
  static let clientsDeferringSchemas: Set<String> = ["claude-code"]

  /// Where one client's override lives, for `ClientDetail`'s picker and for the
  /// read below. Per client rather than per profile because a profile feeds
  /// several clients at once: overriding there to get one of them fronted again
  /// would drag the others along with it.
  static func clientOverrideKey(_ client: String) -> String {
    "lazyToolsClient.\(client)"
  }

  /// Whether this client defers schemas itself, override resolved.
  ///
  /// The pure half, taking the override as an argument rather than reading it,
  /// so `make unit` can pin the table and both directions of the override
  /// without a defaults domain. Same split as `globalDefault` being a thin read
  /// over a constant, and the same reason: the rule is the thing worth testing.
  ///
  /// An unrecognised client does NOT defer, so the facade applies to it. This
  /// axis is an exception to something the user asked for, and an exception with
  /// no evidence behind it is not an exception — defaulting the other way would
  /// make a switch somebody turned on quietly do nothing for every client
  /// Bastion has not been taught about, with no symptom naming the cause. Wrong
  /// in this direction is a listing that visibly shrank and is one picker away
  /// from fixed. `scripts/facade-check.sh`, whose token names an arbitrary
  /// client, depends on this answer.
  static func clientDefersSchemas(_ client: String, override: Bool?) -> Bool {
    override ?? clientsDeferringSchemas.contains(client)
  }

  /// The same question against the stored override. The only form the gateway
  /// reads, so a client that has expressed no preference cannot be mistaken for
  /// one that said no.
  static func clientDefersSchemas(_ client: String) -> Bool {
    let stored = UserDefaults.standard.string(forKey: clientOverrideKey(client))
    // "" is the Default tag and `Bool("")` is nil, so the empty position falls
    // through to the table rather than reading as a no.
    let override: Bool? = stored.flatMap { Bool($0) }
    return clientDefersSchemas(client, override: override)
  }

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

  /// Rows returned when nothing matched the whole query.
  ///
  /// Tighter than `searchLimit` on purpose; see `find`.
  static let partialLimit = 10

  /// The shortest query word that is allowed to mean anything.
  ///
  /// Two characters of raw substring match half of everything, and since the
  /// count of matched words now decides which tools come back, a stray "of"
  /// inflates every tier equally except the one it was supposed to narrow.
  static let shortestTerm = 3

  // MARK: - The declarations

  /// The three entries a client sees in place of the real list.
  ///
  /// `summary` and `displayName` come from `servers.json`, which already has
  /// both, so the model knows what it is searching before it searches — without
  /// them `bastion_search_tools` is a tool with no subject and a model will not
  /// reach for it. `toolCount` is the honest scale of what is behind the door.
  static func declarations(
    displayName: String, summary: String, toolCount: Int, hasWriteDispatcher: Bool = false
  ) -> [[String: Any]] {
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
                "Words to match against tool names and descriptions. If no tool carries all of "
                + "them, the closest are returned. Empty lists everything.",
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
          + "Bastion, and a guessed argument name comes back as that server's own error."
          + (hasWriteDispatcher
            ? " This will not run a tool Bastion knows to change things — those go through "
              + "\(callWriteName)."
            : ""),
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
        // STILL no annotations, even now that this refuses known writes.
        //
        // It is tempting to claim `readOnlyHint: true` here — it would let a
        // host stop prompting for the reads, which is the whole point of the
        // split. It would also be a lie. A tool that is neither in the
        // manifest's `writeTools` nor annotated by the server is UNCLASSIFIED,
        // and `WriteGate`'s stated doctrine is that silence is not a "no".
        // Bastion already bets that way for its own gating, but that bet only
        // decides Bastion's refusal; putting it in this annotation moves it
        // into the EDITOR's confirmation prompt, where being wrong means a
        // mutation nobody was asked about. Refusing the writes it knows is
        // honest and checkable. Claiming to be read-only is neither.
        //
        // `false` is no better than it was: it would feed
        // `WriteGate.annotatedWriteTools` this dispatcher's own name and gate
        // the reads with it.
      ],
    ]
      + (hasWriteDispatcher
        ? [
          [
            "name": callWriteName,
            "description":
              "Call one of \(displayName)'s tools that CHANGES something — creating, updating, "
              + "deleting. Same arguments as \(callName), which will not run these. Look the "
              + "name up with \(searchName) and read its schema with \(describeName) first.",
            "inputSchema": [
              "type": "object",
              "properties": [
                "name": ["type": "string", "description": "The exact tool name."],
                "arguments": [
                  "type": "object",
                  "description":
                    "The tool's own arguments, matching the schema \(describeName) gave.",
                ],
              ],
              "required": ["name"],
            ],
            // Honest in both directions, unlike the dispatcher above: this one
            // reaches only tools Bastion has positive evidence are mutating, so
            // `readOnlyHint: false` is a fact rather than a guess. The point of
            // saying it is that a host reads it and keeps asking.
            //
            // No `destructiveHint`. "Changes something" and "destroys something"
            // are different claims and `WriteGate` merges them on the way in —
            // `readOnlyHint: false` alone puts a tool in the write set — so
            // asserting the stronger one here would over-claim for every update
            // that deletes nothing.
            "annotations": ["readOnlyHint": false],
          ]
        ]
        : [])
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
  /// What the declarations cost, taking the FLAG rather than the set: a view
  /// asking this has a stored measurement, not a catalog, and the fourth
  /// declaration's text names no tool of the server's, so its size does not
  /// depend on which tools are in the set.
  static func declarationBytes(
    displayName: String, summary: String, toolCount: Int, hasWriteDispatcher: Bool = false
  ) -> Int {
    declarations(
      displayName: displayName, summary: summary, toolCount: toolCount,
      hasWriteDispatcher: hasWriteDispatcher
    )
    .reduce(0) { $0 + ToolCost.bytes(of: $1) }
  }

  // MARK: - The floor

  /// How much smaller the facade has to be before fronting a listing is worth
  /// it: the real list must be at least this many times the declarations, in
  /// entries and in bytes both.
  ///
  /// A RATIO rather than a token count, because the thing being traded away
  /// scales with neither. What a fronted server costs — the host's own per-tool
  /// approval collapsing onto one dispatcher, its tool search indexing three
  /// generic entries — is a fixed price, paid in full whether the listing was
  /// eighty-five tools or three. So the saving has to be worth a fixed price,
  /// and "halves it" is the smallest claim that plainly is.
  ///
  /// Two rather than 1.0 for a reason worth stating: at parity the facade is not
  /// neutral, it is a loss. The declarations replace the schemas with a promise
  /// that they can be fetched, so a client that actually uses the server pays
  /// the listing AND the round trips.
  static let savingFactor = 2

  /// Why a listing is not worth fronting, or nil when it is.
  ///
  /// Two terms, and the first is the one that matters — see `worthFronting`.
  enum Floor: Equatable {
    /// Fewer tools than a search index is worth building over.
    case tooFewTools
    /// Enough tools, but the declarations cost about what they would replace.
    case notCheaper
  }

  /// What a whole `tools/list` costs the client that receives it.
  ///
  /// The same sum `ToolCost` bills a profile for, so the floor is decided on the
  /// number the app puts on screen rather than on a second estimate that could
  /// disagree with it.
  static func listingBytes(_ catalog: [[String: Any]]) -> Int {
    catalog.reduce(0) { $0 + ToolCost.bytes(of: $1) }
  }

  /// The floor: whether fronting this listing buys anything, as the arithmetic
  /// alone.
  ///
  /// The third term of the gate, and the only one that needed no new switch. The
  /// server axis asks whether somebody turned this on, the client axis asks
  /// whether the client needs the help — and both can be satisfied by a server
  /// there is nothing to save on.
  ///
  /// **The count is the term that decides the real cases, and it is not a proxy
  /// for the bytes.** What this feature sells is not compression, it is
  /// SELECTION: eighty-five schemas go unsent because an agent needed two of
  /// them. A server exposing three tools offers no selection to make — an agent
  /// reaching for it needs all three — so the index costs two round trips to
  /// learn what one listing already said, and the search that was supposed to
  /// find things has three entries to find. An index over a handful is not an
  /// index. Cloudflare's hosted endpoint is the case in hand: `search`,
  /// `execute` and `docs`, which is ALREADY this design, at 1.7k tokens of
  /// deliberately verbose descriptions. It clears the byte term comfortably and
  /// should still never be fronted, which is exactly the mistake a bytes-only
  /// floor makes.
  ///
  /// Measured rather than listed. The alternative was a set of vendors known to
  /// front their own tools, which is the shape `clientsDeferringSchemas` takes
  /// and is wrong here: that set is a claim about a client's behaviour nothing
  /// inside Bastion can measure, where this is a claim about two integers. A
  /// list would also rot silently the first time a vendor unpacked its
  /// dispatcher, and it would do nothing for the small CHILD server that has the
  /// same problem and no vendor to name.
  ///
  /// An empty catalog comes out `tooFewTools`, which is right and not
  /// incidental: three tools that can reach nothing are worse than an honest
  /// empty list.
  static func floor(
    listingBytes: Int, listingCount: Int, facadeBytes: Int, facadeCount: Int
  ) -> Floor? {
    if listingCount < facadeCount * savingFactor { return .tooFewTools }
    if listingBytes < facadeBytes * savingFactor { return .notCheaper }
    return nil
  }

  static func worthFronting(
    listingBytes: Int, listingCount: Int, facadeBytes: Int, facadeCount: Int
  ) -> Bool {
    floor(
      listingBytes: listingBytes, listingCount: listingCount, facadeBytes: facadeBytes,
      facadeCount: facadeCount) == nil
  }

  /// How many entries the facade sends in a listing's place: three, or four for
  /// a server Bastion can tell writes from reads on.
  static func declarationCount(hasWriteDispatcher: Bool) -> Int { hasWriteDispatcher ? 4 : 3 }

  /// The same question against a catalog, for the two wirings that hold one.
  static func floor(
    catalog: [[String: Any]], displayName: String, summary: String, hasWriteDispatcher: Bool
  ) -> Floor? {
    floor(
      listingBytes: listingBytes(catalog), listingCount: catalog.count,
      facadeBytes: declarationBytes(
        displayName: displayName, summary: summary, toolCount: catalog.count,
        hasWriteDispatcher: hasWriteDispatcher),
      facadeCount: declarationCount(hasWriteDispatcher: hasWriteDispatcher))
  }

  static func worthFronting(
    catalog: [[String: Any]], displayName: String, summary: String, hasWriteDispatcher: Bool
  ) -> Bool {
    floor(
      catalog: catalog, displayName: displayName, summary: summary,
      hasWriteDispatcher: hasWriteDispatcher) == nil
  }

  // MARK: - Search

  /// One row of the index.
  struct Row: Equatable {
    let name: String
    let summary: String
  }

  /// What a search found, with enough of its arithmetic kept for the text to be
  /// honest about it.
  struct Outcome {
    let rows: [Row]
    /// Entries in the tier `rows` was taken from, before the cap.
    let matches: Int
    /// Words of the query the returned rows carry, of `words`. Fewer means the
    /// rows are the closest thing to an answer rather than an answer.
    let matchedWords: Int
    /// Words in the query, after `queryTerms` deduplicated and pruned it.
    let words: Int
    /// The query's words no tool in the catalog carried at all, in the order
    /// typed. Can be empty while `matchedWords < words`, when two tools each
    /// carried a different word and neither carried both.
    let missed: [String]
  }

  /// Where one term hit, worst last.
  ///
  /// Summed across the query's terms, not minimised. Taking the best single
  /// term made a two-word query rank on its luckiest word alone: "list version"
  /// tied `list_versions` with `list_apps` on "list" and then broke the tie
  /// alphabetically, handing back the tool that matches one word ahead of the
  /// one that matches both. Adding the ranks makes matching more of the query
  /// worth something.
  ///
  /// The bottom two rungs are what pays for searching a whole description: a
  /// word in the name is an advertisement, a word in the summary is a
  /// description, and a word forty lines down next to an enum of error codes is
  /// a coincidence. One monotone axis — how prominently does this tool announce
  /// this word — rather than a second score to weigh against the first.
  private enum Hit: Int {
    case exactName = 0
    case namePrefix = 1
    case nameSubstring = 2
    case summary = 3
    case tail = 4
    case missing = 5
  }

  /// The query as the words that will be matched.
  ///
  /// Deduplicated, and short words dropped, both because how MUCH of the query
  /// a tool matched now decides which tools are returned at all. Undeduplicated,
  /// "version version submission" lets a repeated word outweigh a tool that
  /// carried two distinct concepts. And a model that pastes a sentence rather
  /// than keywords contributes "a", "to", "of", which as raw substrings hit
  /// almost every description ever written.
  static func queryTerms(in query: String) -> [String] {
    var seen = Set<String>()
    return query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
      .filter { $0.count >= shortestTerm && seen.insert($0).inserted }
  }

  /// A term retried without its plural `s`, or nil when there is nothing safe to
  /// drop.
  ///
  /// This is the whole reason the feature was reported broken: a model searched
  /// "version builds submission" against App Store Connect and was told no tool
  /// matched, because the one that does says "its build and metadata" and
  /// "builds" is not a substring of "build". The other direction already works,
  /// since "build" IS a substring of "builds".
  ///
  /// The regular plural only — "capabilities" and "matches" still miss, and the
  /// comment says so rather than claiming to handle plurals. Longer than three
  /// characters so "ios" does not become "io", and never after "ss" or "us",
  /// because "status", "process", "class" and "focus" would fold into stems
  /// that match by accident. That guard matters more than it looks: a fold is
  /// only tried when the exact term missed, which is exactly the case where an
  /// accidental hit becomes the best tier and hides the real answer.
  static func singular(_ term: String) -> String? {
    guard term.count > 3, term.hasSuffix("s"), !term.hasSuffix("ss"), !term.hasSuffix("us")
    else { return nil }
    return String(term.dropLast())
  }

  /// The tools matching `query`, best first.
  ///
  /// The rank is how well the terms hit the NAME — because a model searching
  /// "version" wants `list_versions` above the six tools whose prose happens to
  /// mention a version. Ties break on the name so the output of two identical
  /// searches is two identical strings, which is what makes this testable at
  /// all.
  ///
  /// Not every term has to appear. Entries are grouped by how many of them they
  /// matched and only the best group is returned, which is the same thing as
  /// requiring all of them whenever some tool carries all of them, and is an
  /// answer rather than silence when none does. Strict matching failed badly in
  /// the only way that costs anything here: one unlucky word threw away the
  /// tools that matched every other one, and a model told "no tool matches" has
  /// no reason to think the tool exists. Its only recourse was the empty query,
  /// which spends the whole index this feature exists to avoid sending.
  ///
  /// One consequence worth stating: a result is now a property of the query AND
  /// the catalog, not of a tool on its own, since the tier is a maximum taken
  /// across every entry. Adding a tool to a server can change the rows an
  /// unrelated query returns, so nothing may cache this keyed on the query.
  static func find(catalog: [[String: Any]], query: String, limit: Int? = nil) -> Outcome {
    let terms = queryTerms(in: query)

    // The empty query is the full index, and it comes back in the server's own
    // order rather than sorted. Servers group related tools and put the ones
    // they expect you to reach for first; alphabetising that throws away a
    // judgement the author made and Bastion cannot reconstruct.
    guard !terms.isEmpty else {
      let rows = catalog.prefix(limit ?? indexLimit).compactMap { entry -> Row? in
        guard let name = entry["name"] as? String else { return nil }
        return Row(name: name, summary: shorten(description(of: entry)))
      }
      return Outcome(rows: rows, matches: rows.count, matchedWords: 0, words: 0, missed: [])
    }

    var scored: [(matched: Int, rank: Int, row: Row)] = []
    var carried = [Bool](repeating: false, count: terms.count)

    for entry in catalog {
      guard let name = entry["name"] as? String else { continue }
      let full = description(of: entry)
      let summary = shorten(full)

      let lowerName = name.lowercased()
      // Two haystacks: the whole description decides WHETHER a term matched,
      // the shortened summary decides how well. Searching only the summary
      // meant everything past `summaryLimit` was unreachable — App Store
      // Connect's `list_builds` ends "the latest VALID build for TestFlight"
      // past the cut, so searching "testflight build" could not find it.
      let head = "\(lowerName) \(summary.lowercased())"
      let whole = "\(lowerName) \(full.lowercased())"

      var matched = 0
      var rank = 0
      for (index, term) in terms.enumerated() {
        // Resolved per entry rather than once per query: "builds" can hit a
        // tool that spells it out and need the fold on the next one, and the
        // rank has to score whichever form actually matched, or a fold that
        // landed in the NAME is filed as a passing mention in the prose.
        var effective: String?
        if whole.contains(term) {
          effective = term
        } else if let folded = singular(term), whole.contains(folded) {
          effective = folded
        }

        guard let effective else {
          rank += Hit.missing.rawValue
          continue
        }

        let hit: Hit
        if lowerName == effective {
          hit = .exactName
        } else if lowerName.hasPrefix(effective) {
          hit = .namePrefix
        } else if lowerName.contains(effective) {
          hit = .nameSubstring
        } else if head.contains(effective) {
          hit = .summary
        } else {
          hit = .tail
        }
        rank += hit.rawValue
        matched += 1
        carried[index] = true
      }
      scored.append((matched: matched, rank: rank, row: Row(name: name, summary: summary)))
    }

    // A total miss is still a miss. Without this guard every entry ties at zero
    // and the "best" tier is the entire catalog — the one bug in this function
    // that would be worse than the one it fixes.
    guard let best = scored.map(\.matched).max(), best > 0 else {
      return Outcome(rows: [], matches: 0, matchedWords: 0, words: terms.count, missed: terms)
    }

    // A tier that matched two words of three is low-precision by construction,
    // and a long low-precision list is the expensive failure: a model handed
    // twenty-five plausible names picks a plausible one rather than the right
    // one. Show fewer of them than of a full match.
    let cap = limit ?? (best == terms.count ? searchLimit : partialLimit)
    let tier = scored.filter { $0.matched == best }
    let rows = tier.sorted { ($0.rank, $0.row.name) < ($1.rank, $1.row.name) }.prefix(cap)
      .map(\.row)
    // Filtered out of the ordered terms, never collected into a Set: Swift
    // randomises Set iteration per process, and two identical searches have to
    // be two identical strings.
    let missed = terms.enumerated().filter { !carried[$0.offset] }.map(\.element)
    return Outcome(
      rows: Array(rows), matches: tier.count, matchedWords: best, words: terms.count,
      missed: missed)
  }

  /// The rows alone, for callers that do not need the arithmetic.
  static func search(catalog: [[String: Any]], query: String, limit: Int? = nil) -> [Row] {
    find(catalog: catalog, query: query, limit: limit).rows
  }

  /// The search result as the text a model reads.
  ///
  /// The trailing sentence is load-bearing: without it a model that has found
  /// `app_store_connect_list_versions` has a name and no way to know it may not
  /// call it directly. Naming the next two tools every time costs a line and
  /// saves a failed call.
  ///
  /// A partial match says so FIRST, and names the words that missed rather than
  /// the ones that hit. A caveat printed under ten rows is a caveat nobody
  /// reads, and a partial list that reads like a full one is worse than the
  /// silence it replaced — the model needs to know it should re-word before it
  /// starts trusting the names. The missing word is the one it has to change.
  ///
  /// It never hints that the write gate hid something. `catalog` arrives
  /// pre-filtered, and taking the tier over what is left is correct; saying so
  /// would leak the gate's state to a client that is not supposed to see it.
  static func searchText(catalog: [[String: Any]], query: String, limit: Int? = nil) -> String {
    let found = find(catalog: catalog, query: query, limit: limit)
    guard !found.rows.isEmpty else {
      return "No tool matches '\(query)'. Call \(searchName) with an empty query to see all "
        + "\(catalog.count)."
    }

    // Taken from the tier the rows came from, not from `missed`, which is a
    // weaker claim: two tools can each carry a different word, leaving nothing
    // unmatched by the catalog while no single tool matched the whole query.
    let partial = found.matchedWords < found.words
    var notice = ""
    if partial {
      notice =
        "Nothing matches all of '\(query)'. These match \(found.matchedWords) of \(found.words)"
      if found.missed.isEmpty {
        notice += " words.\n\n"
      } else {
        let quoted = found.missed.map { "\"\($0)\"" }.joined(separator: ", ")
        notice += " — no tool mentions \(quoted).\n\n"
      }
    }

    let listing = found.rows.map { $0.summary.isEmpty ? $0.name : "\($0.name) — \($0.summary)" }
      .joined(separator: "\n")

    // Shown, matched and total are three different numbers and were being
    // reported as two. A capped tier read "25 of 85 tools", which a model takes
    // as "25 matched"; and a word common enough to hit everything could print
    // "all 85 tools" directly beneath a partial-match warning.
    let shown: String
    if found.rows.count < found.matches {
      shown =
        "Showing \(found.rows.count) of \(found.matches) matches, out of \(catalog.count) "
        + "tools"
    } else if found.matches == catalog.count && !partial {
      shown = "all \(catalog.count) tools"
    } else {
      shown = "\(found.matches) of \(catalog.count) tools"
    }

    return notice + listing + "\n\n\(shown). Read a schema with \(describeName), then run it with "
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
    method: String, params: [String: Any]?, catalog: [[String: Any]],
    writeTools: Set<String> = [], displayName: String, summary: String
  ) -> Routing {
    if method == "tools/list" {
      return .answer([
        "tools": declarations(
          displayName: displayName, summary: summary, toolCount: catalog.count,
          hasWriteDispatcher: !writeTools.isEmpty)
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
        return .answer(content("\(name) needs the name of the tool to call.", isError: true))
      }
      // A name the model invented, or one the write gate is hiding. Answered
      // here rather than forwarded: the server would reject an unknown tool with
      // a protocol error a model cannot act on, where this comes back with the
      // near misses and the next call succeeds.
      guard catalog.contains(where: { $0["name"] as? String == unwrapped.name }) else {
        return .answer(content(describeText(catalog: catalog, name: unwrapped.name), isError: true))
      }
      // The split, enforced. Refused rather than quietly forwarded, and refused
      // in BOTH directions so the two dispatchers stay disjoint: the value of
      // "`bastion_call_tool` cannot run a write" is exactly that nothing has to
      // be trusted to check it a second time. The message names the other one,
      // because a refusal a model cannot act on costs a whole turn.
      let isWrite = writeTools.contains(unwrapped.name)
      if isWrite, name == callName {
        return .answer(
          content(
            "\(unwrapped.name) changes things, so \(callName) will not run it. Call it through "
              + "\(callWriteName) instead, with the same arguments.", isError: true))
      }
      if !isWrite, name == callWriteName {
        return .answer(
          content(
            "\(unwrapped.name) does not change anything, so \(callWriteName) will not run it. "
              + "Call it through \(callName) instead, with the same arguments.", isError: true))
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
