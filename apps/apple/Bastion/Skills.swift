import Foundation

/// The skill sources, the choices made about their skills, and the reconcile
/// that makes every target folder match.
///
/// Every edit saves and reconciles at once, as a workspace edit rewires. The
/// catalog, targets and plan are cached here and rebuilt by `refresh`, so
/// SwiftUI bodies read them and never scan.
@MainActor
@Observable
final class SkillStore {
  static let shared = SkillStore()

  private(set) var sources: [SkillSource] = []
  private(set) var choices: [String: Set<String>] = [:]
  /// Repository target id → the link names Bastion made or adopted there.
  /// Only these are Bastion's to relink or remove in a repository, and its
  /// keys are also the repositories to look in again after a folder leaves a
  /// workspace. See `SkillLinks.plan`.
  private(set) var repositoryLinks: [String: Set<String>] = [:]

  private(set) var catalog: [Skill] = []
  private(set) var available: Set<String> = []
  /// Global targets only. Repository targets are built per reconcile from the
  /// workspaces and `repositoryLinks`.
  private(set) var targets: [SkillTarget] = []
  /// The repository targets of the current plan, for the pane's sections.
  private(set) var repositoryTargets: [SkillTarget] = []
  private(set) var desired = SkillLinks.Desired()
  private(set) var plan = SkillLinks.Plan()
  private(set) var failures: [SkillLinker.Failure] = []
  /// What claude.ai has synced down into Claude Code's default folder. The
  /// only local view of the skills Claude Desktop's chat uses. Cached so a
  /// view body never reads the disk.
  private(set) var accountSkills: Set<String> = []

  /// What `skills.json` holds.
  struct Selection: Codable, Equatable {
    struct Choice: Codable, Equatable { var targets: [String] }
    var choices: [String: Choice] = [:]
    var repositoryLinks: [String: [String]] = [:]

    init(choices: [String: Choice] = [:], repositoryLinks: [String: [String]] = [:]) {
      self.choices = choices
      self.repositoryLinks = repositoryLinks
    }

