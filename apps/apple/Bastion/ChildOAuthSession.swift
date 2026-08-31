import Foundation

/// Driving a login that belongs to somebody else's process.
///
/// The counterpart to `RemoteOAuthSession`, and its opposite in the one way
/// that matters: there, Bastion *is* the OAuth client — it discovers, it
/// registers, it holds the token in its own Keychain scope and injects a header
/// no tool can read back. Here it holds nothing. The client id is the server's,
/// the browser is opened by the child, the callback lands on the child's own
/// socket, and the refresh token is written into the child's per-profile state
/// directory by the child. Bastion presses the button and reports the answer.
///
/// That is not a lesser arrangement, and it is the reason the two kinds are
/// kept apart rather than merged behind one `isAuthorized` flag. Some servers
/// have to own their own OAuth: `mcp-reddit` cannot delegate it, because Reddit
/// matches `redirect_uri` byte for byte against a registration Bastion has no
/// way to edit. A single flag would let Bastion's "no tool can read this token"
/// promise be printed under a token Bastion never sees.
///
/// Everything here is a `tools/call` against the **live supervised child**,
/// through the same path a client takes — `ServerCheck.call`, which is also how
/// `ToolProbe` exercises a real server. A private throwaway process would prove
/// something about a server Bastion is not running, and would log in the wrong
/// one.
nonisolated enum ChildOAuthSession {

  enum ChildAuthError: LocalizedError {
    case unsavedProfile
    case malformed(tool: String)
    case refused(tool: String, message: String)

    var errorDescription: String? {
      switch self {
      case .unsavedProfile:
        return "Save the profile first — signing in runs the server with this profile's settings."
      case .malformed(let tool):
        return "'\(tool)' answered with something this version cannot read"
      case .refused(let tool, let message):
        return "'\(tool)' refused: \(message)"
      }
    }
  }

  // MARK: - Asking

  /// Whether the child says it is signed in.
  ///
  /// The child is the only authority. There is no file Bastion can stat and no
  /// Keychain item it can read — `stateEnv` puts the token somewhere inside the
  /// profile directory, but under a name the server chooses, and guessing it
  /// would be a second implementation of somebody else's storage format.
  ///
  /// Blocking, and a spawn if the child is not already up. Call it off the main
  /// actor and only when the answer is going to be shown.
  static func isSignedIn(profile: Profile, server: BastionServer, mode: BastionServer.AuthMode)
    throws -> Bool
  {
    guard let tool = mode.statusTool else { return false }
    let result = try call(tool: tool, profile: profile, server: server)
    // `signedIn` is the one field this reads. Everything else the status tool
    // returns is for a human or a model, and pattern-matching prose would be a
    // promise about wording nobody made.
    guard let signedIn = result["signedIn"] as? Bool else {
      throw ChildAuthError.malformed(tool: tool)
    }
    return signedIn
  }

  // MARK: - Acting

  /// Run the child's own login and report where it left things.
  ///
  /// Returns the signed-in state afterwards rather than throwing on every
  /// failure, because the interesting failure is not a failure. `Supervisor`
  /// abandons a call after 180 seconds, and a user reading a consent screen can
  /// take longer than that — but the child is still listening on its callback
  /// and still writes the token when the browser comes back. Reporting that as
  /// an error would be Bastion contradicting a login that worked, so the status
  /// tool gets the last word either way.
  @discardableResult
  static func logIn(profile: Profile, server: BastionServer, mode: BastionServer.AuthMode) throws
    -> Bool
  {
    guard let tool = mode.loginTool else { return false }
    var failure: Error?
    do {
      _ = try call(tool: tool, profile: profile, server: server)
    } catch {
      failure = error
    }

    // The child writes its token, then keeps serving the tools it registered at
    // startup — which, for a server that hides its user-scoped tools until it
    // has a user, is the wrong set. mcp-reddit says so itself: "Restart the MCP
    // server to pick up the user-scoped tools." Nothing else here would ever
    // restart it, so a successful login would look like it did nothing.
    restart(profile: profile, server: server)

    let signedIn = (try? isSignedIn(profile: profile, server: server, mode: mode)) ?? false
    if let failure, !signedIn { throw failure }
    return signedIn
  }

  /// Make the child forget its token.
  static func logOut(profile: Profile, server: BastionServer, mode: BastionServer.AuthMode) throws {
    guard let tool = mode.logoutTool else { return }
    _ = try call(tool: tool, profile: profile, server: server)
    restart(profile: profile, server: server)
  }

  // MARK: - Plumbing

  /// Stop the child so the next call spawns a fresh one.
  ///
  /// Stop rather than restart: nothing needs it running this instant, and
  /// spawning here would start a process for a profile the user may be about to
  /// close the editor on.
  private static func restart(profile: Profile, server: BastionServer) {
    Supervisor.shared.stop(profile: profile.name, server: server.id)
  }

  /// One `tools/call`, with the tool's own JSON payload decoded.
  ///
  /// The decoding, including the `isError`-in-a-result trap, is `ToolReply`'s —
  /// which is pure, and covered by `make unit`.
  private static func call(tool: String, profile: Profile, server: BastionServer) throws
    -> [String: Any]
  {
    guard ProfileStore.lookup(name: profile.name, server: server.id) != nil else {
      throw ChildAuthError.unsavedProfile
    }

    let result = try ServerCheck.call(
      profile: profile, server: server, era: .legacy, method: "tools/call",
      params: ["name": tool, "arguments": [String: Any]()],
      id: Int.random(in: 1_000...9_999))

    // Named against the tool that produced it: `ToolReply` cannot know which
    // call it is decoding, and "'reddit_auth_login' refused: ..." is the only
    // version of this sentence somebody can act on.
    do {
      return try ToolReply.decode(result)
    } catch ToolReply.ReplyError.refused(let message) {
      throw ChildAuthError.refused(tool: tool, message: message)
    } catch {
      throw ChildAuthError.malformed(tool: tool)
    }
  }
}
