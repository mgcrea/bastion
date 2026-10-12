# Only Bastion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One switch per Claude Code profile that writes `disableClaudeAiConnectors` and an `allowedMcpServers` allowlist (Bastion's endpoint plus the servers already in that profile's `.claude.json`) into the profile's `settings.json`, keeps it current, and reports its state.

**Architecture:** Two Foundation-only files carry everything testable: `ClientSettingsSplice` edits top-level members of a JSON file without re-encoding the rest (the JSON counterpart of `ClientWiringTOML`), and `ClientLockdown` is the policy (the allowlist, the state, which keys to write or remove, the UserDefaults record). `ClientWiring+Lockdown` joins them to the app's clients, `rewire` and `unwire`; a SwiftUI card and an MCP tool expose it.

**Tech Stack:** Swift 6 / SwiftUI / Foundation, standalone `swiftc` check binaries (`make wiring-check`), `xcodebuild` via `make app`.

**Spec:** `docs/superpowers/specs/2026-10-12-only-bastion-design.md`

## Global Constraints

- `ClientSettingsSplice.swift` and `ClientLockdown.swift` import **Foundation only**; `make wiring-check` compiles them beside `ClientWiringMerge.swift`.
- New files in `apps/apple/Bastion/` join the app target automatically (synchronized groups); never edit `project.pbxproj`.
- Keys written: exactly `disableClaudeAiConnectors` (value `true`) and `allowedMcpServers`, in that order. Bastion never reads or writes `deniedMcpServers`.
- Bastion's allowlist entry: `{"serverUrl": "http://127.0.0.1:<port>/s/*"}`, `<port>` from `Gateway.shared.port`.
- UserDefaults key `clientLockdown`: `[client id: [keys Bastion added]]`. Present id = switched on.
- Every write goes through `ClientWiringMerge.write(_ data:to:backupSuffix:expecting:)` with `backupSuffix: "bastion-backup"`.
- Unattended writes only inside `rewire`, after its `autoWires` guard (Debug builds never write unasked).
- A gateway port change takes effect at relaunch, where `migrateKeyScheme` → `rewire` → `refreshLockdowns` runs; no Settings hook is added (the spec’s “a port change in Settings triggers it too” is met by that relaunch).
- The card is hidden under `DemoSeed.isEnabled`, so screenshot goldens do not move.
- Swift style: 2-space indent, `make format-swift` before each commit. Commits: `feat(clients): …`, `docs(clients): …`.

## Review Focus

- A `settings.json` with `}` or `{` or `\"` inside string values: the lexer must not end a member early. Pinned in Task 1 (fixture holds `"a } b { \" c"`).
- CRLF line endings: inserted members must use `\r\n`, and on→off must return the original bytes. Pinned in Task 1.
- A `settings.json` that is a symlink into a dotfiles repo: written through, link kept. Pinned in Task 1.
- Claude Code rewriting `settings.json` between Bastion's read and write: refused, external change kept. Pinned in Task 1.
- A UTF-8 BOM or other leading junk: refused as `notAnObject`, never written. Pinned in Task 1.

---

### Task 1: `ClientSettingsSplice`, a byte-preserving editor for top-level JSON members

**Files:**

- Create: `apps/apple/Bastion/ClientSettingsSplice.swift`
- Modify: `Makefile` (the `wiring-check:` recipe, add the new file)
- Test: `scripts/wiring-check.swift` (new sections, called from `main`)

**Interfaces:**

- Consumes: `ClientWiringMerge.stamp(of:)`, `ClientWiringMerge.settledContents(of:)`, `ClientWiringMerge.write(_ data: Data, to:backupSuffix:expecting:) -> URL?`, `ClientWiringMerge.WriteError.changedUnderneath`.
- Produces:
  - `enum ClientSettingsSplice`
  - `typealias Edit = (key: String, value: Any?)`: `nil` value removes the key.
  - `enum ParseError: LocalizedError, Equatable { case notUTF8, notAnObject, comment(offset: Int), trailingComma(offset: Int), duplicateKey(String), malformed(offset: Int) }`
  - `struct Document { let values: [String: Any]; … }`
  - `static func parse(_ data: Data) throws -> Document`
  - `static func applying(_ edits: [Edit], to data: Data) throws -> Data`
  - `static func rewrite(_ url: URL, backupSuffix: String, edits: ([String: Any]) throws -> [Edit]) throws -> URL?`: stamp, read (a missing file reads as empty), parse, ask `edits` for the changes given the current values, apply, write. Returns the backup URL, `nil` when nothing was written or the file is new.

- [ ] **Step 1: Add the file to the check build**

In `Makefile`, the `wiring-check:` recipe, add one line after `apps/apple/Bastion/ClientWiringTOML.swift \`:

```make
		apps/apple/Bastion/ClientSettingsSplice.swift \
```

- [ ] **Step 2: Write the failing checks**

Append to `scripts/wiring-check.swift`, inside `struct WiringCheck`, before its closing brace:

```swift
  // MARK: - settings.json splice

  /// Shaped like a hand-written Claude Code settings.json: nested objects, an
  /// array, escaped quotes, braces inside strings, non-ASCII, and a trailing
  /// newline.
  static let settingsFixture = """
    {
      "env": { "FOO": "a } b { \\" c", "URL": "https://x.y/z" },
      "permissions": {
        "allow": ["Bash(git status)", "Read(//tmp/**)"]
      },
      "model": "opus",
      "statusLine": {"type": "command", "command": "echo é ✓"}
    }

    """

  static let lockdownEdits: [ClientSettingsSplice.Edit] = [
    ("disableClaudeAiConnectors", true),
    ("allowedMcpServers", [["serverUrl": "http://127.0.0.1:8720/s/*"]]),
  ]

  static func spliced(_ text: String, _ edits: [ClientSettingsSplice.Edit]) -> String? {
    guard let out = try? ClientSettingsSplice.applying(edits, to: Data(text.utf8)) else {
      return nil
    }
    return String(decoding: out, as: UTF8.self)
  }

  static func spliceLeavesEveryOtherByteAlone() {
    print("\nsettings.json: every other byte survives")
    guard let out = spliced(settingsFixture, lockdownEdits) else {
      return check("the fixture splices", false)
    }
    let anchor = settingsFixture.range(of: "\"echo é ✓\"}")!.upperBound
    let head = String(settingsFixture[..<anchor])
    check("everything up to the last value is unchanged", out.hasPrefix(head))
    check("the closing brace and newline are unchanged", out.hasSuffix("\n}\n"))
    check(
      "the members are appended in order, in the file's indentation",
      out.contains(
        "\"echo é ✓\"},\n  \"disableClaudeAiConnectors\": true,\n  \"allowedMcpServers\": [\n"
          + "    {\n      \"serverUrl\": \"http://127.0.0.1:8720/s/*\"\n    }\n  ]\n}"))
    let before = try? ClientSettingsSplice.parse(Data(settingsFixture.utf8)).values
    let after = try? ClientSettingsSplice.parse(Data(out.utf8)).values
    check("the result parses", after != nil)
    for key in ["env", "permissions", "model", "statusLine"] {
      check("'\(key)' is deep-equal after", deepEqual(before?[key], after?[key]))
    }
    check("the new key reads back", deepEqual(after?["disableClaudeAiConnectors"], true))
  }

  static func spliceRoundTrips() {
    print("\nsettings.json: on then off is the original file")
    let on = spliced(settingsFixture, lockdownEdits)
    let offInOrder = on.flatMap {
      spliced($0, [("disableClaudeAiConnectors", nil), ("allowedMcpServers", nil)])
    }
    let offReversed = on.flatMap {
      spliced($0, [("allowedMcpServers", nil), ("disableClaudeAiConnectors", nil)])
    }
    check("removing in write order restores every byte", offInOrder == settingsFixture)
    check("removing in reverse order restores every byte", offReversed == settingsFixture)
    check("applying the same edits twice is idempotent", on.flatMap { spliced($0, lockdownEdits) } == on)
    check("removing an absent key changes nothing", spliced(settingsFixture, [("nope", nil)]) == settingsFixture)
  }

  static func spliceReplacesOnlyTheValue() {
    print("\nsettings.json: replacing a value touches only its span")
    let out = spliced(settingsFixture, [("model", "sonnet")])
    check(
      "only the value moved",
      out == settingsFixture.replacingOccurrences(of: "\"opus\"", with: "\"sonnet\""))
  }

  static func spliceIntoEmptyShapes() {
    print("\nsettings.json: empty file, empty object, one line")
    check(
      "an empty file becomes an object holding the key",
      spliced("", [("disableClaudeAiConnectors", true)])
        == "{\n  \"disableClaudeAiConnectors\": true\n}\n")
    check(
      "a whitespace-only file does too",
      spliced("  \n", [("disableClaudeAiConnectors", true)])
        == "{\n  \"disableClaudeAiConnectors\": true\n}\n")
    let filled = spliced("{}", lockdownEdits)
    check("{} gains both keys", filled?.contains("\"allowedMcpServers\"") == true)
    check(
      "and loses them again to exactly {}",
      filled.flatMap {
        spliced($0, [("disableClaudeAiConnectors", nil), ("allowedMcpServers", nil)])
      } == "{}")
    check(
      "a one-line object stays on one line",
      spliced("{\"a\":1}", [("disableClaudeAiConnectors", true)])
        == "{\"a\":1, \"disableClaudeAiConnectors\": true}")
    check(
      "a one-line round trip is exact",
      spliced("{\"a\":1}", lockdownEdits).flatMap {
        spliced($0, [("disableClaudeAiConnectors", nil), ("allowedMcpServers", nil)])
      } == "{\"a\":1}")
  }

  static func spliceKeepsCRLF() {
    print("\nsettings.json: CRLF files stay CRLF")
    let crlf = "{\r\n  \"model\": \"opus\"\r\n}\r\n"
    let on = spliced(crlf, lockdownEdits)
    check("inserted lines end in CRLF", on?.contains("\"opus\",\r\n  \"disableClaudeAiConnectors\"") == true)
    check("no bare LF is introduced", on?.replacingOccurrences(of: "\r\n", with: "").contains("\n") == false)
    check(
      "on then off is the original",
      on.flatMap { spliced($0, [("disableClaudeAiConnectors", nil), ("allowedMcpServers", nil)]) }
        == crlf)
  }

  static func spliceRefusesWhatItCannotRoundTrip() {
    print("\nsettings.json: refusals")
    func refusal(_ text: String) -> ClientSettingsSplice.ParseError? {
      do {
        _ = try ClientSettingsSplice.parse(Data(text.utf8))
        return nil
      } catch let error as ClientSettingsSplice.ParseError {
        return error
      } catch {
        return nil
      }
    }
    check("a line comment", refusal("{\n  // hi\n  \"a\": 1\n}") == .comment(offset: 4))
    check(
      "a block comment inside a value",
      { if case .comment = refusal("{\"a\": [1, /* x */ 2]}") { true } else { false } }())
    check("a top-level trailing comma", refusal("{\"a\": 1,\n}") == .trailingComma(offset: 7))
    check("a nested trailing comma", refusal("{\"a\": [1, 2,]}") != nil)
    check("a key set twice", refusal("{\"a\": 1, \"a\": 2}") == .duplicateKey("a"))
    check("a top-level array", refusal("[1]") == .notAnObject)
    check("a byte-order mark", refusal("\u{FEFF}{}") == .notAnObject)
    check("an unterminated string", refusal("{\"a\": \"x}") != nil)
    check("bytes after the object", refusal("{} {}") != nil)
    let notUTF8: ClientSettingsSplice.ParseError? = {
      do {
        _ = try ClientSettingsSplice.parse(Data([0x7B, 0xFF, 0x7D]))
        return nil
      } catch { return error as? ClientSettingsSplice.ParseError }
    }()
    check("invalid UTF-8", notUTF8 == .notUTF8)
  }

  static func spliceRewriteOnDisk() {
    print("\nsettings.json: rewrite on disk")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("splice-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let edits: ([String: Any]) -> [ClientSettingsSplice.Edit] = { _ in lockdownEdits }

    // A refusal never writes, and leaves no backup.
    let commented = dir.appendingPathComponent("commented.json")
    try? Data("{ // x\n}".utf8).write(to: commented)
    let refused = (try? ClientSettingsSplice.rewrite(commented, backupSuffix: "bastion-backup", edits: edits)) == nil
    check("a file with a comment is refused", refused)
    check("and left byte-identical", (try? Data(contentsOf: commented)) == Data("{ // x\n}".utf8))
    check("with no backup", !fm.fileExists(atPath: commented.path + ".bastion-backup"))

    // A missing file is created, with no backup to report.
    let fresh = dir.appendingPathComponent("fresh/settings.json")
    let freshBackup = try? ClientSettingsSplice.rewrite(fresh, backupSuffix: "bastion-backup", edits: edits)
    check("a missing file is created", fm.fileExists(atPath: fresh.path))
    check("with no backup", freshBackup == nil)

    // An existing file is backed up once; an identical second pass writes nothing.
    let existing = dir.appendingPathComponent("settings.json")
    try? Data(settingsFixture.utf8).write(to: existing)
    let first = try? ClientSettingsSplice.rewrite(existing, backupSuffix: "bastion-backup", edits: edits)
    check("the first write leaves a backup", first != nil)
    check("holding the original", first.flatMap { try? Data(contentsOf: $0) } == Data(settingsFixture.utf8))
    try? fm.removeItem(at: first ?? existing.appendingPathExtension("bastion-backup"))
    let second = try? ClientSettingsSplice.rewrite(existing, backupSuffix: "bastion-backup", edits: edits)
    check("an identical second pass writes nothing", second == nil)
    check("and makes no new backup", !fm.fileExists(atPath: existing.path + ".bastion-backup"))
    let litter = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0.hasSuffix(".tmp") } ?? []
    check("no temp files are left behind", litter.isEmpty)

    // A symlinked settings.json is written through; the link stays a link.
    let target = dir.appendingPathComponent("dotfiles-settings.json")
    let link = dir.appendingPathComponent("linked/settings.json")
    try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data("{}\n".utf8).write(to: target)
    try? fm.createSymbolicLink(at: link, withDestinationURL: target)
    _ = try? ClientSettingsSplice.rewrite(link, backupSuffix: "bastion-backup", edits: edits)
    let isLink = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
    check("the link is still a link", isLink)
    check(
      "and its target was written",
      (try? String(contentsOf: target, encoding: .utf8))?.contains("allowedMcpServers") == true)

    // Claude Code writing between the read and the write: refused, its change kept.
    let racy = dir.appendingPathComponent("racy.json")
    try? Data("{\"a\": 1}".utf8).write(to: racy)
    var raced = false
    do {
      try ClientSettingsSplice.rewrite(racy, backupSuffix: "bastion-backup") { _ in
        try? Data("{\"a\": 1, \"b\": 2}".utf8).write(to: racy)
        return lockdownEdits
      }
    } catch ClientWiringMerge.WriteError.changedUnderneath(_) {
      raced = true
    } catch {}
    check("a write over a file that moved is refused", raced)
    check(
      "and the other writer's change survives",
      (try? String(contentsOf: racy, encoding: .utf8)) == "{\"a\": 1, \"b\": 2}")
  }
