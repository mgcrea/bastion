import Foundation

/// Calls back, debounced, when any of a set of files is written in place,
/// replaced, created or removed.
///
/// One vnode source per file and one per directory holding them, not FSEvents:
/// the default Claude Code profile's `.claude.json` sits in the home folder, and
/// an FSEvents stream there reports every write under it. The file source sees
/// a write in place, and an atomic replace (temp file and rename, which is how
/// Cupertino and Bastion both write) as the old inode's delete. It is reopened
/// after every event, because a replace leaves it on the inode swapped out. The
/// directory source is for a file that did not exist when the watch began: a
/// profile with no `.claude.json` yet, or one deleted and written again.
/// `make config-watch-check` fails without either.
///
/// A directory event says only that some entry in it changed, so another file
/// written beside a watched one also calls back. Callers re-read and decide;
/// this only says "look again".
///
/// Foundation only, so `make config-watch-check` drives it against real files.
@MainActor
final class ConfigFileWatcher {
  private let debounce: TimeInterval
  /// The ceiling on how long a burst can put the call off: the default
  /// profile's folder is the home folder, and steady writes there would
  /// otherwise restart the debounce indefinitely.
  private let maxWait: TimeInterval
  private let onChange: @MainActor () -> Void
  private var paths: Set<String> = []
  private var files: [String: DispatchSourceFileSystemObject] = [:]
  private var directories: [String: DispatchSourceFileSystemObject] = [:]
  private var pending: DispatchWorkItem?
  /// When the burst the pending call answers began.
  private var burstStarted: Date?

  init(
    debounce: TimeInterval = 1, maxWait: TimeInterval = 5,
    onChange: @escaping @MainActor () -> Void
  ) {
    self.debounce = debounce
    self.maxWait = maxWait
    self.onChange = onChange
  }

  /// Watch exactly `paths`. A path that does not exist yet is picked up when
  /// its directory reports it; an empty set stops everything.
  func watch(_ paths: Set<String>) {
    self.paths = paths
    let folders = Set(paths.map { ($0 as NSString).deletingLastPathComponent })
    for path in Set(files.keys).subtracting(paths) { files.removeValue(forKey: path)?.cancel() }
    for folder in Set(directories.keys).subtracting(folders) {
      directories.removeValue(forKey: folder)?.cancel()
    }
    if paths.isEmpty {
      pending?.cancel()
      pending = nil
      burstStarted = nil
    }
    for folder in folders where directories[folder] == nil {
      directories[folder] = source(folder, events: .write) { [weak self] in
        self?.changed(in: folder)
      }
    }
    for path in paths where files[path] == nil {
      files[path] = source(path, events: [.write, .extend, .delete, .rename]) { [weak self] in
        self?.changed(path)
      }
    }
  }

  private func changed(in folder: String) {
    // Any file in it may have been replaced or created: reopen them all.
    for path in files.keys where (path as NSString).deletingLastPathComponent == folder {
      files.removeValue(forKey: path)?.cancel()
    }
    watch(paths)
    schedule()
  }

  private func changed(_ path: String) {
    files.removeValue(forKey: path)?.cancel()
    watch(paths)
    schedule()
  }

  private func schedule() {
    pending?.cancel()
    let started = burstStarted ?? Date()
    burstStarted = started
    let delay = max(0, min(debounce, maxWait - Date().timeIntervalSince(started)))
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        self?.burstStarted = nil
        self?.onChange()
      }
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// Nil when the path cannot be opened, which for a file not created yet is
  /// expected: the directory source reports its creation.
  private func source(
    _ path: String, events: DispatchSource.FileSystemEvent,
    handler: @escaping @MainActor () -> Void
  ) -> DispatchSourceFileSystemObject? {
    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else { return nil }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: events, queue: .main)
    source.setEventHandler { MainActor.assumeIsolated { handler() } }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    return source
  }
}
