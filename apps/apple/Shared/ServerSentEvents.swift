import Foundation

/// The `data:` payloads of a `text/event-stream` body, in order.
///
/// A Streamable HTTP server may answer a single POST with an SSE stream rather
/// than one JSON object, and Bastion is now on both ends of that: it reads one
/// from a remote server, and it emits one to a client that asked for progress
/// (`EventStream.swift`). The two uses share this parser and nothing else.
///
/// The remote leg still collapses what it reads to the frame carrying an id and
/// drops the rest — see `RemoteInstance.Response.jsonRPC()`. That is not the
/// same limitation it used to be: the obstacle is no longer "nowhere to forward
/// them to" but `RemoteEndpoint.verify(connectedTo:)`, which refuses a
/// rebinding answer only because the body is buffered until the addresses are
/// known.
///
/// Its own file so `scripts/remote-check.swift` can compile it alone. A parser
/// nobody can run is a parser nobody has checked, and this one has to be right
/// about a wire format written by somebody else.
///
/// Only `data:` is read. `event:`, `id:` and `retry:` are all meaningful in the
/// EventSource protocol and none of them are meaningful here — the payload is
/// JSON-RPC, which carries its own correlation.
///
/// ## Bytes, not Characters
///
/// This splits the raw `Data` rather than a `String`, and that is load-bearing
/// rather than an optimisation. Swift treats `\r\n` as **one** `Character` — a
/// grapheme cluster — so `string.split(separator: "\n")` does not split a CRLF
/// line ending at all. A first version did exactly that and silently returned
/// the whole stream as a single payload against any server that framed with
/// CRLF, which is legal and common. `remote-check` caught it, and the byte-level
/// split is the fix rather than a special case bolted on afterwards.
nonisolated enum ServerSentEvents {
  private static let newline = UInt8(ascii: "\n")
  private static let carriageReturn = UInt8(ascii: "\r")

  static func dataPayloads(in body: Data) -> [Data] {
    var out: [Data] = []
    var current: [String] = []

    func flush() {
      guard !current.isEmpty else { return }
      // Multiple `data:` lines in one event are joined with newlines, which is
      // what the EventSource spec says and what a pretty-printed JSON body
      // arrives as.
      if let data = current.joined(separator: "\n").data(using: .utf8) { out.append(data) }
      current = []
    }

    for rawLine in body.split(separator: newline, omittingEmptySubsequences: false) {
      // A CRLF stream leaves the \r on the end of every line; left in place it
      // would land inside the JSON and fail to parse.
      let bytes = rawLine.last == carriageReturn ? rawLine.dropLast() : rawLine
      guard var line = String(bytes: bytes, encoding: .utf8) else { continue }

      // A blank line dispatches the event.
      if line.isEmpty {
        flush()
        continue
      }
      // A comment, used as a keep-alive by servers that send one.
      if line.hasPrefix(":") { continue }
      guard line.hasPrefix("data:") else { continue }

      line.removeFirst(5)
      // Exactly one leading space is part of the framing, not the data.
      if line.hasPrefix(" ") { line.removeFirst() }
      current.append(line)
    }
    // A stream that ends without a trailing blank line still dispatched its
    // last event as far as anyone reading it is concerned.
    flush()
    return out
  }

  /// The index just past the last event terminator in `body`, or nil when no
  /// event has ended yet.
  ///
  /// A terminator is a blank line: `\n\n` on an LF stream and `\n\r\n` on a
  /// CRLF one. Those two cover `\r\n\r\n` as well, since it contains the
  /// second. Bytes rather than Characters, for the reason in the header above.
  private static func lastEventBoundary(in body: Data) -> Data.Index? {
    let lf = body.range(of: Data([newline, newline]), options: .backwards)?.upperBound
    let crlf = body.range(
      of: Data([newline, carriageReturn, newline]), options: .backwards)?.upperBound
    switch (lf, crlf) {
    case let (first?, second?): return max(first, second)
    case let (first?, nil): return first
    case let (nil, second?): return second
    case (nil, nil): return nil
    }
  }

  /// An incremental reader, for a stream that is still arriving.
  ///
  /// `dataPayloads` treats the end of its input as the end of an event, which is
  /// right for a body that is complete and wrong for one that is not: handed a
  /// half-received frame it would dispatch half a frame. `Parser` holds the
  /// partial tail back until a blank line proves the event ended.
  ///
  /// The property worth testing, and the one `remote-check` asserts: for any
  /// body cut into any sequence of chunks, the payloads from `feed` over those
  /// chunks followed by `finish` equal `dataPayloads(in:)` of the whole body.
  struct Parser {
    private var buffer = Data()

    init() {}

    /// Every complete event at the front of what has been fed so far.
    mutating func feed(_ bytes: Data) -> [Data] {
      buffer.append(bytes)
      guard let cut = lastEventBoundary(in: buffer) else { return [] }
      let complete = Data(buffer[..<cut])
      buffer = Data(buffer[cut...])
      return dataPayloads(in: complete)
    }

    /// Whatever is left when the stream ends, dispatched the way
    /// `dataPayloads` dispatches a body with no trailing blank line.
    mutating func finish() -> [Data] {
      defer { buffer = Data() }
      return dataPayloads(in: buffer)
    }
  }
}
