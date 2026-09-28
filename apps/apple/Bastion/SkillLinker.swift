import Darwin
import Foundation

/// The only code that changes a skills folder.
///
/// Foundation only, so `make skills-check` runs it against a throwaway folder.
/// Every write is one of three shapes, each chosen so a reader of the folder
/// never sees a half-made entry and nothing Bastion does not own is replaced.
/// Relink and unlink avoid TOCTOU races by using atomic system calls: `renamex_np`
/// with `RENAME_SWAP` for relink, and `renamex_np` with `RENAME_EXCL` for unlink.
/// A foreign entry is never modified, moved or deleted.
nonisolated enum SkillLinker {
  struct Failure: Equatable, Hashable {
    let target: String
    let name: String
    let message: String
  }

  enum LinkError: LocalizedError {
    case notALink(String)
    case rename(String, String)
    case moveAside(String, String)
    case leftAside(original: String, now: String)

    var errorDescription: String? {
      switch self {
      case .notALink(let path): "\(path) is not a symlink, so Bastion leaves it alone."
      case .rename(let path, let reason): "Could not put the new link at \(path): \(reason)."
      case .moveAside(let path, let reason): "Could not move \(path) aside to remove it: \(reason)."
      case .leftAside(let original, let now):
        "\(original) is not a symlink; Bastion moved the foreign entry to \(now) for you to recover."
      }
    }
  }

  static func apply(_ actions: [SkillAction], targets: [SkillTarget]) -> [Failure] {
    let byID = Dictionary(targets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let manager = FileManager.default
    var failures: [Failure] = []
    for action in actions {
      guard let target = byID[action.target] else {
        failures.append(
          Failure(target: action.target, name: action.name, message: "no such target"))
        continue
      }
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
          try unlinkIfSymlink(atPath: path, in: target.path)
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

  /// Creates a new link under a hidden temporary name, then atomically exchanges it
  /// with whatever is at the path using renamex_np(RENAME_SWAP). If a symlink is
  /// swapped out, removes it. If something else is swapped out, swaps it back and fails.
  /// This avoids a TOCTOU race where a foreign entry could appear between the check
  /// and the replacement.
  private static func replaceLink(at path: String, with destination: String, in folder: String)
    throws
  {
    let temporary = (folder as NSString).appendingPathComponent(
      ".bastion-link-" + UUID().uuidString)
    let manager = FileManager.default
    try manager.createSymbolicLink(atPath: temporary, withDestinationPath: destination)

    // Atomically swap the new link with whatever is at path.
    // After this: path holds OUR new link, temporary holds what was at path (if anything).
    guard renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 else {
      let reason = String(cString: strerror(errno))
      try? manager.removeItem(atPath: temporary)  // best-effort cleanup of our temporary
      throw LinkError.rename(path, reason)
    }

    // Check what we swapped out. RENAME_SWAP requires both paths to exist, so lstat succeeds.
    var info = stat()
    guard lstat(temporary, &info) == 0 else {
      let reason = String(cString: strerror(errno))
      throw LinkError.rename(path, reason)
    }

    if (info.st_mode & S_IFMT) == S_IFLNK {
      // It was our old link. Remove it (Bastion owns all symlinks in the target).
      guard unlink(temporary) == 0 else {
        // Swallow this error. The new link is in place; the old one is just orphaned.
        return
      }
      return
    }

    // It's not a symlink, so it's foreign. Swap it back to path to preserve it.
    // After this: path holds the foreign entry, temporary holds OUR new link (which failed).
    guard renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 else {
      // The swap-back failed. Leave the foreign entry exactly where it is (at temporary)
      // and report where it went. Do NOT touch temporary; we never delete what isn't ours.
      throw LinkError.leftAside(original: path, now: temporary)
    }
    // Swap-back succeeded: path is restored to foreign, temporary holds our new link.
    // Remove our link (now at temporary, which is Bastion's own temporary name).
    guard unlink(temporary) == 0 else {
      // Swallow the error; our link stayed at temporary under a hidden name but we're going to fail anyway.
      return
    }
    throw LinkError.notALink(path)
  }

  /// Moves the entry at path aside using atomic RENAME_EXCL, checks if it's a symlink,
  /// and removes it if so. If it's not a symlink, moves it back and fails. This avoids
  /// a TOCTOU race where a foreign entry could appear between the check and deletion.
  private static func unlinkIfSymlink(atPath path: String, in folder: String) throws {
    let hidden = (folder as NSString).appendingPathComponent(
      ".bastion-unlink-" + UUID().uuidString)

    // Move atomically aside with RENAME_EXCL. After this: path is empty, hidden holds the entry.
    guard renamex_np(path, hidden, UInt32(RENAME_EXCL)) == 0 else {
      let reason = String(cString: strerror(errno))
      throw LinkError.moveAside(path, reason)
    }

    // Check what we moved aside.
    var info = stat()
    guard lstat(hidden, &info) == 0 else {
      let reason = String(cString: strerror(errno))
      throw LinkError.moveAside(path, reason)
    }

    if (info.st_mode & S_IFMT) == S_IFLNK {
      // It's a symlink (Bastion owns all symlinks in the target). Remove it.
      guard unlink(hidden) == 0 else {
        // Swallow the error; the symlink is orphaned but we're reporting unlink failed anyway.
        return
      }
      return
    }

    // It's not a symlink, so it's foreign. Move it back to path to restore it.
    guard renamex_np(hidden, path, UInt32(RENAME_EXCL)) == 0 else {
      // The move-back failed. Leave the foreign entry where it is (at hidden) and report it.
      // Do NOT touch hidden; we never delete what isn't ours.
      throw LinkError.leftAside(original: path, now: hidden)
    }
    throw LinkError.notALink(path)
  }
}