```

In `main()`, after the last `toml…()` call in the fixture list, add:

```swift
    spliceLeavesEveryOtherByteAlone()
    spliceRoundTrips()
    spliceReplacesOnlyTheValue()
    spliceIntoEmptyShapes()
    spliceKeepsCRLF()
    spliceRefusesWhatItCannotRoundTrip()
    spliceRewriteOnDisk()
```

- [ ] **Step 3: Run the check to verify it fails**

Run: `make wiring-check`
Expected: compile error, `cannot find 'ClientSettingsSplice' in scope` (or "no such file" for the new Makefile line).

- [ ] **Step 4: Write `ClientSettingsSplice.swift`**

Create `apps/apple/Bastion/ClientSettingsSplice.swift`:

```swift
import Foundation

/// Editing top-level members of a Claude Code `settings.json` without
/// re-encoding the rest of it.
///
/// Foundation only, for the same reason as `ClientWiringMerge`: `make
/// wiring-check` compiles this file beside `scripts/wiring-check.swift` and
/// runs the result.
///
/// `settings.json` is hand-edited, and `ClientWiringMerge.write(_ root:)`
/// re-serialises with sorted keys and its own indentation. That is fine for
/// `.claude.json`, which Claude Code writes itself, and not for a file somebody
/// arranged by hand. So this does for top-level JSON members what
/// `ClientWiringTOML` does for `[mcp_servers]` tables: the lexer finds where
/// each member starts and ends, an edit replaces only the spans it names, and
/// every other byte is quoted back verbatim. On followed by off returns the
/// original file.
///
/// It refuses what it cannot round-trip — a comment, a trailing comma, a key
/// set twice, anything that is not one JSON object — rather than guess, and
/// every write path begins with this read, so a refusal never writes.
enum ClientSettingsSplice {
  /// A key and its new value; a `nil` value removes the key.
  typealias Edit = (key: String, value: Any?)

  enum ParseError: LocalizedError, Equatable {
    case notUTF8
    case notAnObject
    case comment(offset: Int)
    case trailingComma(offset: Int)
    case duplicateKey(String)
    case malformed(offset: Int)

    var errorDescription: String? {
      switch self {
      case .notUTF8:
        return "settings.json is not UTF-8; leaving it alone"
      case .notAnObject:
        return "settings.json is not one JSON object; leaving it alone"
      case .comment(let offset):
        return "settings.json has a comment at byte \(offset), which Bastion would not keep; "
          + "leaving it alone"
      case .trailingComma(let offset):
        return "settings.json has a trailing comma at byte \(offset); leaving it alone"
      case .duplicateKey(let key):
        return "settings.json sets '\(key)' twice; leaving it alone"
      case .malformed(let offset):
        return "settings.json is not valid JSON near byte \(offset); leaving it alone"
      }
    }
  }

  /// One top-level `"key": value`, as byte offsets into the file.
  struct Member: Equatable {
    let key: String
    /// The key's opening quote.
    let start: Int
    let valueStart: Int
    /// One past the value's last byte.
    let valueEnd: Int
  }

  struct Document {
    let bytes: [UInt8]
    let members: [Member]
    /// The top-level braces; nil for a file holding nothing but whitespace.
    let braces: (open: Int, close: Int)?
    /// The first member's indentation. Nil when it shares a line with `{`,
    /// which is a one-line file and gets one-line edits.
    let indent: String?
    /// `\r\n` if the file uses it anywhere, else `\n`.
    let newline: String
    let values: [String: Any]
  }

  // MARK: - Reading

