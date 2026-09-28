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
    frontmatterShapes()
    validationRules()
    catalogScan()
    sourceNames()

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
      "1025 characters is refused",
      !problems("do-x", ["name": "do-x", "description": String(repeating: "d", count: 1025)])
        .isEmpty)
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
      "a collection lists folders holding SKILL.md, sorted", found.map(\.name) == ["alpha", "beta"])
    check("ids are source-qualified", found.first?.id == "global:alpha")
    check("an invalid skill is listed with its problems", found.last?.isValid == false)
    check(
      "a skill source is one skill",
      SkillCatalog.skills(in: single, fs: fs)?.map(\.id) == ["app-icon:app-icon"])
    check("a missing source is nil, not empty", SkillCatalog.skills(in: missing, fs: fs) == nil)

    let whole = SkillCatalog.catalog([collection, single, missing, retired], fs: fs)
    check(
      "the catalog keeps source order",
      whole.skills.map(\.id) == ["global:alpha", "global:beta", "app-icon:app-icon"])
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
}
