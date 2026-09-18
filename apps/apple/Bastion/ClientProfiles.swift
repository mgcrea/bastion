import Foundation

/// One client, several config files.
///
/// Every other client on the list is one application reading one file, and
/// `ClientWiring.all` can name it as a literal. Claude Code is not: it honours
/// `CLAUDE_CONFIG_DIR`, so one Mac can run several independent profiles, each
/// with its own server list, and Bastion cannot know their names in advance.
///
/// Foundation only, `nonisolated`, and no `UserDefaults` below the reader at the
/// bottom — so `make unit` compiles this file beside `scripts/unit-check.swift`
/// and exercises the rule directly. The rule is the thing worth testing; the
/// directory scan is not. Same split `ToolFacade.clientDefersSchemas` uses, and
/// for the same reason.

// MARK: - The id grammar

/// How a client id spells "the same client, a different config file".
///
/// General rather than Claude's: nothing here knows what a Claude is. The seven
/// ids that exist today carry no separator, so `family(of:)` is the identity
/// function on every one of them and this type changes nothing until a profile
/// row appears.
nonisolated enum ClientIdentity {
  /// `@`, and it had to survive six different carriers to earn that.
  ///
  /// The id is a Keychain `kSecAttrAccount`, the tail of the
  /// `lazyToolsClient.<id>` defaults key, the tail of `MainPane`'s
  /// `client:<id>` raw value, a JSON string in `list_clients` and
  /// `wire_client`, the tail of the dev-only `dev-token-<id>` filename, and a
  /// Codable value in `CallStatsRollup.ClientRow`. `@` is legal in all six.
  ///
  /// The rejected ones, so nobody re-opens this: `:` parses (MainPane splits on
  /// the FIRST colon) but Finder renders it as `/`; `/` breaks the dev-token
  /// filename; `-` cannot be parsed against `lm-studio`; `.` collides with the
  /// separator in the defaults key.
  static let separator: Character = "@"

  /// The client a row is a profile of. Total, and the identity function on an
  /// id with no separator — which is every id that exists today.
  static func family(of id: String) -> String {
    guard let cut = id.firstIndex(of: separator) else { return id }
    return String(id[id.startIndex..<cut])
  }

  /// The profile part, or nil for a client with a single config file.
  ///
  /// `nil` is load-bearing beyond naming: `ClientWiring.rewire` gates on it, so
  /// "has no suffix" is what keeps every existing user's `~/.claude.json` on the
  /// path it has always taken.
  static func suffix(of id: String) -> String? {
    guard let cut = id.firstIndex(of: separator) else { return nil }
    let tail = String(id[id.index(after: cut)...])
    return tail.isEmpty ? nil : tail
  }

  static func compose(family: String, suffix: String) -> String {
    "\(family)\(separator)\(suffix)"
  }

  /// `Profile.isValidName`'s rule, and deliberately the same one.
  ///
  /// A suffix ends up in a Keychain account and in a `UserDefaults` key, which
  /// is the same exposure a profile name has — so the same constraint, rather
  /// than a second one somebody has to learn.
  static func isValidSuffix(_ candidate: String) -> Bool {
    !candidate.isEmpty && candidate.count <= 32
      && candidate.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
  }
}

// MARK: - Claude Code's config directories

