import Foundation

/// The only code that changes a skills folder.
///
/// Foundation only, so `make skills-check` runs it against a throwaway folder.
/// Every write is one of three shapes, each chosen so a reader of the folder
/// never sees a half-made entry and nothing Bastion does not own is replaced.
nonisolated enum SkillLinker {
  struct Failure: Equatable, Hashable {
    let target: String
    let name: String
    let message: String
  }

  enum LinkError: LocalizedError {
    case notALink(String)
    case rename(String, String)

    var errorDescription: String? {
      switch self {
      case .notALink(let path): "\(path) is not a symlink, so Bastion leaves it alone."
      case .rename(let path, let reason): "Could not put the new link at \(path): \(reason)."
      }
    }
  }

  static func apply(_ actions: [SkillAction], targets: [SkillTarget]) -> [Failure] {
    let byID = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let manager = FileManager.default
    var failures: [Failure] = []
    for action in actions {
      guard let target = byID[action.target] else { continue }
      let path = (target.path as NSString).appendingPathComponent(action.name)
      do {
        switch action {
        case .link(_, _, let destination):
          try manager.createDirectory(atPath: target.path, withIntermediateDirectories: true)
          // Straight at the final name: symlink(2) fails if anything appeared
          // there since the plan, where a rename would silently replace it.
          try manager.createSymbolicLink(atPath: path, withDestinationPath: destination)
        case .relink(_, _, let destination):
          try replaceLink(at: path, with: destination, in: target.path)
        case .unlink:
          guard (try? manager.destinationOfSymbolicLink(atPath: path)) != nil else {
            throw LinkError.notALink(path)
          }
          try manager.removeItem(atPath: path)
        }
      } catch {
        failures.append(
          Failure(target: target.id, name: action.name, message: error.localizedDescription))
      }
    }
    return failures
  }

  /// Moves a foreign entry to the Trash. Only ever called from "Overwrite
  /// anyway", never from a plan.
  static func trash(_ path: String) throws {
    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
  }

  /// Rewrites Bastion's block in a repository's `info/exclude`. nil when there
  /// was nothing to do or the write succeeded.
  static func writeExclude(key: String, entries: [String], fs: SkillFileSystem) -> Failure? {
    guard let path = SkillExclude.path(forKey: key, fs: fs) else { return nil }
    let existing = fs.contents(path) ?? ""
    let next = SkillExclude.updated(existing, entries: entries)
    guard next != existing else { return nil }
    do {
      try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      try next.write(toFile: path, atomically: true, encoding: .utf8)
      return nil
    } catch {
      return Failure(target: key, name: ".git/info/exclude", message: error.localizedDescription)
    }
  }

  /// A new link under a hidden temporary name, renamed over the old one.
  /// rename(2) replaces a symlink atomically, so the name is never missing.
  private static func replaceLink(at path: String, with destination: String, in folder: String)
    throws
  {
    let manager = FileManager.default
    guard (try? manager.destinationOfSymbolicLink(atPath: path)) != nil else {
      throw LinkError.notALink(path)
    }
    let temporary = (folder as NSString).appendingPathComponent(
      ".bastion-link-" + UUID().uuidString)
    try manager.createSymbolicLink(atPath: temporary, withDestinationPath: destination)
    guard rename(temporary, path) == 0 else {
      let reason = String(cString: strerror(errno))
      try? manager.removeItem(atPath: temporary)
      throw LinkError.rename(path, reason)
    }
  }
}
