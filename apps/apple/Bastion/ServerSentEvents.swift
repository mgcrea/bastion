import Foundation

/// The `data:` payloads of a `text/event-stream` body, in order.
///
/// A Streamable HTTP server may answer a single POST with an SSE stream rather
/// than one JSON object, so Bastion has to be able to read one even though it
/// never emits one. Everything the stream carries beyond the response itself —
/// `notifications/progress`, log messages — is dropped, because Bastion's own
/// front door answers with a single JSON object and there is nowhere to forward
/// them to. That is the limitation the README already states for the child
/// case, reaching a second transport rather than becoming a new one.
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
}
