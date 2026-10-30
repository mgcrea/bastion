import CoreServices
import Foundation

/// Tells the workspace store when something under a workspace's folders may
/// have changed what they reach: a repository cloned, created or deleted.
///
/// Before this, a clone got nothing until something else rewired, and the
/// Rescan button was the only way to say so. One FSEvents stream covers every
/// workspace's folders, recreated only when that set changes. The 2-second
/// latency lets a clone, or a batch of them, settle into one burst, and
/// `WorkspaceScope.isRelevantChange` drops everything that happens inside a
/// repository, which is nearly all of what a working tree reports.
@MainActor
final class WorkspaceWatcher {
  private let onRelevantChange: @MainActor () -> Void
  private var stream: FSEventStreamRef?
  private var folders: Set<String> = []
  private var repositoryKeys: Set<String> = []

  init(onRelevantChange: @escaping @MainActor () -> Void) {
    self.onRelevantChange = onRelevantChange
  }

  /// Watch `folders`, ignoring changes inside `repositoryKeys`. The same
  /// folders again only refreshes the keys; none stops watching.
  func watch(_ folders: Set<String>, repositoryKeys: Set<String>) {
    self.repositoryKeys = repositoryKeys
    guard folders != self.folders else { return }
    stop()
    self.folders = folders
    guard !folders.isEmpty else { return }

    // Unretained: the store owns this for the life of the app, and the stream
    // is stopped before anything here could go away.
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<WorkspaceWatcher>.fromOpaque(info).takeUnretainedValue()
      let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
      // Delivered on the main queue, set below.
      MainActor.assumeIsolated { watcher.received(changed) }
    }
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, Array(folders) as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
    else {
      hostLog("workspaces", .error, "could not watch the workspace folders for new repositories")
      return
    }
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  private func received(_ paths: [String]) {
    guard
      paths.contains(where: { WorkspaceScope.isRelevantChange($0, repositoryKeys: repositoryKeys) })
    else { return }
    onRelevantChange()
  }

  private func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}