  static func parse(_ data: Data) throws -> Document {
    guard String(data: data, encoding: .utf8) != nil else { throw ParseError.notUTF8 }
    let b = [UInt8](data)
    let newline = data.range(of: Data("\r\n".utf8)) != nil ? "\r\n" : "\n"
    var i = 0
    try skipSpace(b, &i)
    guard i < b.count else {
      return Document(
        bytes: b, members: [], braces: nil, indent: nil, newline: newline, values: [:])
    }
    guard b[i] == UInt8(ascii: "{") else { throw ParseError.notAnObject }
    let open = i
    i += 1
    var members: [Member] = []
    var seen: Set<String> = []
    var pendingComma: Int?
    while true {
      try skipSpace(b, &i)
      guard i < b.count else { throw ParseError.malformed(offset: i) }
      if b[i] == UInt8(ascii: "}") {
        if let comma = pendingComma { throw ParseError.trailingComma(offset: comma) }
        break
      }
      guard b[i] == UInt8(ascii: "\"") else { throw ParseError.malformed(offset: i) }
      let start = i
      i = try endOfString(b, from: i)
      guard
        let key = (try? JSONSerialization.jsonObject(
          with: Data(b[start..<i]), options: .fragmentsAllowed)) as? String
      else { throw ParseError.malformed(offset: start) }
      guard seen.insert(key).inserted else { throw ParseError.duplicateKey(key) }
      try skipSpace(b, &i)
      guard i < b.count, b[i] == UInt8(ascii: ":") else { throw ParseError.malformed(offset: i) }
      i += 1
      try skipSpace(b, &i)
      let valueStart = i
      i = try endOfValue(b, from: i)
      members.append(Member(key: key, start: start, valueStart: valueStart, valueEnd: i))
      pendingComma = nil
      try skipSpace(b, &i)
      guard i < b.count else { throw ParseError.malformed(offset: i) }
      if b[i] == UInt8(ascii: ",") {
        pendingComma = i
        i += 1
      } else if b[i] != UInt8(ascii: "}") {
        throw ParseError.malformed(offset: i)
      }
    }
    let close = i
    i += 1
    try skipSpace(b, &i)
    guard i == b.count else { throw ParseError.malformed(offset: i) }
    // The lexer decides extents; Foundation decides validity. A trailing comma
    // or a bad number nested inside a value is caught here.
    guard let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw ParseError.malformed(offset: open)
    }
    return Document(
      bytes: b, members: members, braces: (open, close),
      indent: indent(b, open: open, first: members.first), newline: newline, values: values)
  }

  /// Whitespace, refusing a comment: a `/` can start nothing else between
  /// tokens.
  private static func skipSpace(_ b: [UInt8], _ i: inout Int) throws {
    while i < b.count {
      switch b[i] {
      case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): i += 1
      case UInt8(ascii: "/"): throw ParseError.comment(offset: i)
      default: return
      }
    }
  }

  /// From an opening quote to one past the closing one, stepping over escapes.
  private static func endOfString(_ b: [UInt8], from start: Int) throws -> Int {
    var i = start + 1
    while i < b.count {
      switch b[i] {
      case UInt8(ascii: "\\"): i += 2
      case UInt8(ascii: "\""): return i + 1
      default: i += 1
      }
    }
    throw ParseError.malformed(offset: start)
  }

  /// One past the end of the value starting at `start`. Strings are stepped
  /// over whole, so a brace inside one never counts.
  private static func endOfValue(_ b: [UInt8], from start: Int) throws -> Int {
    guard start < b.count else { throw ParseError.malformed(offset: start) }
    switch b[start] {
    case UInt8(ascii: "\""):
      return try endOfString(b, from: start)
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      var depth = 0
      var i = start
      while i < b.count {
        switch b[i] {
        case UInt8(ascii: "\""):
          i = try endOfString(b, from: i)
          continue
        case UInt8(ascii: "/"):
          throw ParseError.comment(offset: i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
          depth += 1
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          depth -= 1
          if depth == 0 { return i + 1 }
        default:
          break
        }
        i += 1
      }
      throw ParseError.malformed(offset: start)
    default:
      // A number, true, false or null: up to the next delimiter.
      let delimiters: Set<UInt8> = [
        UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"),
        UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "/"),
      ]
      var i = start
      while i < b.count, !delimiters.contains(b[i]) { i += 1 }
      guard i > start else { throw ParseError.malformed(offset: start) }
      return i
    }
  }

  private static func indent(_ b: [UInt8], open: Int, first: Member?) -> String? {
    guard let first else { return "  " }
    var j = first.start
    while j > open, b[j - 1] == UInt8(ascii: " ") || b[j - 1] == UInt8(ascii: "\t") { j -= 1 }
    guard j > open, b[j - 1] == UInt8(ascii: "\n") else { return nil }
    return String(decoding: b[j..<first.start], as: UTF8.self)
  }

  // MARK: - Editing

  /// The edits applied in order, each against a fresh parse of the previous
  /// result.
  static func applying(_ edits: [Edit], to data: Data) throws -> Data {
    var data = data
    for edit in edits { data = Data(try apply(edit, to: parse(data))) }
    return data
  }

  /// A new member is appended after the last one and a removed member takes
  /// its separator with it, chosen so that appending and then removing is the
  /// identity: removing the last member cuts from the previous value's end,
  /// which is exactly the `,<newline><indent>` an append inserted there.
  private static func apply(_ edit: Edit, to doc: Document) throws -> [UInt8] {
    var b = doc.bytes
    let newline = doc.indent == nil ? nil : doc.newline
    let index = doc.members.firstIndex { $0.key == edit.key }
    switch (index, edit.value) {
    case (nil, nil):
      return b
    case (let i?, let value?):
      let member = doc.members[i]
      let rendered = try text(value, indent: doc.indent ?? "", newline: newline)
      b.replaceSubrange(member.valueStart..<member.valueEnd, with: Array(rendered.utf8))
      return b
    case (let i?, nil):
      let member = doc.members[i]
      if doc.members.count == 1, let braces = doc.braces {
        b.replaceSubrange(braces.open...braces.close, with: Array("{}".utf8))
      } else if i == doc.members.count - 1 {
        b.removeSubrange(doc.members[i - 1].valueEnd..<member.valueEnd)
      } else {
        b.removeSubrange(member.start..<doc.members[i + 1].start)
      }
      return b
    case (nil, let value?):
      if let last = doc.members.last {
        let separator = doc.indent.map { "," + doc.newline + $0 } ?? ", "
        let member = try quoted(edit.key) + ": " + text(value, indent: doc.indent ?? "", newline: newline)
        b.insert(contentsOf: Array((separator + member).utf8), at: last.valueEnd)
        return b
      }
      let nl = doc.newline
      let body =
        "{" + nl + "  " + (try quoted(edit.key)) + ": " + (try text(value, indent: "  ", newline: nl))
        + nl + "}"
      guard let braces = doc.braces else { return Array((body + nl).utf8) }
      b.replaceSubrange(braces.open...braces.close, with: Array(body.utf8))
      return b
    }
  }

  /// JSON for a value Bastion writes, laid out like the file: two more spaces
  /// per level than `indent`, `"key": value`, keys sorted. A nil `newline` is
  /// one line, for a file whose members share a line with its braces.
  static func text(_ value: Any, indent: String, newline: String?) throws -> String {
    let inner = indent + "  "
    func list(_ items: [String], _ open: String, _ close: String) -> String {
      guard !items.isEmpty else { return open + close }
      guard let newline else { return open + items.joined(separator: ", ") + close }
      return open + newline + items.map { inner + $0 }.joined(separator: "," + newline) + newline
        + indent + close
    }
    switch value {
    case let array as [Any]:
      return list(try array.map { try text($0, indent: inner, newline: newline) }, "[", "]")
    case let object as [String: Any]:
      return list(
        try object.keys.sorted().map {
          try quoted($0) + ": " + text(object[$0]!, indent: inner, newline: newline)
        }, "{", "}")
    default:
      let data = try JSONSerialization.data(
        withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
      return String(decoding: data, as: UTF8.self)
    }
  }

  static func quoted(_ key: String) throws -> String { try text(key, indent: "", newline: nil) }

  // MARK: - On disk

  /// Read, decide, splice, write: the one path every settings write takes.
  ///
  /// `edits` is handed the file's current values and returns the changes, so
  /// a decision is always made against the bytes the write is conditional on.
  /// A refusal, from the parse or from `edits`, throws before anything is
  /// written. The write itself is `ClientWiringMerge.write`: backup,
  /// temp-and-swap, 0600, nothing when the bytes would not change, and
  /// `changedUnderneath` when the file moved since the read.
  @discardableResult
  static func rewrite(
    _ url: URL, backupSuffix: String, edits: ([String: Any]) throws -> [Edit]
  ) throws -> URL? {
    let stamp = ClientWiringMerge.stamp(of: url)
    let data = stamp == .absent ? Data() : try ClientWiringMerge.settledContents(of: url)
    let document = try parse(data)
    let changes = try edits(document.values)
    guard !changes.isEmpty else { return nil }
    return try ClientWiringMerge.write(
      applying(changes, to: data), to: url, backupSuffix: backupSuffix, expecting: stamp)
  }
}
```

- [ ] **Step 5: Run the check to verify it passes**

Run: `make wiring-check`
Expected: every line `ok`, last line `N/N passed`, exit 0. If `the members are appended in order…` fails, print `out` and compare the indentation of the nested `{`: the array items sit at `indent + "  "` and their members at `indent + "    "`.

- [ ] **Step 6: Format and commit**

```bash
make format-swift
git add Makefile apps/apple/Bastion/ClientSettingsSplice.swift scripts/wiring-check.swift
git commit -m "feat(clients): splice top-level members of settings.json without re-encoding it"
```

---

### Task 2: `ClientLockdown`, the allowlist, its state, and what to write or remove

**Files:**

- Create: `apps/apple/Bastion/ClientLockdown.swift`
- Modify: `Makefile` (the `wiring-check:` recipe)
- Test: `scripts/wiring-check.swift`

**Interfaces:**

- Consumes: `ClientWiringMerge.isOurs(_:)`, `ClientSettingsSplice.Edit`.
- Produces (all on `enum ClientLockdown`):
  - `static let allowedKey = "allowedMcpServers"`, `connectorsKey = "disableClaudeAiConnectors"`, `defaultsKey = "clientLockdown"`, `managedKeys: [String]` (`[connectorsKey, allowedKey]`)
  - `static func bastionPattern(port: Int) -> [String: Any]`, `static func isBastionPattern(_ entry: Any) -> Bool`, `static func isBastionShaped(_ key: String, _ value: Any?) -> Bool`
  - `struct Rule { let entry: [String: Any]; let label: String }`, `struct Plan { let rules: [Rule]; let kept: [String]; let skipped: [String]; var allowed: [[String: Any]] }`
  - `static func plan(claudeConfig root: [String: Any], port: Int) -> Plan`
  - `enum State: Equatable { case off, on, stale(missing: [String], extra: Int), drifted([String]), leftBehind, unreadable(String) }` with `var summary: String` and `var isUnreadable: Bool`
  - `static func state(settings: [String: Any], plan: Plan, enabled: Bool) -> State`
  - `enum Refusal: LocalizedError, Equatable { case collision([String]), drifted([String]) }`
  - `static func enabling(current: [String: Any], plan: Plan, recorded: Set<String>, force: Bool) throws -> (edits: [ClientSettingsSplice.Edit], owned: Set<String>)`
  - `static func disabling(current: [String: Any], recorded: Set<String>, force: Bool) throws -> [ClientSettingsSplice.Edit]`
  - `static func recorded(_ id: String, _ defaults: UserDefaults = .standard) -> Set<String>?`, `static func records(_ defaults: UserDefaults = .standard) -> [String: [String]]`, `static func record(_ id: String, owned: Set<String>, _ defaults: UserDefaults = .standard)`, `static func forget(_ id: String, _ defaults: UserDefaults = .standard)`

- [ ] **Step 1: Add the file to the check build**

In the `wiring-check:` recipe, after the `ClientSettingsSplice.swift` line:

```make
		apps/apple/Bastion/ClientLockdown.swift \
```

- [ ] **Step 2: Write the failing checks**

Append to `struct WiringCheck`:

```swift
  // MARK: - Only Bastion

  static let cupertino = "/Applications/Cupertino.app/Contents/Helpers/cupertino-bridge"

  /// A profile's `.claude.json`: Bastion's own entries (global and project), a
  /// stdio bridge, a local HTTP server, an entry with nothing launchable, the
  /// same URL twice, and a project block holding no servers.
  static let lockdownConfig: [String: Any] = [
    "mcpServers": [
      "prod-stripe": entry(httpReach("stripe")),
      "cupertino-mail": [
        "type": "stdio", "command": cupertino,
        "args": ["--server=mail", "--client=claude-code"], "env": [String: Any](),
      ],
      "armada": ["type": "http", "url": "http://127.0.0.1:8790/mcp"],
      "broken": ["type": "stdio"],
    ],
    "projects": [
      "/r/b": ["mcpServers": ["armada-again": ["type": "http", "url": "http://127.0.0.1:8790/mcp"]]],
      "/r/a": [
        "mcpServers": [
          "local-db": ["command": "npx", "args": ["-y", "db-mcp"]],
          "prod-npm": entry(httpReach("npm")),
        ]
      ],
      "/r/empty": ["allowedTools": [String]()],
    ],
  ]

  static func lockdownPlanIsBastionPlusTheConfig() {
    print("\nOnly Bastion: the allowlist")
    let plan = ClientLockdown.plan(claudeConfig: lockdownConfig, port: 8720)
    check(
      "Bastion's wildcard first, then global, then projects by path, sorted, deduplicated",
      deepEqual(
        plan.allowed,
        [
          ["serverUrl": "http://127.0.0.1:8720/s/*"],
          ["serverUrl": "http://127.0.0.1:8790/mcp"],
          ["serverCommand": [cupertino, "--server=mail", "--client=claude-code"]],
          ["serverCommand": ["npx", "-y", "db-mcp"]],
        ]))
    check("labels name where each rule came from", plan.rules.map(\.label) == ["Bastion", "armada", "cupertino-mail", "local-db"])
    check("every kept key is listed, duplicates included", plan.kept == ["armada", "cupertino-mail", "local-db", "armada-again"])
    check("an entry with no url or command is skipped and named", plan.skipped == ["broken"])
    check("Bastion's own entries are never listed one by one", !plan.kept.contains("prod-stripe") && !plan.kept.contains("prod-npm"))
    check(
      "an empty config is Bastion alone",
      deepEqual(ClientLockdown.plan(claudeConfig: [:], port: 9000).allowed, [["serverUrl": "http://127.0.0.1:9000/s/*"]]))
  }

  static func lockdownRecognisesItsOwnPattern() {
    print("\nOnly Bastion: recognising Bastion's entry")
    func ours(_ url: String) -> Bool { ClientLockdown.isBastionPattern(["serverUrl": url]) }
    check("127.0.0.1", ours("http://127.0.0.1:8720/s/*"))
    check("localhost, another port", ours("http://localhost:1/s/*"))
    check("[::1]", ours("http://[::1]:8720/s/*"))
    check("not one endpoint", !ours("http://127.0.0.1:8720/s/prod/x"))
    check("not https", !ours("https://127.0.0.1:8720/s/*"))
    check("not another host", !ours("http://10.0.0.1:8720/s/*"))
    check("not a command entry", !ClientLockdown.isBastionPattern(["serverCommand": ["x"]]))
  }

  static func lockdownStateTable() {
    print("\nOnly Bastion: state")
    let plan = ClientLockdown.plan(claudeConfig: lockdownConfig, port: 8720)
    let on: [String: Any] = ["disableClaudeAiConnectors": true, "allowedMcpServers": plan.allowed]
    func state(_ settings: [String: Any], enabled: Bool = true) -> ClientLockdown.State {
      ClientLockdown.state(settings: settings, plan: plan, enabled: enabled)
    }
    check("nothing, switched off: off", state([:], enabled: false) == .off)
    check(
      "our wildcard, switched off: left behind",
      state(["allowedMcpServers": [["serverUrl": "http://127.0.0.1:9999/s/*"]]], enabled: false) == .leftBehind)
    check("exactly the plan: on", state(on) == .on)
    check(
      "the plan in another order: still on",
      state(["disableClaudeAiConnectors": true, "allowedMcpServers": Array(plan.allowed.reversed())]) == .on)
    check(
      "a server missing: stale, named",
      state(["disableClaudeAiConnectors": true, "allowedMcpServers": Array(plan.allowed.dropLast())])
        == .stale(missing: ["local-db"], extra: 0))
    var moved = plan.allowed
    moved[0] = ["serverUrl": "http://127.0.0.1:9000/s/*"]
    check(
      "the port moved: stale, Bastion named",
      state(["disableClaudeAiConnectors": true, "allowedMcpServers": moved]) == .stale(missing: ["Bastion"], extra: 1))
    check(
      "a server since removed: stale, counted",
      state(["disableClaudeAiConnectors": true, "allowedMcpServers": plan.allowed + [["serverUrl": "https://gone"]]])
        == .stale(missing: [], extra: 1))
    check(
      "connectors switched back on: drifted",
      state(["disableClaudeAiConnectors": false, "allowedMcpServers": plan.allowed]) == .drifted(["disableClaudeAiConnectors"]))
    check(
      "our wildcard edited out: drifted",
      state(["disableClaudeAiConnectors": true, "allowedMcpServers": [["serverUrl": "http://x"]]]) == .drifted(["allowedMcpServers"]))
    check("both gone: drifted, both named", state([:]) == .drifted(["disableClaudeAiConnectors", "allowedMcpServers"]))
    check("stale reads as a sentence", ClientLockdown.State.stale(missing: ["local-db"], extra: 0).summary == "stale — local-db not allowed")
    check("on reads as on", ClientLockdown.State.on.summary == "on")
  }

  static func lockdownEnablingAndDisabling() {
    print("\nOnly Bastion: what is written and removed")
    let plan = ClientLockdown.plan(claudeConfig: lockdownConfig, port: 8720)
    func keys(_ edits: [ClientSettingsSplice.Edit]) -> [String] { edits.map(\.key) }
    func enabling(_ current: [String: Any], recorded: Set<String> = [], force: Bool = false)
      -> Result<(edits: [ClientSettingsSplice.Edit], owned: Set<String>), ClientLockdown.Refusal>
    {
      do {
        return .success(try ClientLockdown.enabling(current: current, plan: plan, recorded: recorded, force: force))
      } catch let refusal as ClientLockdown.Refusal {
        return .failure(refusal)
      } catch { fatalError("\(error)") }
    }

    let fresh = try? enabling([:]).get()
    check("an empty file gets both keys, in order", fresh.map { keys($0.edits) } == ["disableClaudeAiConnectors", "allowedMcpServers"])
    check("and Bastion owns both", fresh?.owned == ["disableClaudeAiConnectors", "allowedMcpServers"])

    let handSet = try? enabling(["disableClaudeAiConnectors": true]).get()
    check("a hand-set true is adopted, not rewritten", handSet.map { keys($0.edits) } == ["allowedMcpServers"])
    check("and not recorded, so it outlives the switch", handSet?.owned == ["allowedMcpServers"])

    let foreignList: [String: Any] = ["allowedMcpServers": [["serverName": "mine"]]]
    check("a hand-written allowlist is a collision", (try? enabling(foreignList).get()) == nil)
    if case .failure(let refusal) = enabling(foreignList) {
      check("naming the key", refusal == .collision(["allowedMcpServers"]))
    }
    check("force takes it over and records it", (try? enabling(foreignList, force: true).get())?.owned.contains("allowedMcpServers") == true)
    check("a hand-set false is a collision", (try? enabling(["disableClaudeAiConnectors": false]).get()) == nil)

    let stale: [String: Any] = [
      "disableClaudeAiConnectors": true,
      "allowedMcpServers": [["serverUrl": "http://127.0.0.1:8720/s/*"]],
    ]
    let refreshed = try? enabling(stale, recorded: ["disableClaudeAiConnectors", "allowedMcpServers"]).get()
    check("a stale list of ours is rewritten without force", refreshed.map { keys($0.edits) } == ["allowedMcpServers"])
    check("keeping the record", refreshed?.owned == ["disableClaudeAiConnectors", "allowedMcpServers"])
    let current: [String: Any] = ["disableClaudeAiConnectors": true, "allowedMcpServers": plan.allowed]
    check("a current file needs no edits", (try? enabling(current).get())?.edits.isEmpty == true)

    let both: Set<String> = ["disableClaudeAiConnectors", "allowedMcpServers"]
    check("off removes both recorded keys", (try? ClientLockdown.disabling(current: current, recorded: both, force: false)).map(keys) == ["disableClaudeAiConnectors", "allowedMcpServers"])
    check("an unrecorded key stays", (try? ClientLockdown.disabling(current: current, recorded: ["allowedMcpServers"], force: false)).map(keys) == ["allowedMcpServers"])
    let edited: [String: Any] = ["disableClaudeAiConnectors": false, "allowedMcpServers": plan.allowed]
    var refused: ClientLockdown.Refusal?
    do { _ = try ClientLockdown.disabling(current: edited, recorded: both, force: false) } catch let r as ClientLockdown.Refusal { refused = r } catch {}
    check("a recorded key edited by hand refuses off", refused == .drifted(["disableClaudeAiConnectors"]))
    check("force removes it anyway", (try? ClientLockdown.disabling(current: edited, recorded: both, force: true)).map(keys) == ["disableClaudeAiConnectors", "allowedMcpServers"])
    check("a recorded key already gone is skipped", (try? ClientLockdown.disabling(current: [:], recorded: both, force: false))?.isEmpty == true)
  }

  static func lockdownRecordRoundTrips() {
    print("\nOnly Bastion: the record")
    let suite = "wiring-check-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return check("a scratch defaults suite", false) }
    defer { defaults.removePersistentDomain(forName: suite) }
    check("nothing recorded reads as switched off", ClientLockdown.recorded("claude-code", defaults) == nil)
    ClientLockdown.record("claude-code", owned: [], defaults)
    check("an empty record still reads as switched on", ClientLockdown.recorded("claude-code", defaults) == [])
    ClientLockdown.record("claude-code@x", owned: ["allowedMcpServers"], defaults)
    check("each id keeps its own keys", ClientLockdown.recorded("claude-code@x", defaults) == ["allowedMcpServers"])
    ClientLockdown.forget("claude-code", defaults)
    check("forget removes one id", ClientLockdown.recorded("claude-code", defaults) == nil && ClientLockdown.recorded("claude-code@x", defaults) != nil)
  }

  static func lockdownSplicesIntoARealShape() {
    print("\nOnly Bastion: through the splice")
    let plan = ClientLockdown.plan(claudeConfig: lockdownConfig, port: 8720)
    let data = Data(settingsFixture.utf8)
    guard let doc = try? ClientSettingsSplice.parse(data),
      let on = try? ClientLockdown.enabling(current: doc.values, plan: plan, recorded: [], force: false),
      let written = try? ClientSettingsSplice.applying(on.edits, to: data),
      let after = try? ClientSettingsSplice.parse(written)
    else { return check("enable splices into the fixture", false) }
    check("the result is on", ClientLockdown.state(settings: after.values, plan: plan, enabled: true) == .on)
    guard let off = try? ClientLockdown.disabling(current: after.values, recorded: on.owned, force: false),
      let restored = try? ClientSettingsSplice.applying(off, to: written)
    else { return check("disable splices back out", false) }
    check("on then off is the original file", restored == data)
  }
```

In `main()`, after the splice calls from Task 1:

```swift
    lockdownPlanIsBastionPlusTheConfig()
    lockdownRecognisesItsOwnPattern()
    lockdownStateTable()
    lockdownEnablingAndDisabling()
    lockdownRecordRoundTrips()
    lockdownSplicesIntoARealShape()
```

- [ ] **Step 3: Run the check to verify it fails**

Run: `make wiring-check`
Expected: compile error, `cannot find 'ClientLockdown' in scope`.

- [ ] **Step 4: Write `ClientLockdown.swift`**

Create `apps/apple/Bastion/ClientLockdown.swift`:

```swift
import Foundation

/// Only Bastion: what goes into a Claude Code profile's `settings.json`, what
/// state that file is in, and which keys are Bastion's to take back out.
///
/// Policy only, and Foundation only, so `make wiring-check` runs it against
/// fixtures. `ClientWiring+Lockdown` supplies the files and the clients;
/// `ClientSettingsSplice` does the editing. See the "Only Bastion" section of
/// `docs/clients.md`.
///
/// Hygiene rather than a boundary: user-scope `allowedMcpServers` merges with
/// every other settings scope, so a project's settings can widen it.
enum ClientLockdown {
  static let allowedKey = "allowedMcpServers"
  static let connectorsKey = "disableClaudeAiConnectors"
  /// `[client id: [keys Bastion added]]`. An id present, even with an empty
  /// list, is the switch on.
  static let defaultsKey = "clientLockdown"
  /// Written in this order.
  static let managedKeys = [connectorsKey, allowedKey]

  // MARK: - The allowlist

  static func bastionPattern(port: Int) -> [String: Any] {
    ["serverUrl": "http://127.0.0.1:\(port)/s/*"]
  }

  /// Bastion's wildcard on any loopback spelling and any port. Any port on
  /// purpose: a list written before the port changed is stale, not foreign.
  static func isBastionPattern(_ entry: Any) -> Bool {
    guard let url = (entry as? [String: Any])?["serverUrl"] as? String else { return false }
    return url.range(
      of: #"^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]+/s/\*$"#, options: .regularExpression)
      != nil
  }

  /// Whether a value of one of the two keys is the shape Bastion writes.
  static func isBastionShaped(_ key: String, _ value: Any?) -> Bool {
    switch key {
    case connectorsKey: return (value as? Bool) == true
    case allowedKey: return (value as? [Any])?.contains(where: isBastionPattern) == true
    default: return false
    }
  }

  struct Rule {
    let entry: [String: Any]
    /// "Bastion", or the first config key the rule came from.
    let label: String
  }

  struct Plan {
    let rules: [Rule]
    /// Every config key a rule was made for, duplicates included.
    let kept: [String]
    /// Entries with neither a url nor a command, which Claude Code could not
    /// launch either.
    let skipped: [String]
    var allowed: [[String: Any]] { rules.map(\.entry) }
  }

  /// Bastion's wildcard, then one exact rule per server in the profile's
  /// `.claude.json` that Bastion did not write: global first, then each project
  /// folder in path order, keys sorted within each, duplicates collapsed.
  static func plan(claudeConfig root: [String: Any], port: Int) -> Plan {
    var rules = [Rule(entry: bastionPattern(port: port), label: "Bastion")]
    var seen: Set<String> = [canonical(rules[0].entry)]
    var kept: [String] = []
    var skipped: [String] = []
    var blocks = [root["mcpServers"] as? [String: Any] ?? [:]]
    if let projects = root["projects"] as? [String: Any] {
      for folder in projects.keys.sorted() {
        if let servers = (projects[folder] as? [String: Any])?["mcpServers"] as? [String: Any] {
          blocks.append(servers)
        }
      }
    }
    for servers in blocks {
      for key in servers.keys.sorted() {
        let entry = servers[key]
        if ClientWiringMerge.isOurs(entry) { continue }
        guard let entry = entry as? [String: Any], let rule = rule(for: entry) else {
          if !skipped.contains(key) { skipped.append(key) }
          continue
        }
        if seen.insert(canonical(rule)).inserted { rules.append(Rule(entry: rule, label: key)) }
        kept.append(key)
      }
    }
    return Plan(rules: rules, kept: kept, skipped: skipped)
  }

  /// An exact `serverUrl` for a server with a URL, an exact `serverCommand`
  /// (command and args, never env) for one with a command.
  private static func rule(for entry: [String: Any]) -> [String: Any]? {
    if let url = entry["url"] as? String { return ["serverUrl": url] }
    if let command = entry["command"] as? String {
      return ["serverCommand": [command] + (entry["args"] as? [String] ?? [])]
    }
    return nil
  }

  static func canonical(_ value: Any) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    else { return "" }
    return String(decoding: data, as: UTF8.self)
  }

  // MARK: - State

  enum State: Equatable {
    case off
    case on
    /// Ours, but the config gained a server (`missing`) or lost one (`extra`),
    /// or the port moved.
    case stale(missing: [String], extra: Int)
    /// Switched on, and these keys are no longer the shape Bastion writes.
    case drifted([String])
    /// Switched off, and the file still holds Bastion's wildcard.
    case leftBehind
    case unreadable(String)

    var summary: String {
      switch self {
      case .off: return "off"
      case .on: return "on"
      case .stale(let missing, _) where !missing.isEmpty:
        let shown = missing.prefix(4).joined(separator: ", ")
        let more = missing.count > 4 ? " and \(missing.count - 4) more" : ""
        return "stale — \(shown)\(more) not allowed"
      case .stale(_, let extra):
        return "stale — allows \(extra) server\(extra == 1 ? "" : "s") no longer configured"
      case .drifted(let keys):
        return "drifted — \(keys.joined(separator: ", ")) edited by hand"
      case .leftBehind:
        return "left behind — Bastion's allowlist is still in settings.json"
      case .unreadable(let why):
        return "unreadable — \(why)"
      }
    }

    var isUnreadable: Bool {
      if case .unreadable = self { return true }
      return false
    }
  }

  static func state(settings: [String: Any], plan: Plan, enabled: Bool) -> State {
    let allowed = settings[allowedKey]
    let ours = isBastionShaped(allowedKey, allowed)
    guard enabled else { return ours ? .leftBehind : .off }
    let drifted = managedKeys.filter { !isBastionShaped($0, settings[$0]) }
    if !drifted.isEmpty { return .drifted(drifted) }
    let current = Set((allowed as? [Any] ?? []).map(canonical))
    let wanted = plan.rules.map { canonical($0.entry) }
    let missing = zip(plan.rules, wanted).filter { !current.contains($0.1) }.map(\.0.label)
    let extra = current.subtracting(wanted).count
    return missing.isEmpty && extra == 0 ? .on : .stale(missing: missing, extra: extra)
  }

  // MARK: - Writing and removing

  enum Refusal: LocalizedError, Equatable {
    /// Keys the file already sets to something Bastion did not write.
    case collision([String])
    /// Keys Bastion wrote that were edited since.
    case drifted([String])

    var errorDescription: String? {
      switch self {
      case .collision(let keys):
        return "settings.json already sets \(keys.joined(separator: " and ")) to something "
          + "Bastion did not write. Replacing it keeps the old value in settings.json.bastion-backup."
      case .drifted(let keys):
        return "\(keys.joined(separator: " and ")) in settings.json was edited after Bastion "
          + "wrote it. Removing it would drop that edit."
      }
    }
  }

  /// The edits that turn the switch on or bring it current, and the keys
  /// Bastion owns afterwards.
  ///
  /// A key already holding exactly the wanted value is adopted, not recorded,
  /// so it outlives the switch. An allowlist of Bastion's shape is Bastion's
  /// (stale, or left behind) and is rewritten without `force`. Anything else
  /// already there is a collision unless `force`.
  static func enabling(
    current: [String: Any], plan: Plan, recorded: Set<String>, force: Bool
  ) throws -> (edits: [ClientSettingsSplice.Edit], owned: Set<String>) {
    let wanted: [(String, Any)] = [(connectorsKey, true), (allowedKey, plan.allowed)]
    var edits: [ClientSettingsSplice.Edit] = []
    var owned = recorded
    var collisions: [String] = []
    for (key, value) in wanted {
      guard let existing = current[key] else {
        edits.append((key, value))
        owned.insert(key)
        continue
      }
      if canonical(existing) == canonical(value) { continue }
      if (key == allowedKey && isBastionShaped(key, existing)) || force {
        edits.append((key, value))
        owned.insert(key)
        continue
      }
      collisions.append(key)
    }
    if !collisions.isEmpty { throw Refusal.collision(collisions) }
    return (edits, owned)
  }

  /// The edits that turn the switch off: each recorded key still in Bastion's
  /// shape is removed; one edited out of it refuses unless `force`.
  static func disabling(
    current: [String: Any], recorded: Set<String>, force: Bool
  ) throws -> [ClientSettingsSplice.Edit] {
    var edits: [ClientSettingsSplice.Edit] = []
    var drifted: [String] = []
    for key in managedKeys where recorded.contains(key) {
      guard let existing = current[key] else { continue }
      if isBastionShaped(key, existing) || force {
        edits.append((key, nil))
      } else {
        drifted.append(key)
      }
    }
    if !drifted.isEmpty { throw Refusal.drifted(drifted) }
    return edits
  }

  // MARK: - The record

  static func records(_ defaults: UserDefaults = .standard) -> [String: [String]] {
    defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
  }

  /// The keys Bastion added for this client, or nil when the switch is off.
  static func recorded(_ id: String, _ defaults: UserDefaults = .standard) -> Set<String>? {
    records(defaults)[id].map(Set.init)
  }

  static func record(_ id: String, owned: Set<String>, _ defaults: UserDefaults = .standard) {
    var all = records(defaults)
    all[id] = managedKeys.filter(owned.contains)
    defaults.set(all, forKey: defaultsKey)
  }

  static func forget(_ id: String, _ defaults: UserDefaults = .standard) {
    var all = records(defaults)
    all[id] = nil
    defaults.set(all, forKey: defaultsKey)
  }
}
```

- [ ] **Step 5: Run the check to verify it passes**

Run: `make wiring-check`
Expected: all `ok`, exit 0.

- [ ] **Step 6: Format and commit**

```bash
make format-swift
git add Makefile apps/apple/Bastion/ClientLockdown.swift scripts/wiring-check.swift
git commit -m "feat(clients): decide a Claude Code profile's MCP allowlist and its state"
```

---

### Task 3: Join it to the clients: settings path, read, write, `rewire`, `unwire`

**Files:**

- Create: `apps/apple/Bastion/ClientWiring+Lockdown.swift`
- Modify: `apps/apple/Bastion/ClientWiring.swift`: `retryingIfChanged` (line ~622) loses `private`; `unwire(_:)` (line ~924) turns the switch off first; `rewire(retiring:)` (line ~814) refreshes lockdowns after its wiring loop.

**Interfaces:**

- Consumes: everything from Tasks 1 and 2; `ClientWiring.Client`, `ClientWiring.all`, `ClientWiring.hasConfig(_:)`, `ClientIdentity.suffix(of:)`, `ClaudeProfiles.family`, `Gateway.shared.port` (`UInt16`), `ClientConfigRevision.shared.bump()`, `hostLog(_:_:_:)`.
- Produces:
  - `static func supportsLockdown(_ client: Client) -> Bool`
  - `static func settingsURL(for client: Client) -> URL?`
  - `struct Lockdown { let state: ClientLockdown.State; let plan: ClientLockdown.Plan?; let settingsURL: URL }`
  - `static func lockdown(of client: Client) -> Lockdown?`
  - `@discardableResult static func setLockdown(_ client: Client, on: Bool, force: Bool = false) throws -> URL?`
  - `static func refreshLockdowns()`
  - `enum LockdownError: LocalizedError { case unsupported(String) }`

- [ ] **Step 1: Widen `retryingIfChanged`**

In `ClientWiring.swift`, change

```swift
  private static func retryingIfChanged<T>(_ url: URL, _ body: () throws -> T) throws -> T {
```

to

```swift
  static func retryingIfChanged<T>(_ url: URL, _ body: () throws -> T) throws -> T {
```

- [ ] **Step 2: Write `ClientWiring+Lockdown.swift`**

```swift
import Foundation

/// Only Bastion for the Claude Code rows: where each profile's `settings.json`
/// is, what state it is in, and the one path that writes it. The policy is
/// `ClientLockdown`; the editing is `ClientSettingsSplice`.
extension ClientWiring {
  enum LockdownError: LocalizedError {
    case unsupported(String)

    var errorDescription: String? {
      switch self {
      case .unsupported(let name):
        return "\(name) is not a Claude Code profile. Only Bastion writes Claude Code's "
          + "settings.json and nothing else."
      }
    }
  }

  /// Claude Code and its config directories, and nothing else: no other client
  /// has a setting that filters MCP servers by source.
  static func supportsLockdown(_ client: Client) -> Bool {
    client.family == ClaudeProfiles.family && client.format == .json
  }

  /// `<config dir>/settings.json`.
  ///
  /// The default profile is the asymmetry `ClaudeProfiles.configName` warns
  /// about, the other way round: its `.claude.json` sits OUTSIDE `~/.claude`,
  /// its `settings.json` INSIDE. A profile row's config file is already inside
  /// its directory, so the two sit side by side.
  static func settingsURL(for client: Client) -> URL? {
    guard supportsLockdown(client) else { return nil }
    let directory =
      ClientIdentity.suffix(of: client.id) == nil
      ? client.configURL.deletingLastPathComponent().appendingPathComponent(".claude")
      : client.configURL.deletingLastPathComponent()
    return directory.appendingPathComponent("settings.json")
  }

  struct Lockdown {
    let state: ClientLockdown.State
    /// Nil when either file could not be read.
    let plan: ClientLockdown.Plan?
    let settingsURL: URL
  }

  /// The allowlist this client's `.claude.json` calls for right now.
  static func lockdownPlan(of client: Client) throws -> ClientLockdown.Plan {
    let root = hasConfig(client) ? try ClientWiringMerge.readJSON(client.configURL) : [:]
    return ClientLockdown.plan(claudeConfig: root, port: Int(Gateway.shared.port))
  }

  /// Re-read on every call, like `status(of:)`: both files are Claude Code's.
  static func lockdown(of client: Client) -> Lockdown? {
    guard let url = settingsURL(for: client) else { return nil }
    let enabled = ClientLockdown.recorded(client.id) != nil
    do {
      let plan = try lockdownPlan(of: client)
      let data =
        FileManager.default.fileExists(atPath: url.path)
        ? try ClientWiringMerge.settledContents(of: url) : Data()
      let values = try ClientSettingsSplice.parse(data).values
      return Lockdown(
        state: ClientLockdown.state(settings: values, plan: plan, enabled: enabled), plan: plan,
        settingsURL: url)
    } catch {
      return Lockdown(state: .unreadable(error.localizedDescription), plan: nil, settingsURL: url)
    }
  }

  /// Turn Only Bastion on (or bring it current), or off.
  ///
  /// Refusals are `ClientLockdown.Refusal`, and `force` is the override for
  /// both, as `wire`'s is for a collision. The record is updated only after a
  /// write succeeded, or when there was nothing to write.
  @discardableResult
  static func setLockdown(_ client: Client, on: Bool, force: Bool = false) throws -> URL? {
    guard let url = settingsURL(for: client) else {
      throw LockdownError.unsupported(client.displayName)
    }
    let plan = on ? try lockdownPlan(of: client) : nil
    var owned: Set<String> = []
    let backup = try retryingIfChanged(url) {
      try ClientSettingsSplice.rewrite(url, backupSuffix: "bastion-backup") { current in
        let recorded = ClientLockdown.recorded(client.id)
        if let plan {
          let result = try ClientLockdown.enabling(
            current: current, plan: plan, recorded: recorded ?? [], force: force)
          owned = result.owned
          return result.edits
        }
        // Left behind: no record, so only the allowlist is known to be ours.
        let keys =
          recorded
          ?? (ClientLockdown.isBastionShaped(
            ClientLockdown.allowedKey, current[ClientLockdown.allowedKey])
            ? [ClientLockdown.allowedKey] : [])
        return try ClientLockdown.disabling(current: current, recorded: keys, force: force)
      }
    }
    if on {
      ClientLockdown.record(client.id, owned: owned)
    } else {
      ClientLockdown.forget(client.id)
    }
    ClientConfigRevision.shared.bump()
    hostLog(
      "wiring", .info,
      "\(client.displayName): Only Bastion \(on ? "on" : "off")"
        + (backup.map { " (backup at \($0.lastPathComponent))" } ?? ""))
    return backup
  }

  /// For `rewire`: bring every switched-on profile's allowlist up to date.
  /// Logged, never raised, for the same reason `rewire` is silent.
  static func refreshLockdowns() {
    let records = ClientLockdown.records()
    for client in all where records[client.id] != nil {
      do {
        try setLockdown(client, on: true)
      } catch {
        hostLog(
          "wiring", .error,
          "\(client.displayName): Only Bastion left unchanged — \(error.localizedDescription)")
      }
    }
  }
}
```

- [ ] **Step 3: Hook `rewire`**

In `ClientWiring.swift`, `rewire(retiring:)`, after the closing brace of the `for client in all where client.isInstalled { … }` loop and before the function's closing brace, add:

```swift
    // After the wiring above, so a profile wired this pass is current before
    // its allowlist is. Same gate: a Debug build never gets here.
    refreshLockdowns()
```

- [ ] **Step 4: Hook `unwire`**

Replace

```swift
  @discardableResult
  static func unwire(_ client: Client) throws -> URL? {
    try retryingIfChanged(client.configURL) { try unwireOnce(client) }
  }
```

with

```swift
  @discardableResult
  static func unwire(_ client: Client) throws -> URL? {
    // An allowlist naming a Bastion that is no longer wired would block every
    // server the profile has. A key edited by hand since is no longer ours to
    // remove, so a drifted refusal just drops the record.
    if supportsLockdown(client), ClientLockdown.recorded(client.id) != nil {
      do {
        try setLockdown(client, on: false)
      } catch ClientLockdown.Refusal.drifted(_) {
        ClientLockdown.forget(client.id)
      }
    }
    return try retryingIfChanged(client.configURL) { try unwireOnce(client) }
  }
```

- [ ] **Step 5: Build**

Run: `make app`
Expected: `BUILD SUCCEEDED`, no new `warning:` lines from the three touched files. `make wiring-check` still passes.

- [ ] **Step 6: Format and commit**

```bash
make format-swift
git add apps/apple/Bastion/ClientWiring+Lockdown.swift apps/apple/Bastion/ClientWiring.swift
git commit -m "feat(clients): keep Only Bastion current from rewire, and lift it on unwire"
```

---

### Task 4: MCP: `set_client_lockdown`, and `lockdown` in `list_clients`

**Files:**

- Modify: `apps/apple/Bastion/BuiltinTools.swift`: `ToolError` (line ~23) gains a case; the declarations list (after `unwire_client`, line ~522); the dispatch switch (after `case "unwire_client"`, line ~581); `listClients` row (line ~1150); a new handler after `unwireClient` (line ~1905).

**Interfaces:**

- Consumes: `ClientWiring.supportsLockdown`, `setLockdown`, `lockdown(of:)`, `settingsURL(for:)`, `ClientLockdown.Refusal`.
- Produces: MCP tool `set_client_lockdown { client: string, on: boolean, force?: boolean }` returning `client`, `state`, `settings_path`, `backup?`, `allowed`, `skipped`, `note`; `list_clients` rows for Claude Code gain `lockdown`.

- [ ] **Step 1: Add the refusal case**

In `enum ToolError`, after `case wireRefused(String)`:

```swift
    case lockdownRefused(String)
```

and in its `errorDescription` switch, after the `.wireRefused` case:

```swift
      case .lockdownRefused(let why):
        return "\(why) To do it anyway, call set_client_lockdown again with force: true."
```

- [ ] **Step 2: Declare the tool**

After the `unwire_client` `Declaration(…)`, inside the same array:

```swift
    Declaration(
      "set_client_lockdown", title: "Allow only Bastion",
      "Turn Only Bastion on or off for a Claude Code client. On writes "
        + "disableClaudeAiConnectors and an allowedMcpServers list into that profile's "
        + "settings.json: Bastion's endpoint plus every other server already in its .claude.json, "
        + "so servers added by plugins, claude.ai connectors and a repository's .mcp.json are "
        + "blocked. Only those two keys change and a backup is written first. Hygiene, not a "
        + "security boundary: a project's own settings can widen the list.",
      properties: [
        "client": schema(
          "string", "A Claude Code client id: 'claude-code' or 'claude-code@<name>'."),
        "on": schema(
          "boolean",
          "True to turn it on or bring it up to date, false to remove what Bastion wrote."),
        "force": schema(
          "boolean",
          "Replace values set by hand for those two keys (on), or remove keys edited since "
            + "Bastion wrote them (off). Off by default."),
      ],
      required: ["client", "on"], mutates: true),
```

- [ ] **Step 3: Dispatch it**

After `case "unwire_client": return try unwireClient(arguments)`:

```swift
    case "set_client_lockdown": return try setClientLockdown(arguments)
```

- [ ] **Step 4: Write the handler**

After `unwireClient(_:)`:

```swift
  private static func setClientLockdown(_ arguments: [String: Any]) throws -> Any {
    let id = try string(arguments, "client")
    guard let client = ClientWiring.all.first(where: { $0.id == id }) else {
      throw ToolError.noSuchClient(id: id, known: ClientWiring.all.map(\.id))
    }
    guard ClientWiring.supportsLockdown(client) else {
      throw ToolError.badArgument(
        name: "client", expected: "a Claude Code client id: 'claude-code' or 'claude-code@<name>'")
    }
    guard let on = arguments["on"] as? Bool else { throw ToolError.missingArgument("on") }
    let backup: URL?
    do {
      backup = try ClientWiring.setLockdown(
        client, on: on, force: arguments["force"] as? Bool ?? false)
    } catch let refusal as ClientLockdown.Refusal {
      throw ToolError.lockdownRefused(refusal.localizedDescription)
    }
    let lockdown = ClientWiring.lockdown(of: client)
    var out: [String: Any] = [
      "client": id,
      "state": lockdown?.state.summary ?? "unknown",
      "settings_path": ClientWiring.settingsURL(for: client)?.path ?? "",
    ]
    if let backup { out["backup"] = backup.path }
    if let plan = lockdown?.plan {
      out["allowed"] = plan.kept
      out["skipped"] = plan.skipped
    }
    out["note"] = "Start a new Claude Code session to apply. deniedMcpServers is never touched."
    return out
  }
```

- [ ] **Step 5: Report it in `list_clients`**

In `listClients`, after `if let caveat = client.caveat { row["note"] = caveat }`:

```swift
      // Claude Code rows only; nil for every other client.
      if let lockdown = ClientWiring.lockdown(of: client) {
        row["lockdown"] = lockdown.state.summary
      }
```

- [ ] **Step 6: Build and run the built-in server check**

Run: `make app && make builtin`
Expected: `BUILD SUCCEEDED`; `builtin-check.sh` passes (no tool returns a secret; the new tool returns paths and key names only).

- [ ] **Step 7: Format and commit**

```bash
make format-swift
git add apps/apple/Bastion/BuiltinTools.swift
git commit -m "feat(clients): set_client_lockdown, and each Claude Code row's lockdown in list_clients"
```

---

### Task 5: The Only Bastion card in the client pane

**Files:**

- Create: `apps/apple/Bastion/ClientLockdownCard.swift`
- Modify: `apps/apple/Bastion/ClientDetail.swift:248` (after `contextCard(snapshot)`)

**Interfaces:**

- Consumes: `ClientWiring.lockdown(of:)`, `setLockdown`, `ClientLockdown.State`, `ClientLockdown.Refusal`, `Card(title:content:)` from `ActivityPanes.swift`, `ClientConfigRevision.shared.value`, `DemoSeed.isEnabled`.
- Produces: `struct ClientLockdownCard: View { let client: ClientWiring.Client }`.

- [ ] **Step 1: Write the card**

```swift
import SwiftUI

/// The Only Bastion switch for one Claude Code profile: an allowlist in that
/// profile's `settings.json` that lets through Bastion and the servers already
/// in its `.claude.json`, and nothing a plugin or claude.ai adds. See the
/// "Only Bastion" section of docs/clients.md.
///
/// Re-read on every redraw, like the rest of `ClientDetail`: both files are
/// Claude Code's, and either may have changed a second ago.
struct ClientLockdownCard: View {
  let client: ClientWiring.Client

  @State private var message: String?
  /// A refused change waiting on "Replace": the direction it was going.
  @State private var pendingForce: Bool?
  @State private var refusal = ""

  private var lockdown: ClientWiring.Lockdown? {
    // Subscribes the card to Bastion's own writes, as in `ClientDetail.read()`.
    _ = ClientConfigRevision.shared.value
    return ClientWiring.lockdown(of: client)
  }

  var body: some View {
    if let lockdown {
      Card(title: "Only Bastion") {
        VStack(alignment: .leading, spacing: 6) {
          Toggle(
            "Allow only Bastion and the servers in this config",
            isOn: Binding(
              get: { Self.isOn(lockdown.state) },
              set: { change(on: $0, force: false) })
          )
          .toggleStyle(.switch)
          .controlSize(.small)
          .disabled(lockdown.state.isUnreadable)

          HStack(spacing: 8) {
            Text(lockdown.state.summary)
              .font(.callout)
              .foregroundStyle(Self.tint(lockdown.state))
              .fixedSize(horizontal: false, vertical: true)
            switch lockdown.state {
            case .stale, .drifted:
              Button("Update") { change(on: true, force: false) }.controlSize(.small)
            case .leftBehind:
              Button("Remove") { change(on: false, force: false) }.controlSize(.small)
            default:
              EmptyView()
            }
          }

          if let plan = lockdown.plan {
            Text("Allowed: " + (["Bastion"] + plan.kept).joined(separator: ", "))
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if !plan.skipped.isEmpty {
              Text("Not allowed, no url or command: " + plan.skipped.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }

          Text(
            "Writes disableClaudeAiConnectors and allowedMcpServers into "
              + (lockdown.settingsURL.path as NSString).abbreviatingWithTildeInPath
              + ". Servers added by plugins, claude.ai connectors and a repository's .mcp.json "
              + "are blocked; a project's own settings can still widen the list. Start a new "
              + "\(client.displayName) session to apply."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          if let message {
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .alert(
        "settings.json was not written",
        isPresented: Binding(get: { pendingForce != nil }, set: { if !$0 { pendingForce = nil } })
      ) {
        Button("Replace", role: .destructive) {
          let on = pendingForce
          pendingForce = nil
          if let on { change(on: on, force: true) }
        }
        Button("Cancel", role: .cancel) { pendingForce = nil }
      } message: {
        Text(refusal)
      }
    }
  }

  private func change(on: Bool, force: Bool) {
    do {
      let backup = try ClientWiring.setLockdown(client, on: on, force: force)
      message =
        (on ? "Only Bastion is on." : "Only Bastion is off.")
        + (backup.map { " Previous version saved as \($0.lastPathComponent)." } ?? "")
        + " Start a new \(client.displayName) session to apply."
    } catch let refused as ClientLockdown.Refusal {
      refusal = refused.localizedDescription
      message = refusal
      pendingForce = on
    } catch {
      message = "Could not write settings.json: \(error.localizedDescription)"
    }
  }

  static func isOn(_ state: ClientLockdown.State) -> Bool {
    switch state {
    case .on, .stale, .drifted: true
    case .off, .leftBehind, .unreadable: false
    }
  }

  static func tint(_ state: ClientLockdown.State) -> Color {
    switch state {
    case .on: .green
    case .stale: .orange
    case .drifted, .unreadable: .red
    case .off, .leftBehind: .secondary
    }
  }
}
```

- [ ] **Step 2: Place it**

In `ClientDetail.swift`, `body`, replace

```swift
        contextCard(snapshot)
```

with

```swift
        contextCard(snapshot)
        // Hidden under a capture: it reads settings.json from the real home
        // directory, which no golden screenshot may depend on.
        if ClientWiring.supportsLockdown(client), !DemoSeed.isEnabled {
          ClientLockdownCard(client: client)
        }
```

- [ ] **Step 3: Build**

Run: `make app`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Screenshot goldens are unchanged**

Run: `make screenshots-check`
Expected: pass. If it fails on a Claude Code client capture, the `DemoSeed.isEnabled` guard is not in effect; fix that rather than re-accepting goldens.

- [ ] **Step 5: Format and commit**

```bash
make format-swift
git add apps/apple/Bastion/ClientLockdownCard.swift apps/apple/Bastion/ClientDetail.swift
git commit -m "feat(clients): an Only Bastion card in each Claude Code client's pane"
```

---

### Task 6: `wiring-check-real` covers the real `settings.json` files

**Files:**

- Modify: `scripts/wiring-check.swift` (`main()`'s path dispatch, plus one new function)
- Modify: `Makefile` (`wiring-check-real:` paths)

**Interfaces:**

- Consumes: `ClientSettingsSplice.parse/applying`, `ClientLockdown.plan/enabling/disabling/state`.
- Produces: nothing new for the app.

- [ ] **Step 1: Write the real-file check**

Append to `struct WiringCheck`:

```swift
  /// Read-only. Parses a real settings.json, turns the switch on in memory
  /// against an empty config, and asserts every key the user had is
  /// deep-equal after, and that off returns the original bytes when Bastion
  /// added every key it wrote.
  static func realSettingsSurvive(_ url: URL) {
    print("\n\(url.path)")
    guard let data = try? Data(contentsOf: url) else {
      return print("  skip (no file)")
    }
    let doc: ClientSettingsSplice.Document
    do {
      doc = try ClientSettingsSplice.parse(data)
    } catch {
      return check("parses: \(error.localizedDescription)", false)
    }
    check("parses", true)
    let plan = ClientLockdown.plan(claudeConfig: [:], port: port)
    guard
      let on = try? ClientLockdown.enabling(current: doc.values, plan: plan, recorded: [], force: true),
      let written = try? ClientSettingsSplice.applying(on.edits, to: data),
      let after = try? ClientSettingsSplice.parse(written)
    else { return check("switches on in memory", false) }
    for (key, value) in doc.values where !ClientLockdown.managedKeys.contains(key) {
      check("'\(key)' survives", deepEqual(value, after.values[key]))
    }
    check("reads as on", ClientLockdown.state(settings: after.values, plan: plan, enabled: true) == .on)
    let addedEverything = on.owned.allSatisfy { doc.values[$0] == nil }
    if addedEverything,
      let off = try? ClientLockdown.disabling(current: after.values, recorded: on.owned, force: false),
      let restored = try? ClientSettingsSplice.applying(off, to: written)
    {
      check("on then off is byte-identical", restored == data)
    }
  }
```

- [ ] **Step 2: Dispatch to it**

In `main()`, in the `for path in paths` loop, replace

```swift
        if url.pathExtension == "toml" {
          realTOMLFileSurvives(url)
        } else {
          realFileSurvives(url)
        }
```

with

```swift
        if url.pathExtension == "toml" {
          realTOMLFileSurvives(url)
        } else if url.lastPathComponent == "settings.json" {
          realSettingsSurvive(url)
        } else {
          realFileSurvives(url)
        }
```

- [ ] **Step 3: Add the paths**

In `Makefile`, `wiring-check-real:`, extend the argument list (keep the trailing backslashes consistent):

```make
		"$(HOME)/.claude-skitrust/.claude.json" \
		"$(HOME)/.claude/settings.json" \
		"$(HOME)/.claude-skitrust/settings.json"
```

- [ ] **Step 4: Run it**

Run: `make wiring-check-real`
Expected: both `settings.json` sections print `ok parses`, one `ok '<key>' survives` per existing key (`deniedMcpServers`, `enabledPlugins`, …), `ok reads as on`, exit 0. `on then off` is absent for these two files today, because `disableClaudeAiConnectors` is already set by hand there; that is expected.

- [ ] **Step 5: Commit**

```bash
git add scripts/wiring-check.swift Makefile
git commit -m "test(clients): prove the settings.json splice against the real files, read-only"
```

---

### Task 7: Document it, and check it end to end

**Files:**

- Modify: `docs/clients.md`: a new `## Only Bastion` section after `## Claude Code's config directories` (before `## What a client pays to be wired at all`); one row in the `## What asserts what` table.

- [ ] **Step 1: Write the section**

Insert before `## What a client pays to be wired at all`:

```markdown
## Only Bastion

A Claude Code profile picks up MCP servers from four places: its
`.claude.json`, a repository's `.mcp.json`, every plugin it has installed
(the ones synced down from the claude.ai account included), and claude.ai's
connectors. Bastion writes the first. The last two arrive unasked: the
knowledge-work plugins alone declare about forty hosted servers.

**Only Bastion** is a switch on each Claude Code row, and `set_client_lockdown`
over MCP. It writes two keys into that profile's `settings.json`:

- `disableClaudeAiConnectors: true`
- `allowedMcpServers`: `http://127.0.0.1:<port>/s/*`, then one exact rule
  for every server already in the profile's `.claude.json` that Bastion did
  not write, a `serverUrl` for one with a URL and a `serverCommand` (command
  and args) for one that spawns.

So the servers somebody configured on purpose keep working, and everything a
plugin or claude.ai adds is filtered out. A repository's `.mcp.json` is
filtered too. It is hygiene, not a boundary: a project's own settings can
widen the list, and only `allowManagedMcpServersOnly` in managed settings
would stop that.

**The file is spliced, not serialised.** `settings.json` is hand-edited, so
`ClientSettingsSplice` finds the two members and replaces only their bytes,
the way `ClientWiringTOML` treats Codex. A file it cannot round-trip (a
comment, a trailing comma, a key set twice) reads as `unreadable`, and nothing
is written. The write is the same one every client gets: backup, temp and
swap, `0600`, refused if the file moved since it was read.

**What is Bastion's.** `clientLockdown` in Bastion's defaults records, per
client, which of the two keys Bastion added. Turning the switch off removes
those and nothing else, so a `disableClaudeAiConnectors: true` somebody set
by hand outlives it. `deniedMcpServers` is never read or written. Unwiring a
client turns its switch off first, since an allowlist naming a Bastion that is
no longer wired would block every server the profile has.

| State         | Meaning                                                                 |
| ------------- | ----------------------------------------------------------------------- |
| `on`          | Both keys are what Bastion would write now.                             |
| `stale`       | Ours, but `.claude.json` gained or lost a server, or the port moved.    |
| `drifted`     | A key Bastion wrote was edited by hand; _Update_ asks before replacing. |
| `left behind` | Switched off, and Bastion's wildcard is still in the file.              |
| `unreadable`  | The splice refused the file.                                            |

`rewire` refreshes every switched-on profile, so a stale list is rewritten on
the next launch or profile change; a Debug build never does this unasked.

### Release check

With the switch on for a profile:

    CLAUDE_CONFIG_DIR=<dir> claude mcp list

shows no line starting `plugin:` or `claude.ai`, and every Bastion entry plus
every server the card lists as allowed. Verified on 2026-10-12 against Claude
Code 2.1.296: the wildcard matched all 24 Bastion entries, exact rules matched
an HTTP server and a stdio bridge, and every plugin server, URL-less
placeholders included, was filtered.
```

Add a row to the `## What asserts what` table, after the `make wiring-check-real` row:

```markdown
| `make wiring-check` (settings) | The `settings.json` splice (every other byte unchanged, on then off is the original, CRLF kept, comments and duplicate keys refused, symlinks written through, a moved file refused) and Only Bastion's allowlist, state table and key ownership. `wiring-check-real` runs the splice over your real `settings.json` files, read-only. |
```

- [ ] **Step 2: Format the docs**

Run: `node_modules/.bin/oxfmt --write docs/clients.md && node_modules/.bin/oxfmt --check docs/clients.md`
Expected: `All matched files use the correct format.`

- [ ] **Step 3: End-to-end check against a scratch profile (Debug build)**

```bash
mkdir -p ~/.claude-lockcheck
ln -s ~/.claude/plugins ~/.claude-lockcheck/plugins
printf '{\n  "mcpServers": {}\n}\n' > ~/.claude-lockcheck/.claude.json
printf '{\n  "model": "opus"\n}\n' > ~/.claude-lockcheck/settings.json
cp ~/.claude-lockcheck/settings.json /tmp/lockcheck-settings.orig
```

If the installed Release Bastion is running, quit it first so the Debug build can take the gateway port, and reopen it at the end. Open the Debug build (`open apps/apple/.build/Build/Products/Debug/Bastion.app`). In the sidebar, select **Claude Code (lockcheck)**:

1. Press **Configure** (wires it; required before automatic upkeep).
2. Turn **Only Bastion** on. Expected: state `on`. `cat ~/.claude-lockcheck/settings.json` shows `"model": "opus"` unchanged on its line, then the two new keys.
3. Run `CLAUDE_CONFIG_DIR=~/.claude-lockcheck claude mcp list | grep -cE '^(plugin:|claude\.ai)'`. Expected: `0`.
4. Turn **Only Bastion** off. Expected: `cmp ~/.claude-lockcheck/settings.json /tmp/lockcheck-settings.orig` prints nothing (identical).
5. Press **Unwire**, then revoke the lockcheck client's token if the pane offers it.

Clean up:

```bash
rm -rf ~/.claude-lockcheck /tmp/lockcheck-settings.orig
```

- [ ] **Step 4: Run every check once more**

Run: `make wiring-check && make wiring-check-real && make unit && make app`
Expected: all pass, `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add docs/clients.md
git commit -m "docs(clients): Only Bastion, what it writes, what it owns, and the release check"
```

---

### Task 8 (after the release is installed, with the user's go-ahead): switch the reference machine over

Not part of the branch. Once a Release build carrying this is installed:

- [ ] Remove the hand-written `deniedMcpServers` from `~/.claude/settings.json` and `~/.claude-skitrust/settings.json` (its `https://*` entry would block any https server the allowlist keeps, and denylists win). Leave `disableClaudeAiConnectors: true`; Bastion adopts it unrecorded.
- [ ] Turn **Only Bastion** on for **Claude Code** and **Claude Code (skitrust)**.
- [ ] Run the release check for both: `claude mcp list` and `CLAUDE_CONFIG_DIR=~/.claude-skitrust claude mcp list` each show `0` lines starting `plugin:` or `claude.ai`, and Cupertino and Armada still listed.
