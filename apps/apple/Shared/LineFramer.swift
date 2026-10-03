import Foundation

/// Newline-delimited frames out of a byte stream that arrives in arbitrary
/// chunks — a child's stdout in the supervisor, the host's stdin in the bridge.
///
/// What it holds never contains a newline: everything up to the last newline of
/// a chunk is handed back as soon as it arrives. So only the chunk just read is
/// ever searched. The loops this replaces searched everything they held on
/// every read, and a 30 MB tool result arriving 64 KB at a time cost seconds of
/// CPU on the reader thread, with every other client of that child waiting
/// behind it.
nonisolated struct LineFramer {
  private var pending = Data()
  /// A frame this long is not MCP framing. Past it, with no newline in sight,
  /// what is held is dropped rather than grown without bound.
  let limit: Int
  /// How many times that has happened, for a caller that says so.
  private(set) var discarded = 0

  init(limit: Int = 32 << 20) {
    self.limit = limit
  }

  /// What is held with no newline after it, once the stream has ended — still
  /// a line somebody printed. Nil when nothing is held.
  mutating func flush() -> Data? {
    guard !pending.isEmpty else { return nil }
    defer { pending = Data() }
    return pending
  }

  /// Takes one read's bytes and returns every complete, non-empty line they
  /// closed, oldest first.
  mutating func feed<Bytes: Collection>(_ chunk: Bytes) -> [Data] where Bytes.Element == UInt8 {
    let bytes = Array(chunk)
    guard let last = bytes.lastIndex(of: UInt8(ascii: "\n")) else {
      pending.append(contentsOf: bytes)
      if pending.count > limit {
        pending.removeAll(keepingCapacity: false)
        discarded += 1
      }
      return []
    }
    pending.append(contentsOf: bytes[..<last])
    let complete = pending
    pending = Data(bytes[(last + 1)...])
    return complete.split(separator: UInt8(ascii: "\n")).filter { !$0.isEmpty }.map { Data($0) }
  }
}
