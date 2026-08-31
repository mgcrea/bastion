import Foundation

/// What a recorded call is allowed to carry.
///
/// Bastion's audit line used to be a tool name and nothing else, and the claim
/// on screen said so. It now records what a tool was called with, because a
/// record that cannot say *which* order was fetched is a metrics counter rather
/// than an audit log. Two things had to be true first, and this file is where
/// both are enforced:
///
///   THE SECRET   `set_credential` takes the credential as an argument. A naive
///                capture writes a Keychain secret into the feed, which
///                `recent_activity` then hands back to a model — the exact
///                thing `BuiltinServer`'s first invariant forbids. A tool whose
///                argument *is* the secret cannot have its arguments recorded,
///                and that is not a setting.
///
///   THE SIZE     An argument is not reliably small. A note body, a file write
///                and a long prompt all arrive as one. Capture is capped in
///                bytes before it reaches a store that keeps 2000 of them.
///
/// Deliberately free of dependencies on the rest of the app: no store, no
/// catalog, no main actor. That is what lets `make unit` compile it against
/// `unit-check.swift` alone, which is the only kind of test this project has.
nonisolated enum CallCapture {
  /// How much of a call a profile wants kept.
  ///
  /// Ordered by how much it records, so `>=` is a meaningful question.
  enum Mode: String, Codable, CaseIterable, Comparable {
    /// Names only — what Bastion recorded before any of this existed.
    case off
    /// What a tool was called with.
    case arguments
    /// And what it answered.
    case argumentsAndResults

    private var rank: Int {
      switch self {
      case .off: 0
      case .arguments: 1
      case .argumentsAndResults: 2
      }
    }

    static func < (a: Mode, b: Mode) -> Bool { a.rank < b.rank }

    var label: String {
      switch self {
      case .off: "Names only"
      case .arguments: "Arguments"
      case .argumentsAndResults: "Arguments and results"
      }
    }
  }

  /// What the app records when a profile has expressed no preference.
  ///
  /// Arguments on, results off. Arguments are the half that answers "what did
  /// the agent actually send", which is the question worth having by default;
  /// results are the unbounded half and are opted into per profile.
  static let defaultMode: Mode = .arguments

  /// Per payload, before it reaches a 2000-entry ring buffer.
  static let byteCap = 4096

  // MARK: - Settings

  /// The app-wide default, for every profile that has expressed no preference.
  static let defaultsKey = "callCaptureMode"

  /// Whether `recent_activity` may report profiles other than the caller's.
  ///
  /// Off. A profile's own rows are safe to hand back by construction — the
  /// agent already sent those arguments and received those results, so it
  /// learns nothing it did not have. Another profile's rows are the one thing
  /// a gateway holding every credential on the machine must not volunteer, so
  /// widening this is a deliberate act rather than the default.
  static let allProfilesDefaultsKey = "recentActivityAllProfiles"

  static var globalDefault: Mode {
    guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
      let mode = Mode(rawValue: raw)
    else { return defaultMode }
    return mode
  }

  static var reportsAllProfiles: Bool {
    UserDefaults.standard.bool(forKey: allProfilesDefaultsKey)
  }

  /// What replaces a value that must not be recorded.
  static let redacted = "«redacted»"

  /// Tools whose arguments are never captured, whatever any setting says.
  ///
  /// `set_credential`'s `value` parameter is documented to models as "The
  /// secret. Stored in the Keychain, never written to disk." Recording it would
  /// make that sentence false in the one place a model can read back.
  static let neverCapture: Set<String> = ["set_credential"]

  /// Argument keys that are always redacted, whichever server declared them.
  ///
  /// A backstop under the manifest, not a replacement for it. Bastion knows
  /// which of *its own* variables are secret; it cannot know that a third-party
  /// server's `token` argument is one, so this covers the names that are
  /// conventional enough to be worth guessing at. Redaction here is
  /// best-effort by construction and the UI must not imply otherwise.
  static let alwaysRedacted: Set<String> = [
    "value", "secret", "token", "password", "passwd", "credential", "credentials",
    "api_key", "apikey", "access_token", "refresh_token", "client_secret",
    "authorization", "auth", "private_key", "session", "cookie",
  ]

  // MARK: - Capture

  /// What a `tools/call` was called with, or nil if nothing should be kept.
  ///
  /// `secretKeys` is the calling profile's manifest variables marked secret —
  /// the one set of names Bastion can be certain about.
  static func arguments(
    tool: String?, params: [String: Any]?, mode: Mode, secretKeys: Set<String> = []
  ) -> String? {
    guard mode >= .arguments, let params else { return nil }
    if let tool, neverCapture.contains(tool) { return nil }
    guard let inner = params["arguments"] as? [String: Any] else { return nil }
    if inner.isEmpty { return nil }
    return encode(redact(inner, secretKeys: secretKeys))
  }

  /// What came back, or nil if nothing should be kept.
  ///
  /// An `error` frame and an `isError: true` result are both kept: a failure is
  /// the case someone is most likely to be reading the log to understand, and
  /// neither is visible today even as a failure.
  static func result(_ frame: [String: Any]?, mode: Mode, secretKeys: Set<String> = []) -> String? {
    guard mode >= .argumentsAndResults, let frame else { return nil }
    if let error = frame["error"] {
      return encode(redact(error, secretKeys: secretKeys))
    }
    guard let value = frame["result"] else { return nil }
    if let object = value as? [String: Any], object.isEmpty { return nil }
    return encode(redact(value, secretKeys: secretKeys))
  }

  /// Whether a result frame reported a failure, for the row's tint.
  static func isFailure(_ frame: [String: Any]?) -> Bool {
    guard let frame else { return false }
    if frame["error"] != nil { return true }
    return (frame["result"] as? [String: Any])?["isError"] as? Bool == true
  }

  // MARK: - Redaction

  /// Walk a decoded JSON value, blanking anything under a secret-looking key.
  ///
  /// Recurses through objects and arrays, because a credential nested two
  /// levels down is still a credential. Matching is case-insensitive and
  /// ignores `-`/`_`, so `API-Key`, `api_key` and `apiKey` are one name.
  static func redact(_ value: Any, secretKeys: Set<String>) -> Any {
    switch value {
    case let object as [String: Any]:
      var out: [String: Any] = [:]
      for (key, inner) in object {
        out[key] = isSecretKey(key, secretKeys) ? redacted : redact(inner, secretKeys: secretKeys)
      }
      return out
    case let array as [Any]:
      return array.map { redact($0, secretKeys: secretKeys) }
    default:
      return value
    }
  }

  static func isSecretKey(_ key: String, _ secretKeys: Set<String>) -> Bool {
    let normalised = normalise(key)
    if alwaysRedacted.contains(where: { normalise($0) == normalised }) { return true }
    return secretKeys.contains { normalise($0) == normalised }
  }

  private static func normalise(_ s: String) -> String {
    s.lowercased().replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "_", with: "")
  }

  // MARK: - Encoding

  /// Compact JSON, capped, or nil if it cannot be represented.
  ///
  /// `JSONSerialization` refuses a fragment, so a bare string or number result
  /// is wrapped rather than dropped — a tool that answers `"ok"` should still
  /// leave a record.
  static func encode(_ value: Any) -> String? {
    let wrapped: Any = JSONSerialization.isValidJSONObject(value) ? value : [value]
    guard let data = try? JSONSerialization.data(withJSONObject: wrapped, options: [.sortedKeys]),
      var text = String(data: data, encoding: .utf8)
    else { return nil }
    if !JSONSerialization.isValidJSONObject(value) {
      // Unwrap the single-element array the wrap above added.
      text = String(text.dropFirst().dropLast())
    }
    return truncate(text, to: byteCap)
  }

  /// Cut to `limit` bytes on a character boundary, saying how much went.
  ///
  /// Bytes rather than characters because the cap exists to bound memory, and
  /// on a boundary because a `String` cut mid-scalar is not a `String`. The
  /// marker is part of the record: a truncated argument that does not say it
  /// was truncated is a misleading audit line.
  static func truncate(_ text: String, to limit: Int) -> String {
    let bytes = text.utf8.count
    guard bytes > limit else { return text }
    var end = text.startIndex
    var used = 0
    for index in text.indices {
      let width = text[index].utf8.count
      if used + width > limit { break }
      used += width
      end = text.index(after: index)
    }
    return String(text[text.startIndex..<end]) + "… +\(bytes - used) bytes"
  }
}
