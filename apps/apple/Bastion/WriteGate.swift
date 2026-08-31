import Foundation

/// A remote server's write gate: which tools Bastion will not forward, and how
/// a `tools/list` answer is filtered before a client sees it.
///
/// A child server's gate is an environment variable, set once at spawn, and the
/// server itself then never registers the tool — `mcp-appstore-connect` guards
/// twelve of its tool files with a bare `if (!allowWrites) return;`. There is
/// nothing for Bastion to filter, because there is nothing there.
///
/// A remote server has no environment. The only thing Bastion controls is what
/// it forwards, so the gate moves here. Two sources, ORed:
///
/// - **The manifest's `writeTools`**, written down by whoever added the entry.
/// - **The server's own annotations**, learned from a `tools/list` that passed
///   through. This is what catches a mutating tool added after the manifest
///   list was written — the failure mode a pure denylist always has.
///
/// **This filters Bastion, not the server.** Anything else holding the same
/// credential can call the same API directly, so the credential's own scopes
/// remain the real boundary. Every UI that shows the toggle has to say so.
///
/// Its own file so `scripts/remote-check.swift` can compile it alone. It was
/// extracted after a bug in which the gate's logic was right and every
/// *consumer* of "does this server write" was wrong — see
/// `BastionServer.hasWritePath`. A rule with no test is a rule that gets
/// re-derived somewhere else.
nonisolated enum WriteGate {
  /// Tool names the server marks as mutating.
  ///
  /// `readOnlyHint: false` and `destructiveHint: true` are both read as "this
  /// changes things". A tool with no annotations at all says nothing either
  /// way and is not gated by this — only `writeTools` can gate it.
  static func annotatedWriteTools(in tools: [[String: Any]]) -> Set<String> {
    Set(
      tools.compactMap { tool -> String? in
        guard let name = tool["name"] as? String else { return nil }
        let hints = tool["annotations"] as? [String: Any]
        let readOnly = hints?["readOnlyHint"] as? Bool
        let destructive = hints?["destructiveHint"] as? Bool
        return readOnly == false || destructive == true ? name : nil
      })
  }

  /// Whether a call to `name` is gated, given the manifest's list and whatever
  /// annotations have been learned so far.
  static func isWriteTool(_ name: String, declared: [String], annotated: Set<String>) -> Bool {
    declared.contains(name) || annotated.contains(name)
  }

  /// The tools a client may see.
  ///
  /// Absent rather than offered-and-refused, which is what `BuiltinTools`
  /// already does and for the reason stated there: a model never plans around a
  /// tool it cannot use. The refusal on `tools/call` stays anyway, because a
  /// client holding a cached list can still name one.
  static func visibleTools(
    in tools: [[String: Any]], declared: [String], annotated: Set<String>, allowWrites: Bool
  ) -> [[String: Any]] {
    guard !allowWrites else { return tools }
    return tools.filter { tool in
      // A tool with no name cannot be gated by name. Kept rather than dropped:
      // it is malformed, and silently deleting somebody else's malformed tool
      // is a worse failure than passing it on.
      guard let name = tool["name"] as? String else { return true }
      return !isWriteTool(name, declared: declared, annotated: annotated)
    }
  }

  /// The whole filter over one `tools/list` response.
  ///
  /// Returns the answer to forward and the annotations learned on the way —
  /// which are recorded whether or not writes are on, because this instance is
  /// per profile and the annotation is a fact about the server.
  ///
  /// Anything that is not a `tools/list` result passes through untouched.
  static func filter(
    _ object: [String: Any], method: String, declared: [String], annotated: Set<String>,
    allowWrites: Bool
  ) -> (response: [String: Any], learned: Set<String>) {
    guard method == "tools/list",
      var result = object["result"] as? [String: Any],
      let tools = result["tools"] as? [[String: Any]]
    else { return (object, []) }

    let learned = annotatedWriteTools(in: tools)
    let kept = visibleTools(
      in: tools, declared: declared, annotated: annotated.union(learned), allowWrites: allowWrites)
    guard kept.count != tools.count else { return (object, learned) }

    result["tools"] = kept
    var out = object
    out["result"] = result
    return (out, learned)
  }
}
