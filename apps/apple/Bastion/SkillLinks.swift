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
/// `make skills-check` drives every case from a fake tree. In a global folder,
/// ownership is "a symlink that points into a source under its own name", with
/// no ledger, for the reason `isOurs` is the ledger in `ClientWiringMerge`: a
/// record of what was written is one more thing that can disagree with the
/// disk. A repository is different: its links were often made by something
/// else (a Makefile, a teammate's script), and it comes into view whenever a
/// workspace changes, so there a link is Bastion's to change only once its
/// name is in the per-folder ledger — Bastion made it, or found it already
/// pointing at the skill it wanted there.
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
    /// Links into a source in a repository folder that Bastion did not make
    /// and does not want there. Left alone.
    var unadopted: [String] = []
    var refused: String?

    /// Whether the folder has anything to say beyond "all as wanted".
    var isQuiet: Bool {
      collisions.isEmpty && unavailable.isEmpty && shadowed.isEmpty && unadopted.isEmpty
        && refused == nil
    }
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

  /// The repository a `projectTargetID` names, or nil for any other id.
  static func projectKey(fromTargetID id: String) -> String? {
    projectFolder(fromTargetID: id)?.key
  }

  /// The repository and folder a `projectTargetID` names.
  static func projectFolder(fromTargetID id: String) -> (key: String, flavor: Flavor)? {
    guard id.hasPrefix("project:") else { return nil }
    let body = id.dropFirst("project:".count)
    for flavor in Flavor.allCases where body.hasSuffix("/" + flavor.rawValue) {
      let key = String(body.dropLast(flavor.rawValue.count + 1))
      return key.isEmpty ? nil : (key, flavor)
    }
    return nil
  }

  /// Every repository some target covers, by its own id or an alias: a
  /// repository folder merged into a global target (a home-folder
  /// repository) keeps no `projectKey`, but still needs its exclude lines.
  static func repositoryKeys(_ targets: [SkillTarget]) -> Set<String> {
    Set(
      targets.flatMap { target in
        [target.projectKey].compactMap { $0 }
          + ([target.id] + target.aliases).compactMap(projectKey(fromTargetID:))
      })
  }

  /// Whether `target` is, or stands in for, one of `key`'s folders.
  static func covers(_ target: SkillTarget, key: String) -> Bool {
    ([target.id] + target.aliases).contains { projectKey(fromTargetID: $0) == key }
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

  /// `ledger` is project target id → the names Bastion made there (or
  /// adopted); global targets ignore it. In a repository folder a claimed
  /// link whose name is not in the ledger is never changed: kept when it
  /// already points at the wanted skill, a collision when it points at
  /// another, and `unadopted` when nothing is wanted under its name.
  static func plan(
    targets: [SkillTarget], desired: Desired, sources: [SkillSource], available: Set<String>,
    ledger: [String: Set<String>], fs: SkillFileSystem
  ) -> Plan {
    var plan = Plan()
    for target in targets {
      let recorded = ledgerNames(target, ledger)
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
          let owner = claimed(name, absolute(raw, in: folder), sources: sources, fs: fs)
        else {
          report.foreign.append(name)
          if want[name] != nil { report.collisions.append(name) }
          continue
        }
        if !owner.retired && !available.contains(owner.name) {
          report.unavailable.append(name)
          continue
        }
        if let recorded, !recorded.contains(name) {
          if let skill = want[name] {
            // Right already: adopted, and `nextLedger` records it. Wrong: the
            // link is somebody else's choice, so only Overwrite Anyway moves it.
            if !same(absolute(raw, in: folder), skill.path, fs: fs) {
              report.collisions.append(name)
            }
          } else {
            report.unadopted.append(name)
          }
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
  /// global target already holding a link to them, and otherwise a workspace
  /// scope, but only where EVERY repository that workspace resolves to
  /// already links that skill, in either folder. Anything looser plans new
  /// links into repositories that never had the skill — a parent workspace
  /// such as `apps` reaches twenty repositories, and scoping a skill found in
  /// one of them to it would link it into all twenty, and relink a same-name
  /// skill from another source in the others. Of several workspaces that
  /// qualify, the one with the fewest repositories wins, then the first by
  /// name. A skill linked both globally and in a repository stays global,
  /// because scoping it would unlink the global copy. A skill that fits no
  /// workspace is left unscoped, and its repository links are not adopted.
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
      var best: (name: String, keys: Int)?
      for workspace in workspaces {
        let keys = resolved(workspace)
        guard !keys.isEmpty,
          keys.allSatisfy({ key in
            Flavor.allCases.contains { linked(skill, in: join(key, $0.rawValue), fs: fs) }
          })
        else { continue }
        if let current = best, (current.keys, current.name) <= (keys.count, workspace) { continue }
        best = (workspace, keys.count)
      }
      if let best { scopes[best.name, default: []].insert(skill.id) }
    }
    return (choices, scopes)
  }

  // MARK: - Ownership

  /// The source a link destination lands in: of the sources containing it,
  /// the first for which it is a skill slot. Active sources are asked first,
  /// so a folder removed and added back is owned by the row that is live.
  /// Asking only "inside" would let a source that is a PARENT of another
  /// (`claude-skills` above `claude-skills/global`) win every link into the
  /// child, and then disown them all as not being its slots.
  static func owner(
    of destination: String, sources: [SkillSource], fs: SkillFileSystem
  ) -> SkillSource? {
    let spelled = (destination as NSString).standardizingPath
    let resolved = fs.canonical(spelled)
    let ordered = sources.filter { !$0.retired } + sources.filter(\.retired)
    return ordered.first { source in
      let spellings = [(source.path as NSString).standardizingPath, fs.canonical(source.path)]
      return spellings.contains { inside(spelled, $0) || inside(resolved, $0) }
        && isSlot(destination, of: source, fs: fs)
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
  ///
  /// `name` is the entry's own name, and it must be the destination's last
  /// component: Bastion always names a link after its folder, so
  /// `my-review -> src/code-review` is somebody's alias, not Bastion's link.
  static func claimed(
    _ name: String, _ destination: String, sources: [SkillSource], fs: SkillFileSystem
  ) -> SkillSource? {
    guard name == ((destination as NSString).standardizingPath as NSString).lastPathComponent,
      let source = owner(of: destination, sources: sources, fs: fs)
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
      return claimed(name, absolute(raw, in: physical), sources: sources, fs: fs) != nil
    }.sorted()
  }

  /// Names of retired sources some target still links into. The rest can be
  /// dropped from `skill-sources.json`. In a repository folder only ledger
  /// names count: a Makefile's link into a retired source is never removed,
  /// so counting it would keep that source alive forever.
  static func retiredStillLinked(
    targets: [SkillTarget], sources: [SkillSource], ledger: [String: Set<String>],
    fs: SkillFileSystem
  ) -> Set<String> {
    guard sources.contains(where: \.retired) else { return [] }
    var out: Set<String> = []
    for target in targets {
      let recorded = ledgerNames(target, ledger)
      let physical = fs.canonical(target.path)
      for name in fs.children(target.path) where !name.hasPrefix(".") {
        if let recorded, !recorded.contains(name) { continue }
        guard let raw = fs.symlinkDestination(join(target.path, name)),
          let owner = claimed(name, absolute(raw, in: physical), sources: sources, fs: fs),
          owner.retired
        else { continue }
        out.insert(owner.name)
      }
    }
    return out
  }

  /// The ledger after a reconcile, read from the disk after the apply: per
  /// repository target, the recorded names still present as claimed links,
  /// plus every wanted name now pointing at the wanted skill — which covers
  /// both what this pass linked or relinked and what it adopted. Global
  /// targets have no entry, and neither does a folder left with nothing.
  /// A folder that cannot be listed (missing, unmounted, unreadable) keeps
  /// its recorded names unchanged: `children` would answer `[]` for it, and
  /// forgetting them would leave Bastion's own links unadopted for good.
  static func nextLedger(
    targets: [SkillTarget], desired: Desired, ledger: [String: Set<String>],
    sources: [SkillSource], fs: SkillFileSystem
  ) -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    for target in targets {
      guard let recorded = ledgerNames(target, ledger) else { continue }
      guard fs.canList(target.path) else {
        if !recorded.isEmpty { out[target.id] = recorded }
        continue
      }
      let want = desired.links[target.id] ?? [:]
      let folder = fs.canonical(target.path)
      let names = ownedNames(in: target.path, sources: sources, fs: fs).filter { name in
        if recorded.contains(name) { return true }
        guard let skill = want[name], let raw = fs.symlinkDestination(join(target.path, name))
        else { return false }
        return same(absolute(raw, in: folder), skill.path, fs: fs)
      }
      if !names.isEmpty { out[target.id] = Set(names) }
    }
    return out
  }

  /// The lines `SkillExclude` keeps in a repository's `info/exclude`:
  /// Bastion's links, anchored at the repository root, under EVERY folder of
  /// `key` their target covers. Targets merge by resolved folder, so the
  /// ledger is keyed by one id while git may see the links through another:
  /// with `.claude/skills -> ../.agents/skills` the `.claude` row is primary
  /// but git reports `.agents/skills/alpha`.
  ///
  /// A repository target contributes its ledger names only; a link somebody
  /// else made is theirs to ignore or commit. A repository folder merged
  /// into a GLOBAL target (a home-folder repository) has no ledger, and
  /// there every link the global target claims is Bastion's, so those names
  /// are listed.
  static func projectExcludeEntries(
    key: String, targets: [SkillTarget], ledger: [String: Set<String>],
    sources: [SkillSource], fs: SkillFileSystem
  ) -> [String] {
    var byFlavor: [Flavor: Set<String>] = [:]
    for target in targets {
      let folders = ([target.id] + target.aliases).compactMap(projectFolder(fromTargetID:))
        .filter { $0.key == key }
      guard !folders.isEmpty else { continue }
      let names =
        ledgerNames(target, ledger)
        ?? Set(ownedNames(in: target.path, sources: sources, fs: fs))
      for folder in folders { byFlavor[folder.flavor, default: []].formUnion(names) }
    }
    return Flavor.allCases.flatMap { flavor in
      (byFlavor[flavor] ?? []).sorted().map { "/\(flavor.rawValue)/\($0)" }
    }
  }

  /// The ledger's names for a repository target, under its own id or any
  /// alias, or nil for a global target, which keeps no ledger.
  private static func ledgerNames(_ target: SkillTarget, _ ledger: [String: Set<String>])
    -> Set<String>?
  {
    guard target.projectKey != nil else { return nil }
    return ([target.id] + target.aliases).reduce(into: Set<String>()) {
      $0.formUnion(ledger[$1] ?? [])
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

/// Bastion's block in a repository's `.git/info/exclude`.
///
/// `info/exclude` rather than `.gitignore`: it is local to the clone and never
/// committed, and it is shared by every worktree of the repository. Without it
/// `git add .` commits a symlink to `/Users/<me>/…`. Only the block is
/// Bastion's; every other line comes back byte for byte.
nonisolated enum SkillExclude {
  static let begin = "# >>> bastion skills: managed by Bastion, edits here are overwritten"
  static let end = "# <<< bastion skills"

  /// A block runs from a `begin` to the first `end` before the next `begin`.
  /// A `begin` with no such `end` (a hand edit, a truncated write) loses only
  /// its own line: taking everything up to some later `end`, or to the end
  /// of the file, would take the user's lines with it.
  static func updated(_ existing: String, entries: [String]) -> String {
    var lines = existing.components(separatedBy: "\n")
    while let start = lines.firstIndex(of: begin) {
      let limit = lines[(start + 1)...].firstIndex(of: begin) ?? lines.endIndex
      if let stop = lines[(start + 1)..<limit].firstIndex(of: end) {
        lines.removeSubrange(start...stop)
      } else {
        lines.remove(at: start)
      }
    }
    var text = lines.joined(separator: "\n")
    guard !entries.isEmpty else { return text }
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    return text + ([begin] + entries + [end]).joined(separator: "\n") + "\n"
  }

  static func path(forKey key: String, fs: SkillFileSystem) -> String? {
    let git = (key as NSString).appendingPathComponent(".git")
    guard fs.isDirectory(git) else { return nil }
    return (git as NSString).appendingPathComponent("info/exclude")
  }
}
