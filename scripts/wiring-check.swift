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
    (id: "tastytrade", label: "TastyTrade"),
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

  static func entries(_ reach: (String) -> ClientWiringMerge.Reach) -> [String: [String: Any]] {
    Dictionary(uniqueKeysWithValues: servers.map { ("bastion-\($0.id)", entry(reach($0.id))) })
  }

  static func expected(_ reach: (String) -> ClientWiringMerge.Reach)
    -> [(key: String, reach: ClientWiringMerge.Reach, label: String)]
  {
    servers.map { (key: "bastion-\($0.id)", reach: reach($0.id), label: $0.label) }
  }

  static func main() {
    // Given real config paths, prove the merge against those files rather than
    // fixtures. Read-only: the file is parsed, merged in memory, and compared.
    // Synthetic fixtures can only test the shapes somebody thought of, and the
    // interesting ones here — ninety-eight project blocks, a `preferences`
    // object, an `inputs` key — are shapes nobody would have invented.
    let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
    if !paths.isEmpty {
      for path in paths { realFileSurvives(URL(fileURLWithPath: path)) }
      print("\n\(checks - failures)/\(checks) passed")
      exit(failures > 0 ? 1 : 0)
    }

    unrelatedKeysSurvive()
    bothTransportsRoundTrip()
    isOursIsNarrow()
    legacyMigratesOnlyWhenOurs()
    staleIsDecidedByWhereItPoints()
    incompleteVersusNotConfigured()
    unwiringRemovesOnlyOurs()
    nonObjectJSONRefused()
    backupAndNoLitter()
    projectScopeIsIsolated()

    print("\n\(checks - failures)/\(checks) passed")
    if failures > 0 { exit(1) }
  }

  // MARK: - Against a real file

  /// Deep structural equality, so "unchanged" means unchanged rather than
  /// "still has a value under that key".
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

    let after = ClientWiringMerge.merged(
      into: before, rootKey: rootKey, entries: entries { httpReach($0) }, legacy: [:])

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
    check(
      "nothing vanished",
      afterServers.count == originalServers.count + servers.count - ours.count)

    // The nested case, where value semantics bite.
    if let projects = before["projects"] as? [String: Any], let folder = projects.keys.sorted().first {
      let nested = ClientWiringMerge.mergedIntoProject(
        before, folder: folder, entries: entries { httpReach($0) }, legacy: [:])
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
      entries: entries { httpReach($0) }, legacy: [:])
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
        into: [:], rootKey: "mcpServers", entries: entries(reach), legacy: [:])
      let servers = out["mcpServers"] as? [String: Any] ?? [:]
      check("\(name): audits as configured", ClientWiringMerge.audit(servers: servers, expected: expected(reach)) == .configured)
      check("\(name): every entry is recognised as ours", servers.values.allSatisfy { ClientWiringMerge.isOurs($0) })
    }
    // The shapes are not interchangeable: a config wired for one and audited
    // against the other is stale, not configured. That is what a config written
    // before the bridge existed actually looks like.
    let httpOut = ClientWiringMerge.merged(
      into: [:], rootKey: "mcpServers", entries: entries { httpReach($0) }, legacy: [:])
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

  /// A legacy key is migrated only when we were the ones who wrote it.
  static func legacyMigratesOnlyWhenOurs() {
    print("\nLegacy keys")
    // `shopify` here is the key the step-5 migration wrote — ours. `keycloak`
    // is somebody else's stdio server that happens to share the name.
    let before: [String: Any] = [
      "mcpServers": [
        "shopify": ["type": "http", "url": "http://127.0.0.1:8720/s/prod/shopify"],
        "keycloak": ["command": "npx", "args": ["-y", "someone-elses-keycloak"]],
      ]
    ]
    let legacy = Dictionary(uniqueKeysWithValues: servers.map { ("bastion-\($0.id)", $0.id) })
    let out = ClientWiringMerge.merged(
      into: before, rootKey: "mcpServers", entries: entries { httpReach($0) }, legacy: legacy)
    let after = out["mcpServers"] as? [String: Any] ?? [:]

    check("our own old key is removed", after["shopify"] == nil)
    check("replaced by the new key", after["bastion-shopify"] != nil)
    check("somebody else's same-named server survives", after["keycloak"] != nil)
    check(
      "and is untouched",
      (after["keycloak"] as? [String: Any])?["command"] as? String == "npx")
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
    partial.removeValue(forKey: "bastion-tastytrade")
    let audit = ClientWiringMerge.audit(
      servers: partial as [String: Any], expected: expected { httpReach($0) })
    check("one of three present is incomplete", audit == .incomplete(["Keycloak", "TastyTrade"]))
    check(
      "and names them in the order given",
      { if case .incomplete(let names) = audit { return names == ["Keycloak", "TastyTrade"] }
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
      into: root, rootKey: "mcpServers", entries: entries { httpReach($0) }, legacy: [:])
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
      root, folder: "/Users/x/a", entries: entries { httpReach($0) }, legacy: [:])
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
          root, folder: "/Users/x/new", entries: entries { httpReach($0) }, legacy: [:])
        let all = fresh["projects"] as? [String: Any] ?? [:]
        return all.count == 4 && (all["/Users/x/new"] as? [String: Any]) != nil
      }())
  }
}
