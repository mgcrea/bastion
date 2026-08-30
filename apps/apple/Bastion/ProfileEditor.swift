import SwiftUI

/// Create or edit one profile — the screen this app did not have.
///
/// The split it enforces is rule 5, and it is the whole reason Bastion is worth
/// running: a value the manifest marks secret goes to the Keychain and nowhere
/// else, while everything else goes to `profiles.json`. Nothing here ever puts
/// a credential into a client config, a log line or the Activity feed.
///
/// A stored secret is never read back into its field. The editor asks the
/// Keychain only whether an item **exists**, which is a different question from
/// what it holds — so opening this sheet on a configured profile does not pull
/// a brokerage refresh token into a `String` in this process to render six
/// bullet characters. Leaving such a field untouched leaves the credential
/// exactly where it was.
struct ProfileEditor: View {
  /// What is being edited. One value rather than a `Bool` and a payload,
  /// because a sheet driven by two pieces of state can be presented with the
  /// wrong one.
  enum Subject: Identifiable {
    case new
    case existing(Profile)

    var id: String {
      switch self {
      case .new: "new"
      case .existing(let profile): profile.id
      }
    }

    var profile: Profile? {
      if case .existing(let profile) = self { return profile }
      return nil
    }
  }

  let server: BastionServer
  let subject: Subject

  @Environment(\.dismiss) private var dismiss

  @State private var name: String
  @State private var values: [String: String]
  @State private var secrets: [String: String]
  /// Secrets the user asked to delete outright, applied on save.
  @State private var cleared: Set<String>
  @State private var allowWrites: Bool
  @State private var error: String?

  init(server: BastionServer, subject: Subject) {
    self.server = server
    self.subject = subject
    let profile = subject.profile
    _name = State(initialValue: profile?.name ?? "")
    _values = State(initialValue: profile?.values ?? [:])
    _secrets = State(initialValue: [:])
    _cleared = State(initialValue: [])
    _allowWrites = State(initialValue: profile?.allowWrites ?? false)
  }

  private var isNew: Bool { subject.profile == nil }

