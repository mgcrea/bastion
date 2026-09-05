import Foundation
import os

/// One reply, written as `text/event-stream` instead of a single buffered
/// object.
///
/// This is the current transport, not the deprecated one. Streamable HTTP lets
/// a server answer one POST with an SSE body carrying notifications ahead of
/// the result, and that is all this is: still one POST, still one response,
/// still no session. What it is NOT is the 2024-11-05 HTTP+SSE transport — no
/// `GET` channel that outlives a request, no `Mcp-Session-Id`, no
/// `Last-Event-ID`, no replay. `Gateway` still answers 405 to `GET` and
/// `DELETE`, and the reasoning at `Gateway.route` still holds.
///
/// ## Opened late, on purpose
///
/// The head is written when the FIRST frame is sent, not when the request is
/// judged streamable. Until then nothing has been committed and `Gateway.serve`
/// can still send an ordinary `HTTPResponse` with its own status — which is
/// what preserves the 404/`-32601` for an unknown method, the 400/`-32020` for
/// a mismatched header, the 202 for a notification and the licence gate's
/// 200-with-error. A call that turns out to emit no progress is answered
/// byte-for-byte as it was before this type existed.
///
/// ## Two threads, two rules
///
/// Progress frames are written by the child's reader thread (`Supervisor
/// .Instance.received`), which is shared by every client of that child. That
/// thread must never block here: a peer that stopped reading would otherwise
/// stall every other client behind it. So a progress frame is sent with
/// `MSG_DONTWAIT` and DROPPED when the socket has no room. Progress is
/// advisory; a dropped frame costs a percentage nobody sees, and blocking
/// costs everyone.
///
/// The final frame is written by the connection's own thread, blocking, bounded
/// by the `SO_SNDTIMEO` set at accept. That thread exists to block.
///
/// `MSG_DONTWAIT` rather than `poll` then `write`: the socket is in blocking
/// mode, so a `poll` saying "writable" proves only that SOME space exists, and
/// the `write` that follows could still park the reader thread for the full
/// send timeout on a frame larger than that space.
nonisolated final class HTTPStream: Sendable {
  private struct State {
    var opened = false
    /// A write failed after writing part of a frame. Nothing may follow it: a
    /// truncated final event is unambiguous to a reader, but a well-formed
    /// event appended after a truncated one is a stream that parses cleanly
    /// and says something false.
    var broken = false
    var sent = 0
    var dropped = 0
  }

  private let fd: Int32
  /// Whether the client said it can read one. A stream that is not armed is
  /// inert: `send` does nothing and `isOpen` stays false.
  private let armed: Bool
  private let state = OSAllocatedUnfairLock(initialState: State())

  init(fd: Int32, armed: Bool) {
    self.fd = fd
    self.armed = armed
  }

  /// Whether the head went out, and so whether this connection is committed to
  /// a 200 and an event-stream body.
  var isOpen: Bool { state.withLock { $0.opened } }

  /// Frames written and frames dropped for backpressure, for the one summary
  /// line logged at close.
  var counts: (sent: Int, dropped: Int) { state.withLock { ($0.sent, $0.dropped) } }

  /// Send one frame, from the child's reader thread. Never blocks.
  ///
  /// `false` means the frame did not go out — not armed, already broken, or the
  /// socket had no room. None of those is worth failing the call over.
  @discardableResult
  func send(_ payload: Data) -> Bool {
    guard armed else { return false }
    return state.withLock { current in
      guard !current.broken else { return false }
      var out = Data()
      if !current.opened {
        out += Self.head
        // A small frame with the next one seconds away is exactly the shape
        // Nagle sits on. Set here rather than at accept so the ordinary
        // single-write path is untouched.
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
      }
      out += Self.frame(payload)

      switch Self.sendWithoutBlocking(fd, out) {
      case .sent:
        current.opened = true
        current.sent += 1
        return true
      case .dropped:
        // Nothing was written, so the stream is still intact and the head can
        // still go out with a later frame.
        current.dropped += 1
        return false
      case .broken:
        current.opened = true
        current.broken = true
        return false
      }
    }
  }

  /// Write the result and finish, from the connection's own thread.
  ///
  /// Only called when `isOpen`, so the status is already committed to 200 and
  /// the response's own status code is gone. That is reachable only for a call
  /// that emitted progress and then failed, which `Gateway` notes; the JSON-RPC
  /// error inside the body still says what happened, which is the part a client
  /// branches on.
  ///
  /// Nothing is written when the stream is broken: the peer has already seen a
  /// truncated event and the close is the honest end of it.
  func finish(with response: HTTPResponse) {
    let shouldWrite = state.withLock { current -> Bool in
      guard current.opened, !current.broken else { return false }
      current.sent += 1
      return true
    }
    guard shouldWrite else { return }
    _ = writeAll(fd, Self.frame(response.body))
  }

  // MARK: - Wire

  /// No `Content-Length` and no `Transfer-Encoding`: the body is delimited by
  /// the close, which RFC 9112 §6.3 allows for a response and which is the
  /// framing this server already uses on every reply. Chunked is ruled out in
  /// `HTTP.swift` and would buy nothing here.
  ///
  /// No `id:` on any event either. An `id:` is what invites a client back with
  /// `Last-Event-ID`, and there is no session and no replay buffer behind it.
  /// Not emitting one is how the stream stays honest about what it is.
  private static let head = Data(
    """
    HTTP/1.1 200 OK\r
    Content-Type: text/event-stream\r
    Connection: close\r
    Cache-Control: no-store\r
    X-Content-Type-Options: nosniff\r
    \r\n
    """.utf8)

  /// One event: a `data:` line per line of payload, then a blank line.
  ///
  /// The per-line split mirrors the join in `ServerSentEvents.dataPayloads`.
  /// `JSONSerialization` never emits a literal newline, but a payload forwarded
  /// verbatim from somebody else's server can be pretty-printed.
  private static func frame(_ payload: Data) -> Data {
    var out = Data()
    let newline = UInt8(ascii: "\n")
    for line in payload.split(separator: newline, omittingEmptySubsequences: false) {
      out += Data("data: ".utf8)
      out += line
      out.append(newline)
    }
    out.append(newline)
    return out
  }

  private enum SendOutcome {
    /// The whole frame went out.
    case sent
    /// Nothing went out. The stream is intact and a later frame may succeed.
    case dropped
    /// Either part of a frame went out, or the socket is gone. Stop.
    case broken
  }

  /// One frame, or nothing at all.
  ///
  /// `MSG_DONTWAIT` keeps this off the blocking path. A partial send is the
  /// only bad outcome and is why `broken` exists: it means bytes of a frame
  /// reached the peer and the rest never will.
  private static func sendWithoutBlocking(_ fd: Int32, _ data: Data) -> SendOutcome {
    data.withUnsafeBytes { raw -> SendOutcome in
      guard let base = raw.baseAddress else { return .sent }
      var offset = 0
      while offset < raw.count {
        let n = Darwin.send(fd, base + offset, raw.count - offset, MSG_DONTWAIT)
        if n > 0 {
          offset += n
          continue
        }
        if errno == EINTR { continue }
        // No room right now: retryable, but only if the frame had not already
        // started going out.
        if errno == EAGAIN || errno == EWOULDBLOCK {
          return offset == 0 ? .dropped : .broken
        }
        // EPIPE, ECONNRESET and friends. The peer is gone; stop trying.
        return .broken
      }
      return .sent
    }
  }
}
