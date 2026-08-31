import Foundation

/// The payload inside an MCP `tools/call` result.
///
/// Split out of `ChildOAuthSession` with no dependencies on anything in the
/// app, so it can be compiled alone and fed real bytes by `make unit`. The rest
/// of that flow needs a supervised child and a browser; this part is pure, and
/// it is where the sharp edges are.
///
/// Two of them, both easy to get wrong in the direction that reports a failure
/// as a success:
///
/// 1. A tool that fails answers with a **result** carrying `isError: true`, not
///    a JSON-RPC error. Anything checking only the JSON-RPC layer sees success.
/// 2. The useful payload is JSON *encoded as text* inside `content`, so it
///    takes two decodes. A caller that stops after one gets a string.
enum ToolReply {

  enum ReplyError: LocalizedError {
    case malformed
    case refused(String)

    var errorDescription: String? {
      switch self {
      case .malformed: return "the reply was not a tool result this version can read"
      case .refused(let message): return message
      }
    }
  }

  /// The decoded payload, or a throw carrying the tool's own reason.
  static func decode(_ result: [String: Any]) throws -> [String: Any] {
    // Joined rather than `.first`: a server is free to split its text across
    // several content blocks, and taking only the first would parse half a
    // JSON document as the whole answer.
    let text =
      (result["content"] as? [[String: Any]])?
      .compactMap { $0["text"] as? String }
      .joined()

    guard let text, let data = text.data(using: .utf8),
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ReplyError.malformed
    }

    if result["isError"] as? Bool == true {
      throw ReplyError.refused(payload["error"] as? String ?? "no reason given")
    }
    return payload
  }
}
