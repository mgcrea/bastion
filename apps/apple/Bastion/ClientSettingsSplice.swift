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
        let key =
          (try? JSONSerialization.jsonObject(
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
    // The lexer decides extents; Foundation decides validity, such as a bad
    // number nested inside a value.
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
      // The last byte that was not whitespace, to catch a comma before a
      // closer: Foundation accepts `[1, 2,]`, and a rewrite would not keep it.
      var lastComma: Int?
      while i < b.count {
        switch b[i] {
        case UInt8(ascii: "\""):
          i = try endOfString(b, from: i)
          lastComma = nil
          continue
        case UInt8(ascii: "/"):
          throw ParseError.comment(offset: i)
        case UInt8(ascii: ","):
          lastComma = i
        case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
          break
        case UInt8(ascii: "{"), UInt8(ascii: "["):
          depth += 1
          lastComma = nil
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          if let comma = lastComma { throw ParseError.trailingComma(offset: comma) }
          depth -= 1
          if depth == 0 { return i + 1 }
        default:
          lastComma = nil
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
        let member =
          try quoted(edit.key) + ": " + text(value, indent: doc.indent ?? "", newline: newline)
        b.insert(contentsOf: Array((separator + member).utf8), at: last.valueEnd)
        return b
      }
      let nl = doc.newline
      let body =
        "{" + nl + "  " + (try quoted(edit.key)) + ": "
        + (try text(value, indent: "  ", newline: nl))
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
