import Foundation

/// A folder Bastion reads skills from and never writes into.
///
/// `retired` is a removed source that still has links somewhere. Ownership is
/// "a link that points into a source", so a source forgotten outright would
/// strand its links as foreign; kept as retired, its links are recognised and
/// removed, and the row is dropped once none is left.
nonisolated struct SkillSource: Codable, Equatable, Identifiable {
  enum Kind: String, Codable {
    /// A folder whose immediate subfolders holding a `SKILL.md` are skills.
    case collection
    /// One skill folder.
    case skill
  }

  var name: String
  var path: String
  var kind: Kind
  var retired: Bool

  var id: String { name }

  init(name: String, path: String, kind: Kind, retired: Bool = false) {
    self.name = name
    self.path = path
    self.kind = kind
    self.retired = retired
  }

  private enum CodingKeys: String, CodingKey { case name, path, kind, retired }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    path = try container.decode(String.self, forKey: .path)
    kind = try container.decode(Kind.self, forKey: .kind)
    retired = try container.decodeIfPresent(Bool.self, forKey: .retired) ?? false
  }
}

/// One skill folder, as found in a source.
///
/// The id is `<source>:<name>` because the name alone does not identify a
/// skill: armada, bastion and cupertino each have a `cut-a-release`.
nonisolated struct Skill: Equatable, Identifiable {
  let source: String
  /// The folder name, which is also the name the link gets.
  let name: String
  /// The skill folder as the source spells it.
  let path: String
  let description: String
  let problems: [String]

  var id: String { "\(source):\(name)" }
  var isValid: Bool { problems.isEmpty }
}

/// What linking asks of a disk beyond what folder resolution does.
nonisolated protocol SkillFileSystem: WorkspaceFileSystem {
  /// The raw destination of a symlink, relative or absolute, or nil when the
  /// entry is not a symlink.
  func symlinkDestination(_ path: String) -> String?
  /// Whether anything is at `path`, a dangling symlink included.
  func entryExists(_ path: String) -> Bool
}

nonisolated struct LocalSkillFileSystem: SkillFileSystem {
  private let base = LocalWorkspaceFileSystem()

  func isDirectory(_ path: String) -> Bool { base.isDirectory(path) }
  func isFile(_ path: String) -> Bool { base.isFile(path) }
  func contents(_ path: String) -> String? { base.contents(path) }
  func children(_ path: String) -> [String] { base.children(path) }
  func canonical(_ path: String) -> String { base.canonical(path) }

  func symlinkDestination(_ path: String) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: path)
  }

  func entryExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }
}

/// The top-level scalar fields of a `SKILL.md` frontmatter block.
///
/// Deliberately not a YAML parser. Validation needs two strings, `name` and
/// `description`, and the shapes skills actually use for them: plain, quoted,
/// folded (`>`), literal (`|`), and a plain value wrapped onto indented lines.
/// Nested maps such as `metadata:` are read as an opaque string and ignored.
nonisolated enum SkillFrontmatter {
  static func fields(_ text: String) -> [String: String]? {
    var body = text
    if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
    body = body.replacingOccurrences(of: "\r\n", with: "\n")
    let lines = body.components(separatedBy: "\n")
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let close = lines.indices.dropFirst().first(where: {
        lines[$0].trimmingCharacters(in: .whitespaces) == "---"
      })
    else { return nil }

    var out: [String: String] = [:]
    var index = 1
    while index < close {
      let line = lines[index]
      index += 1
      guard let first = line.first, first != " ", first != "\t", first != "#",
        let colon = line.firstIndex(of: ":")
      else { continue }
      let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

      var block: [String] = []
      while index < close,
        lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty
      {
        block.append(lines[index].trimmingCharacters(in: .whitespaces))
        index += 1
      }
      while block.last?.isEmpty == true { block.removeLast() }

      if ["|", "|-", "|+"].contains(value) {
        value = block.joined(separator: "\n")
      } else if [">", ">-", ">+"].contains(value) {
        value = block.filter { !$0.isEmpty }.joined(separator: " ")
      } else if !block.isEmpty {
        value = ([value] + block.filter { !$0.isEmpty }).joined(separator: " ")
      }
      out[key] = unquoted(value)
    }
    return out
  }

  private static func unquoted(_ value: String) -> String {
    guard value.count >= 2, let first = value.first, first == value.last,
      first == "\"" || first == "'"
    else { return value }
    let inner = String(value.dropFirst().dropLast())
    return first == "'"
      ? inner.replacingOccurrences(of: "''", with: "'")
      : inner.replacingOccurrences(of: "\\\"", with: "\"")
  }
}

