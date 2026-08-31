import AppKit
import Foundation
import os

/// The half of OAuth that touches the network and the screen.
///
/// `RemoteOAuth` holds everything that is a pure function of a URL or a JSON
/// body, so it can be asserted with no app and no network. This is the rest:
/// the fetches, the browser, and the one lock that keeps N clients of a profile
/// from refreshing the same token N times.
///
/// ## Who starts what
///
/// **Authorization is only ever started by a person**, from the profile editor.
/// It needs a human at a browser and can take minutes or never finish, and
/// `Supervisor.call` is synchronous on a connection's own thread — so a client
/// whose profile is not authorized is told to go and authorize it, in a
/// sentence naming the profile, rather than left holding a socket while a
/// window waits for a click it may never get.
///
/// The browser is the user's own, and the code comes back to a one-shot
/// loopback listener rather than a custom scheme. `RemoteOAuthCallback` records
/// why: Stripe's consent page blocks navigation to any non-http(s) protocol, so
/// the private-use scheme authorized successfully and then dropped the code on
/// the floor.
///
/// **Refresh is started by a request**, because it needs nobody. It is a token
/// call with no UI, it happens inline on a 401, and the request that triggered
/// it is retried once.
nonisolated final class RemoteOAuthSession: @unchecked Sendable {
  static let shared = RemoteOAuthSession()

  /// One refresh at a time per profile.
  ///
  /// Four clients of `prod/stripe` hitting an expired token at once is the
  /// normal case, not a race to worry about later. Without this each would
  /// spend the same refresh token, and every provider that rotates refresh
  /// tokens on use would invalidate three of the four — leaving a profile that
  /// has to be re-authorized by hand for no reason anyone could see.
  private let refreshGates = OSAllocatedUnfairLock<[String: DispatchSemaphore]>(initialState: [:])

  private let session: URLSession

  private init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    session = URLSession(configuration: configuration)
  }

  // MARK: - Reading what a profile has

  /// The `Authorization` value for a profile, refreshing first if it is due.
  ///
  /// `nil` means this profile is not on OAuth at all, which is not an error —
  /// it is the bearer path, and the caller falls back to the profile's own
  /// variables.
  func authorizationHeader(profile: Profile, server: BastionServer) throws -> String? {
    guard let tokens = CredentialStore.readTokens(profile: profile.name, server: server.id)
    else { return nil }
    guard tokens.isExpired() else { return tokens.authorizationHeader }
    return try refresh(profile: profile, server: server, known: tokens).authorizationHeader
  }

  /// Whether this profile has been authorized. Never says anything about the
  /// token itself.
  static func isAuthorized(profile: String, server: String) -> Bool {
    CredentialStore.readTokens(profile: profile, server: server) != nil
  }

  func signOut(profile: Profile, server: BastionServer) throws {
    // Best effort, and deliberately before the local delete: a revocation that
    // fails must not stop the local removal, or "sign out" would leave the
    // token exactly where it was.
    if let tokens = CredentialStore.readTokens(profile: profile.name, server: server.id),
      let metadata = try? discover(for: server), let revocation = metadata.revocation
    {
      var request = URLRequest(url: revocation)
      request.httpMethod = "POST"
      request.setValue(
        "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      request.httpBody = RemoteOAuth.formBody([
        ("token", tokens.refreshToken ?? tokens.accessToken),
        ("client_id", tokens.clientID),
      ])
      _ = try? send(request)
    }
    try CredentialStore.deleteTokens(profile: profile.name, server: server.id)
    hostLog(profile.id, .info, "signed out of \(server.id)")
  }

  // MARK: - Refresh

  /// Exchange a refresh token for a live one.
  ///
  /// Behind a per-profile gate, and re-reading the stored set once inside it:
  /// the request that was second in line arrives to find the first has already
  /// refreshed, and returning that rather than spending the refresh token again
  /// is the entire point of the gate.
  @discardableResult
  func refresh(profile: Profile, server: BastionServer, known: RemoteOAuth.TokenSet) throws
    -> RemoteOAuth.TokenSet
  {
    let key = profile.id
    let gate = refreshGates.withLock { table -> DispatchSemaphore in
      if let existing = table[key] { return existing }
      let created = DispatchSemaphore(value: 1)
      table[key] = created
      return created
    }
    gate.wait()
    defer { gate.signal() }

    if let current = CredentialStore.readTokens(profile: profile.name, server: server.id),
      current.accessToken != known.accessToken, !current.isExpired()
    {
      return current
    }

    guard let refreshToken = known.refreshToken else {
      throw RemoteOAuth.OAuthError.tokenFailed(
        "\(server.id) issued no refresh token for the \(profile.name) profile, so it has to be "
          + "authorized again in Bastion")
    }
    let metadata = try discover(for: server)
    var request = URLRequest(url: metadata.token)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = RemoteOAuth.formBody([
      ("grant_type", "refresh_token"),
      ("refresh_token", refreshToken),
      ("client_id", known.clientID),
      // Re-asserted on refresh, not only at authorization: RFC 8707 binds the
      // token to this resource, and a refresh that dropped it could widen the
      // audience of every token after the first.
      ("resource", server.endpoint?.absoluteString ?? ""),
    ])

    let (status, json) = try sendJSON(request)
    guard (200..<300).contains(status) else {
      throw RemoteOAuth.OAuthError.tokenFailed(
        (json["error_description"] as? String) ?? (json["error"] as? String)
          ?? "HTTP \(status) from the token endpoint")
    }
    let refreshed = try RemoteOAuth.tokenSet(
      from: json, clientID: known.clientID, issuer: metadata.issuer, previous: known)
    try CredentialStore.writeTokens(refreshed, profile: profile.name, server: server.id)
    hostLog(profile.id, .info, "refreshed the \(server.id) token")
    return refreshed
  }

  // MARK: - Discovery

  /// Protected-resource metadata, then authorization-server metadata.
  ///
  /// The unauthenticated probe is what names the authorization server, and it
  /// is done rather than assumed: a server is entitled to delegate to any AS it
  /// likes and to say so only in its 401.
  func discover(for server: BastionServer) throws -> RemoteOAuth.Metadata {
    guard let endpoint = server.endpoint else {
      throw RemoteOAuth.OAuthError.discoveryFailed("\(server.id) is not a remote server")
    }
    try RemoteEndpoint.preflight(endpoint)

    // 1. Ask the resource where its metadata is.
    var probe = URLRequest(url: endpoint)
    probe.httpMethod = "POST"
    probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
    probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    probe.httpBody = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": "bastion-probe", "method": "initialize",
      "params": [
        "protocolVersion": server.dialect.rawValue, "capabilities": [:],
        "clientInfo": ["name": "bastion", "version": AppInfo.version],
      ],
    ])
    let (_, _, headers) = try send(probe)
    let challenge = headers["WWW-Authenticate"] ?? headers["Www-Authenticate"] ?? ""

    // A server that names its metadata is believed; one that does not gets the
    // RFC 9728 default path, which is the only other place it could be.
    let resourceMetadata =
      RemoteOAuth.resourceMetadataURL(fromChallenge: challenge)
      ?? URL(string: "/.well-known/oauth-protected-resource", relativeTo: endpoint)?.absoluteURL

    guard let resourceMetadata else { throw RemoteOAuth.OAuthError.noChallenge }
    try RemoteEndpoint.preflight(resourceMetadata)

    let (resourceStatus, resourceJSON) = try sendJSON(URLRequest(url: resourceMetadata))
    guard (200..<300).contains(resourceStatus),
      let servers = resourceJSON["authorization_servers"] as? [String],
      let first = servers.first, let issuer = URL(string: first)
    else {
      throw RemoteOAuth.OAuthError.discoveryFailed(
        "\(resourceMetadata.absoluteString) named no authorization server")
    }
    try RemoteEndpoint.preflight(issuer)

    // 2. The authorization server's own metadata, trying each spec-legal
    //    location in order.
    var lastDetail = "no metadata document"
    for candidate in RemoteOAuth.metadataURLs(forIssuer: issuer) {
      guard let (status, json) = try? sendJSON(URLRequest(url: candidate)),
        (200..<300).contains(status)
      else { continue }
      do {
        return try RemoteOAuth.Metadata.parse(json, expecting: issuer)
      } catch {
        // A document that parsed as the wrong issuer is a finding, not a miss.
        // Recorded and carried, so the failure names it rather than saying
        // "not found" about a document that was right there.
        lastDetail = error.localizedDescription
      }
    }
    throw RemoteOAuth.OAuthError.discoveryFailed(lastDetail)
  }

  // MARK: - Registration

  /// Register this profile as its own OAuth client, per RFC 7591.
  ///
  /// **Per profile, not per server.** Two profiles of one server are two
  /// identities by the whole design of the app, and giving them one client id
  /// would make them one row in the provider's own session list — so revoking
  /// `staging/stripe` from Stripe's dashboard would silently revoke
  /// `prod/stripe` too. One client each keeps "revoke this one" meaning what it
  /// says on both ends.
  private func register(
    metadata: RemoteOAuth.Metadata, profile: Profile, server: BastionServer, redirectURI: String
  ) throws -> String {
    guard let registration = metadata.registration else {
      throw RemoteOAuth.OAuthError.registrationFailed(
        "\(server.id) does not offer dynamic registration, so Bastion has no client id to use")
    }
    var request = URLRequest(url: registration)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "client_name": "Bastion (\(profile.name)/\(server.id))",
      "redirect_uris": [redirectURI],
      "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"],
      // A public client. Measured against Stripe, which advertises
      // `token_endpoint_auth_methods_supported: ["none"]` — so there is no
      // client secret, which is the single most dangerous thing this flow would
      // otherwise have to store.
      "token_endpoint_auth_method": "none",
      "application_type": "native",
    ])

    let (status, json) = try sendJSON(request)
    guard (200..<300).contains(status), let clientID = json["client_id"] as? String else {
      throw RemoteOAuth.OAuthError.registrationFailed(
        (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(status)")
    }
    return clientID
  }

  // MARK: - Authorization, the part with a person in it

  /// Discover, register, open a browser, and store what comes back.
  ///
  /// `async` because a person is involved and there is nothing to block on
  /// usefully — unlike every other path in the remote transport, this one is
  /// started from the UI and answers to it. The blocking parts run off the main
  /// actor so the window that started it stays alive while somebody reads a
  /// consent screen.
  func authorize(profile: Profile, server: BastionServer) async throws {
    // The listener first, because its port is part of the redirect URI and the
    // redirect URI is part of the registration. Bound before anything is
    // registered, so a port that cannot be opened fails before a client record
    // exists at the provider.
    let callback = try RemoteOAuthCallback()

    let metadata = try await offMain { try self.discover(for: server) }
    guard metadata.supportsS256 else {
      throw RemoteOAuth.OAuthError.discoveryFailed(
        "\(server.id)'s authorization server does not support PKCE S256, and Bastion will not "
          + "authorize without it")
    }
    guard let resource = server.endpoint else {
      throw RemoteOAuth.OAuthError.discoveryFailed("\(server.id) is not a remote server")
    }

    let clientID = try await offMain {
      try self.register(
        metadata: metadata, profile: profile, server: server,
        redirectURI: callback.redirectURI)
    }
    let pkce = RemoteOAuth.PKCE()
    let state = RemoteOAuth.randomState()
    guard
      let url = RemoteOAuth.authorizationURL(
        metadata: metadata, clientID: clientID, redirectURI: callback.redirectURI,
        resource: resource, state: state, pkce: pkce,
        scope: metadata.scopes.joined(separator: " "))
    else {
      throw RemoteOAuth.OAuthError.discoveryFailed("could not build an authorization URL")
    }

    await MainActor.run { NSWorkspace.shared.open(url) }

    // Five minutes. Long enough to find a password manager and a second factor,
    // short enough that an abandoned flow closes its socket rather than leaving
    // one open for the rest of the session.
    let redirect = try await offMain { try callback.waitForCallback(timeout: 300) }
    let code = try RemoteOAuth.code(fromCallback: redirect, expecting: state)

    var request = URLRequest(url: metadata.token)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = RemoteOAuth.formBody([
      ("grant_type", "authorization_code"),
      ("code", code),
      ("redirect_uri", callback.redirectURI),
      ("client_id", clientID),
      ("code_verifier", pkce.verifier),
      ("resource", resource.absoluteString),
    ])

    let (status, json) = try await offMain { try self.sendJSON(request) }
    guard (200..<300).contains(status) else {
      throw RemoteOAuth.OAuthError.tokenFailed(
        (json["error_description"] as? String) ?? (json["error"] as? String) ?? "HTTP \(status)")
    }
    let tokens = try RemoteOAuth.tokenSet(
      from: json, clientID: clientID, issuer: metadata.issuer, previous: nil)
    try CredentialStore.writeTokens(tokens, profile: profile.name, server: server.id)
    hostLog(profile.id, .info, "authorized with \(server.id)")
  }

  /// Run blocking work somewhere that is not the main actor.
  private func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) { try work() }.value
  }

  // MARK: - Blocking HTTP

  /// Blocking, like everything else the supervisor's thread calls into.
  private func send(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
    let semaphore = DispatchSemaphore(value: 0)
    let outcome = OSAllocatedUnfairLock<Result<(Int, Data, [String: String]), Error>?>(
      initialState: nil)
    let task = session.dataTask(with: request) { data, response, error in
      let result: Result<(Int, Data, [String: String]), Error>
      defer {
        outcome.withLock { $0 = result }
        semaphore.signal()
      }
      if let error {
        result = .failure(RemoteOAuth.OAuthError.discoveryFailed(error.localizedDescription))
        return
      }
      guard let http = response as? HTTPURLResponse else {
        result = .failure(RemoteOAuth.OAuthError.discoveryFailed("no HTTP response"))
        return
      }
      var headers: [String: String] = [:]
      for (key, value) in http.allHeaderFields {
        if let key = key as? String, let value = value as? String { headers[key] = value }
      }
      result = .success((http.statusCode, data ?? Data(), headers))
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + 35) == .success else {
      task.cancel()
      throw RemoteOAuth.OAuthError.discoveryFailed("timed out")
    }
    guard let result = outcome.withLock({ $0 }) else {
      throw RemoteOAuth.OAuthError.discoveryFailed("no response")
    }
    return try result.get()
  }

  private func sendJSON(_ request: URLRequest) throws -> (Int, [String: Any]) {
    let (status, data, _) = try send(request)
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return (status, json)
  }
}