    private enum CodingKeys: String, CodingKey { case choices, repositoryLinks }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      choices = try container.decodeIfPresent([String: Choice].self, forKey: .choices) ?? [:]
      repositoryLinks =
        try container.decodeIfPresent([String: [String]].self, forKey: .repositoryLinks) ?? [:]
    }
  }

  struct Preview: Identifiable {
    let source: SkillSource
    let skills: [Skill]
    let choices: [String: Set<String>]
    let scopes: [String: Set<String>]
    let plan: SkillLinks.Plan
    var id: String { source.name }
  }

  enum StoreError: LocalizedError {
    case notAFolder(String)
    case overlapsTarget(String, String)
    case alreadyASource(String)
    case overlapsSource(String, String)
    case unknownSource(String)
    case unknownSkill(String)
    case unknownTarget(String)
    case notACollision(String)
    case linkingOff

    var errorDescription: String? {
      switch self {
      case .notAFolder(let path): "\(path) is not a folder."
      case .overlapsTarget(let path, let target):
        "\(path) overlaps \(target), where skills are linked. A source has to live elsewhere."
      case .alreadyASource(let name): "That folder is already the source '\(name)'."
      case .overlapsSource(let path, let name):
        "\(path) is inside the source '\(name)', or contains it. Add one or the other."
      case .unknownSource(let name): "There is no source named '\(name)'."
      case .unknownSkill(let id): "There is no skill '\(id)'."
      case .unknownTarget(let id): "There is no skills folder '\(id)'."
      case .notACollision(let name): "'\(name)' is not in the way of a skill Bastion wants to link."
      case .linkingOff:
        "Linking is off in this build. Launch with -reconcileSkills YES to turn it on."
      }
    }
  }

  private let fs: SkillFileSystem = LocalSkillFileSystem()
  private var sourcesURL: URL { AppSupport.directory.appendingPathComponent("skill-sources.json") }
  private var skillsURL: URL { AppSupport.directory.appendingPathComponent("skills.json") }
  private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

  init() { load() }

  // MARK: - Persistence

  func load() {
    // The fixture, never the files or the disk: skill names and paths carry a
    // client's name as readily as folder names do.
    if DemoSeed.isEnabled {
      sources = DemoSeed.skillSources
      catalog = DemoSeed.skills
      available = Set(sources.map(\.name))
      targets = DemoSeed.skillTargets
      choices = DemoSeed.skillChoices
      accountSkills = DemoSeed.accountSkills
      desired = SkillLinks.desired(
        skills: catalog, choices: choices, scopes: [:], resolved: { _ in [] }, targets: targets)
      return
    }
    sources =
      (try? Data(contentsOf: sourcesURL)).flatMap {
        try? JSONDecoder().decode([SkillSource].self, from: $0)
      } ?? []
    let selection =
      (try? Data(contentsOf: skillsURL)).flatMap {
        try? JSONDecoder().decode(Selection.self, from: $0)
      } ?? Selection()
    choices = selection.choices.mapValues { Set($0.targets) }
    repositoryLinks = selection.repositoryLinks.mapValues(Set.init).filter { !$0.value.isEmpty }
    refresh()
  }

  func save() throws {
    if DemoSeed.isEnabled { return }
    AppSupport.ensureDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let selection = Selection(
      choices: choices.mapValues { .init(targets: $0.sorted()) },
      repositoryLinks: repositoryLinks.mapValues { $0.sorted() })
    for (data, url) in [
      (try encoder.encode(sources), sourcesURL), (try encoder.encode(selection), skillsURL),
    ] {
      try data.write(to: url, options: .atomic)
      // After every write: `.atomic` replaces the file.
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
  }

  // MARK: - Reading

  /// Re-read sources and discover targets. Writes nothing.
  func refresh() {
    guard !DemoSeed.isEnabled else { return }
    let found = SkillCatalog.catalog(sources, fs: fs)
    catalog = found.skills
    available = found.available
    targets = SkillLinks.globalTargets(home: home, claude: claudeDirectories, fs: fs)
    let all: [SkillTarget]
    (all, desired, plan) = planned(
      sources: sources, catalog: catalog, available: available, choices: choices,
      scopes: WorkspaceStore.shared.skillScopes)
    repositoryTargets = all.filter { $0.projectKey != nil }
    let synced = home + "/.claude/skills/synced"
    accountSkills = Set(
      fs.children(synced).filter { !$0.hasPrefix(".") && fs.isDirectory(synced + "/" + $0) })
  }

  func isOn(_ skillID: String, _ targetID: String) -> Bool {
    choices[skillID]?.contains(targetID) == true
  }

  func targets(of skillID: String) -> [String] { (choices[skillID] ?? []).sorted() }

  /// Characters of every description linked into one target: each is loaded
  /// into every session that reads the folder.
  func descriptionCharacters(in targetID: String) -> Int {
    (desired.links[targetID] ?? [:]).values.reduce(0) { $0 + $1.description.count }
  }

  // MARK: - Editing

  /// Toggles one target, tolerating every OTHER stored id that no longer
  /// resolves — a Claude profile's config folder removed since the choice was
  /// saved, say. Dropping those here rather than leaving them for
  /// `setTargets` to refuse is what keeps a vanished target from blocking
  /// every future toggle on the skill; `targetID` itself is not filtered, so
  /// toggling ON an id that does not resolve still reaches `setTargets` and
  /// throws `unknownTarget`, which `update_skill` relies on.
  func set(_ skillID: String, target targetID: String, on: Bool) throws {
    var next = choices[skillID] ?? []
    if on { next.insert(targetID) } else { next.remove(targetID) }
    let primary = primaryTargetIDs()
    next = next.filter { $0 == targetID || primary[$0] != nil }
    try setTargets(skillID, next)
  }

  func setTargets(_ skillID: String, _ ids: Set<String>) throws {
    guard catalog.contains(where: { $0.id == skillID }) else {
      throw StoreError.unknownSkill(skillID)
    }
    let primary = primaryTargetIDs()
    if let unknown = ids.first(where: { primary[$0] == nil }) {
      throw StoreError.unknownTarget(unknown)
    }
    let resolved = Set(ids.compactMap { primary[$0] })
    choices[skillID] = resolved.isEmpty ? nil : resolved
    try save()
    reconcile()
  }

  /// What adding a folder as a source would do, seeded from the links that
  /// already point into it. Nothing is saved until `commit`.
  func preview(adding path: String) throws -> Preview {
    let expanded = (path as NSString).expandingTildeInPath
    guard fs.isDirectory(expanded) else { throw StoreError.notAFolder(expanded) }
    let workspaces = WorkspaceStore.shared
    let repositoryTargets = SkillLinks.projectTargets(
      keys: projectKeys(scopes: workspaces.skillScopes), fs: fs)
    let allExistingTargets = SkillLinks.combined(
      global: targets, project: repositoryTargets, fs: fs)
    if let target = SkillLinks.overlap(path: expanded, targets: allExistingTargets, fs: fs) {
      throw StoreError.overlapsTarget(expanded, target.path)
    }
    let candidate = fs.canonical(expanded)
    if let existing = sources.first(where: { !$0.retired && fs.canonical($0.path) == candidate }) {
      throw StoreError.alreadyASource(existing.name)
    }
    // One inside another would claim the same links twice over, and a link
    // into the inner one is a skill slot of only one of them.
    if let existing = sources.first(where: { source in
      let root = fs.canonical(source.path)
      return !source.retired
        && (SkillLinks.inside(candidate, root) || SkillLinks.inside(root, candidate))
    }) {
      throw StoreError.overlapsSource(expanded, existing.name)
    }
    let source = SkillSource(
      name: SkillCatalog.defaultSourceName(for: expanded, taken: Set(sources.map(\.name))),
      path: expanded, kind: SkillCatalog.kind(of: expanded, fs: fs))
    let skills = SkillCatalog.skills(in: source, fs: fs) ?? []
    // Global targets only, deliberately, and not `allExistingTargets`: `seed`
    // records a choice for every target in its list that already holds a
    // link. Passing repository targets here would turn a link found only in
    // a repository into a stored `project:…` choice instead of a workspace
    // scope, which is never a target `setTargets` accepts — the skill would
    // stay unscoped, and every toggle on it would throw `unknownTarget`.
    let seeded = SkillLinks.seed(
      skills: skills, targets: targets, workspaces: workspaces.workspaces.map(\.name),
      resolved: { name in
        workspaces.workspaces.first { $0.name == name }.map(workspaces.resolvedKeys) ?? []
      }, fs: fs)

    var nextScopes = workspaces.skillScopes
    for (name, ids) in seeded.scopes {
      nextScopes[name] = Array(Set(nextScopes[name] ?? []).union(ids)).sorted()
    }
    let nextSources = sources + [source]
    let found = SkillCatalog.catalog(nextSources, fs: fs)
    let (_, _, plan) = planned(
      sources: nextSources, catalog: found.skills, available: found.available,
      choices: choices.merging(seeded.choices) { $1 }, scopes: nextScopes)
    return Preview(
      source: source, skills: skills, choices: seeded.choices, scopes: seeded.scopes, plan: plan)
  }

  func commit(_ preview: Preview) throws {
    sources.append(preview.source)
    choices.merge(preview.choices) { $1 }
    try save()
    if preview.scopes.isEmpty {
      reconcile()
    } else {
      // Saves the workspaces and rewires, and rewire reconciles.
      try WorkspaceStore.shared.addSkills(preview.scopes)
    }
  }

  func removeSource(named name: String) throws {
    guard let index = sources.firstIndex(where: { $0.name == name && !$0.retired }) else {
      throw StoreError.unknownSource(name)
    }
    sources[index].retired = true
    try save()
    reconcile()
  }

  func move(_ name: String, by offset: Int) throws {
    guard let index = sources.firstIndex(where: { $0.name == name }) else {
      throw StoreError.unknownSource(name)
    }
    let destination = min(max(index + offset, 0), sources.count - 1)
    guard destination != index else { return }
    sources.swapAt(index, destination)
    try save()
    reconcile()
  }

  /// "Overwrite anyway": the foreign entry goes to the Trash and the skill is
  /// linked in its place.
  func overwrite(target targetID: String, name: String) throws {
    // First, and unconditionally: a Debug build with linking off must never
    // reach `SkillLinker.trash` below, even though `plan` (refreshed by
    // `reconcile`'s early-return path) can still show a real collision.
    guard Self.reconciles else { throw StoreError.linkingOff }
    // `allTargets` holds the repository targets as well as the global ones,
    // so a collision in a repository's `.claude/skills` is found here too.
    guard plan.reports[targetID]?.collisions.contains(name) == true,
      let target = allTargets().first(where: { $0.id == targetID })
    else { throw StoreError.notACollision(name) }
    let path = (target.path as NSString).appendingPathComponent(name)
    try SkillLinker.trash(path)
    hostLog("skills", .info, "moved \(path) to the Trash to link a skill in its place")
    reconcile()
  }

  func exportZIP(_ skill: Skill, to url: URL) throws {
    let folder = URL(fileURLWithPath: skill.path).resolvingSymlinksInPath().path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--keepParent", folder, url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
  }

  // MARK: - Reconcile

  /// Whether this instance may create, relink or remove symlinks in the real
  /// skills folders.
  ///
  /// Shaped exactly like `ClientWiring.autoWires`, and for the same reason: a
  /// Debug build shares every real skills folder — `~/.claude/skills`,
  /// `~/.agents/skills`, and every repository's `.claude/skills` and
  /// `.agents/skills` — with the installed Release app. Two instances
  /// reconciling the same folders from different selections would unlink and
  /// relink each other's links, and removing a source in one would delete
  /// links the other made and still wants.
  ///
  /// Release on, Debug off, `-reconcileSkills YES` to turn it back on for a
  /// developer exercising the path deliberately.
  nonisolated static var reconciles: Bool {
    // Not `as? Bool`: a launch argument arrives as the string "YES", which
    // that cast turns into nil. `bool(forKey:)` reads YES/NO/true/false/1/0.
    if UserDefaults.standard.object(forKey: "reconcileSkills") != nil {
      return UserDefaults.standard.bool(forKey: "reconcileSkills")
    }
    #if DEBUG
      return false
    #else
      return true
    #endif
  }

  func reconcile() {
    guard !DemoSeed.isEnabled, !sources.isEmpty else {
      failures = []
      return
    }
    guard Self.reconciles else {
      // Refreshed so the pane still shows the plan; nothing below this line
      // runs, so nothing is written to a real skills folder or exclude file
      // from this instance. See `reconciles`.
      refresh()
      failures = []
      return
    }
    refresh()
    let all = allTargets()
    failures = SkillLinker.apply(plan.actions, targets: all)
    for action in plan.actions
    where !failures.contains(where: { $0.target == action.target && $0.name == action.name }) {
      hostLog("skills", .info, action.summary)
    }
    for failure in failures {
      hostLog("skills", .error, "\(failure.target) \(failure.name): \(failure.message)")
    }

    // In memory first, and never reloaded from disk: if `save` below fails,
    // the names made this pass stay here and the next successful save of
    // either file writes them.
    repositoryLinks = SkillLinks.nextLedger(
      targets: all, desired: desired, ledger: repositoryLinks, sources: sources, fs: fs)
    for key in SkillLinks.repositoryKeys(all) {
      let entries = SkillLinks.projectExcludeEntries(
        key: key, targets: all, ledger: repositoryLinks, sources: sources, fs: fs)
      if let failure = SkillLinker.writeExclude(key: key, entries: entries, fs: fs) {
        // Filed under a target covering the repository, so a section in the
        // pane shows it; the bare key matches no section.
        let target = all.first { SkillLinks.covers($0, key: key) }?.id ?? failure.target
        failures.append(.init(target: target, name: failure.name, message: failure.message))
        hostLog("skills", .error, "\(key): \(failure.message)")
      }
    }
    let retiredInUse = SkillLinks.retiredStillLinked(
      targets: all, sources: sources, ledger: repositoryLinks, fs: fs)
    sources.removeAll { $0.retired && !retiredInUse.contains($0.name) }
    do { try save() } catch { hostLog("skills", .error, "could not save: \(error)") }
    // What is left after applying: collisions, foreign entries, refusals.
    refresh()
  }

  // MARK: - Private

  /// Every id a stored choice can resolve through: a target's own id, plus
  /// every alias that lands on the same folder — the shape `setTargets` and
  /// `set` both need to tell a live target from a vanished one.
  private func primaryTargetIDs() -> [String: String] {
    var primary: [String: String] = [:]
    for target in targets {
      primary[target.id] = target.id
      for alias in target.aliases { primary[alias] = target.id }
    }
    return primary
  }

  private var claudeDirectories: [SkillLinks.ClaudeDirectory] {
    [.init(id: ClaudeProfiles.family, label: "Claude Code", directory: home + "/.claude")]
      + ClientWiring.discoveredProfiles.map {
        .init(id: $0.id, label: $0.displayName, directory: $0.directory.path)
      }
  }

  /// Every repository this reconcile looks in: those a workspace with skills
  /// resolves to now, and those holding a link in the ledger. The second half
  /// is what cleans up after a folder leaves a workspace.
  private func projectKeys(scopes: [String: [String]]) -> Set<String> {
    let store = WorkspaceStore.shared
    var keys = Set(repositoryLinks.keys.compactMap(SkillLinks.projectKey(fromTargetID:)))
    for workspace in store.workspaces where scopes[workspace.name]?.isEmpty == false {
      keys.formUnion(store.resolvedKeys(workspace))
    }
    return keys
  }

  private func allTargets() -> [SkillTarget] {
    SkillLinks.combined(
      global: targets,
      project: SkillLinks.projectTargets(
        keys: projectKeys(scopes: WorkspaceStore.shared.skillScopes), fs: fs),
      fs: fs)
  }

  private func planned(
    sources: [SkillSource], catalog: [Skill], available: Set<String>,
    choices: [String: Set<String>], scopes: [String: [String]]
  ) -> ([SkillTarget], SkillLinks.Desired, SkillLinks.Plan) {
    let store = WorkspaceStore.shared
    let all = SkillLinks.combined(
      global: targets,
      project: SkillLinks.projectTargets(keys: projectKeys(scopes: scopes), fs: fs),
      fs: fs)
    let desired = SkillLinks.desired(
      skills: catalog, choices: choices, scopes: scopes,
      resolved: { name in store.workspaces.first { $0.name == name }.map(store.resolvedKeys) ?? []
      },
      targets: all)
    let plan = SkillLinks.plan(
      targets: all, desired: desired, sources: sources, available: available,
      ledger: repositoryLinks, fs: fs)
    return (all, desired, plan)
  }
}
