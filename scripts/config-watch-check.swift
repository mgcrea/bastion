import Foundation

// Drives ConfigFileWatcher against real files in a throwaway folder: each way a
// client config gets written must call back, and nothing must call back once
// the watch is dropped. Compiled with the watcher alone; see
// `make config-watch-check`.

@main
@MainActor
struct ConfigWatchCheck {
  static var failures = 0
  static var passed = 0
  static var calls = 0

  static func check(_ label: String, _ condition: Bool) {
    if condition {
      passed += 1
      print("  ok   \(label)")
    } else {
      failures += 1
      print("  FAIL \(label)")
    }
  }

  /// Runs the main queue until the watcher has called back at least once more
  /// than before, or `timeout` passes. Returns how many calls arrived.
  static func calls(timeout: TimeInterval = 3, after action: () throws -> Void) rethrows -> Int {
    let before = calls
    try action()
    let deadline = Date().addingTimeInterval(timeout)
    while calls == before, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    // Let a trailing debounce land, so a burst is counted as what it is.
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    return calls - before
  }

  static func main() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("config-watch-check-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let config = folder.appendingPathComponent(".claude.json")
    let later = folder.appendingPathComponent("profile/.claude.json")
    try Data("{}".utf8).write(to: config)
    try FileManager.default.createDirectory(
      at: later.deletingLastPathComponent(), withIntermediateDirectories: true)

    let watcher = ConfigFileWatcher(debounce: 0.1) { calls += 1 }
    watcher.watch([config.path, later.path])

    print("Config file watcher")
    check(
      "a write in place calls back",
      try calls {
        let handle = try FileHandle(forWritingTo: config)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
      } > 0)
    check(
      "an atomic replace calls back",
      try calls { try Data("{\"a\":1}".utf8).write(to: config, options: .atomic) } > 0)
    check(
      "a write in place after a replace still calls back",
      try calls {
        let handle = try FileHandle(forWritingTo: config)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
      } > 0)
    check(
      "a burst of writes is one call",
      try calls {
        for n in 0..<5 { try Data("{\"n\":\(n)}".utf8).write(to: config, options: .atomic) }
      } == 1)
    check(
      "a file that did not exist when watched calls back when created",
      try calls { try Data("{}".utf8).write(to: later, options: .atomic) } > 0)
    check(
      "and a write in place to it after that calls back too",
      try calls {
        let handle = try FileHandle(forWritingTo: later)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
      } > 0)

    watcher.watch([])

    // Several Claude Code sessions rewrite .claude.json without pause; a
    // debounce with no ceiling would put the refresh off for as long as they
    // keep at it.
    let steady = ConfigFileWatcher(debounce: 0.3, maxWait: 0.5) { calls += 1 }
    steady.watch([config.path])
    let before = calls
    let end = Date().addingTimeInterval(1.6)
    var n = 0
    while Date() < end {
      n += 1
      try Data("{\"s\":\(n)}".utf8).write(to: config, options: .atomic)
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    check("steady writes still call back while they last", calls - before >= 2)
    steady.watch([])

    check(
      "nothing calls back once the watch is dropped",
      try calls(timeout: 0.6) {
        try Data("{\"b\":2}".utf8).write(to: config, options: .atomic)
      } == 0)

    print("\n\(passed)/\(passed + failures) passed")
    if failures > 0 { exit(1) }
  }
}
