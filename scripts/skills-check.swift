import Foundation

/// Asserts what `SkillCatalog`, `SkillLinks` and `SkillLinker` promise about
/// folders Bastion does not own.
///
/// A standalone `swiftc` binary for the reason `wiring-check.swift` gives: the
/// Xcode project has no test target. The fake tree below knows about symlinks,
/// because every interesting case in this feature is one.
///
/// Run with `make skills-check`.
@main
struct SkillsCheck {
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

  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--real", (3...5).contains(arguments.count) {
      realPlanChangesOnlyBrokenLinks(
        home: arguments[1], source: arguments[2],
        workspacesFile: arguments.count > 3 ? arguments[3] : nil,
        projects: arguments.count > 4 ? arguments[4] : nil)
      print("\n\(checks - failures)/\(checks) passed")
      exit(failures > 0 ? 1 : 0)
    }

    frontmatterShapes()
    validationRules()
    catalogScan()
    sourceNames()

    targetsDeduplicateThroughSymlinks()
    anInvalidSkillIsLeftLinked()
    anExportLeavesHiddenFilesBehind()
    planLinksWhatIsMissingAndNothingElse()
    relativeLinksAreJudgedByWhereTheyLand()
    sourceSpelledThroughASymlink()
    foreignEntriesAreNeverTouched()
    unavailableAndRetiredSources()
    shadowingIsPerFolder()
    scopedSkillsLeaveGlobalTargets()
    overlappingTargetIsRefused()
    seedingAdoptsExistingLinks()
    ledgerHelpers()
    exactCoverSeeding()
    repositoryLedger()
    nestedSourcesClaimBySlot()
    parentSourceClaimsNothingBelowItsSlots()
    globalAndProjectTargetsMergeAcrossTheHomeRepository()
    canonicalOfAMissingPath()
    excludeBlock()
    workspaceDecodesWithoutSkills()
    applyOnDisk()
    linkNeverReplaces()

    print("\n\(checks - failures)/\(checks) passed")
    if failures > 0 { exit(1) }
  }

  // MARK: - Fake tree

  /// Directories, files and symlinks, with symlinks resolved the way the disk
  /// resolves them: every component, the last one included.
  struct FakeFS: SkillFileSystem {
    var directories: Set<String> = ["/"]
    var files: [String: String] = [:]
    var links: [String: String] = [:]
    /// Folders that exist but cannot be listed (chmod 000, a privacy block).
    var unlistable: Set<String> = []

    static func parent(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    mutating func dir(_ path: String) {
      var current = path
      while current != "/" && !current.isEmpty {
        directories.insert(current)
        current = Self.parent(current)
      }
    }

    mutating func file(_ path: String, _ text: String) {
      dir(Self.parent(path))
      files[path] = text
    }

    mutating func link(_ path: String, to destination: String) {
      dir(Self.parent(path))
      links[path] = destination
    }

    mutating func skill(
      _ folder: String, name: String? = nil, description: String = "Does a thing."
    ) {
      let skillName = name ?? (folder as NSString).lastPathComponent
      file(
        folder + "/SKILL.md", "---\nname: \(skillName)\ndescription: \(description)\n---\nBody.\n")
    }

    func resolve(_ path: String, depth: Int = 0) -> String {
      guard depth < 16 else { return path }
      let parts = path.split(separator: "/").map(String.init)
      var current = "/"
      for (index, part) in parts.enumerated() {
        if part == "." { continue }
        if part == ".." {
          current = Self.parent(current)
          continue
        }
        let next = (current as NSString).appendingPathComponent(part)
        if let destination = links[next] {
          let landed =
            destination.hasPrefix("/")
            ? destination : (current as NSString).appendingPathComponent(destination)
          let rest = parts[(index + 1)...].joined(separator: "/")
          return resolve(
            rest.isEmpty ? landed : (landed as NSString).appendingPathComponent(rest),
            depth: depth + 1)
        }
        current = next
      }
      return current
    }

    func isDirectory(_ path: String) -> Bool { directories.contains(resolve(path)) }
    func isFile(_ path: String) -> Bool { files[resolve(path)] != nil }
    func contents(_ path: String) -> String? { files[resolve(path)] }
    func canonical(_ path: String) -> String { resolve(path) }

    func children(_ path: String) -> [String] {
      let folder = resolve(path)
      // What the real one does, and what `SkillFileSystem` documents: a folder
      // that cannot be listed answers no entries, not its true ones.
      if unlistable.contains(folder) { return [] }
      return directories.union(files.keys).union(links.keys)
        .filter { $0 != folder && Self.parent($0) == folder }
        .map { ($0 as NSString).lastPathComponent }
        .sorted()
    }

    func symlinkDestination(_ path: String) -> String? {
      let folder = resolve(Self.parent(path))
      return links[
        (folder as NSString).appendingPathComponent((path as NSString).lastPathComponent)]
    }

    func entryExists(_ path: String) -> Bool {
      symlinkDestination(path) != nil || isDirectory(path) || isFile(path)
    }

    func canList(_ path: String) -> Bool {
      isDirectory(path) && !unlistable.contains(resolve(path))
    }
  }

  // MARK: - Catalog

  static func frontmatterShapes() {
    print("frontmatter")
    let plain = SkillFrontmatter.fields("---\nname: a\ndescription: Does a.\n---\nBody")
    check("plain fields", plain?["name"] == "a" && plain?["description"] == "Does a.")

    let crlf = SkillFrontmatter.fields("\u{FEFF}---\r\nname: a\r\ndescription: Does a.\r\n---\r\n")
    check("CRLF and a BOM read the same", crlf?["name"] == "a" && crlf?["description"] == "Does a.")

    let quoted = SkillFrontmatter.fields("---\nname: a\ndescription: \"Use when: x\"\n---\n")
    check("a quoted value keeps its colon", quoted?["description"] == "Use when: x")

    let single = SkillFrontmatter.fields("---\nname: a\ndescription: 'it''s fine'\n---\n")
    check("a single-quoted value unescapes ''", single?["description"] == "it's fine")

    let folded = SkillFrontmatter.fields(
      "---\nname: a\ndescription: >\n  First line\n  second line.\nlicense: MIT\n---\n")
    check("a folded block joins its lines", folded?["description"] == "First line second line.")
    check("and the next key still parses", folded?["license"] == "MIT")

    let literal = SkillFrontmatter.fields("---\nname: a\ndescription: |\n  One\n  Two\n---\n")
    check("a literal block keeps its newlines", literal?["description"] == "One\nTwo")

    let wrapped = SkillFrontmatter.fields(
      "---\nname: a\ndescription: Starts here\n  and carries on.\n---\n")
    check(
      "a plain scalar continued on indented lines",
      wrapped?["description"] == "Starts here and carries on.")

    check("no opening fence is no frontmatter", SkillFrontmatter.fields("name: a\n") == nil)
    check("no closing fence is no frontmatter", SkillFrontmatter.fields("---\nname: a\n") == nil)
  }

  static func validationRules() {
    print("validation")
    func problems(_ folder: String, _ fields: [String: String]?) -> [String] {
      SkillCatalog.problems(folderName: folder, fields: fields)
    }
    check(
      "a valid skill has no problems",
      problems("do-x", ["name": "do-x", "description": "Does x."]).isEmpty)
    check("missing frontmatter is one problem", problems("do-x", nil).count == 1)
    check(
      "a name that differs from its folder",
      !problems("do-x", ["name": "do-y", "description": "d"]).isEmpty)
    check("uppercase is refused", !problems("Do-x", ["name": "Do-x", "description": "d"]).isEmpty)
    check(
      "a doubled hyphen is refused",
      !problems("do--x", ["name": "do--x", "description": "d"]).isEmpty)
    check(
      "a trailing hyphen is refused",
      !problems("do-x-", ["name": "do-x-", "description": "d"]).isEmpty)
    check(
      "65 characters is refused",
      !problems(
        String(repeating: "a", count: 65),
        ["name": String(repeating: "a", count: 65), "description": "d"]
      ).isEmpty)
    check("no name is refused", !problems("do-x", ["description": "d"]).isEmpty)
    check("no description is refused", !problems("do-x", ["name": "do-x"]).isEmpty)
    check(
      "1024 characters is allowed",
      problems("do-x", ["name": "do-x", "description": String(repeating: "d", count: 1024)]).isEmpty
    )
    check(
      "1024 characters has no warning",
      SkillCatalog.warnings(fields: [
        "name": "do-x", "description": String(repeating: "d", count: 1024),
      ])
      .isEmpty)
    check(
      "1025 characters is allowed, with a warning",
      problems("do-x", ["name": "do-x", "description": String(repeating: "d", count: 1025)]).isEmpty
        && SkillCatalog.warnings(
          fields: ["name": "do-x", "description": String(repeating: "d", count: 1025)]
        ).count == 1)
    check(
      "1536 characters is allowed",
      problems("do-x", ["name": "do-x", "description": String(repeating: "d", count: 1536)]).isEmpty
    )
    check(
      "1536 characters carries exactly one warning",
      SkillCatalog.warnings(
        fields: ["name": "do-x", "description": String(repeating: "d", count: 1536)]
      ).count == 1)
    check(
      "1537 characters is refused",
      !problems("do-x", ["name": "do-x", "description": String(repeating: "d", count: 1537)])
        .isEmpty)
    check(
      "1537 characters is a problem, and (my call) not also a warning — it is already refused, so a warning on top would be redundant",
      SkillCatalog.warnings(
        fields: ["name": "do-x", "description": String(repeating: "d", count: 1537)]
      ).isEmpty)
    check(
      "synced is reserved", !problems("synced", ["name": "synced", "description": "d"]).isEmpty)
    check(
      "anthropic-skills is reserved",
      !problems("anthropic-skills", ["name": "anthropic-skills", "description": "d"]).isEmpty)
  }

  static func catalogScan() {
    print("catalog")
    var fs = FakeFS()
    let global = "/Users/me/Projects/claude-skills/global"
    fs.skill(global + "/alpha")
    fs.skill(global + "/beta", name: "not-beta")
    fs.skill(global + "/gamma", description: String(repeating: "d", count: 1100))
    fs.dir(global + "/push-testflight-build-workspace/evals")
    fs.skill(global + "/.hidden")
    fs.file(global + "/README.md", "x")
    fs.skill("/Users/me/Projects/appshot/skills/app-icon")

    let collection = SkillSource(name: "global", path: global, kind: .collection)
    let single = SkillSource(
      name: "app-icon", path: "/Users/me/Projects/appshot/skills/app-icon", kind: .skill)
    let missing = SkillSource(name: "gone", path: "/Users/me/nowhere", kind: .collection)
    let retired = SkillSource(name: "old", path: global, kind: .collection, retired: true)

    let found = SkillCatalog.skills(in: collection, fs: fs) ?? []
    check(
      "a collection lists folders holding SKILL.md, sorted",
      found.map(\.name) == ["alpha", "beta", "gamma"])
    check("ids are source-qualified", found.first?.id == "global:alpha")
    check(
      "an invalid skill is listed with its problems",
      found.first(where: { $0.name == "beta" })?.isValid == false)
    check(
      "a description over 1024 but within Claude Code's 1536 is valid, with one warning",
      found.first(where: { $0.name == "gamma" })?.isValid == true
        && found.first(where: { $0.name == "gamma" })?.warnings.count == 1)
    check(
      "a skill source is one skill",
      SkillCatalog.skills(in: single, fs: fs)?.map(\.id) == ["app-icon:app-icon"])
    check("a missing source is nil, not empty", SkillCatalog.skills(in: missing, fs: fs) == nil)

    let whole = SkillCatalog.catalog([collection, single, missing, retired], fs: fs)
    check(
      "the catalog keeps source order",
      whole.skills.map(\.id) == [
        "global:alpha", "global:beta", "global:gamma", "app-icon:app-icon",
      ])
    check("a retired source contributes no skills", !whole.skills.contains { $0.source == "old" })
    check(
      "available names the sources whose folder exists",
      whole.available == ["global", "app-icon", "old"])

    check(
      "a folder holding SKILL.md is a skill source",
      SkillCatalog.kind(of: single.path, fs: fs) == .skill)
    check("any other folder is a collection", SkillCatalog.kind(of: global, fs: fs) == .collection)

    let decoded = try? JSONDecoder().decode(
      SkillSource.self, from: Data(#"{"name":"s","path":"/s","kind":"collection"}"#.utf8))
    check("a source written without retired decodes as active", decoded?.retired == false)
  }

  static func sourceNames() {
    print("source names")
    check(
      "a folder name is used as is",
      SkillCatalog.defaultSourceName(for: "/a/global", taken: []) == "global")
    check(
      "it is made valid",
      SkillCatalog.defaultSourceName(for: "/a/My Skills!", taken: []) == "my-skills")
    check(
      "a clash gets a suffix",
      SkillCatalog.defaultSourceName(for: "/b/global", taken: ["global"]) == "global-2")
    check(
      "and the next one",
      SkillCatalog.defaultSourceName(for: "/c/global", taken: ["global", "global-2"]) == "global-3")
    check(
      "nothing usable falls back",
      SkillCatalog.defaultSourceName(for: "/a/日本", taken: []) == "source")
    check(
      "every default is valid",
      SkillCatalog.isValidSourceName(SkillCatalog.defaultSourceName(for: "/a/--x--", taken: [])))
  }

  // MARK: - Plan

  static let home = "/Users/me"
  static let globalPath = "/Users/me/Projects/claude-skills/global"
  static let global = SkillSource(name: "global", path: globalPath, kind: .collection)

  /// Shared, the default Claude folder, and a second config folder whose
  /// `skills` is a symlink to the first, as on the reference machine.
  static func machine() -> FakeFS {
    var fs = FakeFS()
    fs.skill(globalPath + "/alpha")
    fs.skill(globalPath + "/beta")
    fs.dir(home + "/.agents/skills")
    fs.dir(home + "/.claude/skills")
    fs.link(home + "/.claude-skitrust/skills", to: home + "/.claude/skills")
    return fs
  }

  static let claudeRows = [
    SkillLinks.ClaudeDirectory(
      id: "claude-code", label: "Claude Code", directory: home + "/.claude"),
    SkillLinks.ClaudeDirectory(
      id: "claude-code@skitrust", label: "Claude Code (skitrust)",
      directory: home + "/.claude-skitrust"),
  ]

  /// Catalog, targets, desired links and plan in one call, as the store does.
  static func planned(
    _ fs: FakeFS, sources: [SkillSource] = [global], choices: [String: Set<String>],
    scopes: [String: [String]] = [:], resolved: [String: Set<String>] = [:],
    ledger: [String: Set<String>] = [:]
  ) -> (targets: [SkillTarget], plan: SkillLinks.Plan) {
    let catalog = SkillCatalog.catalog(sources, fs: fs)
    let keys = scopes.keys.reduce(into: Set<String>()) { $0.formUnion(resolved[$1] ?? []) }
      .union(ledger.keys.compactMap(SkillLinks.projectKey(fromTargetID:)))
    let targets = SkillLinks.combined(
      global: SkillLinks.globalTargets(home: home, claude: claudeRows, fs: fs),
      project: SkillLinks.projectTargets(keys: keys, fs: fs), fs: fs)
    let desired = SkillLinks.desired(
      skills: catalog.skills, choices: choices, scopes: scopes,
      resolved: { resolved[$0] ?? [] }, targets: targets)
    return (
      targets,
      SkillLinks.plan(
        targets: targets, desired: desired, sources: sources, available: catalog.available,
        ledger: ledger, fs: fs)
    )
  }

  /// The spec: an invalid skill produces no action. `desired` skipped it, but
  /// its existing links were still claimed and then unlinked — so a SKILL.md
  /// edited past the length limit, or missing `name:` (which Claude Code
  /// accepts), vanished from every folder on the next save, with no preview.
  static func anInvalidSkillIsLeftLinked() {
    print("invalid skills")
    var fs = machine()
    fs.skill(globalPath + "/alpha", description: String(repeating: "x", count: 2000))
    fs.link(home + "/.agents/skills/alpha", to: globalPath + "/alpha")
    let (_, plan) = planned(fs, choices: ["global:alpha": ["shared"]])
    check(
      "a link to a skill that no longer validates is not unlinked",
      !plan.actions.contains(.unlink(target: "shared", name: "alpha")))
    check(
      "and is reported as invalid",
      plan.reports["shared"]?.invalid == ["alpha"])
  }

  /// The ZIP is for uploading to claude.ai. A `.skill` source rooted at a
  /// repository makes the skill folder the repository, and `ditto` packed its
  /// `.git` and any `.env` beside SKILL.md.
  static func anExportLeavesHiddenFilesBehind() {
    print("export")
    let fm = FileManager.default
    let root = scratch()
    defer { try? fm.removeItem(atPath: root) }
    let skill = root + "/my-skill"
    try? fm.createDirectory(atPath: skill + "/scripts", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: skill + "/.git", withIntermediateDirectories: true)
    try? "---\nname: my-skill\n---\n".write(
      toFile: skill + "/SKILL.md", atomically: true, encoding: .utf8)
    try? "echo hi".write(toFile: skill + "/scripts/run.sh", atomically: true, encoding: .utf8)
    try? "TOKEN=secret".write(toFile: skill + "/.env", atomically: true, encoding: .utf8)
    try? "[core]".write(toFile: skill + "/.git/config", atomically: true, encoding: .utf8)

    let staging = URL(fileURLWithPath: root + "/staging")
    guard let staged = try? SkillExport.stage(skill, in: staging) else {
      return check("a skill folder can be staged", false)
    }
    let present = Set(
      (fm.enumerator(atPath: staged.path)?.allObjects as? [String]) ?? [])
    check("it keeps the folder's name", staged.lastPathComponent == "my-skill")
    check("SKILL.md and the scripts go", present.isSuperset(of: ["SKILL.md", "scripts/run.sh"]))
    check(
      "a .env and the .git folder do not",
      !present.contains(".env") && !present.contains { $0.hasPrefix(".git") })
  }

  static func targetsDeduplicateThroughSymlinks() {
    print("targets")
    let targets = SkillLinks.globalTargets(home: home, claude: claudeRows, fs: machine())
    check("shared plus one Claude target", targets.map(\.id) == ["shared", "claude-code"])
    check("the symlinked folder is an alias", targets.last?.aliases == ["claude-code@skitrust"])
    check("and its label names both", targets.last?.label == "Claude Code, Claude Code (skitrust)")

    var fs = machine()
    fs.link("/r/app/.agents/skills", to: "../.claude/skills")
    fs.dir("/r/app/.claude/skills")
    let project = SkillLinks.projectTargets(keys: ["/r/app"], fs: fs)
    check("a repository whose two folders are one gets one target", project.count == 1)

    let absent =
      claudeRows + [
        SkillLinks.ClaudeDirectory(
          id: "claude-code@gone", label: "Gone", directory: home + "/.claude-gone")
      ]
    check(
      "a Claude Code folder that does not exist contributes no target",
      SkillLinks.globalTargets(home: home, claude: absent, fs: machine()).map(\.id) == [
        "shared", "claude-code",
      ])
  }

  static func planLinksWhatIsMissingAndNothingElse() {
    print("plan")
    var fs = machine()
    fs.link(home + "/.claude/skills/beta", to: globalPath + "/beta")
    let (_, plan) = planned(
      fs,
      choices: [
        "global:alpha": ["claude-code@skitrust", "shared"], "global:beta": ["claude-code"],
      ])
    check(
      "a missing link is planned in each chosen target, an alias counting as its folder",
      Set(plan.actions) == [
        .link(target: "claude-code", name: "alpha", destination: globalPath + "/alpha"),
        .link(target: "shared", name: "alpha", destination: globalPath + "/alpha"),
      ])

    var moved = machine()
    moved.link(home + "/.claude/skills/alpha", to: "/Users/me/Projects/claude-skills/global/beta")
    let (_, relinked) = planned(moved, choices: ["global:alpha": ["claude-code"]])
    check(
      "a link named alpha pointing at the skill beta is not ours: no action",
      relinked.actions.isEmpty)
    check(
      "and alpha is reported as a collision",
      relinked.reports["claude-code"]?.collisions == ["alpha"])

    var alias = machine()
    alias.link(home + "/.claude/skills/my-alias", to: globalPath + "/alpha")
    let (_, aliased) = planned(alias, choices: [:])
    check("a link under another name than its folder is never unlinked", aliased.actions.isEmpty)
    check(
      "and is foreign", aliased.reports["claude-code"]?.foreign == ["my-alias"])

    var stale = machine()
    stale.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    stale.link(home + "/.claude/skills/astro-bootstrap", to: globalPath + "/astro-bootstrap")
    let (_, unlinked) = planned(stale, choices: [:])
    check(
      "a link of ours not chosen, and a dangling one, are unlinked",
      Set(unlinked.actions) == [
        .unlink(target: "claude-code", name: "alpha"),
        .unlink(target: "claude-code", name: "astro-bootstrap"),
      ])

    var workspace = machine()
    workspace.dir(globalPath + "/push-testflight-build-workspace/iteration-1")
    workspace.link(
      home + "/.claude/skills/push-testflight-build-workspace",
      to: globalPath + "/push-testflight-build-workspace")
    let (_, kept) = planned(workspace, choices: [:])
    check(
      "a link into a source that lands on a folder with no SKILL.md is left alone",
      kept.actions.isEmpty)
    check(
      "and listed as foreign",
      kept.reports["claude-code"]?.foreign == ["push-testflight-build-workspace"])

    var invalid = machine()
    invalid.skill(globalPath + "/gamma", name: "Gamma")
    let (_, skipped) = planned(invalid, choices: ["global:gamma": ["claude-code"]])
    check("an invalid skill is never linked", skipped.actions.isEmpty)
  }

  static func relativeLinksAreJudgedByWhereTheyLand() {
    print("relative links")
    var fs = machine()
    fs.link(home + "/.claude/skills/alpha", to: "../../Projects/claude-skills/global/alpha")
    fs.link(home + "/.claude/skills/theirs", to: "../../elsewhere/theirs")
    let (_, plan) = planned(fs, choices: ["global:alpha": ["claude-code"]])
    check("a relative link to the right skill needs nothing", plan.actions.isEmpty)
    check(
      "a relative link elsewhere is foreign",
      plan.reports["claude-code"]?.foreign == ["theirs"])
  }

  static func sourceSpelledThroughASymlink() {
    print("symlinked source")
    var fs = machine()
    fs.link("/Users/me/code", to: "/Users/me/Projects")
    let spelled = SkillSource(
      name: "global", path: "/Users/me/code/claude-skills/global", kind: .collection)
    fs.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    let (_, plan) = planned(fs, sources: [spelled], choices: ["global:alpha": ["claude-code"]])
    check(
      "a link by the physical spelling belongs to a source named by the other", plan.actions.isEmpty
    )
  }

  static func foreignEntriesAreNeverTouched() {
    print("foreign")
    var fs = machine()
    fs.skill(home + "/.agents/skills/alpha")
    fs.dir(home + "/.claude/skills/.trash")
    fs.dir(home + "/.claude/skills/synced/some")
    fs.link(home + "/.claude/skills/find-skills", to: home + "/.agents/skills/find-skills")
    let (_, plan) = planned(fs, choices: ["global:alpha": ["shared", "claude-code"]])
    check(
      "a real folder in the way is a collision, not an action",
      plan.actions == [
        .link(target: "claude-code", name: "alpha", destination: globalPath + "/alpha")
      ])
    check("the collision is reported", plan.reports["shared"]?.collisions == ["alpha"])
    check(
      "hidden entries are not even listed, other foreign ones are",
      plan.reports["claude-code"]?.foreign == ["find-skills", "synced"])
  }

  static func unavailableAndRetiredSources() {
    print("unavailable and retired")
    var fs = machine()
    let away = SkillSource(name: "away", path: "/Volumes/Work/skills", kind: .collection)
    let old = SkillSource(
      name: "old", path: "/Users/me/old-skills", kind: .collection, retired: true)
    fs.link(home + "/.claude/skills/offline", to: "/Volumes/Work/skills/offline")
    fs.link(home + "/.claude/skills/legacy", to: "/Users/me/old-skills/legacy")
    let (_, plan) = planned(fs, sources: [global, away, old], choices: [:])
    check(
      "a link into a missing source is left alone and reported",
      plan.reports["claude-code"]?.unavailable == ["offline"])
    check(
      "a link into a retired source is removed even though its folder is gone",
      plan.actions == [.unlink(target: "claude-code", name: "legacy")])
  }

  static func shadowingIsPerFolder() {
    print("shadowing")
    var fs = machine()
    let second = SkillSource(name: "second", path: "/Users/me/second", kind: .collection)
    fs.skill("/Users/me/second/alpha")
    let (_, plan) = planned(
      fs, sources: [global, second],
      choices: ["global:alpha": ["claude-code"], "second:alpha": ["claude-code", "shared"]])
    check(
      "the earlier source wins a folder both want",
      plan.actions.contains(
        .link(target: "claude-code", name: "alpha", destination: globalPath + "/alpha")))
    check(
      "the later one is reported as shadowed there",
      plan.reports["claude-code"]?.shadowed == ["second:alpha"])
    check(
      "and is linked where it has no rival",
      plan.actions.contains(
        .link(target: "shared", name: "alpha", destination: "/Users/me/second/alpha")))

    var reordered = machine()
    reordered.skill("/Users/me/second/alpha")
    reordered.link(home + "/.claude/skills/alpha", to: "/Users/me/second/alpha")
    let (_, precedence) = planned(
      reordered, sources: [global, second],
      choices: ["global:alpha": ["claude-code"], "second:alpha": ["claude-code"]])
    check(
      "a link of ours to a skill that lost precedence is relinked to the winner",
      precedence.actions == [
        .relink(target: "claude-code", name: "alpha", destination: globalPath + "/alpha")
      ])
  }

  static func scopedSkillsLeaveGlobalTargets() {
    print("scoped")
    var fs = machine()
    fs.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    fs.dir("/r/app/.git")
    let (_, plan) = planned(
      fs, choices: ["global:alpha": ["claude-code"]], scopes: ["app": ["global:alpha"]],
      resolved: ["app": ["/r/app"]])
    check(
      "a scoped skill is unlinked from global targets and linked into both repository folders",
      Set(plan.actions) == [
        .unlink(target: "claude-code", name: "alpha"),
        .link(
          target: SkillLinks.projectTargetID("/r/app", .claude), name: "alpha",
          destination: globalPath + "/alpha"),
        .link(
          target: SkillLinks.projectTargetID("/r/app", .agents), name: "alpha",
          destination: globalPath + "/alpha"),
      ])

    let (_, twice) = planned(
      machine(), choices: [:], scopes: ["a": ["global:alpha"], "b": ["global:alpha"]],
      resolved: ["a": ["/r/app"], "b": ["/r/app"]])
    check("two workspaces reaching one repository link it once", twice.actions.count == 2)
    check("and shadow nothing", twice.reports.values.allSatisfy { $0.shadowed.isEmpty })
  }

  static func overlappingTargetIsRefused() {
    print("overlap")
    var fs = machine()
    fs.link(home + "/.claude-work", to: globalPath)
    let rows =
      claudeRows + [
        SkillLinks.ClaudeDirectory(
          id: "claude-code@work", label: "Work", directory: home + "/.claude-work")
      ]
    fs.dir(globalPath + "/skills")
    let targets = SkillLinks.globalTargets(home: home, claude: rows, fs: fs)
    let catalog = SkillCatalog.catalog([global], fs: fs)
    let desired = SkillLinks.desired(
      skills: catalog.skills, choices: ["global:alpha": ["claude-code@work"]], scopes: [:],
      resolved: { _ in [] }, targets: targets)
    let plan = SkillLinks.plan(
      targets: targets, desired: desired, sources: [global], available: catalog.available,
      ledger: [:], fs: fs)
    check("nothing is ever written inside a source", plan.actions.isEmpty)
    check("and the target says why", plan.reports["claude-code@work"]?.refused != nil)

    check(
      "a new source inside a target is caught before it is added",
      SkillLinks.overlap(path: home + "/.agents/skills/find-skills", targets: targets, fs: fs)?.id
        == "shared")
  }

  static func seedingAdoptsExistingLinks() {
    print("seed")
    var fs = machine()
    fs.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    fs.link("/r/app/.claude/skills/beta", to: globalPath + "/beta")
    fs.link("/r/app/.claude/skills/alpha", to: globalPath + "/alpha")
    let skills = SkillCatalog.catalog([global], fs: fs).skills
    let targets = SkillLinks.globalTargets(home: home, claude: claudeRows, fs: fs)
    let seeded = SkillLinks.seed(
      skills: skills, targets: targets, workspaces: ["app"], resolved: { _ in ["/r/app"] }, fs: fs)
    check("a global link becomes a choice", seeded.choices == ["global:alpha": ["claude-code"]])
    check(
      "a repository-only link becomes a workspace scope", seeded.scopes == ["app": ["global:beta"]])
    check(
      "a skill linked both ways stays global, so seeding never unlinks it",
      seeded.scopes["app"]?.contains("global:alpha") != true)

    // Bastion made the repository's alpha link earlier, so it is in the ledger.
    let (_, plan) = planned(
      fs, choices: seeded.choices, scopes: ["app": ["global:beta"]], resolved: ["app": ["/r/app"]],
      ledger: [SkillLinks.projectTargetID("/r/app", .claude): ["alpha"]])
    check(
      "the seeded plan only adds the missing .agents half and drops the doubled global link",
      Set(plan.actions) == [
        .link(
          target: SkillLinks.projectTargetID("/r/app", .agents), name: "beta",
          destination: globalPath + "/beta"),
        .unlink(target: SkillLinks.projectTargetID("/r/app", .claude), name: "alpha"),
      ])

    let (_, fresh) = planned(
      fs, choices: seeded.choices, scopes: ["app": ["global:beta"]], resolved: ["app": ["/r/app"]])
    check(
      "with nothing in the ledger, the doubled repository link is left alone and reported",
      Set(fresh.actions) == [
        .link(
          target: SkillLinks.projectTargetID("/r/app", .agents), name: "beta",
          destination: globalPath + "/beta")
      ]
        && fresh.reports[SkillLinks.projectTargetID("/r/app", .claude)]?.unadopted == ["alpha"])
  }

  static func ledgerHelpers() {
    print("ledger")
    var fs = machine()
    let old = SkillSource(name: "old", path: "/Users/me/old", kind: .collection, retired: true)
    fs.link("/r/app/.claude/skills/alpha", to: globalPath + "/alpha")
    fs.link("/r/app/.agents/skills/alpha", to: globalPath + "/alpha")
    fs.link("/r/app/.agents/skills/theirs", to: "/elsewhere")
    fs.link(home + "/.claude/skills/legacy", to: "/Users/me/old/legacy")
    check(
      "exclude entries are the links of ours, anchored at the root",
      SkillLinks.projectExcludeEntries(
        key: "/r/app", targets: SkillLinks.projectTargets(keys: ["/r/app"], fs: fs),
        ledger: [
          SkillLinks.projectTargetID("/r/app", .claude): ["alpha"],
          SkillLinks.projectTargetID("/r/app", .agents): ["alpha"],
        ], sources: [global], fs: fs)
        == ["/.claude/skills/alpha", "/.agents/skills/alpha"])
    let targets = SkillLinks.globalTargets(home: home, claude: claudeRows, fs: fs)
    check(
      "a retired source with a link left is still linked",
      SkillLinks.retiredStillLinked(targets: targets, sources: [global, old], ledger: [:], fs: fs)
        == ["old"])
    check(
      "a retired source re-added under a new name loses to the active one",
      SkillLinks.owner(
        of: globalPath + "/alpha",
        sources: [
          SkillSource(name: "was", path: globalPath, kind: .collection, retired: true), global,
        ],
        fs: fs)?.name == "global")
  }

  /// The final review's scenario: a parent workspace over three
  /// repositories, a one-repository workspace for each, and three sources
  /// each holding a `cut-a-release` linked into its own repository.
  static func exactCoverSeeding() {
    print("exact-cover seeding")
    var fs = machine()
    let sources = ["a", "b", "c"].map {
      SkillSource(name: "p\($0)", path: "/s/p\($0)", kind: .collection)
    }
    for letter in ["a", "b", "c"] {
      fs.skill("/s/p\(letter)/cut-a-release")
      fs.dir("/r/\(letter)/.git")
      fs.link("/r/\(letter)/.claude/skills/cut-a-release", to: "/s/p\(letter)/cut-a-release")
    }
    let resolved: [String: Set<String>] = [
      "apps": ["/r/a", "/r/b", "/r/c"], "a": ["/r/a"], "b": ["/r/b"], "c": ["/r/c"],
    ]
    let skills = SkillCatalog.catalog(sources, fs: fs).skills
    let targets = SkillLinks.globalTargets(home: home, claude: claudeRows, fs: fs)
    let seeded = SkillLinks.seed(
      skills: skills, targets: targets, workspaces: ["apps", "a", "b", "c"],
      resolved: { resolved[$0] ?? [] }, fs: fs)
    check(
      "each skill is scoped to its own repository's workspace, not the parent",
      seeded.scopes == [
        "a": ["pa:cut-a-release"], "b": ["pb:cut-a-release"], "c": ["pc:cut-a-release"],
      ] && seeded.choices.isEmpty)

    let (_, plan) = planned(
      fs, sources: sources, choices: [:], scopes: seeded.scopes.mapValues { $0.sorted() },
      resolved: resolved)
    check(
      "the seeded plan has no relink and no unlink",
      plan.actions.allSatisfy { if case .link = $0 { return true } else { return false } })
    check(
      "and links only the missing .agents half, into a repository already holding that skill",
      Set(plan.actions)
        == Set(
          ["a", "b", "c"].map {
            SkillAction.link(
              target: SkillLinks.projectTargetID("/r/\($0)", .agents), name: "cut-a-release",
              destination: "/s/p\($0)/cut-a-release")
          }))

    var partial = fs
    partial.link("/r/b/.claude/skills/cut-a-release", to: "/s/pa/cut-a-release")
    let unscoped = SkillLinks.seed(
      skills: skills, targets: targets, workspaces: ["apps"],
      resolved: { resolved[$0] ?? [] }, fs: partial)
    check(
      "a workspace only some of whose repositories hold the skill does not qualify",
      unscoped.scopes.isEmpty && unscoped.choices.isEmpty)

    let tie = SkillLinks.seed(
      skills: skills.filter { $0.source == "pa" }, targets: targets, workspaces: ["z", "a", "y"],
      resolved: { ["z": ["/r/a"], "a": ["/r/a"], "y": ["/r/a", "/r/b"]][$0] ?? [] }, fs: fs)
    check("fewest repositories, then name, breaks a tie", tie.scopes == ["a": ["pa:cut-a-release"]])

    let empty = SkillLinks.seed(
      skills: skills, targets: targets, workspaces: ["none"], resolved: { _ in [] }, fs: fs)
    check("a workspace resolving to nothing never qualifies", empty.scopes.isEmpty)
  }

  static func repositoryLedger() {
    print("repository ledger")
    let claude = SkillLinks.projectTargetID("/r/app", .claude)
    let agents = SkillLinks.projectTargetID("/r/app", .agents)
    check(
      "a project target id gives back its key",
      SkillLinks.projectKey(fromTargetID: claude) == "/r/app"
        && SkillLinks.projectKey(fromTargetID: agents) == "/r/app"
        && SkillLinks.projectKey(fromTargetID: "claude-code") == nil)

    // A repository newly in view, holding a Makefile link Bastion never made.
    var fs = machine()
    fs.dir("/r/app/.git")
    fs.link("/r/app/.claude/skills/beta", to: globalPath + "/beta")
    let (_, newcomer) = planned(
      fs, choices: [:], scopes: ["app": ["global:alpha"]], resolved: ["app": ["/r/app"]])
    check(
      "an owned link to an unwanted skill, not in the ledger, gets no action",
      !newcomer.actions.contains { $0.name == "beta" })
    check("and is reported as unadopted", newcomer.reports[claude]?.unadopted == ["beta"])

    // In the ledger and no longer wanted: unlinked.
    let (_, recorded) = planned(
      fs, choices: [:], scopes: ["app": ["global:alpha"]], resolved: ["app": ["/r/app"]],
      ledger: [claude: ["beta"]])
    check(
      "a ledger name no longer wanted is unlinked",
      recorded.actions.contains(.unlink(target: claude, name: "beta")))

    // A non-ledger link of ours at a wanted name, pointing at another skill:
    // the same name from another source, as `cut-a-release` is.
    var wrong = machine()
    let second = SkillSource(name: "second", path: "/Users/me/second", kind: .collection)
    wrong.skill("/Users/me/second/alpha")
    wrong.link("/r/app/.claude/skills/alpha", to: "/Users/me/second/alpha")
    let (_, collided) = planned(
      wrong, sources: [global, second], choices: [:], scopes: ["app": ["global:alpha"]],
      resolved: ["app": ["/r/app"]])
    check(
      "a non-ledger link of ours at a wanted name is a collision, not a relink",
      !collided.actions.contains { $0.target == claude }
        && collided.reports[claude]?.collisions == ["alpha"])
    let (_, owned) = planned(
      wrong, sources: [global, second], choices: [:], scopes: ["app": ["global:alpha"]],
      resolved: ["app": ["/r/app"]], ledger: [claude: ["alpha"]])
    check(
      "the same link in the ledger is relinked",
      owned.actions.contains(
        .relink(target: claude, name: "alpha", destination: globalPath + "/alpha")))

    // The helper, after an apply simulated on the fake tree.
    var after = machine()
    after.dir("/r/app/.git")
    after.skill(globalPath + "/gamma")
    after.link("/r/app/.claude/skills/alpha", to: globalPath + "/alpha")  // wanted, adopted
    after.link("/r/app/.agents/skills/alpha", to: globalPath + "/alpha")  // linked this pass
    after.link("/r/app/.claude/skills/beta", to: globalPath + "/beta")  // Makefile's, unwanted
    after.link("/r/app/.claude/skills/gamma", to: globalPath + "/gamma")  // recorded, kept
    let catalog = SkillCatalog.catalog([global], fs: after)
    let targets = SkillLinks.projectTargets(keys: ["/r/app"], fs: after)
    let desired = SkillLinks.desired(
      skills: catalog.skills, choices: [:], scopes: ["app": ["global:alpha"]],
      resolved: { _ in ["/r/app"] }, targets: targets)
    let next = SkillLinks.nextLedger(
      targets: targets, desired: desired, ledger: [claude: ["gamma", "vanished"]],
      sources: [global], fs: after)
    check(
      "the next ledger keeps recorded names still linked, adopts wanted ones, and adds new links",
      next == [claude: ["alpha", "gamma"], agents: ["alpha"]])
    check(
      "a name in no ledger and not wanted stays out", next[claude]?.contains("beta") == false)
    var emptied = after
    emptied.dir("/r/empty/.claude/skills")
    check(
      "a folder left with nothing has no entry",
      SkillLinks.nextLedger(
        targets: SkillLinks.projectTargets(keys: ["/r/empty"], fs: emptied), desired: desired,
        ledger: [SkillLinks.projectTargetID("/r/empty", .claude): ["x"]], sources: [global],
        fs: emptied
      ).isEmpty)

    // A folder that cannot be listed says nothing about what is in it.
    let gone = SkillLinks.projectTargetID("/Volumes/Work/repo", .claude)
    check(
      "a missing folder keeps its recorded names",
      SkillLinks.nextLedger(
        targets: SkillLinks.projectTargets(keys: ["/Volumes/Work/repo"], fs: after),
        desired: desired, ledger: [gone: ["alpha"]], sources: [global], fs: after)
        == [gone: ["alpha"]])
    var locked = after
    locked.unlistable.insert("/r/app/.claude/skills")
    check(
      "an unlistable folder keeps its recorded names unchanged, and adopts nothing new",
      SkillLinks.nextLedger(
        targets: targets, desired: desired, ledger: [claude: ["gamma", "vanished"]],
        sources: [global], fs: locked
      ) == [claude: ["gamma", "vanished"], agents: ["alpha"]])

    check(
      "exclude entries list only ledger names",
      SkillLinks.projectExcludeEntries(
        key: "/r/app", targets: targets, ledger: [claude: ["gamma"]], sources: [global],
        fs: after)
        == ["/.claude/skills/gamma"])

    // `.claude/skills -> ../.agents/skills`: one target, the `.claude` row
    // primary, and the ledger keyed by it. git sees the link through
    // `.agents/skills`, so the line must name that folder too.
    var merged = machine()
    merged.dir("/r/app/.git")
    merged.dir("/r/app/.agents/skills")
    merged.link("/r/app/.claude/skills", to: "../.agents/skills")
    merged.link("/r/app/.agents/skills/alpha", to: globalPath + "/alpha")
    let one = SkillLinks.projectTargets(keys: ["/r/app"], fs: merged)
    check(
      "a .claude folder linked to .agents is one target, .claude primary",
      one.map(\.id) == [claude] && one.first?.aliases == [agents])
    check(
      "and the exclude block names the link under both folders",
      SkillLinks.projectExcludeEntries(
        key: "/r/app", targets: one, ledger: [claude: ["alpha"]], sources: [global], fs: merged)
        == ["/.claude/skills/alpha", "/.agents/skills/alpha"])

    // A home-folder repository: both of its folders are global targets, so
    // it has no ledger, and every link those targets claim is Bastion's.
    var homeRepo = machine()
    homeRepo.dir(home + "/.git")
    homeRepo.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    homeRepo.link(home + "/.claude/skills/theirs", to: "/elsewhere/theirs")
    let homeTargets = SkillLinks.combined(
      global: SkillLinks.globalTargets(home: home, claude: claudeRows, fs: homeRepo),
      project: SkillLinks.projectTargets(keys: [home], fs: homeRepo), fs: homeRepo)
    check(
      "a repository merged into global targets is still a repository to exclude in",
      SkillLinks.repositoryKeys(homeTargets) == [home]
        && homeTargets.allSatisfy { $0.projectKey == nil })
    check(
      "and its exclude lines are the links the global targets claim",
      SkillLinks.projectExcludeEntries(
        key: home, targets: homeTargets, ledger: [:], sources: [global], fs: homeRepo)
        == ["/.claude/skills/alpha"])

    var retired = machine()
    let old = SkillSource(name: "old", path: "/Users/me/old", kind: .collection, retired: true)
    retired.link("/r/app/.claude/skills/legacy", to: "/Users/me/old/legacy")
    let repository = SkillLinks.projectTargets(keys: ["/r/app"], fs: retired)
    check(
      "a repository link into a retired source outside the ledger keeps nothing alive",
      SkillLinks.retiredStillLinked(
        targets: repository, sources: [global, old], ledger: [:], fs: retired
      ).isEmpty)
    check(
      "the same link in the ledger does",
      SkillLinks.retiredStillLinked(
        targets: repository, sources: [global, old], ledger: [claude: ["legacy"]], fs: retired)
        == ["old"])
    // The repository folder is unmounted or unreadable: its links cannot be
    // seen, so they cannot be counted as gone. Dropping the retired source
    // here meant that when the folder came back, its links pointed into a
    // source nobody remembered, and their exclude lines were removed.
    var unreadable = retired
    unreadable.unlistable.insert("/r/app/.claude/skills")
    check(
      "a folder that cannot be listed keeps the retired sources it may still link",
      SkillLinks.retiredStillLinked(
        targets: repository, sources: [global, old], ledger: [claude: ["legacy"]],
        fs: unreadable) == ["old"])
    let (_, leftAlone) = planned(
      retired, sources: [global, old], choices: [:], scopes: ["app": ["global:alpha"]],
      resolved: ["app": ["/r/app"]])
    check(
      "and it is left alone, not unlinked",
      !leftAlone.actions.contains(.unlink(target: claude, name: "legacy"))
        && leftAlone.reports[claude]?.unadopted == ["legacy"])
  }

  static func nestedSourcesClaimBySlot() {
    print("nested sources")
    var fs = machine()
    fs.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    let parent = SkillSource(
      name: "claude-skills", path: "/Users/me/Projects/claude-skills", kind: .collection)
    check(
      "a link into the inner source is owned by it, even with the outer one listed first",
      SkillLinks.owner(of: globalPath + "/alpha", sources: [parent, global], fs: fs)?.name
        == "global")
    let (_, plan) = planned(fs, sources: [parent, global], choices: [:])
    check(
      "so an unwanted link there is unlinked, not left as foreign",
      plan.actions == [.unlink(target: "claude-code", name: "alpha")])
  }

  static func parentSourceClaimsNothingBelowItsSlots() {
    print("parent source")
    var fs = machine()
    fs.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    let oneLevelUp = SkillSource(
      name: "claude-skills", path: "/Users/me/Projects/claude-skills", kind: .collection)
    let (_, plan) = planned(fs, sources: [oneLevelUp], choices: [:])
    check(
      "a collection one level above the real one plans nothing",
      plan.actions.isEmpty)
    check(
      "and the working link beneath it is foreign, not claimed",
      plan.reports["claude-code"]?.foreign == ["alpha"])

    var single = machine()
    single.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    let skillAboveIt = SkillSource(name: "global-as-skill", path: globalPath, kind: .skill)
    let (_, singlePlan) = planned(single, sources: [skillAboveIt], choices: [:])
    check(
      "a .skill source whose path is a parent of the linked skill plans nothing",
      singlePlan.actions.isEmpty)
    check(
      "and the link beneath it is foreign there too",
      singlePlan.reports["claude-code"]?.foreign == ["alpha"])
  }

  static func globalAndProjectTargetsMergeAcrossTheHomeRepository() {
    print("combined targets")
    var fs = machine()
    fs.dir(home + "/.git")
    fs.link(home + "/.claude/skills/alpha", to: globalPath + "/alpha")
    let (targets, plan) = planned(
      fs, choices: ["global:alpha": ["claude-code"]], scopes: ["home": ["global:beta"]],
      resolved: ["home": [home]])
    check(
      "the project rows for the home repository are not targets of their own",
      !targets.map(\.id).contains(SkillLinks.projectTargetID(home, .claude))
        && !targets.map(\.id).contains(SkillLinks.projectTargetID(home, .agents)))
    check(
      "alpha, already linked and still chosen, is not unlinked",
      !plan.actions.contains(.unlink(target: "claude-code", name: "alpha")))
    check(
      "beta reaches claude-code and shared once each, not twice for either folder",
      Set(plan.actions) == [
        .link(target: "claude-code", name: "beta", destination: globalPath + "/beta"),
        .link(target: "shared", name: "beta", destination: globalPath + "/beta"),
      ] && plan.actions.count == 2)
  }

  // MARK: - Local filesystem

  /// On disk, under a scratch folder — never a real skills folder. Proves
  /// `LocalSkillFileSystem.canonical` resolves a symlinked ancestor even when
  /// the path past it does not exist, which the fake filesystem's `resolve`
  /// already does for free and so could never have caught missing on the
  /// real one.
  static func canonicalOfAMissingPath() {
    print("canonical of a missing path")
    let root = (NSTemporaryDirectory() as NSString).appendingPathComponent(
      "skills-check-\(UUID().uuidString)")
    let real = (root as NSString).appendingPathComponent("real")
    let alias = (root as NSString).appendingPathComponent("alias")
    try? FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
    try? FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: "real")
    defer { try? FileManager.default.removeItem(atPath: root) }

    let fs = LocalSkillFileSystem()
    check(
      "a missing path spelled through a symlinked ancestor canonicalises through it",
      fs.canonical(alias + "/missing/x") == fs.canonical(real) + "/missing/x")
  }

  // MARK: - Real

  /// Read-only: builds the targets the app would build on this Mac, seeds a
  /// plan for the real sources against the real workspaces with an empty
  /// ledger — adding them to a fresh Bastion — and asserts the plan changes
  /// nothing but broken links and the missing `.agents/skills` half of a
  /// repository link that already exists.
  static func realPlanChangesOnlyBrokenLinks(
    home: String, source path: String, workspacesFile: String?, projects: String?
  ) {
    print("real: \(path)")
    let fs = LocalSkillFileSystem()
    guard fs.isDirectory(path) else {
      print("  skip: \(path) is not a folder")
      return
    }
    var rows = [
      SkillLinks.ClaudeDirectory(
        id: "claude-code", label: "Claude Code", directory: home + "/.claude")
    ]
    for name in fs.children(home).sorted() where name.hasPrefix(".claude-") {
      let directory = (home as NSString).appendingPathComponent(name)
      if fs.isDirectory(directory) {
        rows.append(
          .init(id: "claude-code@" + name.dropFirst(8), label: name, directory: directory))
      }
    }
    let global = SkillLinks.globalTargets(home: home, claude: rows, fs: fs)

    var paths = [path]
    if let projects, fs.isDirectory(projects) {
      paths += fs.children(projects).sorted().filter { !$0.hasPrefix(".") }
        .map { (projects as NSString).appendingPathComponent($0) }.filter(fs.isDirectory)
    }
    var sources: [SkillSource] = []
    for folder in paths {
      sources.append(
        SkillSource(
          name: SkillCatalog.defaultSourceName(for: folder, taken: Set(sources.map(\.name))),
          path: folder, kind: SkillCatalog.kind(of: folder, fs: fs)))
      print("  source \(sources.last!.name): \(folder)")
    }

    var workspaces: [Workspace] = []
    if let workspacesFile {
      if let data = FileManager.default.contents(atPath: workspacesFile),
        let rows = try? JSONDecoder().decode([Workspace].self, from: data)
      {
        workspaces = rows.sorted { $0.name < $1.name }
      } else {
        print("  skip workspaces: \(workspacesFile) is absent or unreadable")
      }
    }
    var resolved: [String: Set<String>] = [:]
    for workspace in workspaces {
      resolved[workspace.name] = WorkspaceScope.projectKeys(for: workspace.folders, fs: fs)
      print("  workspace \(workspace.name): \(resolved[workspace.name]!.count) repositories")
    }
    // Every repository a workspace reaches, not only those of workspaces
    // with skills: each is a repository that can come into view, and none
    // may be changed by a link Bastion did not make.
    let keys = resolved.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    let targets = SkillLinks.combined(
      global: global, project: SkillLinks.projectTargets(keys: keys, fs: fs), fs: fs)

    let catalog = SkillCatalog.catalog(sources, fs: fs)
    let seeded = SkillLinks.seed(
      skills: catalog.skills, targets: global, workspaces: workspaces.map(\.name),
      resolved: { resolved[$0] ?? [] }, fs: fs)
    for (workspace, ids) in seeded.scopes.sorted(by: { $0.key < $1.key }) {
      print("  seed \(workspace): \(ids.sorted().joined(separator: ", "))")
    }
    let scopes = seeded.scopes.mapValues { $0.sorted() }
    let desired = SkillLinks.desired(
      skills: catalog.skills, choices: seeded.choices, scopes: scopes,
      resolved: { resolved[$0] ?? [] }, targets: targets)
    let plan = SkillLinks.plan(
      targets: targets, desired: desired, sources: sources, available: catalog.available,
      ledger: [:], fs: fs)
    for action in plan.actions { print("  plan \(action.summary)") }
    for target in targets {
      let report = plan.reports[target.id] ?? SkillLinks.TargetReport()
      if !report.unadopted.isEmpty {
        print("  left alone in \(target.id): \(report.unadopted.joined(separator: ", "))")
      }
      if !report.collisions.isEmpty {
        print("  collision in \(target.id): \(report.collisions.joined(separator: ", "))")
      }
    }

    let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    let allowed = plan.actions.allSatisfy { action in
      switch action {
      case .unlink(let target, let name):
        guard let folder = byID[target]?.path,
          let raw = fs.symlinkDestination((folder as NSString).appendingPathComponent(name))
        else { return false }
        return !fs.entryExists(SkillLinks.absolute(raw, in: fs.canonical(folder)))
      case .link(let target, let name, let destination):
        guard let key = byID[target]?.projectKey,
          target == SkillLinks.projectTargetID(key, .agents)
        else { return false }
        let claude = (key as NSString).appendingPathComponent(".claude/skills")
        guard let raw = fs.symlinkDestination((claude as NSString).appendingPathComponent(name))
        else { return false }
        return fs.canonical(SkillLinks.absolute(raw, in: fs.canonical(claude)))
          == fs.canonical(destination)
      case .relink:
        return false
      }
    }
    check(
      "the seeded plan changes nothing but broken links and missing .agents halves", allowed)
  }

  static func excludeBlock() {
    print("info/exclude")
    let user = "# git ls-files --others --exclude-from=.git/info/exclude\n*.local\n"
    let added = SkillExclude.updated(user, entries: ["/.claude/skills/a", "/.agents/skills/a"])
    check("the user's lines come first, byte for byte", added.hasPrefix(user))
    check(
      "the block holds exactly the entries",
      added == user + SkillExclude.begin + "\n/.claude/skills/a\n/.agents/skills/a\n"
        + SkillExclude.end + "\n")
    check(
      "updating is idempotent",
      SkillExclude.updated(added, entries: ["/.claude/skills/a", "/.agents/skills/a"]) == added)

    let replaced = SkillExclude.updated(added + "after\n", entries: ["/.claude/skills/b"])
    check(
      "a changed set replaces the block and keeps lines after it",
      replaced.contains("/.claude/skills/b\n") && !replaced.contains("/skills/a\n")
        && replaced.contains("after\n"))

    check("no entries removes the block", SkillExclude.updated(added, entries: []) == user)
    check(
      "no entries and no block changes nothing", SkillExclude.updated(user, entries: []) == user)
    check(
      "a file without a final newline gets one before the block",
      SkillExclude.updated("*.local", entries: ["/x"]).hasPrefix("*.local\n" + SkillExclude.begin))
    check(
      "an empty file gets only the block",
      SkillExclude.updated("", entries: ["/x"]) == SkillExclude.begin + "\n/x\n" + SkillExclude.end
        + "\n")

    let orphan = "*.local\n" + SkillExclude.begin + "\nmine\n"
    let once = SkillExclude.updated(orphan, entries: ["/x"])
    let twice = SkillExclude.updated(once, entries: ["/y"])
    check("a user line after an orphaned begin survives an update", once.contains("\nmine\n"))
    check(
      "and a second one, with exactly one block left",
      twice.contains("\nmine\n") && twice.components(separatedBy: SkillExclude.begin).count == 2
        && twice.components(separatedBy: SkillExclude.end).count == 2
        && twice.contains("\n/y\n") && !twice.contains("\n/x\n"))
    let orphanThenBlock = SkillExclude.updated(
      SkillExclude.begin + "\nmine\n" + SkillExclude.begin + "\n/x\n" + SkillExclude.end + "\n",
      entries: [])
    check(
      "an end is matched only up to the next begin", orphanThenBlock == "mine\n")

    var fs = FakeFS()
    fs.dir("/r/app/.git/info")
    fs.file("/r/sub/.git", "gitdir: ../app/.git/modules/sub")
    fs.dir("/r/plain")
    check(
      "a repository's exclude file",
      SkillExclude.path(forKey: "/r/app", fs: fs) == "/r/app/.git/info/exclude")
    check("none for a .git file", SkillExclude.path(forKey: "/r/sub", fs: fs) == nil)
    check("none outside git", SkillExclude.path(forKey: "/r/plain", fs: fs) == nil)
  }

  static func workspaceDecodesWithoutSkills() {
    print("workspace model")
    let written124 = #"[{"folders":["/r"],"name":"rgis","profiles":["rgis/ovh"]}]"#
    let rows = try? JSONDecoder().decode([Workspace].self, from: Data(written124.utf8))
    check("a 1.24 file decodes", rows?.count == 1)
    check("with its profiles intact", rows?.first?.profiles == ["rgis/ovh"])
    check("and no skills", rows?.first?.skills == [])

    let encoded = try? JSONEncoder().encode(
      Workspace(name: "a", folders: [], profiles: [], skills: ["global:x"]))
    let back = encoded.flatMap { try? JSONDecoder().decode(Workspace.self, from: $0) }
    check("skills round-trip", back?.skills == ["global:x"])
    check(
      "the three-argument init still exists",
      Workspace(name: "a", folders: [], profiles: []).skills.isEmpty)
  }

  static func scratch() -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(
      "skills-check-" + UUID().uuidString)
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
  }

  static func applyOnDisk() {
    print("apply")
    let root = scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let manager = FileManager.default
    let skillA = root + "/source/a"
    let skillB = root + "/source/b"
    try? manager.createDirectory(atPath: skillA, withIntermediateDirectories: true)
    try? manager.createDirectory(atPath: skillB, withIntermediateDirectories: true)
    let target = SkillTarget(
      id: "t", aliases: [], label: "T", path: root + "/target/skills", projectKey: nil)

    var failures = SkillLinker.apply(
      [.link(target: "t", name: "a", destination: skillA)], targets: [target])
    check(
      "link creates the folder and the link",
      failures.isEmpty
        && (try? manager.destinationOfSymbolicLink(atPath: target.path + "/a")) == skillA)

    failures = SkillLinker.apply(
      [.relink(target: "t", name: "a", destination: skillB)], targets: [target])
    check(
      "relink repoints it",
      failures.isEmpty
        && (try? manager.destinationOfSymbolicLink(atPath: target.path + "/a")) == skillB)
    let leftovers = (try? manager.contentsOfDirectory(atPath: target.path)) ?? []
    check("and leaves no temporary entry behind", leftovers == ["a"])

    failures = SkillLinker.apply([.unlink(target: "t", name: "a")], targets: [target])
    check(
      "unlink removes the link",
      failures.isEmpty && !LocalSkillFileSystem().entryExists(target.path + "/a"))
    check("and never what it pointed at", manager.fileExists(atPath: skillB))

    try? manager.createDirectory(atPath: target.path + "/real", withIntermediateDirectories: true)
    try? "content".write(
      toFile: target.path + "/real/file", atomically: true, encoding: .utf8)
    failures = SkillLinker.apply([.unlink(target: "t", name: "real")], targets: [target])
    check(
      "unlink refuses a real folder",
      failures.count == 1 && manager.fileExists(atPath: target.path + "/real"))
    check(
      "and its contents survive",
      (try? String(contentsOfFile: target.path + "/real/file", encoding: .utf8)) == "content")
    let contentsAfter = (try? manager.contentsOfDirectory(atPath: target.path)) ?? []
    check("and no .bastion-* entry is left", !contentsAfter.contains { $0.hasPrefix(".bastion-") })

    try? manager.createDirectory(
      atPath: target.path + "/folder2", withIntermediateDirectories: true)
    try? "data".write(
      toFile: target.path + "/folder2/data", atomically: true, encoding: .utf8)
    failures = SkillLinker.apply(
      [.relink(target: "t", name: "folder2", destination: skillB)], targets: [target])
    check(
      "relink refuses a real folder",
      failures.count == 1 && manager.fileExists(atPath: target.path + "/folder2"))
    check(
      "and its contents survive",
      (try? String(contentsOfFile: target.path + "/folder2/data", encoding: .utf8)) == "data")
    let contentsAfter2 = (try? manager.contentsOfDirectory(atPath: target.path)) ?? []
    check("and no .bastion-* entry is left", !contentsAfter2.contains { $0.hasPrefix(".bastion-") })

    try? "regular".write(
      toFile: target.path + "/file", atomically: true, encoding: .utf8)
    failures = SkillLinker.apply([.unlink(target: "t", name: "file")], targets: [target])
    check(
      "unlink refuses a regular file",
      failures.count == 1 && manager.fileExists(atPath: target.path + "/file"))
    check(
      "and it is untouched",
      (try? String(contentsOfFile: target.path + "/file", encoding: .utf8)) == "regular")
    let contentsAfter3 = (try? manager.contentsOfDirectory(atPath: target.path)) ?? []
    check("and no .bastion-* entry is left", !contentsAfter3.contains { $0.hasPrefix(".bastion-") })

    failures = SkillLinker.apply(
      [.link(target: "unknown", name: "b", destination: skillA)], targets: [target])
    check("an action for an unknown target fails", failures.count == 1)

    let fs = LocalSkillFileSystem()
    try? manager.createDirectory(
      atPath: root + "/repo/.git/info", withIntermediateDirectories: true)
    try? "*.local\n".write(
      toFile: root + "/repo/.git/info/exclude", atomically: true, encoding: .utf8)
    check(
      "writing the exclude block succeeds",
      SkillLinker.writeExclude(key: root + "/repo", entries: ["/.claude/skills/a"], fs: fs) == nil)
    let written =
      (try? String(contentsOfFile: root + "/repo/.git/info/exclude", encoding: .utf8)) ?? ""
    check(
      "and keeps the user's line",
      written.hasPrefix("*.local\n") && written.contains("/.claude/skills/a"))
    _ = SkillLinker.writeExclude(key: root + "/repo", entries: [], fs: fs)
    check(
      "clearing it restores the file",
      (try? String(contentsOfFile: root + "/repo/.git/info/exclude", encoding: .utf8))
        == "*.local\n")

    try? manager.createDirectory(
      atPath: root + "/latin/.git/info", withIntermediateDirectories: true)
    let latin = Data([0x23, 0x20, 0xE9, 0x74, 0xE9, 0x0A])  // "# été" in Latin-1
    try? latin.write(to: URL(fileURLWithPath: root + "/latin/.git/info/exclude"))
    check(
      "an exclude file that is not UTF-8 is a failure",
      SkillLinker.writeExclude(key: root + "/latin", entries: ["/x"], fs: fs) != nil)
    check(
      "and is left byte for byte",
      (try? Data(contentsOf: URL(fileURLWithPath: root + "/latin/.git/info/exclude"))) == latin)

    try? manager.createDirectory(atPath: root + "/fresh/.git", withIntermediateDirectories: true)
    check(
      "a repository with no info folder gets one",
      SkillLinker.writeExclude(key: root + "/fresh", entries: ["/x"], fs: fs) == nil
        && manager.fileExists(atPath: root + "/fresh/.git/info/exclude"))

    // An exclude file kept in dotfiles and linked in. The atomic write
    // replaced the link with a regular file, cutting it off from the file the
    // user maintains.
    try? manager.createDirectory(
      atPath: root + "/linked/.git/info", withIntermediateDirectories: true)
    try? manager.createDirectory(atPath: root + "/dotfiles", withIntermediateDirectories: true)
    try? "*.swp\n".write(toFile: root + "/dotfiles/exclude", atomically: true, encoding: .utf8)
    try? manager.createSymbolicLink(
      atPath: root + "/linked/.git/info/exclude", withDestinationPath: root + "/dotfiles/exclude")
    _ = SkillLinker.writeExclude(key: root + "/linked", entries: ["/y"], fs: fs)
    // A submodule: `.git` is a file naming the superproject's
    // `.git/modules/<name>`, and that is where git reads its exclude from.
    try? manager.createDirectory(
      atPath: root + "/super/.git/modules/sub", withIntermediateDirectories: true)
    try? manager.createDirectory(atPath: root + "/super/sub", withIntermediateDirectories: true)
    try? "gitdir: ../.git/modules/sub\n".write(
      toFile: root + "/super/sub/.git", atomically: true, encoding: .utf8)
    check(
      "a submodule's exclude is the one in the superproject's modules folder",
      SkillLinker.writeExclude(key: root + "/super/sub", entries: ["/s"], fs: fs) == nil
        && ((try? String(
          contentsOfFile: root + "/super/.git/modules/sub/info/exclude", encoding: .utf8)) ?? "")
          .contains("/s")
    )

    // A worktree of a bare repository: its gitdir carries a `commondir`, and
    // git reads info/exclude from the common directory, not the worktree's.
    try? manager.createDirectory(
      atPath: root + "/proj.git/worktrees/x", withIntermediateDirectories: true)
    try? "../..\n".write(
      toFile: root + "/proj.git/worktrees/x/commondir", atomically: true, encoding: .utf8)
    try? manager.createDirectory(atPath: root + "/x", withIntermediateDirectories: true)
    try? "gitdir: \(root)/proj.git/worktrees/x\n".write(
      toFile: root + "/x/.git", atomically: true, encoding: .utf8)
    check(
      "a worktree's exclude is the common directory's",
      SkillLinker.writeExclude(key: root + "/x", entries: ["/w"], fs: fs) == nil
        && ((try? String(contentsOfFile: root + "/proj.git/info/exclude", encoding: .utf8))
          ?? "").contains("/w")
    )

    check(
      "a linked exclude file is written through, and stays a link",
      (try? manager.destinationOfSymbolicLink(atPath: root + "/linked/.git/info/exclude")) != nil
        && ((try? String(contentsOfFile: root + "/dotfiles/exclude", encoding: .utf8)) ?? "")
          .contains("/y")
    )
  }

  static func linkNeverReplaces() {
    print("race")
    let root = scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let target = SkillTarget(
      id: "t", aliases: [], label: "T", path: root + "/skills", projectKey: nil)
    try? FileManager.default.createDirectory(
      atPath: target.path + "/a", withIntermediateDirectories: true)
    try? "mine".write(toFile: target.path + "/a/SKILL.md", atomically: true, encoding: .utf8)
    let failures = SkillLinker.apply(
      [.link(target: "t", name: "a", destination: "/nowhere")], targets: [target])
    check("a link onto something that appeared since the plan fails", failures.count == 1)
    check(
      "and the thing is untouched",
      (try? String(contentsOfFile: target.path + "/a/SKILL.md", encoding: .utf8)) == "mine")
  }
}
