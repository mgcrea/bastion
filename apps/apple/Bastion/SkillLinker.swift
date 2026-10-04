import Darwin
import Foundation

/// The only code that changes a skills folder.
///
/// Foundation only, so `make skills-check` runs it against a throwaway folder.
/// Every write is one of three shapes, each chosen so a reader of the folder
/// never sees a half-made entry and nothing Bastion does not own is replaced.
/// Relink and unlink first take the entry out of the way atomically —
/// `renamex_np` with `RENAME_SWAP` for relink, with `RENAME_EXCL` for unlink —
/// and only then look at what they took: it is removed if it is still the link
/// the plan saw, the destination the action carries as `found`, and put back
/// otherwise. Checking before the rename would leave a window between the look
/// and the removal; checking what the rename handed over leaves none. A foreign
/// entry, or a link another tool re-pointed since the plan, is never modified
/// or deleted, only moved aside and back.
nonisolated enum SkillLinker {
  struct Failure: Equatable, Hashable {
    let target: String
    let name: String
    let message: String
  }

  enum LinkError: LocalizedError {
    case notALink(String)
    case changed(path: String, found: String, now: String)
    case rename(String, String)
    case moveAside(String, String)
    case leftAside(original: String, now: String)

    var errorDescription: String? {
      switch self {
      case .notALink(let path): "\(path) is not a symlink, so Bastion leaves it alone."
      case .changed(let path, let found, let now):
        "\(path) now points at \(now), not at \(found) as when Bastion planned this change, "
          + "so Bastion leaves it alone."
      case .rename(let path, let reason): "Could not put the new link at \(path): \(reason)."
      case .moveAside(let path, let reason): "Could not move \(path) aside to remove it: \(reason)."
      case .leftAside(let original, let now):
        "\(original) is not the link Bastion planned to change; Bastion moved what was there to "
          + "\(now) for you to recover."
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
        case .relink(_, _, let found, let destination):
          try replaceLink(at: path, found: found, with: destination, in: target.path)
        case .unlink(_, _, let found):
          try unlinkIfUnchanged(atPath: path, found: found, in: target.path)
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
    // Present but unreadable, or not UTF-8: rewriting it from "" would
    // replace every line the user has there with Bastion's block alone.
    if fs.entryExists(path) && fs.contents(path) == nil {
      return Failure(
        target: key, name: ".git/info/exclude",
        message: "\(path) could not be read as UTF-8 text, so Bastion left it unchanged")
    }
    let existing = fs.contents(path) ?? ""
    let next = SkillExclude.updated(existing, entries: entries)
    guard next != existing else { return nil }
    do {
      try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
      // Through a symlink, to the file it names: an atomic write replaces
      // whatever is at the path, and an exclude file kept in dotfiles and
      // linked in was cut off from the copy the user maintains.
      let target = (path as NSString).resolvingSymlinksInPath
      try next.write(toFile: target, atomically: true, encoding: .utf8)
      return nil
    } catch {
      return Failure(target: key, name: ".git/info/exclude", message: error.localizedDescription)
    }
  }

  /// Creates a new link under a hidden temporary name, then atomically exchanges it
  /// with whatever is at the path using renamex_np(RENAME_SWAP). If what came out
  /// is the link the plan saw, still pointing at `found`, removes it. Anything
  /// else — a foreign entry, or a link another tool re-pointed since the plan —
  /// is swapped back and reported. The check is on what the swap handed over,
  /// so nothing can change between the look and the removal.
  private static func replaceLink(
    at path: String, found: String, with destination: String, in folder: String
  ) throws {
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

    // Check what we swapped out. If lstat fails (very rare), the previous entry is at temporary
    // and our new link is at path. Report where the previous entry went without trying to move it.
    var info = stat()
    guard lstat(temporary, &info) == 0 else {
      throw LinkError.leftAside(original: path, now: temporary)
    }

    let now = linkDestination(temporary, info)
    if now == found {
      // The link the plan claimed as ours, still saying what it said then.
      // Not every symlink in a target is Bastion's: another tool may have
      // re-pointed this name at its own copy since the plan, and "a symlink"
      // alone would have taken that one too. A failed unlink is swallowed:
      // the new link is in place, the old one is just orphaned.
      _ = unlink(temporary)
      return
    }

    // Not the link the plan saw. Swap it back to path to preserve it.
    // After this: path holds that entry again, temporary holds OUR new link.
    guard renamex_np(temporary, path, UInt32(RENAME_SWAP)) == 0 else {
      // The swap-back failed. Leave the entry exactly where it is (at temporary)
      // and report where it went. Do NOT touch temporary; we never delete what isn't ours.
      // This branch has no deterministic test: nothing can force renamex_np to fail after
      // it succeeded before, except catastrophic file system issues. It is safe because it
      // touches nothing and reports where the entry is for recovery.
      throw LinkError.leftAside(original: path, now: temporary)
    }
    // Swap-back succeeded. Remove our link (now at temporary, Bastion's own
    // temporary name); if that fails it stays there hidden, and the action
    // fails either way.
    _ = unlink(temporary)
    throw now.map { LinkError.changed(path: path, found: found, now: $0) }
      ?? LinkError.notALink(path)
  }

  /// Moves the entry at path aside using atomic RENAME_EXCL, then removes it
  /// if it is the link the plan saw, still pointing at `found`. Anything else
  /// is moved back and reported. As in `replaceLink`, the check is on what the
  /// rename handed over, so nothing can change between the look and the removal.
  private static func unlinkIfUnchanged(atPath path: String, found: String, in folder: String)
    throws
  {
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

    let now = linkDestination(hidden, info)
    if now == found {
      // The link the plan claimed as ours, unchanged; see `replaceLink`.
      // A failed unlink is swallowed: the symlink is orphaned under a hidden name.
      _ = unlink(hidden)
      return
    }

    // Not the link the plan saw. Move it back to path to restore it.
    guard renamex_np(hidden, path, UInt32(RENAME_EXCL)) == 0 else {
      // The move-back failed. Leave the entry where it is (at hidden) and report it.
      // Do NOT touch hidden; we never delete what isn't ours.
      throw LinkError.leftAside(original: path, now: hidden)
    }
    throw now.map { LinkError.changed(path: path, found: found, now: $0) }
      ?? LinkError.notALink(path)
  }

  /// What a symlink at `path` points at, read the way the plan read it
  /// (`destinationOfSymbolicLink`, as `LocalSkillFileSystem` does), so an
  /// unchanged link compares equal to `found` byte for byte. nil when `info`,
  /// its `lstat`, says it is not a symlink at all. A link re-spelled to land on
  /// the same folder (relative where it was absolute) counts as changed: it is
  /// left alone and reported, and the next plan sees it as it now is.
  private static func linkDestination(_ path: String, _ info: stat) -> String? {
    guard (info.st_mode & S_IFMT) == S_IFLNK else { return nil }
    return try? FileManager.default.destinationOfSymbolicLink(atPath: path)
  }
}

/// What goes into a skill's ZIP for claude.ai.
///
/// A copy of the folder without its hidden entries. A `.skill` source rooted at
/// a repository makes the skill folder the repository itself, and zipping it
/// whole packed its `.git` — history, remotes, maybe a token in a remote URL —
/// and any `.env` beside SKILL.md, into a file whose only purpose is to be
/// uploaded somewhere else.
nonisolated enum SkillExport {
  /// The staged copy, named as the folder is, inside `staging`.
  static func stage(_ folder: String, in staging: URL) throws -> URL {
    let fm = FileManager.default
    let source = (folder as NSString).resolvingSymlinksInPath
    let target = staging.appendingPathComponent(
      (source as NSString).lastPathComponent, isDirectory: true)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    // Relative paths straight from the walk: building them by trimming an
    // absolute prefix breaks wherever /var and /private/var both spell it.
    guard let walk = fm.enumerator(atPath: source) else { return target }
    while let relative = walk.nextObject() as? String {
      if (relative as NSString).lastPathComponent.hasPrefix(".") {
        walk.skipDescendants()
        continue
      }
      let from = (source as NSString).appendingPathComponent(relative)
      let destination = target.appendingPathComponent(relative)
      var isFolder: ObjCBool = false
      fm.fileExists(atPath: from, isDirectory: &isFolder)
      if isFolder.boolValue {
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
      } else {
        try fm.copyItem(atPath: from, toPath: destination.path)
      }
    }
    return target
  }
}
