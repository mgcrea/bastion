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
  private(set) var linkedProjects: Set<String> = []

  private(set) var catalog: [Skill] = []
  private(set) var available: Set<String> = []
  /// Global targets only. Repository targets are built per reconcile from the
  /// workspaces and `linkedProjects`.
  private(set) var targets: [SkillTarget] = []
  private(set) var desired = SkillLinks.Desired()
  private(set) var plan = SkillLinks.Plan()
  private(set) var failures: [SkillLinker.Failure] = []

  /// What `skills.json` holds.
  struct Selection: Codable, Equatable {
    struct Choice: Codable, Equatable { var targets: [String] }
    var choices: [String: Choice] = [:]
    var linkedProjects: [String] = []
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
    case unknownSource(String)
    case unknownSkill(String)
    case unknownTarget(String)
    case notACollision(String)

    var errorDescription: String? {
      switch self {
      case .notAFolder(let path): "\(path) is not a folder."
      case .overlapsTarget(let path, let target):
        "\(path) overlaps \(target), where skills are linked. A source has to live elsewhere."
      case .alreadyASource(let name): "That folder is already the source '\(name)'."
      case .unknownSource(let name): "There is no source named '\(name)'."
      case .unknownSkill(let id): "There is no skill '\(id)'."
      case .unknownTarget(let id): "There is no skills folder '\(id)'."
      case .notACollision(let name): "'\(name)' is not in the way of a skill Bastion wants to link."
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
    linkedProjects = Set(selection.linkedProjects)
    refresh()
  }

  func save() throws {
    if DemoSeed.isEnabled { return }
    AppSupport.ensureDirectory()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let selection = Selection(
      choices: choices.mapValues { .init(targets: $0.sorted()) },
      linkedProjects: linkedProjects.sorted())
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
    (desired, plan) = planned(
      sources: sources, catalog: catalog, available: available, choices: choices,
      scopes: WorkspaceStore.shared.skillScopes)
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

  /// What claude.ai has synced down into Claude Code's default folder. The only
  /// local view of the skills Claude Desktop's chat uses.
  var accountSkillNames: Set<String> {
    if DemoSeed.isEnabled { return DemoSeed.accountSkills }
    let synced = home + "/.claude/skills/synced"
    return Set(
      fs.children(synced).filter { !$0.hasPrefix(".") && fs.isDirectory(synced + "/" + $0) })
  }

  // MARK: - Editing

  func set(_ skillID: String, target targetID: String, on: Bool) throws {
    var next = choices[skillID] ?? []
    if on { next.insert(targetID) } else { next.remove(targetID) }
    try setTargets(skillID, next)
  }

  func setTargets(_ skillID: String, _ ids: Set<String>) throws {
    guard catalog.contains(where: { $0.id == skillID }) else {
      throw StoreError.unknownSkill(skillID)
    }
    var primary: [String: String] = [:]
    for target in targets {
      primary[target.id] = target.id
      for alias in target.aliases { primary[alias] = target.id }
    }
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
    if let existing = sources.first(where: {
      !$0.retired && fs.canonical($0.path) == fs.canonical(expanded)
    }) {
      throw StoreError.alreadyASource(existing.name)
    }
    let source = SkillSource(
      name: SkillCatalog.defaultSourceName(for: expanded, taken: Set(sources.map(\.name))),
      path: expanded, kind: SkillCatalog.kind(of: expanded, fs: fs))
    let skills = SkillCatalog.skills(in: source, fs: fs) ?? []
    let seeded = SkillLinks.seed(
      skills: skills, targets: allExistingTargets, workspaces: workspaces.workspaces.map(\.name),
      resolved: { name in
        workspaces.workspaces.first { $0.name == name }.map(workspaces.resolvedKeys) ?? []
      }, fs: fs)

    var nextScopes = workspaces.skillScopes
    for (name, ids) in seeded.scopes {
      nextScopes[name] = Array(Set(nextScopes[name] ?? []).union(ids)).sorted()
    }
    let nextSources = sources + [source]
    let found = SkillCatalog.catalog(nextSources, fs: fs)
    let (_, plan) = planned(
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

  func reconcile() {
    guard !DemoSeed.isEnabled, !sources.isEmpty else { return }
    refresh()
    let all = allTargets()
    failures = SkillLinker.apply(plan.actions, targets: all)
    for action in plan.actions { hostLog("skills", .info, action.summary) }
    for failure in failures {
      hostLog("skills", .error, "\(failure.target) \(failure.name): \(failure.message)")
    }

    var stillLinked: Set<String> = []
    for key in Set(all.compactMap(\.projectKey)) {
      let entries = SkillLinks.projectExcludeEntries(key: key, sources: sources, fs: fs)
      if !entries.isEmpty { stillLinked.insert(key) }
      if let failure = SkillLinker.writeExclude(key: key, entries: entries, fs: fs) {
        failures.append(failure)
        hostLog("skills", .error, "\(key): \(failure.message)")
      }
    }
    linkedProjects = stillLinked
    let retiredInUse = SkillLinks.retiredStillLinked(targets: all, sources: sources, fs: fs)
    sources.removeAll { $0.retired && !retiredInUse.contains($0.name) }
    do { try save() } catch { hostLog("skills", .error, "could not save: \(error)") }
    // What is left after applying: collisions, foreign entries, refusals.
    refresh()
  }

  // MARK: - Private

  private var claudeDirectories: [SkillLinks.ClaudeDirectory] {
    [.init(id: ClaudeProfiles.family, label: "Claude Code", directory: home + "/.claude")]
      + ClientWiring.discoveredProfiles.map {
        .init(id: $0.id, label: $0.displayName, directory: $0.directory.path)
      }
  }

  /// Every repository this reconcile looks in: those a workspace with skills
  /// resolves to now, and those Bastion linked into before. The second half is
  /// what cleans up after a folder leaves a workspace.
  private func projectKeys(scopes: [String: [String]]) -> Set<String> {
    let store = WorkspaceStore.shared
    var keys = linkedProjects
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
  ) -> (SkillLinks.Desired, SkillLinks.Plan) {
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
      targets: all, desired: desired, sources: sources, available: available, fs: fs)
    return (desired, plan)
  }
}