nonisolated enum ClaudeProfiles {
  /// The id every Claude Code row reduces to, profile rows included.
  static let family = "claude-code"

  /// `.claude-`, with the dash, and the dash is the whole filter.
  ///
  /// Home directories accumulate `.claude.json`, `.claude.json.backup`,
  /// `.claude.json.bastion-backup` and one per other tool that has ever
  /// rewritten the file. Every one of them begins `.claude.` — a DOT — so a
  /// prefix test on `.claude-` excludes the lot without stat'ing anything, and
  /// `.claude` itself has no dash at all.
  static let directoryPrefix = ".claude-"

  /// What Claude Code calls its MCP config inside a config directory.
  ///
  /// The default profile is the exception that shapes this whole file: its
  /// config dir is `~/.claude` but its config FILE is `~/.claude.json`, outside
  /// it. `~/.claude/.claude.json` does exist on a machine that has run a recent
  /// Claude Code, holding a few hundred bytes of first-run bookkeeping and no
  /// `mcpServers` at all — so any rule shaped "is there a `.claude.json` in
  /// this directory" picks the wrong file for the default profile.
  ///
  /// Which is why the default row never comes through here. It stays the
  /// `home/.claude.json` literal it has always been in `ClientWiring.all`, and
  /// this type only ever answers about the OTHERS.
  static let configName = ".claude.json"

  /// Whether to scan at all. Absent reads as true — detection is the default,
  /// and the toggle is there to turn it off.
  static let detectKey = "detectClaudeConfigDirs"
  /// Config directories named by hand, as paths. For one that lives outside the
  /// home directory, where no scan would find it.
  static let extraDirsKey = "claudeConfigDirs"
  /// Ids Bastion has written at least once, so `rewire` knows which files are
  /// its to keep current. See `ClientWiring.rewire`.
  static let adoptedKey = "claudeProfilesAdopted"

  /// What the caller MEASURED about one candidate directory.
  ///
  /// The pure rule below never touches the disk; this struct is the disk's
  /// testimony, gathered once by `discovered(home:defaults:fileManager:)`. It is
  /// what makes the rule testable against the five real backup filenames and the
  /// `~/.claude` stub without staging a home directory.
  struct Candidate: Equatable {
    let url: URL
    let isDirectory: Bool
    /// Whether `<url>/.claude.json` exists.
    let holdsConfig: Bool
    /// False for a directory the user named by hand, which changes what the
    /// toggle suppresses and whether an empty directory still earns a row.
    let isAutoDetected: Bool
  }

  struct Row: Equatable {
    /// `claude-code@skitrust`.
    let id: String
    let suffix: String
    /// `Claude Code (skitrust)`.
    let displayName: String
    let directory: URL
    var configURL: URL { directory.appendingPathComponent(configName) }
  }

  // MARK: The rule

  /// Whether a name in the home directory is worth stat'ing.
  ///
  /// Pure and cheap on purpose: it runs against every entry in the home
  /// directory, and everything after it costs a syscall.
  static func isCandidateName(_ name: String) -> Bool {
    suffix(forDirectoryNamed: name) != nil
  }

  /// The profile name a directory called `.claude-skitrust` carries.
  static func suffix(forDirectoryNamed name: String) -> String? {
    guard name.hasPrefix(directoryPrefix) else { return nil }
    let tail = String(name.dropFirst(directoryPrefix.count))
    return ClientIdentity.isValidSuffix(tail) ? tail : nil
  }

  /// The suffix for a directory named by hand, which need not be called
  /// `.claude-anything` — it is wherever somebody pointed `CLAUDE_CONFIG_DIR`.
  ///
  /// Derived from the last path component rather than asked for separately: a
  /// second text field whose only job is to name what the path already says is
  /// a field somebody fills in wrong.
  static func suffix(forExplicitDirectory url: URL) -> String? {
    var name = url.standardizedFileURL.lastPathComponent
    if name.hasPrefix(directoryPrefix) {
      name = String(name.dropFirst(directoryPrefix.count))
    } else if name.hasPrefix(".") {
      name = String(name.dropFirst())
    }
    var out = ""
    for character in name.lowercased() {
      if character.isASCII && (character.isLetter || character.isNumber) {
        out.append(character)
      } else if !out.hasSuffix("-") {
        out.append("-")
      }
    }
    while out.hasPrefix("-") { out.removeFirst() }
    while out.hasSuffix("-") { out.removeLast() }
    out = String(out.prefix(32))
    while out.hasSuffix("-") { out.removeLast() }
    return ClientIdentity.isValidSuffix(out) ? out : nil
  }

  /// The whole rule, and the only part of this file worth a test.
  ///
  /// `defaultConfig` is `home/.claude.json` — passed in rather than rebuilt,
  /// because the one thing this must never do is emit a second row over the
  /// file the default Claude Code row already owns. Two rows over one file
  /// means two gateway tokens overwriting each other in it, which is the trap
  /// `docs/clients.md` describes for ChatGPT & Codex.
  static func rows(
    from candidates: [Candidate], autoDetect: Bool, excluding defaultConfig: URL
  ) -> [Row] {
    let defaultFile = defaultConfig.resolvingSymlinksInPath().standardizedFileURL
    // `~/.claude`, reconstructed from the file beside it. Checked as well as the
    // file, because `~/.claude/.claude.json` EXISTS — so a user who names
    // `~/.claude` explicitly would otherwise pass every test below and get a
    // permanently-grey phantom Claude Code pointing at a stub with no servers.
    let defaultDirectory =
      defaultConfig
      .deletingLastPathComponent()
      .appendingPathComponent(".claude")
      .resolvingSymlinksInPath().standardizedFileURL

    var detected: [Row] = []
    var explicit: [Row] = []
    var seenFiles: Set<URL> = [defaultFile]
    var seenIDs: Set<String> = [family]

    for candidate in candidates {
      guard candidate.isDirectory else { continue }
      // An empty directory earns a row only when somebody asked for it by name.
      // Left to the scan, a `~/.claude-old` from a `mv` becomes a client whose
      // Configure writes a `.claude.json` no Claude Code will ever read.
      guard candidate.holdsConfig || !candidate.isAutoDetected else { continue }
      guard autoDetect || !candidate.isAutoDetected else { continue }

      let directory = candidate.url.resolvingSymlinksInPath().standardizedFileURL
      guard directory != defaultDirectory else { continue }
      let configURL =
        directory.appendingPathComponent(configName)
        .resolvingSymlinksInPath().standardizedFileURL
      guard !seenFiles.contains(configURL) else { continue }

      let name =
        candidate.isAutoDetected
        ? suffix(forDirectoryNamed: candidate.url.lastPathComponent)
        : suffix(forExplicitDirectory: candidate.url)
      guard let suffix = name else { continue }
      let id = ClientIdentity.compose(family: family, suffix: suffix)
      guard !seenIDs.contains(id) else { continue }

      seenFiles.insert(configURL)
      seenIDs.insert(id)
      let row = Row(
        id: id, suffix: suffix, displayName: "Claude Code (\(suffix))", directory: directory)
      if candidate.isAutoDetected { detected.append(row) } else { explicit.append(row) }
    }

    // Detected rows sorted, explicit rows in the order they were declared — so
    // the Settings list reads in the order the sidebar does.
    return detected.sorted { $0.suffix < $1.suffix } + explicit
  }

  // MARK: The reader

  /// The impure half: one `readdir`, then the rule.
  ///
  /// Filtered by name before anything is stat'ed, so a home directory with
  /// several hundred entries costs one directory read and a couple of `stat`
  /// calls rather than one per entry.
  static func discovered(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    defaults: UserDefaults = .standard,
    fileManager: FileManager = .default
  ) -> [Row] {
    let autoDetect = defaults.object(forKey: detectKey) as? Bool ?? true
    var candidates: [Candidate] = []

    if autoDetect, let names = try? fileManager.contentsOfDirectory(atPath: home.path) {
      for name in names.sorted() where isCandidateName(name) {
        candidates.append(
          measure(home.appendingPathComponent(name), autoDetected: true, fileManager: fileManager))
      }
    }

    for path in defaults.stringArray(forKey: extraDirsKey) ?? [] {
      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
      let measured = measure(url, autoDetected: false, fileManager: fileManager)
      // A path that is not there is dropped rather than shown as an absent
      // client: `list_clients` would file it under `not_installed` with the note
      // "Bastion can still wire any of them", which is false for a directory
      // whose parent does not exist. The feedback for a typo belongs in
      // Settings, beside the row that has it.
      guard measured.isDirectory else { continue }
      candidates.append(measured)
    }

    return rows(
      from: candidates, autoDetect: autoDetect,
      excluding: home.appendingPathComponent(configName))
  }

  private static func measure(
    _ url: URL, autoDetected: Bool, fileManager: FileManager
  ) -> Candidate {
    var isDirectory: ObjCBool = false
    let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
    return Candidate(
      url: url,
      isDirectory: exists && isDirectory.boolValue,
      holdsConfig: fileManager.fileExists(
        atPath: url.appendingPathComponent(configName).path),
      isAutoDetected: autoDetected)
  }

  // MARK: Adoption

  /// The ids Bastion has written at least once. See `ClientWiring.rewire`.
  static func adopted(_ defaults: UserDefaults = .standard) -> Set<String> {
    Set(defaults.stringArray(forKey: adoptedKey) ?? [])
  }

  static func adopt(_ id: String, _ defaults: UserDefaults = .standard) {
    guard ClientIdentity.suffix(of: id) != nil else { return }
    var ids = defaults.stringArray(forKey: adoptedKey) ?? []
    guard !ids.contains(id) else { return }
    ids.append(id)
    defaults.set(ids, forKey: adoptedKey)
  }
}
