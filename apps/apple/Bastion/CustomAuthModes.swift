import Foundation

extension BastionServer.AuthMode {
  /// One variable of a custom entry, as far as choosing its modes cares.
  struct CustomVariable {
    var name: String
    var isRequired: Bool
    var isSecret: Bool
  }

  /// The modes a custom entry gets: none, or a sign in and, when it lists any,
  /// its optional secrets as the alternative to one.
  ///
  /// The alternative is the secrets *not* marked required, because a required
  /// variable is already required whichever mode is in force: the profile
  /// editor and `ProfileEnvironment` ask for it before they look at a mode at
  /// all. Without a secret to offer, the sign in is the only way in, which is
  /// the honest reading of an OAuth server added with nothing else to type.
  ///
  /// Remote only. `.oauth` starts by discovering against an endpoint, which a
  /// package has not got; `ServerStore.upsert` refuses the flag on one before
  /// it can get here, and this answers none if it ever does.
  ///
  /// Pure, and apart from `ServerStore`, so `make unit` can assert it.
  static func custom(oauth: Bool, isRemote: Bool, variables: [CustomVariable])
    -> [BastionServer.AuthMode]
  {
    guard oauth, isRemote else { return [] }
    var modes: [BastionServer.AuthMode] = [
      .init(id: "oauth2", displayName: "Sign in", kind: .oauth, env: [])
    ]
    let alternative = variables.filter { $0.isSecret && !$0.isRequired }.map(\.name)
    if !alternative.isEmpty {
      modes.append(.init(id: "credential", displayName: "Credential", kind: .env, env: alternative))
    }
    return modes
  }
}
