import Foundation

/// Reading one of Bastion's own JSON stores, telling "not there" from "there
/// and unreadable".
///
/// Every store used to fold the two together: `try?` on the read and `try?` on
/// the decode, and either failure became an empty list. The next save then
/// wrote that empty list over the original, so one hand-edit typo, or a
/// downgrade meeting a field this build does not know, cost every profile on
/// the machine — and for `skills.json` the launch reconcile unlinked every
/// skill before the save got there.
///
/// So a file that is present and cannot be read is a third state. The original
/// is left where it is, a copy is kept beside it in case anything does go on to
/// touch it, and the store refuses to save until a person has looked. The copy
/// has one fixed name, so a store that stays unreadable across launches keeps
/// one copy rather than growing a pile of them.
///
/// Its own file, and Foundation only, so `scripts/unit-check.swift` compiles it.
nonisolated enum StoreFile {
  struct Unreadable: LocalizedError {
    let file: URL
    /// Nil only when the copy itself could not be written.
    let copy: URL?

    var errorDescription: String? {
      let kept = copy.map { " A copy is at \($0.lastPathComponent) beside it." } ?? ""
      return
        "\(file.lastPathComponent) could not be read, so Bastion will not write over it.\(kept) "
        + "Fix or remove the file, then relaunch Bastion."
    }
  }

  enum Loaded<Value> {
    /// No file: an empty store, which is what a fresh install is.
    case absent
    case decoded(Value)
    case unreadable(Unreadable)
  }

  static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Loaded<Value> {
    guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
    guard let data = try? Data(contentsOf: url) else {
      return .unreadable(Unreadable(file: url, copy: nil))
    }
    guard let value = try? JSONDecoder().decode(type, from: data) else {
      return .unreadable(Unreadable(file: url, copy: keepCopy(of: data, beside: url)))
    }
    return .decoded(value)
  }

  /// `<name>.unreadable`, written only when it is missing or says something
  /// else, and 0o600 like the stores themselves: `profiles.json` names accounts.
  private static func keepCopy(of data: Data, beside url: URL) -> URL? {
    let copy = url.appendingPathExtension("unreadable")
    if (try? Data(contentsOf: copy)) == data { return copy }
    do {
      try data.write(to: copy, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
      return copy
    } catch {
      return nil
    }
  }
}
