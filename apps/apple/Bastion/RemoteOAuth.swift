import CryptoKit
import Foundation

/// The OAuth 2.1 client for remote servers — everything except the browser.
///
/// Split from `RemoteOAuthSession` on purpose: everything here is a pure
/// function of a URL, a header or a JSON body, so `scripts/remote-check.swift`
/// can compile and assert it with no app, no network and no window. The half
/// that needs `AuthenticationServices` and a screen lives next door and is the
/// only part a check cannot reach.
///
/// ## Why this exists at all
///
/// The bearer path works and is not going away — Stripe accepts a restricted
/// key, and for a Connect platform acting on a connected account it is the
/// *only* thing that works, because Stripe does not support OAuth in that mode.
/// What OAuth adds is the thing a gateway is uniquely placed to do: **the
/// consent dance happens once, per profile, and every client shares the result
/// without ever seeing a token.** No key is typed into any config file, nothing
/// is pasted into a chat, and the credential can be revoked from the provider's
/// own dashboard rather than hunted for across four repos.
///
/// ## What was measured, rather than assumed
///
/// Against `access.stripe.com` on 2026-08-31:
///
/// - Metadata is at the RFC 8414 **path-insertion** URL. For issuer
///   `https://access.stripe.com/mcp` that is
///   `https://access.stripe.com/.well-known/oauth-authorization-server/mcp`,
///   and NOT `https://access.stripe.com/mcp/.well-known/...`, which 404s. Both
///   forms appear in the wild, so `metadataURLs` returns both, in spec order.
/// - `token_endpoint_auth_method: "none"` — a **public client**. There is no
///   client secret to store, which removes the single most dangerous thing this
///   file would otherwise have to keep.
/// - `code_challenge_methods_supported: ["S256"]`, `scope: "mcp"`,
///   `grant_types: [authorization_code, refresh_token]`.
/// - Dynamic registration accepts a private-use redirect scheme, and it does
///   not matter: Stripe's consent page refuses to *navigate* to one. See
///   `RemoteOAuthCallback` for what replaced it and why registration succeeding
///   was not evidence that it worked.
/// - No `Mcp-Session-Id` is issued, so a refreshed token needs no re-handshake.
nonisolated enum RemoteOAuth {

  enum OAuthError: LocalizedError, Equatable {
    case noChallenge
    case notHTTPS(String)
    case issuerMismatch(expected: String, got: String)
    case discoveryFailed(String)
    case registrationFailed(String)
    case tokenFailed(String)
    case stateMismatch
    case denied(String)

    var errorDescription: String? {
      switch self {
      case .noChallenge:
        return
          "the server refused without saying where to authorize — no WWW-Authenticate with "
          + "resource metadata, so there is nothing to discover"
      case .notHTTPS(let url):
        return "\(url) is not https, and an authorization endpoint has to be"
      case .issuerMismatch(let expected, let got):
        return
          "metadata for \(expected) declares its issuer as \(got). Refused: that mismatch is how "
          + "a discovery document gets pointed at somebody else's authorization server"
      case .discoveryFailed(let detail): return "could not discover how to authorize: \(detail)"
      case .registrationFailed(let detail): return "could not register with the server: \(detail)"
      case .tokenFailed(let detail): return "the token request failed: \(detail)"
      case .stateMismatch:
        return "the authorization response did not match the request it answers — refused"
      case .denied(let detail): return "authorization was refused: \(detail)"
      }
    }
  }

  // MARK: - Step 1, the challenge

  /// The protected-resource metadata URL named by a 401, per RFC 9728.
  ///
  /// Parsed rather than guessed. A server is entitled to put its metadata
  /// anywhere and say so here, and constructing the well-known path ourselves
  /// would work against Stripe and quietly fail against the next one.
  static func resourceMetadataURL(fromChallenge header: String) -> URL? {
    // `Bearer resource_metadata=https://…, error="…"`. Quoted or bare, and the
    // parameter order is not fixed.
    for part in header.split(separator: ",") {
      let trimmed = part.trimmingCharacters(in: .whitespaces)
      let body = trimmed.hasPrefix("Bearer ") ? String(trimmed.dropFirst(7)) : trimmed
      guard let equals = body.firstIndex(of: "=") else { continue }
      let key = body[body.startIndex..<equals].trimmingCharacters(in: .whitespaces)
      guard key.lowercased() == "resource_metadata" else { continue }
      var value = String(body[body.index(after: equals)...])
        .trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
        value = String(value.dropFirst().dropLast())
      }
      return URL(string: value)
    }
    return nil
  }

  // MARK: - Step 2, authorization server metadata

  /// Where to look for an issuer's metadata, in the order to try.
  ///
  /// RFC 8414 §3.1 inserts `.well-known/oauth-authorization-server` **between**
  /// the host and the issuer's path, which is counter-intuitive and is the form
  /// Stripe actually serves. The naive concatenation is tried second because
  /// some servers do use it, and the OpenID form third for the ones that only
  /// publish that.
  static func metadataURLs(forIssuer issuer: URL) -> [URL] {
    let path = issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var base = URLComponents(url: issuer, resolvingAgainstBaseURL: false) else { return [] }
    base.path = ""
    base.query = nil
    base.fragment = nil

    var out: [URL] = []
    func add(_ candidate: String) {
      var components = base
      components.path = candidate
      if let url = components.url { out.append(url) }
    }
    if path.isEmpty {
      add("/.well-known/oauth-authorization-server")
      add("/.well-known/openid-configuration")
    } else {
      add("/.well-known/oauth-authorization-server/\(path)")
      add("/\(path)/.well-known/oauth-authorization-server")
      add("/.well-known/openid-configuration/\(path)")
    }
    return out
  }

  struct Metadata: Equatable {
    let issuer: URL
    let authorization: URL
    let token: URL
    let registration: URL?
    let revocation: URL?
    let scopes: [String]
    let supportsS256: Bool

    /// Parsed strictly, because everything downstream trusts it.
    ///
    /// The issuer check is the load-bearing one: a document fetched for issuer
    /// A that declares itself issuer B is either misconfigured or an attempt to
    /// aim the browser somewhere else, and neither is worth guessing through.
    static func parse(_ json: [String: Any], expecting issuer: URL) throws -> Metadata {
      func https(_ key: String, required: Bool) throws -> URL? {
        guard let raw = json[key] as? String, !raw.isEmpty else {
          if required { throw OAuthError.discoveryFailed("no \(key)") }
          return nil
        }
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else {
          throw OAuthError.notHTTPS(raw)
        }
        return url
      }

      let declared = (json["issuer"] as? String) ?? ""
      let normalise = { (s: String) in s.hasSuffix("/") ? String(s.dropLast()) : s }
      guard normalise(declared) == normalise(issuer.absoluteString) else {
        throw OAuthError.issuerMismatch(expected: issuer.absoluteString, got: declared)
      }

      let methods = (json["code_challenge_methods_supported"] as? [String]) ?? []
      return Metadata(
        issuer: issuer,
        authorization: try https("authorization_endpoint", required: true)!,
        token: try https("token_endpoint", required: true)!,
        registration: try https("registration_endpoint", required: false),
        revocation: try https("revocation_endpoint", required: false),
        scopes: (json["scopes_supported"] as? [String]) ?? [],
        supportsS256: methods.contains("S256"))
    }
  }

  // MARK: - Step 3, PKCE

  /// A verifier and its S256 challenge, per RFC 7636.
  ///
  /// PKCE is not optional in OAuth 2.1 and is what makes a public client safe:
  /// an intercepted authorization code is useless without the verifier, which
  /// never leaves this process.
  struct PKCE {
    let verifier: String
    var challenge: String { Self.challenge(for: verifier) }

    init() {
      var bytes = [UInt8](repeating: 0, count: 32)
      _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      verifier = Self.base64URL(Data(bytes))
    }

    init(verifier: String) { self.verifier = verifier }

    static func challenge(for verifier: String) -> String {
      base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// base64url with no padding — RFC 7636 §A.
    static func base64URL(_ data: Data) -> String {
      data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
  }

  // MARK: - Step 4, the authorization request

  /// The URL the browser is sent to.
  ///
  /// `resource` is RFC 8707 audience binding, and it is why a token minted here
  /// cannot be replayed against a different MCP server that happens to trust the
  /// same authorization server.
  static func authorizationURL(
    metadata: Metadata, clientID: String, redirectURI: String, resource: URL, state: String,
    pkce: PKCE, scope: String?
  ) -> URL? {
    guard var components = URLComponents(url: metadata.authorization, resolvingAgainstBaseURL: false)
    else { return nil }
    var items = [
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "resource", value: resource.absoluteString),
    ]
    if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
    components.queryItems = (components.queryItems ?? []) + items
    return components.url
  }

  /// The code out of the callback URL, with the state checked first.
  ///
  /// A mismatched state is refused rather than reported, because the only
  /// reason to see one is a response to a request this app did not make.
  static func code(fromCallback url: URL, expecting state: String) throws -> String {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ name: String) -> String? {
      items.first { $0.name == name }?.value
    }
    if let error = value("error") {
      throw OAuthError.denied(value("error_description") ?? error)
    }
    guard value("state") == state else { throw OAuthError.stateMismatch }
    guard let code = value("code"), !code.isEmpty else {
      throw OAuthError.denied("no code in the callback")
    }
    return code
  }

  // MARK: - Step 5, the token set

  /// What a profile holds once it is authorized.
  ///
  /// One Keychain item holding all of it as JSON, rather than a field per item:
  /// a refresh that updated the access token but failed to update the expiry
  /// would leave a profile that believes a dead token is live, and a single
  /// atomic write cannot land half way.
  struct TokenSet: Codable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scope: String?
    /// From dynamic registration. Kept so a refresh does not have to discover
    /// and register all over again.
    var clientID: String
    /// The issuer these came from. If a server's metadata later names a
    /// different one, the stored set is for somebody else and is discarded
    /// rather than sent.
    var issuer: String

    /// Refresh slightly early. A token that expires between the check and the
    /// request arriving is a 401 that costs a round trip and a retry, and sixty
    /// seconds is cheaper than finding out.
    func isExpired(now: Date = Date()) -> Bool {
      guard let expiresAt else { return false }
      return now.addingTimeInterval(60) >= expiresAt
    }

    var authorizationHeader: String { "Bearer \(accessToken)" }
  }

  /// Build a token set from a token-endpoint response.
  static func tokenSet(
    from json: [String: Any], clientID: String, issuer: URL, previous: TokenSet?
  ) throws -> TokenSet {
    if let error = json["error"] as? String {
      throw OAuthError.tokenFailed((json["error_description"] as? String) ?? error)
    }
    guard let access = json["access_token"] as? String, !access.isEmpty else {
      throw OAuthError.tokenFailed("no access_token in the response")
    }
    var expires: Date?
    if let seconds = json["expires_in"] as? Double {
      expires = Date().addingTimeInterval(seconds)
    } else if let seconds = json["expires_in"] as? Int {
      expires = Date().addingTimeInterval(Double(seconds))
    }
    return TokenSet(
      accessToken: access,
      // A refresh response is allowed to omit the refresh token, and doing so
      // means "keep the one you have". Dropping it here would turn every such
      // refresh into the last one this profile can ever do.
      refreshToken: (json["refresh_token"] as? String) ?? previous?.refreshToken,
      expiresAt: expires,
      scope: (json["scope"] as? String) ?? previous?.scope,
      clientID: clientID,
      issuer: issuer.absoluteString)
  }

  /// Form-encode a token request body.
  ///
  /// `application/x-www-form-urlencoded`, and every value percent-encoded:
  /// an authorization code containing `+` or `&` is legal and would otherwise
  /// arrive truncated as a maddeningly intermittent failure.
  static func formBody(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    let encoded = fields.map { key, value in
      let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
      let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
      return "\(k)=\(v)"
    }
    return Data(encoded.joined(separator: "&").utf8)
  }

  /// A random, URL-safe `state`.
  static func randomState() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return PKCE.base64URL(Data(bytes))
  }
}
