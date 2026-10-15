import Foundation

/// What a profile rename moves outside `profiles.json`: its Keychain items and
/// its state directory.
///
/// Copy first, delete last. `ProfileStore.rename` copies the items and moves
/// the directory before it saves the new name, and deletes the old items only
/// after, so a failure anywhere before the save leaves the profile exactly as
/// it was.
nonisolated enum ProfileRename {
  /// One Keychain item written under the new name, kept so a failure later can
  /// take it back.
  struct Copied {
    let scope: CredentialStore.Scope
    let account: String
  }

  /// Every `.profile` and `.oauth` item of `old` on `server`, written again
  /// under `new` with the same suffix.
  ///
  /// `lookup`, never `read`. `read` answers a refused ACL prompt with nil,
  /// which here would skip the item and then let the sweep after the save
  /// delete the only copy of a secret. A refusal stops the rename instead.
  static func copySecrets(from old: String, to new: String, server: String) throws -> [Copied] {
    let oldPrefix = "\(old)/\(server)/"
    let newPrefix = "\(new)/\(server)/"
    var copied: [Copied] = []
    do {
      for scope in [CredentialStore.Scope.profile, .oauth] {
        for account in CredentialStore.accounts(scope) where account.hasPrefix(oldPrefix) {
          guard let value = try CredentialStore.lookup(scope, account: account), !value.isEmpty
          else { continue }
          let target = newPrefix + account.dropFirst(oldPrefix.count)
          try CredentialStore.write(scope, account: target, value: value)
          copied.append(Copied(scope: scope, account: target))
        }
      }
    } catch {
      delete(copied)
      throw error
    }
    return copied
  }

  /// Take back copies made by `copySecrets`.
  static func delete(_ copied: [Copied]) {
    for item in copied {
      try? CredentialStore.delete(item.scope, account: item.account)
    }
  }

  /// Delete every item under the old name, once the new one is saved.
  ///
  /// Logged, not thrown, because the rename has already happened. A profile
  /// created later under the old name could inherit whatever is left over.
  static func sweepSecrets(profile: String, server: String) {
    let prefix = "\(profile)/\(server)/"
    for scope in [CredentialStore.Scope.profile, .oauth] {
      for account in CredentialStore.accounts(scope) where account.hasPrefix(prefix) {
        do {
          try CredentialStore.delete(scope, account: account)
        } catch {
          hostLog("profiles", .error, "could not delete \(account) after a rename: \(error.localizedDescription)")
        }
      }
    }
  }

  /// Move the state directory, where a child keeps its own sign-in and the
  /// callback port it was given.
  ///
  /// Whatever already sits under the new name goes to the Trash first.
  /// `ProfileStore.remove` leaves a profile's directory behind, so that is a
  /// dead profile's tokens, and inheriting them is the bug. The Trash keeps it
  /// recoverable.
  static func moveState(from old: String, to new: String, server: String) throws {
    if DemoSeed.isEnabled { return }
    let files = FileManager.default
    let source = ProfileEnvironment.directory(profile: old, server: server)
    let target = ProfileEnvironment.directory(profile: new, server: server)
    if files.fileExists(atPath: target.path) {
      try files.trashItem(at: target, resultingItemURL: nil)
      hostLog("profiles", .info, "moved a leftover '\(new)/\(server)' state directory to the Trash")
    }
    guard files.fileExists(atPath: source.path) else { return }
    try files.moveItem(at: source, to: target)
  }
}