  /// Which secrets are already held, asked by **account name only**.
  ///
  /// `CredentialStore.accounts` lists what exists without decrypting anything,
  /// which is the whole point: presence is what this screen needs to render and
  /// the value is what it must not handle.
  private var stored: Set<String> {
    guard let profile = subject.profile else { return [] }
    let prefix = "\(profile.name)/\(profile.serverID)/"
    return Set(
      CredentialStore.accounts(.profile)
        .filter { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)) })
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section {
          if isNew {
            TextField("Name", text: $name, prompt: Text("prod"))
              .textFieldStyle(.roundedBorder)
            Text(
              "Lower case, digits and hyphens. It becomes a URL path segment, a Keychain account "
                + "and a directory name, which is why it is fixed once created.")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            LabeledContent("Name", value: name)
            Text(
              "A profile cannot be renamed: its name is written into every client config that "
                + "points at it. Remove it and add another instead.")
              .font(.caption).foregroundStyle(.secondary)
          }
        } header: {
          Text("Profile")
        }

        Section {
          ForEach(server.env) { variable in
            VariableField(
              variable: variable,
              isStored: stored.contains(variable.name) && !cleared.contains(variable.name),
              plain: binding(for: variable.name),
              secret: secretBinding(for: variable.name),
              clear: { cleared.insert(variable.name); secrets[variable.name] = "" })
          }
        } header: {
          Text("Values")
        } footer: {
          if !server.callbackEnv.isEmpty {
            Text(
              "Bastion does not yet assign a loopback callback port per profile, so any callback "
                + "URL above must be set by hand and must match the upstream app registration.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }

        if let gate = server.writeGate {
          Section {
            Toggle("Allow writes", isOn: $allowWrites)
            Text(
              "Sets \(gate) for this profile alone. Another profile of the same server can have it "
                + "off at the same time.")
              .font(.caption).foregroundStyle(.secondary)
            if !server.gateBypass.isEmpty {
              Text(
                "\(server.gateBypass.joined(separator: ", ")) is forced off either way, so this "
                  + "toggle is the only switch on that wire.")
                .font(.caption).foregroundStyle(.secondary)
            }
          } header: {
            Text("Writes")
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack(spacing: 10) {
        // What is still missing, computed against what is about to be saved
        // rather than against what is on disk — so filling the last field
        // clears the warning before the sheet closes.
        if let blocking = pendingMissing, !blocking.isEmpty {
          Label("Will not start — missing \(blocking.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else if let error {
          Text(error)
            .font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Save") { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!Profile.isValidName(name))
      }
      .padding(12)
    }
    .frame(minWidth: 560, minHeight: 460)
  }

  // MARK: - Bindings

  private func binding(for key: String) -> Binding<String> {
    Binding(
      get: { values[key] ?? "" },
      set: { values[key] = $0 })
  }

  private func secretBinding(for key: String) -> Binding<String> {
    Binding(
      get: { secrets[key] ?? "" },
      set: {
        secrets[key] = $0
        // Typing into a field that was cleared is a change of mind, and the
        // pending deletion must not then wipe what was just entered.
        if !$0.isEmpty { cleared.remove(key) }
      })
  }

  // MARK: - What is still missing

  /// `ProfileEnvironment.missing` reads the Keychain, which is right at spawn
  /// time and wrong here: the value the user has just typed is not in it yet.
  /// So this answers the same question against the pending edit.
  private var pendingMissing: [String]? {
    guard Profile.isValidName(name) else { return nil }

    func isSet(_ variable: BastionServer.EnvVar) -> Bool {
      if variable.isSecret {
        if !(secrets[variable.name] ?? "").isEmpty { return true }
        return stored.contains(variable.name) && !cleared.contains(variable.name)
      }
      return !(values[variable.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    var missing = server.env.filter { $0.isRequired && !isSet($0) }.map(\.name)
    if !server.authModes.isEmpty {
      let satisfied = server.authModes.contains { mode in
        mode.env.allSatisfy { name in
          server.env.first { $0.name == name }.map(isSet) ?? false
        }
      }
      if !satisfied {
        let options = server.authModes
          .map { "\($0.displayName) (\($0.env.joined(separator: " + ")))" }
          .joined(separator: ", or ")
        missing.append("one of: \(options)")
      }
    }
    return missing
  }

  // MARK: - Save

  private func save() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard Profile.isValidName(trimmed) else {
      error = "A name must be lower case letters, digits and hyphens."
      return
    }
    if isNew, ProfileStore.shared.profile(named: trimmed, server: server.id) != nil {
      error = "A profile named '\(trimmed)' already exists for \(server.displayName)."
      return
    }

    // Only what the manifest names, and only what is not blank. An unknown key
    // would be dropped at spawn anyway; dropping it here keeps `profiles.json`
    // an honest record of what the profile actually sets.
    let known = Set(server.env.filter { !$0.isSecret }.map(\.name))
    var keep: [String: String] = [:]
    for (key, value) in values where known.contains(key) {
      let value = value.trimmingCharacters(in: .whitespaces)
      if !value.isEmpty { keep[key] = value }
    }

    do {
      // The Keychain first. A profile saved with `profiles.json` written and
      // its secrets not is a profile that reads as configured and cannot start;
      // the other order fails with nothing claimed.
      for variable in server.env where variable.isSecret {
        let account = CredentialStore.account(
          profile: trimmed, server: server.id, variable: variable.name)
        let typed = secrets[variable.name] ?? ""
        if !typed.isEmpty {
          try CredentialStore.write(.profile, account: account, value: typed)
        } else if cleared.contains(variable.name) {
          try CredentialStore.delete(.profile, account: account)
        }
        // Blank and not cleared means "leave what is there", which is how an
        // untouched field avoids erasing a credential it never displayed.
      }

      try ProfileStore.shared.upsert(
        Profile(
          name: trimmed, serverID: server.id, values: keep, allowWrites: allowWrites))
      hostLog(
        "profiles", .info,
        "\(isNew ? "created" : "updated") profile '\(trimmed)/\(server.id)'")
      dismiss()
    } catch {
      // Never the underlying value, and `CredentialStore` errors carry only a
      // status code — but this is the one path where a mistake would be silent.
      self.error = "Could not save: \(error.localizedDescription)"
    }
  }
}

// MARK: - One row

private struct VariableField: View {
  let variable: BastionServer.EnvVar
  let isStored: Bool
  @Binding var plain: String
  @Binding var secret: String
  let clear: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(variable.name)
          .font(.system(.caption, design: .monospaced))
        if variable.isRequired { Badge("required", tint: .secondary) }
        if variable.isSecret { Badge("Keychain", tint: .blue) }
        Spacer()
        if variable.isSecret && isStored {
          Button("Remove", action: clear)
            .font(.caption2)
            .buttonStyle(.borderless)
        }
      }

      // `.roundedBorder` explicitly. A `TextField` inside a nested stack in a
      // grouped `Form` gets the plain style, which on macOS draws no bezel at
      // all — the field is there and focusable and looks exactly like the
      // caption under it, so there is nothing on screen saying "type here".
      // The prompt made it worse rather than better: rendered without a box,
      // "Not set" reads as a heading for the row beneath it.
      if variable.isSecret {
        SecureField(
          variable.name,
          text: $secret,
          prompt: Text(isStored ? "Stored — type to replace" : "Not set"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      } else {
        TextField(variable.name, text: $plain, prompt: Text("Not set"))
          .labelsHidden()
          .textFieldStyle(.roundedBorder)
      }

      Text(variable.summary)
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
  }
}
