import Foundation

/// Asserts the properties `ClientWiringMerge` promises about somebody else's
/// config file.
///
/// A standalone `swiftc` binary rather than an XCTest bundle: the Xcode project
/// has two synchronized-group targets and no test target, so adding one means
/// hand-editing project.pbxproj — a bigger and riskier diff than the code under
/// test. Compiling one file with the checks beside it is the cheaper trade, and
/// it is what cupertino does for the same reason.
///
/// The fixtures are shaped like the real files. `~/.claude.json` here holds
/// nine global servers and ninety-eight project blocks; Claude Desktop's config
/// carries `coworkUserFilesPath` and `preferences` beside its entries. Every
/// check below is ultimately the same question: after Bastion writes one key,
/// is everything else byte-identical?
///
/// Run with `make wiring-check`.
@main
struct WiringCheck {
  static var failures = 0
  static var checks = 0

  static func check(_ label: String, _ condition: @autoclosure () -> Bool) {
    checks += 1
    if condition() {
      print("  ok   \(label)")
    } else {
      print("  FAIL \(label)")
      failures += 1
    }
  }

  static let port = 8720
  static let bridge = "/Applications/Bastion.app" + ClientWiringMerge.bridgeSuffix

  static let servers = [
    (id: "shopify", label: "Shopify"),
    (id: "keycloak", label: "Keycloak"),
    (id: "stripe", label: "Stripe"),
  ]

  static func httpReach(_ id: String, profile: String = "prod", port: Int = port)
    -> ClientWiringMerge.Reach
  {
    .http(url: "http://127.0.0.1:\(port)/s/\(profile)/\(id)")
  }

  static func bridgeReach(_ id: String, profile: String = "prod", command: String = bridge)
    -> ClientWiringMerge.Reach
  {
    .bridge(command: command, args: ["--profile=\(profile)", "--server=\(id)"])
  }

  static func entry(_ reach: ClientWiringMerge.Reach, token: String = "tok") -> [String: Any] {
    switch reach {
    case .http(let url):
      return [
        "type": "http", "url": url,
        "headers": ["Authorization": "Bearer \(token)"],
      ]
    case .bridge(let command, let args):
      return [
        "command": command, "args": args,
        "env": ["BASTION_TOKEN": token],
      ]
    }
  }

  /// The prefix defaults to what Bastion used to hard-code, so the checks
  /// written against it still say what they said. It is a parameter because it
  /// is a setting now, and the unprefixed case is the new default.
  static func entries(prefix: String = "bastion-", _ reach: (String) -> ClientWiringMerge.Reach)
    -> [String: [String: Any]]
  {
    Dictionary(uniqueKeysWithValues: servers.map { ("\(prefix)\($0.id)", entry(reach($0.id))) })
  }

  static func expected(prefix: String = "bastion-", _ reach: (String) -> ClientWiringMerge.Reach)
    -> [(key: String, reach: ClientWiringMerge.Reach, label: String)]
  {
    servers.map { (key: "\(prefix)\($0.id)", reach: reach($0.id), label: $0.label) }
  }

  static func main() {
    // Given real config paths, prove the merge against those files rather than
    // fixtures. Read-only: the file is parsed, merged in memory, and compared.
    // Synthetic fixtures can only test the shapes somebody thought of, and the
    // interesting ones here — ninety-eight project blocks, a `preferences`
    // object, an `inputs` key — are shapes nobody would have invented.
    let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if !paths.isEmpty {
      for path in paths {
        let url = URL(fileURLWithPath: path)
        // A client's format is a fact about its path here, as it is in
        // `ClientWiring.all`.
        if url.pathExtension == "toml" {
          realTOMLFileSurvives(url)
        } else {
          realFileSurvives(url)
        }
      }
      print("\n\(checks - failures)/\(checks) passed")
      exit(failures > 0 ? 1 : 0)
    }

    unrelatedKeysSurvive()
    bothTransportsRoundTrip()
    isOursIsNarrow()
    targetReadsBothShapes()
    renamedKeysMigrateOnlyWhenOurs()
    prefixChangeLeavesOneEntry()
    collisionsAreNamedNotOverwritten()
    staleIsDecidedByWhereItPoints()
    incompleteVersusNotConfigured()
    unwiringRemovesOnlyOurs()
    nonObjectJSONRefused()
    backupAndNoLitter()
    projectScopeIsIsolated()
    perEntryStateAgreesWithAudit()
    foreignEntriesAreEverythingNotOurs()
    removingTakesExactlyOneKey()

    tomlScannerFindsEveryServer()
    tomlScannerIsNotFooledByProse()
    tomlValuesDegradeRatherThanLie()
    tomlNamesWhatItCannotParse()
    tomlRefusesShapesItCannotSplice()
    tomlSpliceLeavesEveryOtherByteAlone()
    tomlKeepsComments()
    tomlWireIsIdempotent()
    tomlInsertionPointAndBlankLines()
    tomlRendersOnlyOurOwnShape()
    tomlNeverRewritesAHandWrittenEntry()
    tomlDuplicateKeyIsImpossible()
    tomlBackupAtomicityAndMode()

    print("\n\(checks - failures)/\(checks) passed")
    if failures > 0 { exit(1) }
  }

  // MARK: - Against a real file

  /// Deep structural equality, so "unchanged" means unchanged rather than
  /// "still has a value under that key".
  /// `target(of:)` flattened, for asking whether two entries reach the same
  /// place under different names. `ClientWiringMerge` keeps its own private
  /// copy of this; it is two lines and not worth widening that file's surface.
  static func endpoint(_ entry: Any?) -> String? {
    ClientWiringMerge.target(of: entry).map { "\($0.profile)/\($0.server)" }
  }

