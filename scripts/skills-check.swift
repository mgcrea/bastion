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
    if arguments.first == "--real", arguments.count == 3 {
      realPlanChangesOnlyBrokenLinks(home: arguments[1], source: arguments[2])
      print("\n\(checks - failures)/\(checks) passed")
      exit(failures > 0 ? 1 : 0)
    }

    frontmatterShapes()
    validationRules()
    catalogScan()
    sourceNames()

    targetsDeduplicateThroughSymlinks()
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
    parentSourceClaimsNothingBelowItsSlots()
    globalAndProjectTargetsMergeAcrossTheHomeRepository()
    canonicalOfAMissingPath()

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
    scopes: [String: [String]] = [:], resolved: [String: Set<String>] = [:]
  ) -> (targets: [SkillTarget], plan: SkillLinks.Plan) {
    let catalog = SkillCatalog.catalog(sources, fs: fs)
    let keys = scopes.keys.reduce(into: Set<String>()) { $0.formUnion(resolved[$1] ?? []) }
    let targets = SkillLinks.combined(
      global: SkillLinks.globalTargets(home: home, claude: claudeRows, fs: fs),
      project: SkillLinks.projectTargets(keys: keys, fs: fs), fs: fs)
    let desired = SkillLinks.desired(
      skills: catalog.skills, choices: choices, scopes: scopes,
      resolved: { resolved[$0] ?? [] }, targets: targets)
    return (
      targets,
      SkillLinks.plan(
        targets: targets, desired: desired, sources: sources, available: catalog.available, fs: fs)
    )
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
      "a link of ours pointing at the wrong skill is relinked",
      relinked.actions == [
        .relink(target: "claude-code", name: "alpha", destination: globalPath + "/alpha")
      ])

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
      targets: targets, desired: desired, sources: [global], available: catalog.available, fs: fs)
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

    let (_, plan) = planned(
      fs, choices: seeded.choices, scopes: ["app": ["global:beta"]], resolved: ["app": ["/r/app"]])
    check(
      "the seeded plan only adds the missing .agents half and drops the doubled global link",
      Set(plan.actions) == [
        .link(
          target: SkillLinks.projectTargetID("/r/app", .agents), name: "beta",
          destination: globalPath + "/beta"),
        .unlink(target: SkillLinks.projectTargetID("/r/app", .claude), name: "alpha"),
      ])
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
      SkillLinks.projectExcludeEntries(key: "/r/app", sources: [global], fs: fs)
        == ["/.claude/skills/alpha", "/.agents/skills/alpha"])
    let targets = SkillLinks.globalTargets(home: home, claude: claudeRows, fs: fs)
    check(
      "a retired source with a link left is still linked",
      SkillLinks.retiredStillLinked(targets: targets, sources: [global, old], fs: fs) == ["old"])
    check(
      "a retired source re-added under a new name loses to the active one",
      SkillLinks.owner(
        of: globalPath + "/alpha",
        sources: [
          SkillSource(name: "was", path: globalPath, kind: .collection, retired: true), global,
        ],
        fs: fs)?.name == "global")
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
  /// plan for one real source, and asserts it changes nothing but broken links.
  static func realPlanChangesOnlyBrokenLinks(home: String, source path: String) {
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
    let targets = SkillLinks.globalTargets(home: home, claude: rows, fs: fs)
    let source = SkillSource(
      name: SkillCatalog.defaultSourceName(for: path, taken: []), path: path,
      kind: SkillCatalog.kind(of: path, fs: fs))
    let catalog = SkillCatalog.catalog([source], fs: fs)
    let seeded = SkillLinks.seed(
      skills: catalog.skills, targets: targets, workspaces: [], resolved: { _ in [] }, fs: fs)
    let desired = SkillLinks.desired(
      skills: catalog.skills, choices: seeded.choices, scopes: [:], resolved: { _ in [] },
      targets: targets)
    let plan = SkillLinks.plan(
      targets: targets, desired: desired, sources: [source], available: catalog.available, fs: fs)
    for action in plan.actions { print("  plan \(action.summary)") }
    let byID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
    let brokenOnly = plan.actions.allSatisfy { action in
      guard case .unlink(let target, let name) = action, let folder = byID[target]?.path,
        let raw = fs.symlinkDestination((folder as NSString).appendingPathComponent(name))
      else { return false }
      return !fs.entryExists(SkillLinks.absolute(raw, in: fs.canonical(folder)))
    }
    check("the seeded plan changes nothing but broken links", brokenOnly)
  }
}
