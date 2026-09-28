import Foundation

/// A folder skills are linked into.
///
/// `aliases` are the other ids that resolve to the same folder: on the
/// reference machine `~/.claude-skitrust/skills` is a symlink to
/// `~/.claude/skills`, and two targets over one folder would fight over it.
nonisolated struct SkillTarget: Equatable, Identifiable {
  let id: String
  var aliases: [String]
  var label: String
  let path: String
  /// The repository this folder belongs to, or nil for a global target.
  let projectKey: String?
}

nonisolated enum SkillAction: Equatable, Hashable {
  case link(target: String, name: String, destination: String)
  case relink(target: String, name: String, destination: String)
  case unlink(target: String, name: String)

  var target: String {
    switch self {
    case .link(let target, _, _), .relink(let target, _, _), .unlink(let target, _): target
    }
  }

  var name: String {
    switch self {
    case .link(_, let name, _), .relink(_, let name, _), .unlink(_, let name): name
    }
  }

  var summary: String {
    switch self {
    case .link(let target, let name, let destination): "link \(target)/\(name) -> \(destination)"
    case .relink(let target, let name, let destination):
      "relink \(target)/\(name) -> \(destination)"
    case .unlink(let target, let name): "unlink \(target)/\(name)"
    }
  }
}

/// Which links should exist, which do, and what to do about the difference.
///
/// Pure over `SkillFileSystem`, as `WorkspaceScope` is over its protocol, so
/// `make skills-check` drives every case from a fake tree. Ownership is "a
/// symlink that points into a source", with no ledger of links, for the reason
/// `isOurs` is the ledger in `ClientWiringMerge`: a record of what was written
/// is one more thing that can disagree with the disk.
nonisolated enum SkillLinks {
  static let sharedID = "shared"

  enum Flavor: String, CaseIterable {
    case claude = ".claude/skills"
    case agents = ".agents/skills"
  }

  struct ClaudeDirectory: Equatable {
    let id: String
    let label: String
    let directory: String
  }

  struct Desired: Equatable {
    /// Target id → entry name → the skill linked there.
    var links: [String: [String: Skill]] = [:]
    /// Target id → ids of skills that lost the folder to an earlier source.
    var shadowed: [String: [String]] = [:]
  }

  struct TargetReport: Equatable {
    var foreign: [String] = []
    var collisions: [String] = []
    var unavailable: [String] = []
    var shadowed: [String] = []
    var refused: String?
  }

  struct Plan: Equatable {
    var actions: [SkillAction] = []
    var reports: [String: TargetReport] = [:]
  }

  // MARK: - Targets

  static func globalTargets(
    home: String, claude: [ClaudeDirectory], fs: SkillFileSystem
  ) -> [SkillTarget] {
    let rows =
      [(sharedID, "Shared", join(home, ".agents/skills"))]
      // A Claude Code target is created only if its config folder exists: the
      // applier creates missing TARGET folders, and must not create
      // `~/.claude/skills` on a Mac that has no Claude Code at all.
      + claude.filter { fs.isDirectory($0.directory) }.map {
        ($0.id, $0.label, join($0.directory, "skills"))
      }
    return deduplicated(rows.map { ($0.0, $0.1, $0.2, nil) }, fs: fs)
  }

  static func projectTargets(keys: Set<String>, fs: SkillFileSystem) -> [SkillTarget] {
    let rows = keys.sorted().flatMap { key in
      Flavor.allCases.map { flavor in
        (
          projectTargetID(key, flavor),
          "\((key as NSString).lastPathComponent) · \(flavor.rawValue)",
          join(key, flavor.rawValue), Optional(key)
        )
      }
    }
    return deduplicated(rows, fs: fs)
  }

  static func projectTargetID(_ key: String, _ flavor: Flavor) -> String {
    "project:\(key)/\(flavor.rawValue)"
  }

  /// `globalTargets` and `projectTargets` each deduplicate only within
  /// themselves, so a repository whose key IS the home folder — `~` itself,
  /// picked as a workspace — produces `project:~/.claude/skills`, a second
  /// target over the exact folder `claude-code` already covers, and the two
  /// fight: each sees the other's links as foreign and unwanted. This runs
  /// the same folder-based dedup over both lists joined, so a project row
  /// landing on a global target's folder becomes an alias of it instead,
  /// keeping that target's `projectKey` nil.
  static func combined(
    global: [SkillTarget], project: [SkillTarget], fs: SkillFileSystem
  ) -> [SkillTarget] {
    let rows = (global + project).flatMap { target in
      [(target.id, target.label, target.path, target.projectKey)]
        + target.aliases.map { (($0, "", target.path, target.projectKey)) }
    }
    return deduplicated(rows, fs: fs)
  }

  /// The target a new source path would lie inside, or that would lie inside
  /// it. Checked when a source is added; `plan` checks again, as `refused`.
  static func overlap(path: String, targets: [SkillTarget], fs: SkillFileSystem) -> SkillTarget? {
    let candidate = fs.canonical(path)
    return targets.first { target in
      let folder = fs.canonical(target.path)
      return inside(candidate, folder) || inside(folder, candidate)
    }
  }

  // MARK: - Desired

  static func desired(
    skills: [Skill], choices: [String: Set<String>], scopes: [String: [String]],
    resolved: (String) -> Set<String>, targets: [SkillTarget]
  ) -> Desired {
    var out = Desired()
    var primary: [String: String] = [:]
    for target in targets {
      primary[target.id] = target.id
      for alias in target.aliases { primary[alias] = target.id }
    }
    let scoped = Set(scopes.values.flatMap { $0 })

    func place(_ skill: Skill, in id: String) {
      guard let target = primary[id] else { return }
      if let held = out.links[target]?[skill.name] {
        if held.id != skill.id, out.shadowed[target]?.contains(skill.id) != true {
          out.shadowed[target, default: []].append(skill.id)
        }
        return
      }
      out.links[target, default: [:]][skill.name] = skill
    }

    for skill in skills where skill.isValid {
      if scoped.contains(skill.id) {
        for workspace in scopes.keys.sorted() where scopes[workspace]?.contains(skill.id) == true {
          for key in resolved(workspace).sorted() {
            for flavor in Flavor.allCases { place(skill, in: projectTargetID(key, flavor)) }
          }
        }
      } else {
        for id in (choices[skill.id] ?? []).sorted() { place(skill, in: id) }
      }
    }
    return out
  }

  // MARK: - Plan

  static func plan(
    targets: [SkillTarget], desired: Desired, sources: [SkillSource], available: Set<String>,
    fs: SkillFileSystem
  ) -> Plan {
    var plan = Plan()
    for target in targets {
      var report = TargetReport()
      report.shadowed = desired.shadowed[target.id] ?? []
      if let source = sources.first(where: { overlaps(target, $0, fs: fs) }) {
        report.refused =
          "\(target.path) and the source '\(source.name)' overlap, so nothing is linked here."
        plan.reports[target.id] = report
        continue
      }
      let want = desired.links[target.id] ?? [:]
      let folder = fs.canonical(target.path)
      let entries = fs.children(target.path).filter { !$0.hasPrefix(".") }
      for name in entries {
        guard let raw = fs.symlinkDestination(join(target.path, name)),
          let owner = claimed(absolute(raw, in: folder), sources: sources, fs: fs)
        else {
          report.foreign.append(name)
          if want[name] != nil { report.collisions.append(name) }
          continue
        }
        if !owner.retired && !available.contains(owner.name) {
          report.unavailable.append(name)
          continue
        }
        if let skill = want[name] {
          if !same(absolute(raw, in: folder), skill.path, fs: fs) {
            plan.actions.append(.relink(target: target.id, name: name, destination: skill.path))
          }
        } else {
          plan.actions.append(.unlink(target: target.id, name: name))
        }
      }
      let present = Set(entries)
      for (name, skill) in want.sorted(by: { $0.key < $1.key }) where !present.contains(name) {
        plan.actions.append(.link(target: target.id, name: name, destination: skill.path))
      }
      plan.reports[target.id] = report
    }
    return plan
  }

  // MARK: - Seeding

  /// What a newly added source's skills should start as: a choice for every
  /// global target already holding a link to them, and a workspace scope where
  /// only a repository does. A skill linked both globally and in a repository
  /// stays global, because scoping it would unlink the global copy.
  static func seed(
    skills: [Skill], targets: [SkillTarget], workspaces: [String],
    resolved: (String) -> Set<String>, fs: SkillFileSystem
  ) -> (choices: [String: Set<String>], scopes: [String: Set<String>]) {
    var choices: [String: Set<String>] = [:]
    var scopes: [String: Set<String>] = [:]
    for skill in skills where skill.isValid {
      let global = targets.filter { linked(skill, in: $0.path, fs: fs) }.map(\.id)
      if !global.isEmpty {
        choices[skill.id] = Set(global)
        continue
      }
      for workspace in workspaces {
        for key in resolved(workspace) {
          if Flavor.allCases.contains(where: { linked(skill, in: join(key, $0.rawValue), fs: fs) })
          {
            scopes[workspace, default: []].insert(skill.id)
          }
        }
      }
    }
    return (choices, scopes)
  }

  // MARK: - Ownership

  /// The source a link destination lands in. Active sources are asked first,
  /// so a folder removed and added back is owned by the row that is live.
  static func owner(
    of destination: String, sources: [SkillSource], fs: SkillFileSystem
  ) -> SkillSource? {
    let spelled = (destination as NSString).standardizingPath
    let resolved = fs.canonical(spelled)
    let ordered = sources.filter { !$0.retired } + sources.filter(\.retired)
    return ordered.first { source in
      let spellings = [(source.path as NSString).standardizingPath, fs.canonical(source.path)]
      return spellings.contains { inside(spelled, $0) || inside(resolved, $0) }
    }
  }

  /// The source a link is Bastion's through: it lands inside a source, ON ONE
  /// OF ITS SKILL SLOTS, and on a skill folder or on nothing. A link into a
  /// source that lands on some other folder is not a skill Bastion put there
  /// — including a folder further down: `owner` answers "inside", which is
  /// true of everything beneath a source, but a collection only ever gets
  /// links at its direct children, so a source added one level too high (a
  /// parent of the real collection) must claim nothing beneath it, or it
  /// would unlink every real skill under the folder it was meant to name. The
  /// Makefile this feature replaces links every folder in a collection,
  /// `*-workspace` eval folders included, and those links are left alone
  /// rather than removed.
  static func claimed(
    _ destination: String, sources: [SkillSource], fs: SkillFileSystem
  ) -> SkillSource? {
    guard let source = owner(of: destination, sources: sources, fs: fs),
      isSlot(destination, of: source, fs: fs)
    else { return nil }
    let isSkill = fs.isFile(join(destination, "SKILL.md"))
    return isSkill || !fs.entryExists(destination) ? source : nil
  }

  /// Whether `destination` is where `source` would actually place a skill:
  /// the root itself for a `.skill` source, or a direct child of the root for
  /// a `.collection` one — by either spelling, since `owner` already answers
  /// "inside" by either spelling too. Holds regardless of whether anything
  /// is there, so a dangling link still claims correctly.
  private static func isSlot(_ destination: String, of source: SkillSource, fs: SkillFileSystem)
    -> Bool
  {
    let spelled = (destination as NSString).standardizingPath
    let resolved = fs.canonical(spelled)
    let sourceSpellings = [(source.path as NSString).standardizingPath, fs.canonical(source.path)]
    switch source.kind {
    case .skill:
      return sourceSpellings.contains(spelled) || sourceSpellings.contains(resolved)
    case .collection:
      let parents = [
        (spelled as NSString).deletingLastPathComponent,
        (resolved as NSString).deletingLastPathComponent,
      ]
      return sourceSpellings.contains { parents.contains($0) }
    }
  }

  static func ownedNames(
    in folder: String, sources: [SkillSource], fs: SkillFileSystem
  ) -> [String] {
    let physical = fs.canonical(folder)
    return fs.children(folder).filter { name in
      guard !name.hasPrefix("."), let raw = fs.symlinkDestination(join(folder, name)) else {
        return false
      }
      return claimed(absolute(raw, in: physical), sources: sources, fs: fs) != nil
    }.sorted()
  }

  /// Names of retired sources some target still links into. The rest can be
  /// dropped from `skill-sources.json`.
  static func retiredStillLinked(
    targets: [SkillTarget], sources: [SkillSource], fs: SkillFileSystem
  ) -> Set<String> {
    guard sources.contains(where: \.retired) else { return [] }
    var out: Set<String> = []
    for target in targets {
      let physical = fs.canonical(target.path)
      for name in fs.children(target.path) where !name.hasPrefix(".") {
        guard let raw = fs.symlinkDestination(join(target.path, name)),
          let owner = claimed(absolute(raw, in: physical), sources: sources, fs: fs),
          owner.retired
        else { continue }
        out.insert(owner.name)
      }
    }
    return out
  }

  /// The lines `SkillExclude` keeps in a repository's `info/exclude`: every
  /// link of ours in either folder, anchored at the repository root.
  static func projectExcludeEntries(
    key: String, sources: [SkillSource], fs: SkillFileSystem
  ) -> [String] {
    Flavor.allCases.flatMap { flavor in
      ownedNames(in: join(key, flavor.rawValue), sources: sources, fs: fs)
        .map { "/\(flavor.rawValue)/\($0)" }
    }
  }

  // MARK: - Paths

  static func inside(_ path: String, _ folder: String) -> Bool {
    path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
  }

  static func absolute(_ raw: String, in folder: String) -> String {
    raw.hasPrefix("/")
      ? (raw as NSString).standardizingPath
      : ((folder as NSString).appendingPathComponent(raw) as NSString).standardizingPath
  }

  static func join(_ folder: String, _ name: String) -> String {
    (folder as NSString).appendingPathComponent(name)
  }

  private static func same(_ a: String, _ b: String, fs: SkillFileSystem) -> Bool {
    (a as NSString).standardizingPath == (b as NSString).standardizingPath
      || fs.canonical(a) == fs.canonical(b)
  }

  private static func linked(_ skill: Skill, in folder: String, fs: SkillFileSystem) -> Bool {
    guard let raw = fs.symlinkDestination(join(folder, skill.name)) else { return false }
    return same(absolute(raw, in: fs.canonical(folder)), skill.path, fs: fs)
  }

  private static func overlaps(_ target: SkillTarget, _ source: SkillSource, fs: SkillFileSystem)
    -> Bool
  {
    let folder = fs.canonical(target.path)
    let root = fs.canonical(source.path)
    return inside(folder, root) || inside(root, folder)
  }

  private static func deduplicated(
    _ rows: [(id: String, label: String, path: String, key: String?)], fs: SkillFileSystem
  ) -> [SkillTarget] {
    var out: [SkillTarget] = []
    var byFolder: [String: Int] = [:]
    for row in rows {
      let folder = fs.canonical(row.path)
      if let index = byFolder[folder] {
        out[index].aliases.append(row.id)
        // An empty label marks a row `combined` added only to carry forward
        // an alias a merge already has words for; nothing to add to the text.
        if !row.label.isEmpty { out[index].label += ", \(row.label)" }
        continue
      }
      byFolder[folder] = out.count
      out.append(
        SkillTarget(id: row.id, aliases: [], label: row.label, path: row.path, projectKey: row.key))
    }
    return out
  }
}