  static func deepEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x as [String: Any], y as [String: Any]):
      return x.count == y.count && x.allSatisfy { deepEqual($0.value, y[$0.key]) }
    case let (x as [Any], y as [Any]):
      return x.count == y.count && zip(x, y).allSatisfy { deepEqual($0, $1) }
    case (is NSNull, is NSNull): return true
    case let (x as NSObject, y as NSObject): return x.isEqual(y)
    default: return false
    }
  }

  static func realFileSurvives(_ url: URL) {
    print("\n\(url.path)")
    guard let before = try? ClientWiringMerge.readJSON(url) else {
      return check("reads as a JSON object", false)
    }

    let rootKey = before["servers"] != nil && before["mcpServers"] == nil ? "servers" : "mcpServers"
    let originalServers = before[rootKey] as? [String: Any] ?? [:]
    let ours = Set(originalServers.filter { ClientWiringMerge.isOurs($0.value) }.keys)

    let written = entries { httpReach($0) }
    let after = ClientWiringMerge.merged(into: before, rootKey: rootKey, entries: written)

    // Every top-level key except the servers object comes back identical.
    var topLevelIntact = true
    for (key, value) in before where key != rootKey {
      if !deepEqual(value, after[key]) { topLevelIntact = false }
    }
    check("every other top-level key is byte-identical (\(before.count - 1) of them)", topLevelIntact)

    let afterServers = after[rootKey] as? [String: Any] ?? [:]
    var untouched = true
    var examined = 0
    for (key, value) in originalServers where !ours.contains(key) {
      examined += 1
      if !deepEqual(value, afterServers[key]) { untouched = false }
    }
    check("all \(examined) pre-existing `\(rootKey)` entries are unchanged", untouched)
    check("our entries were added", servers.allSatisfy { afterServers["bastion-\($0.id)"] != nil })
    // What `merged` promises: add the keys that were not there, overwrite the
    // ones that were, and remove exactly the entries of OURS that the new ones
    // supersede — the same profile/server under an older key. It does NOT
    // remove an entry of ours that nothing being written replaces, which is
    // what the arithmetic here used to assume. On a Claude Desktop config wired
    // for `prod/appstore-connect` and `prod/unifi-protect`, writing the three
    // fixture servers supersedes neither, and the old formula read that correct
    // outcome as three entries vanishing.
    let writtenKeys = Set(written.keys)
    let writtenTargets = Set(written.values.compactMap { endpoint($0) })
    let added = writtenKeys.subtracting(originalServers.keys).count
    let superseded = originalServers.filter { key, value in
      !writtenKeys.contains(key) && ours.contains(key)
        && endpoint(value).map { writtenTargets.contains($0) } == true
    }.count
    check(
      "nothing vanished; \(superseded) entr\(superseded == 1 ? "y was" : "ies were") superseded",
      afterServers.count == originalServers.count + added - superseded)

    // The nested case, where value semantics bite.
    if let projects = before["projects"] as? [String: Any], let folder = projects.keys.sorted().first {
      let nested = ClientWiringMerge.mergedIntoProject(
        before, folder: folder, entries: entries { httpReach($0) })
      let afterProjects = nested["projects"] as? [String: Any] ?? [:]
      check("all \(projects.count) project blocks survive a nested write", afterProjects.count == projects.count)
      var othersIntact = true
      for (key, value) in projects where key != folder {
        if !deepEqual(value, afterProjects[key]) { othersIntact = false }
      }
      check("the other \(projects.count - 1) project blocks are unchanged", othersIntact)
      let target = afterProjects[folder] as? [String: Any] ?? [:]
      check("the write landed in the target folder", (target["mcpServers"] as? [String: Any])?["bastion-shopify"] != nil)
    }

    // The other direction: taking one of THEIR entries out of the real file has
    // to leave everything else exactly as it was.
    if let victim = ClientWiringMerge.foreignEntries(in: originalServers).first?.key {
      let pruned = ClientWiringMerge.removing(key: victim, from: before, rootKey: rootKey)
      let prunedServers = pruned[rootKey] as? [String: Any] ?? [:]
      check("removing '\(victim)' drops exactly one entry",
        prunedServers.count == originalServers.count - 1 && prunedServers[victim] == nil)
      var siblingsIntact = true
      for (key, value) in originalServers where key != victim {
        if !deepEqual(value, prunedServers[key]) { siblingsIntact = false }
      }
      check("the other \(originalServers.count - 1) entries survive the removal", siblingsIntact)
      var topIntact = true
      for (key, value) in before where key != rootKey {
        if !deepEqual(value, pruned[key]) { topIntact = false }
      }
      check("every other top-level key survives the removal", topIntact)
    }

    // And the nested one, which is where most un-migrated servers actually live.
    let projectGroups = ClientWiringMerge.foreignProjectEntries(in: before)
    if let group = projectGroups.first, let victim = group.entries.first?.key {
      check("\(projectGroups.count) project folders hold a server Bastion did not write", true)
      let pruned = ClientWiringMerge.removing(
        key: victim, inProject: group.folder, from: before)
      let all = pruned["projects"] as? [String: Any] ?? [:]
      let originalProjects = before["projects"] as? [String: Any] ?? [:]
      var othersIntact = true
      for (key, value) in originalProjects where key != group.folder {
        if !deepEqual(value, all[key]) { othersIntact = false }
      }
      check("the other \(originalProjects.count - 1) project blocks survive a nested removal",
        othersIntact)
      let target = all[group.folder] as? [String: Any] ?? [:]
      check("the nested removal landed",
        (target["mcpServers"] as? [String: Any])?[victim] == nil)
      let originalTarget = originalProjects[group.folder] as? [String: Any] ?? [:]
      var targetKeysIntact = true
      for (key, value) in originalTarget where key != "mcpServers" {
        if !deepEqual(value, target[key]) { targetKeysIntact = false }
      }
      check("the target folder's other keys survive", targetKeysIntact)
    }
  }

  // MARK: - The whole point

  /// A config with other people's things in it comes back with all of them.
  static func unrelatedKeysSurvive() {
    print("\nUnrelated keys survive")
    let before: [String: Any] = [
      "mcpServers": [
        "github": ["type": "http", "url": "https://api.githubcopilot.com/mcp/"],
        "stripe": ["type": "http", "url": "https://mcp.stripe.com/"],
        "some-local": ["command": "npx", "args": ["-y", "some-server"]],
        // A loopback server that is NOT Bastion's: right host, wrong path shape.
        "other-local": ["type": "http", "url": "http://127.0.0.1:9000/mcp"],
      ],
      "coworkUserFilesPath": "/Users/x/Cowork",
      "preferences": ["theme": "dark"],
      "numberOfStartups": 41,
      "emptyString": "",
      "nullish": NSNull(),
    ]
    let out = ClientWiringMerge.merged(
      into: before, rootKey: "mcpServers",
      entries: entries { httpReach($0) })
    let servers = out["mcpServers"] as? [String: Any] ?? [:]

    check("top-level `coworkUserFilesPath` kept", out["coworkUserFilesPath"] as? String != nil)
    check("top-level `preferences` kept", (out["preferences"] as? [String: Any])?.count == 1)
    check("a number is still a number", out["numberOfStartups"] as? Int == 41)
    check("empty-string value kept", out["emptyString"] as? String == "")
    check("null value kept", out["nullish"] is NSNull)
    check("remote github kept", (servers["github"] as? [String: Any])?["url"] != nil)
    check("remote stripe kept", (servers["stripe"] as? [String: Any])?["url"] != nil)
    check("third-party stdio server kept", (servers["some-local"] as? [String: Any])?["command"] as? String == "npx")
    check(
      "a different loopback server is not ours and survives",
      (servers["other-local"] as? [String: Any])?["url"] as? String == "http://127.0.0.1:9000/mcp")
    check("every server written", Self.servers.allSatisfy { servers["bastion-\($0.id)"] != nil })
    check("nothing else appeared", servers.count == 4 + Self.servers.count)
  }

  /// Both entry shapes survive a write and read back as configured.
  static func bothTransportsRoundTrip() {
    print("\nBoth transports")
    for (name, reach) in [
      ("http", { (id: String) in httpReach(id) }),
      ("bridge", { (id: String) in bridgeReach(id) }),
    ] {
      let out = ClientWiringMerge.merged(
        into: [:], rootKey: "mcpServers", entries: entries(reach))
      let servers = out["mcpServers"] as? [String: Any] ?? [:]
      check("\(name): audits as configured", ClientWiringMerge.audit(servers: servers, expected: expected(reach)) == .configured)
      check("\(name): every entry is recognised as ours", servers.values.allSatisfy { ClientWiringMerge.isOurs($0) })
    }
    // The shapes are not interchangeable: a config wired for one and audited
    // against the other is stale, not configured. That is what a config written
    // before the bridge existed actually looks like.
    let httpOut = ClientWiringMerge.merged(
      into: [:], rootKey: "mcpServers", entries: entries { httpReach($0) })
    let servers = httpOut["mcpServers"] as? [String: Any] ?? [:]
    if case .stale = ClientWiringMerge.audit(servers: servers, expected: expected { bridgeReach($0) }) {
      check("http config audited as a bridge config is stale", true)
    } else {
      check("http config audited as a bridge config is stale", false)
    }
  }

  /// `isOurs` must recognise what we wrote and nothing more.
  static func isOursIsNarrow() {
    print("\nisOurs is narrow")
    check("our http endpoint", ClientWiringMerge.isOurs(["type": "http", "url": "http://127.0.0.1:8720/s/prod/shopify"]))
    check("our http endpoint on another port", ClientWiringMerge.isOurs(["url": "http://127.0.0.1:9999/s/staging/keycloak"]))
    check("localhost spelling", ClientWiringMerge.isOurs(["url": "http://localhost:8720/s/prod/shopify"]))
    check("our bridge command", ClientWiringMerge.isOurs(["command": "/Applications/Bastion.app/Contents/Helpers/bastion-bridge"]))
    check(
      "a bridge from a build directory, wherever it was",
      ClientWiringMerge.isOurs(["command": "/Users/x/D/Build/Products/Debug/Bastion.app/Contents/Helpers/bastion-bridge"]))

    check("a remote server is not ours", !ClientWiringMerge.isOurs(["url": "https://mcp.stripe.com/"]))
    check("another loopback server is not ours", !ClientWiringMerge.isOurs(["url": "http://127.0.0.1:9000/mcp"]))
    check(
      "loopback with too many segments is not ours",
      !ClientWiringMerge.isOurs(["url": "http://127.0.0.1:8720/s/prod/shopify/extra"]))
    check(
      "loopback with too few segments is not ours",
      !ClientWiringMerge.isOurs(["url": "http://127.0.0.1:8720/s/prod"]))
    check(
      "a non-loopback host with our path shape is not ours",
      !ClientWiringMerge.isOurs(["url": "http://evil.example/s/prod/shopify"]))
    check("npx is not ours", !ClientWiringMerge.isOurs(["command": "npx", "args": ["-y", "x"]]))
    check("a string is not an entry", !ClientWiringMerge.isOurs("bastion-bridge"))
    check("a missing command is not ours", !ClientWiringMerge.isOurs(["args": []]))
    check("nil is not ours", !ClientWiringMerge.isOurs(nil))
  }

  /// A key is migrated only when we were the ones who wrote it.
  static func renamedKeysMigrateOnlyWhenOurs() {
    print("\nRenamed keys")
    // `shopify` here is the key the step-5 migration wrote — ours. `keycloak`
    // is somebody else's stdio server that happens to share the name.
    let before: [String: Any] = [
      "mcpServers": [
        "shopify": ["type": "http", "url": "http://127.0.0.1:8720/s/prod/shopify"],
        "keycloak": ["command": "npx", "args": ["-y", "someone-elses-keycloak"]],
      ]
    ]
    let out = ClientWiringMerge.merged(
      into: before, rootKey: "mcpServers", entries: entries { httpReach($0) })
    let after = out["mcpServers"] as? [String: Any] ?? [:]

    check("our own old key is removed", after["shopify"] == nil)
    check("replaced by the new key", after["bastion-shopify"] != nil)
    check("somebody else's same-named server survives", after["keycloak"] != nil)
    check(
      "and is untouched",
      (after["keycloak"] as? [String: Any])?["command"] as? String == "npx")
  }

  /// What an entry reaches, which is what makes a rename recognisable.
  static func targetReadsBothShapes() {
    print("\nEndpoints")
    func endpoint(_ entry: Any?) -> String? {
      ClientWiringMerge.target(of: entry).map { "\($0.profile)/\($0.server)" }
    }
    check("http", endpoint(entry(httpReach("shopify"))) == "prod/shopify")
    check("http on another port", endpoint(entry(httpReach("shopify", port: 9999))) == "prod/shopify")
    check(
      "bridge", endpoint(entry(bridgeReach("keycloak", profile: "staging"))) == "staging/keycloak")
    check(
      "bridge from another bundle",
      endpoint(entry(bridgeReach("stripe", command: "/Users/x/B.app" + ClientWiringMerge.bridgeSuffix)))
        == "prod/stripe")
    check("a foreign stdio entry reaches nothing", endpoint(["command": "npx", "args": ["-y", "x"]]) == nil)
    check("a foreign loopback URL reaches nothing", endpoint(["url": "http://127.0.0.1:9000/mcp"]) == nil)
    check("a bridge with no args reaches nothing", endpoint(["command": bridge]) == nil)
    check("a bridge with an empty flag reaches nothing", endpoint(["command": bridge, "args": ["--profile=", "--server=x"]]) == nil)
    check("nil reaches nothing", endpoint(nil) == nil)
  }

  /// Changing the prefix renames our entries rather than duplicating them.
  ///
  /// The bug this exists to prevent is two MCP servers in a client's list
  /// pointing at one endpoint, which is what the old fixed `legacy` list would
  /// have produced the first time somebody turned the prefix off.
  static func prefixChangeLeavesOneEntry() {
    print("\nChanging the prefix")
    let wired = ClientWiringMerge.merged(
      into: [:], rootKey: "mcpServers", entries: entries { httpReach($0) })
    let renamed = ClientWiringMerge.merged(
      into: wired, rootKey: "mcpServers", entries: entries(prefix: "") { httpReach($0) })
    let after = renamed["mcpServers"] as? [String: Any] ?? [:]
    check("the new key is there", after["shopify"] != nil)
    check("the old key is gone", after["bastion-shopify"] == nil)
    check("one entry per server, not two", after.count == servers.count)

    let again = ClientWiringMerge.merged(
      into: renamed, rootKey: "mcpServers", entries: entries(prefix: "mcp-") { httpReach($0) })
    let afterAgain = again["mcpServers"] as? [String: Any] ?? [:]
    check("renaming a second time still leaves one each", afterAgain.count == servers.count)
    check("under the newest name", afterAgain["mcp-shopify"] != nil)

    // A rename is decided by the endpoint, so an entry of ours for a profile
    // this write does not mention is left exactly where it is. That is what
    // stops wiring a subset from deleting the rest.
    let others: [String: Any] = [
      "mcpServers": ["staging-shopify": entry(httpReach("shopify", profile: "staging"))]
    ]
    let kept = ClientWiringMerge.merged(
      into: others, rootKey: "mcpServers", entries: entries(prefix: "") { httpReach($0) })
    check(
      "another profile's entry is not swept up",
      (kept["mcpServers"] as? [String: Any])?["staging-shopify"] != nil)

    // The transport can change under a rename too — Claude Desktop's bridge
    // entry and an HTTP entry for the same profile are the same entry.
    let crossed: [String: Any] = ["mcpServers": ["bastion-shopify": entry(bridgeReach("shopify"))]]
    let swapped = ClientWiringMerge.merged(
      into: crossed, rootKey: "mcpServers", entries: entries(prefix: "") { httpReach($0) })
    let swappedServers = swapped["mcpServers"] as? [String: Any] ?? [:]
    check("a rename across transports leaves one entry", swappedServers["bastion-shopify"] == nil)
    check("and it is the new shape", swappedServers.count == servers.count)
  }

  /// A key taken by somebody else's server is named, never quietly replaced.
  static func collisionsAreNamedNotOverwritten() {
    print("\nCollisions")
    let existing: [String: Any] = [
      "shopify": ["command": "npx", "args": ["-y", "@shopify/mcp"]],
      "keycloak": entry(httpReach("keycloak")),
    ]
    let taken = ClientWiringMerge.collisions(
      servers: existing, keys: ["shopify", "keycloak", "stripe"])
    check("names the key somebody else holds", taken == ["shopify"])
    check(
      "one of ours is not a collision, whatever port it names",
      ClientWiringMerge.collisions(
        servers: ["shopify": entry(httpReach("shopify", port: 9999))], keys: ["shopify"]).isEmpty)
    check(
      "one of ours from a bundle that has moved is not a collision",
      ClientWiringMerge.collisions(
        servers: [
          "shopify": entry(bridgeReach("shopify", command: "/Users/x/B.app" + ClientWiringMerge.bridgeSuffix))
        ], keys: ["shopify"]).isEmpty)
    check("an empty config collides with nothing", ClientWiringMerge.collisions(servers: [:], keys: ["shopify"]).isEmpty)

    // And the audit says collision rather than stale. Stale invites the one
    // action that would destroy the entry: write over it.
    let audit = ClientWiringMerge.audit(
      servers: ["bastion-shopify": ["command": "npx", "args": ["-y", "@shopify/mcp"]]],
      expected: expected { httpReach($0) })
    check("a foreign entry under our key audits as a collision", audit == .collides(["bastion-shopify"]))
    check(
      "and outranks the servers that are merely missing",
      { if case .collides = audit { return true } else { return false } }())
  }

  static func staleIsDecidedByWhereItPoints() {
    print("\nStale")
    let servers: [String: Any] = Dictionary(
      uniqueKeysWithValues: Self.servers.map {
        ("bastion-\($0.id)", entry(httpReach($0.id, port: 9999)) as Any)
      })
    if case .stale(let found) = ClientWiringMerge.audit(
      servers: servers, expected: expected { httpReach($0) })
    {
      check("a different port is stale", found.contains("9999"))
    } else {
      check("a different port is stale", false)
    }

    let old = "/Users/x/Downloads/Bastion.app" + ClientWiringMerge.bridgeSuffix
    let bridged: [String: Any] = Dictionary(
      uniqueKeysWithValues: Self.servers.map {
        ("bastion-\($0.id)", entry(bridgeReach($0.id, command: old)) as Any)
      })
    if case .stale(let found) = ClientWiringMerge.audit(
      servers: bridged, expected: expected { bridgeReach($0) })
    {
      check("reports the path it actually found", found.hasPrefix("/Users/x/Downloads"))
    } else {
      check("reports the path it actually found", false)
    }
  }

  static func incompleteVersusNotConfigured() {
    print("\nIncomplete versus not configured")
    check(
      "an empty config is notConfigured",
      ClientWiringMerge.audit(servers: [:], expected: expected { httpReach($0) }) == .notConfigured)

    var partial = entries { httpReach($0) }
    partial.removeValue(forKey: "bastion-keycloak")
    partial.removeValue(forKey: "bastion-stripe")
    let audit = ClientWiringMerge.audit(
      servers: partial as [String: Any], expected: expected { httpReach($0) })
    check("one of three present is incomplete", audit == .incomplete(["Keycloak", "Stripe"]))
    check(
      "and names them in the order given",
      { if case .incomplete(let names) = audit { return names == ["Keycloak", "Stripe"] }
        return false }())
  }

  static func unwiringRemovesOnlyOurs() {
    print("\nUnwiring")
    let before: [String: Any] = [
      "mcpServers": [
        "bastion-shopify": entry(httpReach("shopify")),
        "github": ["type": "http", "url": "https://api.githubcopilot.com/mcp/"],
        "some-local": ["command": "npx", "args": ["-y", "x"]],
      ],
      "preferences": ["theme": "dark"],
    ]
    let out = ClientWiringMerge.unmerged(from: before, rootKey: "mcpServers")
    let after = out["mcpServers"] as? [String: Any] ?? [:]
    check("ours is gone", after["bastion-shopify"] == nil)
    check("github survives", after["github"] != nil)
    check("the local server survives", after["some-local"] != nil)
    check("unrelated top-level keys survive", out["preferences"] != nil)
    check("nothing else was removed", after.count == 2)
  }

  static func nonObjectJSONRefused() {
    print("\nMalformed input")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bastion-wiring-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for (label, contents) in [("an array", "[1,2,3]"), ("a string", "\"hello\""), ("garbage", "{{{")] {
      let url = directory.appendingPathComponent("\(UUID().uuidString).json")
      try? contents.write(to: url, atomically: true, encoding: .utf8)
      var threw = false
      do { _ = try ClientWiringMerge.readJSON(url) } catch { threw = true }
      check("\(label) throws rather than being overwritten", threw)
    }

    let empty = directory.appendingPathComponent("empty.json")
    try? "".write(to: empty, atomically: true, encoding: .utf8)
    check("an empty file reads as {}", (try? ClientWiringMerge.readJSON(empty))?.isEmpty == true)
  }

  static func backupAndNoLitter() {
    print("\nWriting")
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("bastion-wiring-\(UUID().uuidString)")
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    let config = directory.appendingPathComponent("config.json")
    let original = #"{"mcpServers":{"github":{"url":"https://x"}},"preferences":{"theme":"dark"}}"#
    try? original.write(to: config, atomically: true, encoding: .utf8)

    guard let root = try? ClientWiringMerge.readJSON(config) else {
      return check("fixture reads back", false)
    }
    let merged = ClientWiringMerge.merged(
      into: root, rootKey: "mcpServers", entries: entries { httpReach($0) })
    let backup = try? ClientWiringMerge.write(merged, to: config, backupSuffix: "bastion-backup")

    check("a backup was made", backup != nil)
    check(
      "the backup holds the original bytes",
      (try? String(contentsOf: backup!, encoding: .utf8)) == original)
    check("the config was replaced", (try? ClientWiringMerge.readJSON(config))?["mcpServers"] != nil)
    check(
      "the unrelated key survived the round trip",
      ((try? ClientWiringMerge.readJSON(config))?["preferences"] as? [String: Any]) != nil)

    let mode = (try? fm.attributesOfItem(atPath: config.path))?[.posixPermissions] as? NSNumber
    check("the written config is 0600 — it now carries a token", mode?.intValue == 0o600)

    let left = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
    check("no .tmp left behind", !left.contains { $0.hasSuffix(".tmp") })
    check("exactly config + backup", left.count == 2)

    let fresh = directory.appendingPathComponent("nested/deeper/new.json")
    let none = try? ClientWiringMerge.write(["a": 1], to: fresh, backupSuffix: "bastion-backup")
    check("no backup for a file that did not exist", none == nil)
    check("parent directories created", fm.fileExists(atPath: fresh.path))
  }

  /// The ninety-eight-project case: writing into one folder must not disturb
  /// the others, and must not be defeated by dictionary value semantics.
  static func projectScopeIsIsolated() {
    print("\nProject scope")
    let root: [String: Any] = [
      "mcpServers": ["global-one": ["command": "npx"]],
      "projects": [
        "/Users/x/a": ["mcpServers": ["theirs": ["command": "npx"]], "history": [1, 2, 3]],
        "/Users/x/b": ["mcpServers": [:]],
        "/Users/x/c": ["allowedTools": ["Bash"]],
      ],
    ]

    check(
      "a folder with servers is read",
      ClientWiringMerge.projectScopeServers(in: root, folder: "/Users/x/a")?.count == 1)
    check(
      "a known folder with no servers reads as empty, not absent",
      ClientWiringMerge.projectScopeServers(in: root, folder: "/Users/x/b")?.isEmpty == true)
    check(
      "a folder Claude Code knows but has no mcpServers for reads as empty",
      ClientWiringMerge.projectScopeServers(in: root, folder: "/Users/x/c")?.isEmpty == true)
    check(
      "an unknown folder is nil, not empty",
      ClientWiringMerge.projectScopeServers(in: root, folder: "/Users/x/zzz") == nil)

    let out = ClientWiringMerge.mergedIntoProject(
      root, folder: "/Users/x/a", entries: entries { httpReach($0) })
    let projects = out["projects"] as? [String: Any] ?? [:]
    let a = projects["/Users/x/a"] as? [String: Any] ?? [:]
    let aServers = a["mcpServers"] as? [String: Any] ?? [:]

    check("the write actually landed", aServers["bastion-shopify"] != nil)
    check("their server in that folder survives", aServers["theirs"] != nil)
    check("other keys in that folder survive", (a["history"] as? [Int])?.count == 3)
    check(
      "the other folders are untouched",
      (projects["/Users/x/b"] as? [String: Any])?["mcpServers"] as? [String: Any] != nil
        && (projects["/Users/x/c"] as? [String: Any])?["allowedTools"] != nil)
    check(
      "user scope is untouched",
      (out["mcpServers"] as? [String: Any])?["global-one"] != nil)
    check(
      "writing to a folder that did not exist creates only that folder",
      {
        let fresh = ClientWiringMerge.mergedIntoProject(
          root, folder: "/Users/x/new", entries: entries { httpReach($0) })
        let all = fresh["projects"] as? [String: Any] ?? [:]
        return all.count == 4 && (all["/Users/x/new"] as? [String: Any]) != nil
      }())
  }

  // MARK: - Per-entry status

  /// `audit` is `state` reduced. The pane draws a badge per entry from `state`
  /// and a sentence in its header from `audit`, so the thing worth proving is
  /// not either one alone but that they cannot disagree.
  static func perEntryStateAgreesWithAudit() {
    print("\nPer-entry state")

    let reach = httpReach("shopify")
    let mine = entry(reach)

    check(
      "an absent key is missing",
      ClientWiringMerge.state(of: [:], key: "bastion-shopify", reach: reach) == .missing)
    check(
      "a key holding something that is not an object is missing",
      ClientWiringMerge.state(
        of: ["bastion-shopify": "nonsense"], key: "bastion-shopify", reach: reach) == .missing)
    check(
      "our entry pointing where it should matches",
      ClientWiringMerge.state(
        of: ["bastion-shopify": mine], key: "bastion-shopify", reach: reach) == .matches)
    check(
      "our entry on a previous port is stale, and says where it points",
      ClientWiringMerge.state(
        of: ["bastion-shopify": entry(httpReach("shopify", port: 8719))],
        key: "bastion-shopify", reach: reach)
        == .stale("http://127.0.0.1:8719/s/prod/shopify"))
    check(
      "the other transport is stale too, not a match",
      ClientWiringMerge.state(
        of: ["bastion-shopify": entry(bridgeReach("shopify"))],
        key: "bastion-shopify", reach: reach) == .stale(bridge))
    check(
      "a bridge entry from a bundle that has moved is stale, not foreign",
      ClientWiringMerge.state(
        of: ["bastion-shopify": entry(bridgeReach("shopify", command: "/old" + ClientWiringMerge.bridgeSuffix))],
        key: "bastion-shopify", reach: bridgeReach("shopify"))
        == .stale("/old" + ClientWiringMerge.bridgeSuffix))
    check(
      "somebody else's server is foreign, and names what is there",
      ClientWiringMerge.state(
        of: ["bastion-shopify": ["command": "npx", "args": ["-y", "@shopify/mcp"]]],
        key: "bastion-shopify", reach: reach) == .foreign("npx"))
    check(
      "an entry with neither command nor url is foreign with nothing to name",
      ClientWiringMerge.state(
        of: ["bastion-shopify": ["type": "http"]], key: "bastion-shopify", reach: reach)
        == .foreign(nil))

    // The reduction, over every shape the aggregate distinguishes.
    let expect = expected { httpReach($0) }
    func folded(_ servers: [String: Any]) -> ClientWiringMerge.Audit {
      ClientWiringMerge.audit(
        states: expect.map {
          (key: $0.key, label: $0.label,
           state: ClientWiringMerge.state(of: servers, key: $0.key, reach: $0.reach))
        })
    }
    let cases: [(String, [String: Any])] = [
      ("empty", [:]),
      ("fully wired", entries { httpReach($0) }),
      ("half wired", ["bastion-shopify": mine]),
      ("one stale", entries { $0 == "stripe" ? httpReach($0, port: 8719) : httpReach($0) }),
      ("one taken", {
        var s = entries { httpReach($0) }
        s["bastion-stripe"] = ["command": "npx"]
        return s
      }()),
    ]
    for (label, servers) in cases {
      check(
        "audit agrees with the folded states: \(label)",
        ClientWiringMerge.audit(servers: servers, expected: expect) == folded(servers))
    }
  }

  // MARK: - What Bastion did not write

  /// The list the client pane shows under "other servers in this file". Getting
  /// this wrong in the generous direction offers a Remove button for an entry
  /// Bastion itself wrote; in the stingy direction it hides a server that is
  /// still going around the gateway.
  static func foreignEntriesAreEverythingNotOurs() {
    print("\nForeign entries")

    let servers: [String: Any] = [
      "bastion-shopify": entry(httpReach("shopify")),
      "bastion-keycloak": entry(bridgeReach("keycloak")),
      "moved": entry(bridgeReach("stripe", command: "/old" + ClientWiringMerge.bridgeSuffix)),
      "theirs": ["command": "npx", "args": ["-y", "@playwright/mcp"]],
      "remote": ["type": "http", "url": "https://mcp.stripe.com"],
      "their-local": ["type": "http", "url": "http://127.0.0.1:9000/mcp"],
      "junk": ["type": "http"],
    ]
    let found = ClientWiringMerge.foreignEntries(in: servers)

    check("sorted by key", found.map(\.key) == found.map(\.key).sorted())
    check(
      "only what is not ours, including a bridge from a bundle that has moved",
      found.map(\.key) == ["junk", "remote", "their-local", "theirs"])
    check(
      "a command entry names its command",
      found.first { $0.key == "theirs" }?.identity == "npx")
    check(
      "a url entry names its url",
      found.first { $0.key == "remote" }?.identity == "https://mcp.stripe.com")
    check(
      "a loopback url that is not ours is still listed",
      found.first { $0.key == "their-local" }?.identity == "http://127.0.0.1:9000/mcp")
    check(
      "an entry with neither has no identity to name",
      found.first { $0.key == "junk" }?.identity == nil)
    check("nothing at all is an empty list", ClientWiringMerge.foreignEntries(in: [:]).isEmpty)

    let root: [String: Any] = [
      "mcpServers": ["theirs": ["command": "npx"]],
      "projects": [
        "/Users/x/a": ["mcpServers": ["theirs": ["command": "npx"]]],
        "/Users/x/b": ["mcpServers": ["bastion-shopify": entry(httpReach("shopify"))]],
        "/Users/x/c": ["mcpServers": [:]],
        "/Users/x/d": ["allowedTools": ["Bash"]],
      ],
    ]
    let groups = ClientWiringMerge.foreignProjectEntries(in: root)
    check(
      "only folders holding something not ours are listed",
      groups.map(\.folder) == ["/Users/x/a"])
    check("and the entries in them are named", groups.first?.entries.map(\.key) == ["theirs"])
    check(
      "a file with no projects key has no project entries",
      ClientWiringMerge.foreignProjectEntries(in: ["mcpServers": [:]]).isEmpty)
  }

  // MARK: - Taking one entry out

  /// The destructive half, and the one place the app deletes something it did
  /// not write. Every check here is a way it could take out more than it was
  /// asked to.
  static func removingTakesExactlyOneKey() {
    print("\nRemoving one entry")

    let root: [String: Any] = [
      "numStartups": 42,
      "mcpServers": [
        "bastion-shopify": entry(httpReach("shopify")),
        "theirs": ["command": "npx", "args": ["-y", "@playwright/mcp"]],
        "other": ["command": "uvx", "env": ["A": "b"]],
      ],
      "projects": [
        "/Users/x/a": [
          "mcpServers": ["theirs": ["command": "npx"], "kept": ["command": "uvx"]],
          "history": [1, 2, 3],
        ],
        "/Users/x/b": ["mcpServers": ["theirs": ["command": "npx"]]],
      ],
    ]

    let out = ClientWiringMerge.removing(key: "theirs", from: root, rootKey: "mcpServers")
    let servers = out["mcpServers"] as? [String: Any] ?? [:]
    check("the named entry is gone", servers["theirs"] == nil)
    check("exactly one entry went", servers.count == 2)
    check(
      "the siblings are byte-identical",
      deepEqual(servers["other"], (root["mcpServers"] as? [String: Any])?["other"])
        && deepEqual(servers["bastion-shopify"], entry(httpReach("shopify"))))
    check("unrelated top-level keys survive", (out["numStartups"] as? Int) == 42)
    check("the projects block is untouched", deepEqual(out["projects"], root["projects"]))

    check(
      "removing one of OURS is refused — that is what unwire is for",
      deepEqual(
        ClientWiringMerge.removing(key: "bastion-shopify", from: root, rootKey: "mcpServers"),
        root))
    check(
      "removing a key that is not there changes nothing",
      deepEqual(ClientWiringMerge.removing(key: "nope", from: root, rootKey: "mcpServers"), root))
    check(
      "removing under a root key the file does not have changes nothing",
      deepEqual(ClientWiringMerge.removing(key: "theirs", from: root, rootKey: "servers"), root))
    check(
      "emptying the object leaves it empty rather than absent",
      {
        let one: [String: Any] = ["mcpServers": ["theirs": ["command": "npx"]]]
        let empty = ClientWiringMerge.removing(key: "theirs", from: one, rootKey: "mcpServers")
        return (empty["mcpServers"] as? [String: Any])?.isEmpty == true
      }())

    // The nested case, where dictionary value semantics defeat the obvious code.
    let nested = ClientWiringMerge.removing(key: "theirs", inProject: "/Users/x/a", from: root)
    let projects = nested["projects"] as? [String: Any] ?? [:]
    let a = projects["/Users/x/a"] as? [String: Any] ?? [:]
    let aServers = a["mcpServers"] as? [String: Any] ?? [:]
    check("the nested removal actually landed", aServers["theirs"] == nil)
    check("the other server in that folder survives", aServers["kept"] != nil)
    check("the folder's other keys survive", (a["history"] as? [Int])?.count == 3)
    check(
      "the other folder is untouched",
      deepEqual(projects["/Users/x/b"], (root["projects"] as? [String: Any])?["/Users/x/b"]))
    check("user scope is untouched by a nested removal",
      deepEqual(nested["mcpServers"], root["mcpServers"]))
    check(
      "a folder the file does not know changes nothing",
      deepEqual(ClientWiringMerge.removing(key: "theirs", inProject: "/Users/x/zz", from: root), root))
  }

  // MARK: - The TOML client

  /// Shaped like the real `~/.codex/config.toml`: hand-written structure around
  /// the servers, a quoted-key table, and a multi-line string full of prose
  /// sitting exactly where it can do the most damage.
  static let codexConfig = """
    model = "gpt-5.6-sol"

    [features]
    multi_agent = true

    [projects."/Users/olivier/Projects/swift-r2"]
    trust_level = "trusted"

    [desktop]
    git-commit-instructions = \"\"\"
    ## Notes

    - Never write [mcp_servers.ghost] in a commit message
    - A # here is prose, not a comment
    \"\"\"

    # the servers Codex starts itself
    [mcp_servers.node_repl]
    args = []
    command = "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"
    startup_timeout_sec = 120

    [mcp_servers.node_repl.env]
    CODEX_HOME = "/Users/olivier/.codex"

    [mcp_servers.computer-use]
    command = "./Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient"
    args = ["mcp"]
    enabled = false

    [shell_environment_policy.set]
    SHA = "9230e2bd"

    """

  static func scanned(_ text: String) -> ClientWiringTOML.Document? {
    try? ClientWiringTOML.scan(text)
  }

  /// A server's spans as 1-based inclusive line pairs, for readable checks.
  static func spans(_ document: ClientWiringTOML.Document, _ name: String) -> [[Int]] {
    (document.tables[name]?.ranges ?? []).map { [$0.lowerBound + 1, $0.upperBound] }
  }

  static func line(_ document: ClientWiringTOML.Document, _ index: Int) -> String {
    index < document.lines.count ? String(document.text[document.lines[index]]) : ""
  }

  static func names(_ document: ClientWiringTOML.Document?) -> [String] {
    (document?.tables.keys.map { $0 } ?? []).sorted()
  }

  static func tomlScannerFindsEveryServer() {
    print("\nFinding the servers in a TOML config")
    guard let doc = scanned(codexConfig) else { return check("the fixture scans", false) }

    check("both servers are found", names(doc) == ["computer-use", "node_repl"])
    check(
      "a quoted project table is not a server",
      doc.tables["/Users/olivier/Projects/swift-r2"] == nil)

    // Header through last-line-that-says-something, twice: the table and its
    // subtable, with the blank line between them belonging to neither.
    check("the spans are exactly the lines that hold it", spans(doc, "node_repl") == [[18, 21], [23, 24]])
    check(
      "a subtable extends its server rather than starting a new one",
      spans(doc, "node_repl").count == 2)
    check(
      "and the second span is that subtable",
      line(doc, doc.tables["node_repl"]?.ranges.last?.lowerBound ?? 0)
        .hasPrefix("[mcp_servers.node_repl.env]"))

    // A span ends at the last line that says something. The blank line under it
    // belongs to the table below, which is what stops an unwire eating somebody
    // else's separator.
    check(
      "a span stops before the blank line under it",
      line(doc, doc.tables["computer-use"]?.ranges.first?.upperBound ?? 0)
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

    check("values are read", doc.tables["node_repl"]?.value["args"] as? [Any] != nil)
    check(
      "including the command a foreign entry is recognised by",
      (doc.tables["node_repl"]?.value["command"] as? String)?.hasSuffix("node_repl") == true)
    check(
      "a subtable's values land under it",
      ((doc.tables["node_repl"]?.value["env"] as? [String: Any])?["CODEX_HOME"] as? String)
        == "/Users/olivier/.codex")
    check("a hyphenated bare name is a name", doc.tables["computer-use"] != nil)
    check("enabled = false is read", doc.tables["computer-use"]?.isDisabled == true)
    check("and a server without it is not disabled", doc.tables["node_repl"]?.isDisabled == false)
    check("the disabled set names it", doc.disabled == ["computer-use"])

    // Where new blocks land: past the last server, before the blank line that
    // separates it from the next table.
    check(
      "the anchor is just past the last server span",
      doc.anchor == (doc.tables["computer-use"]?.ranges.first?.upperBound ?? -1))

    let quoted = scanned("[mcp_servers.\"my server\"]\nurl = \"http://x/\"\n")
    check("a quoted table name is unquoted", quoted?.tables["my server"] != nil)

    let parent = scanned(
      "[mcp_servers]\nfoo = { command = \"/bin/foo\" }\nbar = { url = \"http://y/\" }\n")
    check("a bare [mcp_servers] table names its keys as servers", names(parent) == ["bar", "foo"])
    check("and parses them", (parent?.tables["foo"]?.value["command"] as? String) == "/bin/foo")
    check("each inline entry owns exactly its own line", parent?.tables["bar"]?.ranges == [2..<3])

    check("a file with no servers has none", scanned("model = \"x\"\n")?.tables.isEmpty == true)
    check("and anchors at the end of it", scanned("model = \"x\"\n")?.anchor == 1)
    check("an empty file scans", scanned("")?.tables.isEmpty == true)
  }

  /// The failure a line-oriented scanner walks into, stated as a check.
  ///
  /// The real config keeps a multi-line string of markdown directly above its
  /// first server. Prose is allowed to contain a bracket at column 0, a hash,
  /// and the words of a table header; none of it is TOML.
  static func tomlScannerIsNotFooledByProse() {
    print("\nProse in a TOML config is not TOML")
    guard let doc = scanned(codexConfig) else { return check("the fixture scans", false) }

    check("a table header inside a string mints no server", doc.tables["ghost"] == nil)
    check("exactly two servers, not three", doc.tables.count == 2)
    check(
      "and the real header after the string is found at its own line",
      line(doc, doc.tables["node_repl"]?.ranges.first?.lowerBound ?? 0)
        .hasPrefix("[mcp_servers.node_repl]"))

    let literal = scanned(
      "a = '''\n[mcp_servers.ghost]\n# not a comment\n'''\n"
        + "[mcp_servers.real]\nurl = \"http://z/\"\n")
    check("a literal multi-line string is opaque too", names(literal) == ["real"])

    check(
      "a hash inside a literal string does not start a comment",
      (scanned("[mcp_servers.a]\ncommand = '/bin/x#y'\n")?.tables["a"]?.value["command"]
        as? String) == "/bin/x#y")
    check(
      "an escaped quote does not end a basic string",
      (scanned("[mcp_servers.a]\ncommand = \"/bin/\\\"x\"\n")?.tables["a"]?.value["command"]
        as? String) == "/bin/\"x")
    check(
      "a comment naming a table is still a comment",
      scanned("# [mcp_servers.ghost]\nmodel = \"x\"\n")?.tables.isEmpty == true)
    check(
      "a dot inside a quoted key is not a path separator",
      scanned("[mcp_servers.\"a.b\"]\nurl = \"http://q/\"\n")?.tables["a.b"] != nil)
  }

  /// Values are best effort, and best effort means omitting rather than
  /// guessing. Nothing omitted here could have been a `command` or a `url`, so
  /// nothing downstream is poorer for it.
  static func tomlValuesDegradeRatherThanLie() {
    print("\nA value this cannot type is omitted, not guessed")
    let text = """
      [mcp_servers.a]
      command = "/bin/a"
      when = 1979-05-27T07:32:00Z
      ratio = 0.5
      big = 1_000
      nested = [[1, 2], [3]]
      spread = [
        "one",
      ]
      after = "still read"

      """
    guard let doc = scanned(text), let table = doc.tables["a"] else {
      return check("it scans", false)
    }
    check("the command is right", (table.value["command"] as? String) == "/bin/a")
    check("a datetime is omitted", table.value["when"] == nil)
    check("a float is omitted", table.value["ratio"] == nil)
    check("an underscored integer is omitted", table.value["big"] == nil)
    check("a nested array is read", (table.value["nested"] as? [Any])?.count == 2)
    check("a multi-line array is omitted", table.value["spread"] == nil)
    check("and the key after it is still read", (table.value["after"] as? String) == "still read")
    check("the span covers all of it, continuation lines included", spans(doc, "a") == [[1, 10]])
    check(
      "a plain integer is read",
      (scanned("[mcp_servers.a]\nn = 12\n")?.tables["a"]?.value["n"] as? Int) == 12)
  }

  /// The invariant, from both ends.
  ///
  /// A server this can see but not describe must still be NAMED, because the
  /// name is what `collisions` refuses on. Dropping it would let a wire append a
  /// second `[mcp_servers.<name>]`, and a duplicate key does not cost one entry
  /// — it costs the whole file.
  static func tomlNamesWhatItCannotParse() {
    print("\nA server this cannot describe is still a server")
    let text = """
      [mcp_servers.stripe]
      when = 1979-05-27T07:32:00Z
      ratio = 0.5

      [mcp_servers.opaque]

      [mcp_servers.inline]
      command = { not = "a string" }

      """
    guard let doc = scanned(text) else { return check("it scans", false) }
    check("all three are named", names(doc) == ["inline", "opaque", "stripe"])
    check("even with nothing typed under it", doc.tables["stripe"]?.value.isEmpty == true)
    check("even with nothing under it at all", doc.tables["opaque"]?.value.isEmpty == true)

    // The consequence, which is the whole reason for the invariant.
    let servers = doc.servers
    check(
      "so none of them reads as ours",
      servers.allSatisfy { !ClientWiringMerge.isOurs($0.value) })
    check(
      "and a key we would write is refused rather than duplicated",
      ClientWiringMerge.collisions(servers: servers, keys: ["stripe", "keycloak"]) == ["stripe"])
    check(
      "an entry whose command is not a string names no identity",
      ClientWiringMerge.identity(of: doc.tables["inline"]?.value) == nil)
    check(
      "and is listed as foreign anyway",
      ClientWiringMerge.foreignEntries(in: servers).map { $0.key }
        == ["inline", "opaque", "stripe"])
  }

  /// What it refuses, and why a refusal is enough: every write path begins with
  /// a read, so a scan that throws is a client that cannot be written to.
  static func tomlRefusesShapesItCannotSplice() {
    print("\nShapes this refuses rather than guesses at")
    func refuses(_ label: String, _ text: String) {
      var threw = false
      do { _ = try ClientWiringTOML.scan(text) } catch { threw = true }
      check(label, threw)
    }

    refuses("a dotted key under [mcp_servers]", "[mcp_servers]\nfoo.command = \"/bin/foo\"\n")
    refuses("an array of tables", "[[mcp_servers.foo]]\ncommand = \"/bin/foo\"\n")
    refuses("an unterminated multi-line string", "a = \"\"\"\nnever closed\n")
    refuses("an unterminated single-line string", "[mcp_servers.a]\ncommand = \"/bin/a\n")
    refuses("an unclosed table header", "[mcp_servers.a\n")
    refuses("trailing junk after a header", "[mcp_servers.a] oops\n")
    refuses("a key with no value", "[mcp_servers.a]\ncommand\n")
    refuses("an unclosed inline table", "[mcp_servers]\nfoo = { command = \"/bin/foo\"\n")

    check(
      "non-UTF-8 bytes are refused by name",
      {
        let url = FileManager.default.temporaryDirectory
          .appendingPathComponent("bastion-check-\(UUID().uuidString).toml")
        try? Data([0xFF, 0xFE, 0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
          _ = try ClientWiringTOML.read(url)
          return false
        } catch {
          return true
        }
      }())

    check(
      "a refusal names the line, because the remedy is a person looking at it",
      {
        do {
          _ = try ClientWiringTOML.scan("model = \"x\"\n[mcp_servers]\nfoo.bar = 1\n")
          return false
        } catch {
          return error.localizedDescription.contains("line 3")
        }
      }())
  }

  /// What Bastion writes into a TOML config, in the shape Codex reads.
  ///
  /// No `type` key: Codex has none, a `url` implies streamable HTTP, and
  /// `http_headers` takes a literal — which is the fact that makes wiring it
  /// possible at all, since `bearer_token_env_var` names an environment
  /// variable Bastion has no way to set.
  static func tomlEntry(_ id: String, profile: String = "prod", token: String = "tok")
    -> [String: Any]
  {
    [
      "url": "http://127.0.0.1:\(port)/s/\(profile)/\(id)",
      "http_headers": ["Authorization": "Bearer \(token)"],
    ]
  }

  static func tomlEntries(_ ids: [String] = ["shopify", "stripe"]) -> [String: [String: Any]] {
    Dictionary(uniqueKeysWithValues: ids.map { ($0, tomlEntry($0)) })
  }

  static func wire(_ text: String, _ ids: [String] = ["shopify", "stripe"]) -> String? {
    guard let doc = scanned(text) else { return nil }
    return ClientWiringTOML.spliced(doc, removing: [], upserting: tomlEntries(ids))
  }

  static func unwire(_ text: String, _ ids: [String] = ["shopify", "stripe"]) -> String? {
    guard let doc = scanned(text) else { return nil }
    return ClientWiringTOML.spliced(doc, removing: Set(ids), upserting: [:])
  }

  /// The headline claim: a wire adds lines and changes none.
  static func tomlSpliceLeavesEveryOtherByteAlone() {
    print("\nA TOML splice leaves every other byte alone")
    guard let wired = wire(codexConfig) else { return check("it wires", false) }

    // Stated as a subtraction rather than a comparison of parsed values: take
    // our blocks back out and the file must be what it was, to the byte.
    check("taking our blocks back out gives the original", unwire(wired) == codexConfig)
    check("it is strictly longer", wired.count > codexConfig.count)
    check(
      "and every original line is still in it, in order",
      {
        var rest = Substring(wired)
        for line in codexConfig.split(separator: "\n") where !line.isEmpty {
          guard let found = rest.range(of: line) else { return false }
          rest = rest[found.upperBound...]
        }
        return true
      }())

    // Line endings and whitespace on lines nobody touched.
    let crlf = "model = \"x\"\r\n\r\n[mcp_servers.a]\r\nurl = \"http://a/\"\r\n\r\n[other]\r\nk = 1\r\n"
    guard let wiredCRLF = wire(crlf) else { return check("CRLF wires", false) }
    check("a CRLF file stays CRLF", !wiredCRLF.contains("\n\n") || wiredCRLF.contains("\r\n\r\n"))
    check("our own blocks use its line ending", wiredCRLF.contains("[mcp_servers.shopify]\r\n"))
    check("and it round-trips", unwire(wiredCRLF) == crlf)

    let ragged = "\u{FEFF}model\t=  \"x\"   \n\n[mcp_servers.a]\nurl = \"http://a/\"\n"
    guard let wiredRagged = wire(ragged) else { return check("a ragged file wires", false) }
    check("a byte-order mark survives", wiredRagged.hasPrefix("\u{FEFF}"))
    check("tabs and alignment inside a line survive", wiredRagged.contains("model\t=  \"x\"   \n"))
    check("and it round-trips", unwire(wiredRagged) == ragged)
  }

  /// Comments are the thing a serialiser would have eaten, so they get their
  /// own section.
  static func tomlKeepsComments() {
    print("\nComments in a TOML config survive both directions")
    let text = """
      # the top of somebody's file
      model = "x"

      # above the servers
      [mcp_servers.node_repl]
      # inside the block
      command = "/bin/node"  # and trailing

      # this one belongs to the table below, not the one above
      [other]
      k = 1

      """
    guard let wired = wire(text), let back = unwire(wired) else {
      return check("it wires", false)
    }
    for comment in [
      "# the top of somebody's file", "# above the servers", "# inside the block",
      "# and trailing", "# this one belongs to the table below",
    ] {
      check("kept through a wire: \(comment)", wired.contains(comment))
    }
    check("and an unwire gives the file back exactly", back == text)

    // The span rule that makes the last one work: a block ends at its last
    // meaningful line, so the comment under it is the next table's.
    let removed = unwire(wired, ["node_repl"])
    check(
      "removing a foreign entry leaves the comment below it",
      removed?.contains("# this one belongs to the table below") == true)
    check("but takes the entry", removed?.contains("[mcp_servers.node_repl]") == false)
  }

  /// Writing the same thing twice must be a no-op, and writing then removing
  /// must be a round trip. Both are about blank lines, which is why they are
  /// checked to the byte rather than by parsing.
  static func tomlWireIsIdempotent() {
    print("\nWiring a TOML config twice changes nothing the second time")
    for (label, text) in [
      ("the realistic file", codexConfig),
      ("no servers at all", "model = \"x\"\n"),
      ("an empty file", ""),
      ("a trailing blank line", "[other]\nk = 1\n\n"),
      ("servers last in the file", "[other]\nk = 1\n\n[mcp_servers.a]\nurl = \"http://a/\"\n"),
      ("no blank line before the next table", "[mcp_servers.a]\nurl = \"http://a/\"\n[other]\nk = 1\n"),
    ] {
      guard let once = wire(text), let twice = wire(once) else {
        check("\(label): it wires", false)
        continue
      }
      check("\(label): wiring twice is the same file", once == twice)
      check("\(label): wire then unwire is the original", unwire(once) == text)
      check(
        "\(label): ten rounds accumulate nothing",
        {
          var current = text
          for _ in 0..<10 {
            guard let up = wire(current), let down = unwire(up) else { return false }
            current = down
          }
          return current == text
        }())
    }

    check(
      "unwiring a file that holds none of ours writes nothing new",
      unwire(codexConfig) == codexConfig)

    // The one case that cannot round-trip exactly, stated rather than glossed:
    // a file with no final newline has to gain one before anything can be
    // appended, and an unwire has no way to know that newline was ours.
    check(
      "a file with no final newline comes back with one, and nothing else added",
      unwire(wire("model = \"x\"") ?? "") == "model = \"x\"\n")
  }

  static func tomlInsertionPointAndBlankLines() {
    print("\nWhere a TOML block lands, and the blank lines around it")

    // Grouped with the servers already there, not appended past unrelated
    // tables -- which is also what makes a second wire land in the same place.
    guard let wired = wire(codexConfig) else { return check("it wires", false) }
    let lines = wired.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let ours = lines.firstIndex(of: "[mcp_servers.shopify]") ?? -1
    let lastForeign = lines.firstIndex(of: "enabled = false") ?? -1
    let nextTable = lines.firstIndex(of: "[shell_environment_policy.set]") ?? -1
    check("our block goes after the servers already there", ours > lastForeign)
    check("and before the unrelated table below them", ours < nextTable)
    check("with exactly one blank line above it", lines[ours - 1].isEmpty && !lines[ours - 2].isEmpty)
    check(
      "and exactly one between two of our blocks",
      {
        guard let second = lines.firstIndex(of: "[mcp_servers.stripe]") else { return false }
        return lines[second - 1].isEmpty && !lines[second - 2].isEmpty
      }())

    check(
      "a file with no servers gets them at the end",
      wire("model = \"x\"\n")?.hasSuffix("[mcp_servers.stripe]\n"
        + "url = \"http://127.0.0.1:\(port)/s/prod/stripe\"\n"
        + "http_headers = { Authorization = \"Bearer tok\" }\n") == true)
    check(
      "an empty file gets them and nothing else",
      wire("")?.hasPrefix("[mcp_servers.shopify]\n") == true)
    check(
      "a file with no final newline gains exactly one",
      {
        guard let out = wire("model = \"x\"") else { return false }
        return out.hasPrefix("model = \"x\"\n\n[mcp_servers.") && out.hasSuffix("}\n")
      }())
    // The block brings its own blank line even when one is already there. The
    // cost is a second blank line in that one case; the gain is that an unwire
    // gives back the blank line the user wrote instead of eating it.
    check(
      "a block always brings its own blank line",
      wire("model = \"x\"\n\n")?.contains("model = \"x\"\n\n\n[mcp_servers.") == true)
    check(
      "which the unwire takes back, leaving theirs",
      unwire(wire("model = \"x\"\n\n") ?? "") == "model = \"x\"\n\n")
  }

  /// Rendering is only ever pointed at Bastion's own shape, so this checks that
  /// shape and the escaping it has to survive.
  static func tomlRendersOnlyOurOwnShape() {
    print("\nWhat a rendered TOML block says")
    let block = ClientWiringTOML.render(
      name: "stripe", entry: tomlEntry("stripe"), newline: "\n")
    check("it is a table header for the server", block.hasPrefix("[mcp_servers.stripe]\n"))
    check("the url comes first, because that is what a reader wants", {
      let lines = block.split(separator: "\n")
      return lines.count > 1 && lines[1].hasPrefix("url = ")
    }())
    check("the headers are an inline table", block.contains("http_headers = { Authorization ="))
    check("and there is no type key, because Codex has none", !block.contains("type"))

    // Re-reading our own output is the only round trip that has to hold.
    let doc = scanned(block)
    check("it re-scans to one server", names(doc) == ["stripe"])
    check(
      "with the url it was given",
      (doc?.tables["stripe"]?.value["url"] as? String)
        == "http://127.0.0.1:\(port)/s/prod/stripe")
    check(
      "and the header it was given",
      ((doc?.tables["stripe"]?.value["http_headers"] as? [String: Any])?["Authorization"]
        as? String) == "Bearer tok")
    check("which reads as ours", ClientWiringMerge.isOurs(doc?.tables["stripe"]?.value))
    check(
      "and reaches the right profile and server",
      {
        guard let target = ClientWiringMerge.target(of: doc?.tables["stripe"]?.value) else {
          return false
        }
        return target.profile == "prod" && target.server == "stripe"
      }())

    // A token is a secret Bastion did not choose the alphabet of.
    let hostile = "a\"b\\c\nd\te"
    let escaped = ClientWiringTOML.render(
      name: "a", entry: ["url": "http://x/", "http_headers": ["Authorization": hostile]],
      newline: "\n")
    check(
      "a token holding a quote, a backslash and a newline round-trips",
      ((scanned(escaped)?.tables["a"]?.value["http_headers"] as? [String: Any])?["Authorization"]
        as? String) == hostile)

    let odd = ClientWiringTOML.render(name: "my server", entry: ["url": "http://x/"], newline: "\n")
    check("a name needing quotes is quoted", odd.hasPrefix("[mcp_servers.\"my server\"]"))
    check("and comes back unquoted", scanned(odd)?.tables["my server"] != nil)
  }

  static func tomlNeverRewritesAHandWrittenEntry() {
    print("\nA hand-written TOML entry is never re-rendered")
    guard let doc = scanned(codexConfig) else { return check("it scans", false) }
    // One contiguous run of its lines: the table's own span. Its subtable is a
    // second span with a blank line between, checked separately below.
    let foreign = (doc.tables["node_repl"]?.ranges.first.map { $0.map { line(doc, $0) }.joined() })
      ?? ""
    check("there is something to preserve", foreign.contains("startup_timeout_sec = 120"))

    for (label, output) in [
      ("a wire", wire(codexConfig)),
      ("an unwire of ours", unwire(wire(codexConfig) ?? "")),
      ("removing a different entry", unwire(codexConfig, ["computer-use"])),
    ] {
      check("\(label) leaves it byte-identical", output?.contains(foreign) == true)
      check(
        "\(label) leaves its subtable alone too",
        output?.contains("[mcp_servers.node_repl.env]\nCODEX_HOME = \"/Users/olivier/.codex\"")
          == true)
    }

    // Removing it takes both its spans -- the table and its subtable -- and
    // nothing else.
    guard let removed = unwire(codexConfig, ["node_repl"]) else {
      return check("it removes", false)
    }
    check("the table is gone", !removed.contains("[mcp_servers.node_repl]"))
    check("its subtable went with it", !removed.contains("[mcp_servers.node_repl.env]"))
    check("and its values with that", !removed.contains("CODEX_HOME"))
    check("the other server is untouched", removed.contains("[mcp_servers.computer-use]"))
    check("and so is everything that is not a server", removed.contains("[shell_environment_policy.set]"))
    check("including the prose above them", removed.contains("- A # here is prose, not a comment"))
  }

  /// The TOML-specific catastrophe, checked over every fixture: a name written
  /// twice is not a lost entry, it is a file Codex cannot parse at all.
  static func tomlDuplicateKeyIsImpossible() {
    print("\nA splice can never write a name twice")
    let fixtures = [
      "the realistic file": codexConfig,
      "an empty file": "",
      "no servers": "model = \"x\"\n",
      "a parent table": "[mcp_servers]\nshopify = { command = \"/bin/theirs\" }\n",
      "one of ours already there":
        "[mcp_servers.shopify]\nurl = \"http://127.0.0.1:\(port)/s/prod/shopify\"\n",
      "one of ours under a stale port":
        "[mcp_servers.shopify]\nurl = \"http://127.0.0.1:9999/s/prod/shopify\"\n",
    ]
    for (label, text) in fixtures.sorted(by: { $0.key < $1.key }) {
      guard let doc = scanned(text) else {
        check("\(label): it scans", false)
        continue
      }
      // Write over everything, including a key somebody else owns -- the shape
      // `force` produces, and the one most able to duplicate a name.
      let out = ClientWiringTOML.spliced(doc, removing: [], upserting: tomlEntries())
      guard let rescanned = scanned(out) else {
        check("\(label): the result still scans", false)
        continue
      }
      check("\(label): the result still scans", true)
      var headers = 0
      for raw in out.split(separator: "\n", omittingEmptySubsequences: false)
      where raw.hasPrefix("[mcp_servers.shopify]") {
        headers += 1
      }
      check("\(label): the name appears as a header exactly once", headers == 1)
      check(
        "\(label): and the rescan agrees it is one server",
        rescanned.tables["shopify"]?.ranges.count == 1)
      check(
        "\(label): pointing where we put it",
        (rescanned.tables["shopify"]?.value["url"] as? String)
          == "http://127.0.0.1:\(port)/s/prod/shopify")
    }
  }

  /// The byte overload, through the same properties `backupAndNoLitter` asserts
  /// for the JSON one -- because a TOML write goes through it too, and "the
  /// backup is recoverable" is not a claim worth holding on one format only.
  static func tomlBackupAtomicityAndMode() {
    print("\nWriting a TOML config")
    let fm = FileManager.default
    let directory = fm.temporaryDirectory
      .appendingPathComponent("bastion-toml-\(UUID().uuidString)")
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    let config = directory.appendingPathComponent("config.toml")
    try? codexConfig.write(to: config, atomically: true, encoding: .utf8)

    guard let document = try? ClientWiringTOML.read(config) else {
      return check("the fixture reads back", false)
    }
    let text = ClientWiringTOML.spliced(document, removing: [], upserting: tomlEntries())
    let backup = try? ClientWiringMerge.write(
      Data(text.utf8), to: config, backupSuffix: "bastion-backup")

    check("a backup was made", backup != nil)
    check(
      "the backup holds the original bytes",
      (try? String(contentsOf: backup!, encoding: .utf8)) == codexConfig)
    check(
      "the config on disk is the spliced text, to the byte",
      (try? String(contentsOf: config, encoding: .utf8)) == text)
    check(
      "and it reads back with our entries in it",
      names(try? ClientWiringTOML.read(config)) == ["computer-use", "node_repl", "shopify", "stripe"])

    let mode = (try? fm.attributesOfItem(atPath: config.path))?[.posixPermissions] as? NSNumber
    check("the written config is 0600 — it now carries a token", mode?.intValue == 0o600)

    let left = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
    check("no .tmp left behind", !left.contains { $0.hasSuffix(".tmp") })
    check("exactly config + backup", left.count == 2)

    // A `~/.codex` that does not exist yet is the ordinary first-run case.
    let fresh = directory.appendingPathComponent("nested/.codex/config.toml")
    let blocks = ClientWiringTOML.spliced(
      ClientWiringTOML.empty, removing: [], upserting: tomlEntries())
    let none = try? ClientWiringMerge.write(
      Data(blocks.utf8), to: fresh, backupSuffix: "bastion-backup")
    check("no backup for a file that did not exist", none == nil)
    check("parent directories created", fm.fileExists(atPath: fresh.path))
    check("and the new file is exactly our blocks", names(try? ClientWiringTOML.read(fresh)) == ["shopify", "stripe"])
  }

  /// The `wiring-check-real` half for a TOML config.
  ///
  /// Read-only: scanned, spliced in memory and compared. Fixtures only cover
  /// the shapes somebody thought of, and a config.toml that has been lived in
  /// holds the ones nobody would have invented.
  static func realTOMLFileSurvives(_ url: URL) {
    print("\n\(url.path)")
    let document: ClientWiringTOML.Document
    do {
      document = try ClientWiringTOML.read(url)
    } catch {
      return check("it scans (\(error.localizedDescription))", false)
    }
    check("it scans, \(document.lines.count) lines", true)

    let ours = Set(document.tables.filter { ClientWiringMerge.isOurs($0.value.value) }.keys)
    let theirs = document.tables.keys.filter { !ours.contains($0) }.sorted()
    check(
      "\(document.tables.count) servers found, \(theirs.count) of them not ours", true)

    let written = tomlEntries()
    let out = ClientWiringTOML.spliced(document, removing: [], upserting: written)

    // The claim, against a file nobody wrote for a test.
    check(
      "taking our blocks back out gives the file back, to the byte",
      ClientWiringTOML.spliced(
        try! ClientWiringTOML.scan(out), removing: Set(written.keys), upserting: [:])
        == document.text)
    check(
      "wiring it twice changes nothing the second time",
      ClientWiringTOML.spliced(
        try! ClientWiringTOML.scan(out), removing: [], upserting: written) == out)

    let rescanned = try? ClientWiringTOML.scan(out)
    check("the result still scans", rescanned != nil)
    check(
      "every server it held is still there",
      theirs.allSatisfy { rescanned?.tables[$0] != nil })
    check(
      "and says exactly what it said",
      theirs.allSatisfy { deepEqual(document.tables[$0]?.value, rescanned?.tables[$0]?.value) })
    check(
      "no name was written twice",
      rescanned?.tables.values.allSatisfy { $0.ranges.count <= 2 } == true)
    check("our entries were added", written.keys.allSatisfy { rescanned?.tables[$0] != nil })
    check(
      "and read back as ours",
      written.keys.allSatisfy { ClientWiringMerge.isOurs(rescanned?.tables[$0]?.value) })
  }
}