/// Which folders are skills, and whether each one is fit to link.
///
/// The rules are agentskills.io's, which are stricter than Claude Code's own:
/// Claude Code makes `name` optional and allows a 1,536-character description.
/// A skill that passes the strict rules loads in every client, which is the
/// point of linking it into a shared folder.
nonisolated enum SkillCatalog {
  static let reservedNames: Set<String> = ["synced", "anthropic-skills"]
  static let nameLimit = 64
  static let descriptionLimit = 1024

  static func isValidSkillName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= nameLimit
      && name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil
  }

  /// `Profile.isValidName`'s rule, repeated here because `Profile` is app-side
  /// and `make skills-check` compiles this file alone.
  static func isValidSourceName(_ name: String) -> Bool {
    !name.isEmpty && name.count <= 64
      && name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
  }

  static func problems(folderName: String, fields: [String: String]?) -> [String] {
    guard let fields else { return ["SKILL.md has no frontmatter between two --- lines"] }
    var out: [String] = []
    if reservedNames.contains(folderName) {
      out.append("'\(folderName)' is a name Claude Code reserves")
    }
    if let name = fields["name"], !name.isEmpty {
      if !isValidSkillName(name) {
        out.append("name '\(name)' must be 1 to 64 lowercase letters, digits and single hyphens")
      }
      if name != folderName {
        out.append("name '\(name)' differs from its folder '\(folderName)'")
      }
    } else {
      out.append("the frontmatter has no name")
    }
    let description = fields["description"] ?? ""
    if description.isEmpty {
      out.append("the frontmatter has no description")
    } else if description.count > descriptionLimit {
      out.append(
        "the description is \(description.count) characters; the limit is \(descriptionLimit)")
    }
    return out
  }

  static func skill(at path: String, source: String, fs: SkillFileSystem) -> Skill {
    let folder = (path as NSString).lastPathComponent
    let fields = fs.contents((path as NSString).appendingPathComponent("SKILL.md"))
      .flatMap(SkillFrontmatter.fields)
    return Skill(
      source: source, name: folder, path: path, description: fields?["description"] ?? "",
      problems: problems(folderName: folder, fields: fields))
  }

  /// The skills in one source, or nil when its folder is missing. The two are
  /// different claims: a missing folder is a repository not cloned or a volume
  /// not mounted, and its links must be left alone rather than removed.
  static func skills(in source: SkillSource, fs: SkillFileSystem) -> [Skill]? {
    guard fs.isDirectory(source.path) else { return nil }
    switch source.kind {
    case .skill:
      return [skill(at: source.path, source: source.name, fs: fs)]
    case .collection:
      return fs.children(source.path).sorted().compactMap { name in
        guard !name.hasPrefix(".") else { return nil }
        let path = (source.path as NSString).appendingPathComponent(name)
        guard fs.isDirectory(path),
          fs.isFile((path as NSString).appendingPathComponent("SKILL.md"))
        else { return nil }
        return skill(at: path, source: source.name, fs: fs)
      }
    }
  }

  /// Every skill of every active source, in source order, and which sources'
  /// folders exist. A retired source contributes no skills but can be
  /// available: its links are still to be recognised and removed.
  static func catalog(
    _ sources: [SkillSource], fs: SkillFileSystem
  ) -> (skills: [Skill], available: Set<String>) {
    var results: [Skill] = []
    var available: Set<String> = []
    for source in sources {
      guard let found = skills(in: source, fs: fs) else { continue }
      available.insert(source.name)
      if !source.retired { results += found }
    }
    return (results, available)
  }

  static func kind(of path: String, fs: SkillFileSystem) -> SkillSource.Kind {
    fs.isFile((path as NSString).appendingPathComponent("SKILL.md")) ? .skill : .collection
  }

  static func defaultSourceName(for path: String, taken: Set<String>) -> String {
    let folder = (path as NSString).lastPathComponent.lowercased()
    var base = String(folder.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
    base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    if base.isEmpty { base = "source" }
    base = String(base.prefix(60))
    guard taken.contains(base) else { return base }
    var number = 2
    while taken.contains("\(base)-\(number)") { number += 1 }
    return "\(base)-\(number)"
  }
}
