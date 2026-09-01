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
  /// Empty string means "follow the app-wide default", which is what nil means
  /// on the profile — `Picker` needs a concrete tag, so the absence is spelled
  /// rather than optional here.
  @State private var capture: String
  @State private var error: String?
  /// Authorization state, kept separately from `error` so a failed sign-in does
  /// not look like a failed save.
  @State private var isAuthorized: Bool = false
  /// What the child last said about its own login, for a `.childOAuth` server.
  ///
  /// Four states rather than a Bool, because "not asked" is a real answer here
  /// and is not the same as "signed out". Only the child knows, asking costs a
  /// spawn, and rendering the unasked case as "Not authorized" would invite
  /// somebody to sign in on top of a login that already works.
  @State private var childAuthState: ChildAuthState = .unknown
  @State private var authorizing = false

  enum ChildAuthState {
    case unknown
    case checking
    case signedIn
    case signedOut
  }
  @State private var authError: String?

  init(server: BastionServer, subject: Subject) {
    self.server = server
    self.subject = subject
    let profile = subject.profile
    _name = State(initialValue: profile?.name ?? "")
    _values = State(initialValue: profile?.values ?? [:])
    _secrets = State(initialValue: [:])
    _cleared = State(initialValue: [])
    _allowWrites = State(initialValue: profile?.allowWrites ?? false)
    _capture = State(initialValue: profile?.captureMode?.rawValue ?? "")
  }

  private var isNew: Bool { subject.profile == nil }

  /// Which secrets are already held, asked by **account name only**.
  ///
  /// `CredentialStore.storedVariables` lists what exists without decrypting
  /// anything, which is the whole point: presence is what this screen needs to
  /// render and the value is what it must not handle.
  private var stored: Set<String> {
    guard let profile = subject.profile else { return [] }
    return CredentialStore.storedVariables(profile: profile.name, server: profile.serverID)
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

        authorizationSection

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
            callbackFooter
          }
        }

        Section {
          Picker("Record", selection: $capture) {
            Text("Default (\(CallCapture.globalDefault.label))").tag("")
            ForEach(CallCapture.Mode.allCases, id: \.self) { mode in
              Text(mode.label).tag(mode.rawValue)
            }
          }
          Text(
            "For this profile alone. Another profile of the same server can record more, or "
              + "nothing. Credentials are never recorded, and nothing is written to disk.")
            .font(.caption).foregroundStyle(.secondary)
        } header: {
          Text("Activity")
        }

        writesSection
      }
      .formStyle(.grouped)
      // The badge is read from the Keychain rather than remembered, so it is
      // right after a sign-out that happened in another window. A `.childOAuth`
      // server is asked only if it is already running — see
      // `refreshAuthorization` — so opening this sheet never spawns anything.
      .onAppear { refreshAuthorization() }

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
        switch mode.kind {
        case .env:
          return mode.env.allSatisfy { name in
            server.env.first { $0.name == name }.map(isSet) ?? false
          }
        // Exactly the rule `ProfileEnvironment.missing` uses. Two answers to
        // "is this profile usable" is how an editor comes to say Save is fine
        // about a profile the gateway then refuses.
        case .oauth:
          return isAuthorized
        // A `.childOAuth` mode is NOT a gate, and this is the one place the
        // two OAuth kinds must part company. A remote server with no
        // credential can do nothing, so `.oauth` unsatisfied means unusable.
        // A child that logs itself in still works signed out — mcp-reddit
        // serves public reads anonymously, on purpose — and Bastion cannot
        // know whether it is signed in without asking it, which is a spawn
        // and a round trip. Answering "no" here would paint every Reddit
        // profile permanently unusable, including the ones working fine; the
        // authoritative answer is the Authorization section's own dot, which
        // asks the child.
        case .childOAuth:
          return true
        }
      }
      if !satisfied {
        let options = server.authModes
          .map { mode in
            switch mode.kind {
            case .env: "\(mode.displayName) (\(mode.env.joined(separator: " + ")))"
            case .oauth, .childOAuth: "\(mode.displayName) — authorize it above"
            }
          }
          .joined(separator: ", or ")
        missing.append("one of: \(options)")
      }
    }
    return missing
  }

  /// The Authorization section, lifted out of `body`.
  ///
  /// Not a stylistic split: `body` is one expression, and adding a third
  /// auth kind to it pushed the whole form past what the type checker will
  /// solve. Anything added here should stay here.
  @ViewBuilder private var authorizationSection: some View {
  if let oauth = server.authModes.first(where: \.isInteractive) {
    Section {
      HStack(spacing: 10) {
        Circle()
          .fill(authorizationTint(for: oauth))
          .frame(width: 7, height: 7)
        Text(authorizationLabel(for: oauth))
          .font(.callout)
        Spacer()
        if authorizing || childAuthState == .checking {
          ProgressView().controlSize(.small)
        } else if isSignedIn(for: oauth) {
          Button("Sign out", role: .destructive) { signOut() }
        } else {
          // Offered next to the button rather than instead of it: an
          // unknown state is not a reason to make signing in harder, and
          // checking is the cheaper of the two for somebody who suspects
          // they are already signed in.
          if oauth.kind == .childOAuth, childAuthState == .unknown {
            Button("Check") { refreshAuthorization(forceCheck: true) }
          }
          Button(oauth.displayName) { authorize() }
            .buttonStyle(.borderedProminent)
        }
      }
      if let authError {
        Text(authError)
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      // Two kinds, two different true sentences. Bastion holds a
      // `.oauth` token and can promise things about it; a `.childOAuth`
      // token belongs to the server, and printing the Keychain promise
      // over it would be a claim about custody Bastion does not have.
      Text(authorizationCaption(for: oauth))
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if oauth.kind == .childOAuth, server.writeGate != nil {
        // Scopes are fixed at the consent screen. mcp-reddit asks for the
        // write scopes only when its gate is already on, so a login taken
        // before the toggle was saved comes back read-only and every
        // write fails later with a 403 that looks like a Reddit problem.
        Text(
          "The write toggle below is part of what is requested: sign in after setting it, "
            + "and sign in again if you change it.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("Authorization")
    }
  }
  }

  /// The per-profile callback URL, lifted out of `body` for the same reason.
  @ViewBuilder private var callbackFooter: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(
        "The first profile keeps \(server.displayName)'s own default callback, so its setup "
          + "instructions stay correct. A second profile is a second identity and gets its own "
          + "port, which needs its own upstream app — the URL is matched byte for byte. "
          + "Setting the variable above overrides whatever is shown.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      ForEach(server.callbackEnv) { callback in
        // Selectable, because the whole point is that it gets pasted
        // into somebody's app registration page.
        Text(assignedCallback(callback))
          .font(.system(.caption2, design: .monospaced))
          .textSelection(.enabled)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// The Writes section, lifted out of `body` for the same reason as the
  /// Authorization one: the form is a single expression and was already at
  /// the edge of what the type checker will solve.
  @ViewBuilder private var writesSection: some View {
  if server.hasWritePath {
    Section {
      Toggle("Allow writes", isOn: $allowWrites)

      if let gate = server.writeGate {
        Text(
          "Sets \(gate) for this profile alone. Another profile of the same server can have "
            + "it off at the same time.")
          .font(.caption).foregroundStyle(.secondary)
        if !server.gateBypass.isEmpty {
          Text(
            "\(server.gateBypass.joined(separator: ", ")) is forced off either way, so this "
              + "toggle is the only switch on that wire.")
            .font(.caption).foregroundStyle(.secondary)
        }
      } else {
        // A remote server has no environment, so there is no variable to
        // name — the gate is a list of tools Bastion will not forward.
        Text(
          server.writeTools.isEmpty
            ? "For this profile alone. With writes off, Bastion does not forward any tool "
              + "this server marks as not read-only."
            : "For this profile alone. With writes off, Bastion does not forward "
              + "\(server.writeTools.joined(separator: ", ")) — nor any tool this server "
              + "marks as not read-only.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        // The limit, at the point somebody decides whether to trust the
        // switch. Said here as well as on the server's own card, because
        // this is the screen where the decision is actually made.
        Text(
          "This filters what Bastion forwards, not what the server accepts. Anything else "
            + "holding this credential can call the same API directly, so its own scopes "
            + "are the real limit.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } header: {
      Text("Writes")
    }
  }
  }

  // MARK: - Authorization

  /// The interactive mode this editor is showing, if any.
  private var authMode: BastionServer.AuthMode? {
    server.authModes.first(where: \.isInteractive)
  }

  /// The profile as it stands in the editor, which is what a sign-in has to run
  /// under: `allowWrites` is part of what a `.childOAuth` server asks consent
  /// for, so a token minted against the saved value would carry the wrong
  /// scopes the moment somebody flips the toggle and signs in without saving.
  private var draftProfile: Profile {
    Profile(
      name: name, serverID: server.id, values: [:], allowWrites: allowWrites,
      captureMode: CallCapture.Mode(rawValue: capture))
  }

  /// The callback URL this profile has been assigned, or `nil` before there is
  /// a profile to assign one to.
  ///
  /// Read-only here and deliberately not shown as an editable default: writing
  /// it into `values` would freeze today's port into the profile, and the
  /// assignment is meant to be Bastion's to keep. A user who wants a specific
  /// URL types it into the variable above, which wins at spawn time.
  /// What to show for a callback variable. Reads; never decides.
  ///
  /// `ProfileEnvironment.decideCallback` writes to disk, so calling it from
  /// here would run it once per keystroke against a half-typed profile name —
  /// which is precisely what it did, leaving a directory and a burnt port for
  /// every prefix of the name somebody typed. A view asks; the spawn decides.
  private func assignedCallback(_ callback: BastionServer.CallbackVar) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
      let assignment = ProfileEnvironment.callbackAssignment(
        profile: trimmed, server: server.id)
    else {
      return "\(callback.name): decided the first time this profile runs"
    }
    switch assignment {
    // Not an assignment at all, and it must not read as something missing: this
    // is the good case, and the URL to register is the one the server's own
    // setup text prints.
    case .serverDefault:
      return "\(callback.name): \(server.displayName)'s own default — register that one"
    case .port(let port):
      return "\(callback.name)=\(callback.url(port: port))"
    }
  }

  /// Whether this profile is signed in, for whichever kind is on screen.
  private func isSignedIn(for mode: BastionServer.AuthMode) -> Bool {
    mode.kind == .childOAuth ? childAuthState == .signedIn : isAuthorized
  }

  private func authorizationTint(for mode: BastionServer.AuthMode) -> Color {
    if mode.kind == .childOAuth, childAuthState == .unknown { return .secondary.opacity(0.4) }
    return isSignedIn(for: mode) ? .green : .secondary
  }

  private func authorizationLabel(for mode: BastionServer.AuthMode) -> String {
    if mode.kind == .childOAuth {
      switch childAuthState {
      case .unknown: return "Not checked"
      case .checking: return "Checking…"
      case .signedIn: return "Signed in"
      case .signedOut: return "Not signed in"
      }
    }
    return isAuthorized ? "Authorized" : "Not authorized"
  }

  private func authorizationCaption(for mode: BastionServer.AuthMode) -> String {
    switch mode.kind {
    case .oauth:
      return isAuthorized
        ? "Bastion holds the token and refreshes it. It is never written to a config "
          + "file and no tool can read it back. While this profile is authorized the "
          + "token is what Bastion sends, whatever is in the values below."
        : "Opens \(server.displayName) in a browser once. Bastion keeps the token in the "
          + "Keychain and every client shares it without ever seeing it — nothing is "
          + "pasted into a config file."
    case .childOAuth:
      return childAuthState == .signedIn
        ? "The server holds this login itself, in this profile's own directory — Bastion "
          + "never sees the token. Another profile of \(server.displayName) is a separate "
          + "account and signs in separately."
        : "Opens \(server.displayName) in a browser once. The server catches the callback "
          + "and keeps the token in this profile's own directory; Bastion starts the flow "
          + "and never holds the result. Public reads work signed out."
    case .env:
      return ""
    }
  }

  private func refreshAuthorization(forceCheck: Bool = false) {
    guard let mode = authMode else { return }
    switch mode.kind {
    case .oauth:
      isAuthorized = RemoteOAuthSession.isAuthorized(profile: name, server: server.id)
    case .childOAuth:
      // Only the child knows, and asking costs a spawn — which opening an
      // editor must not do. So the dot has a third state: asked, or not asked
      // yet. It resolves for free when the server is already running, and on
      // demand otherwise. Painting "not authorized" for "have not looked" would
      // be the worst of the three, because it reads as a fact and invites
      // somebody to sign in again over a login that is already there.
      let profile = draftProfile
      guard ProfileStore.lookup(name: name, server: server.id) != nil else {
        childAuthState = .signedOut
        return
      }
      let mode = mode
      let server = server
      guard forceCheck || Supervisor.shared.running.contains(where: { $0.id == profile.id })
      else {
        childAuthState = .unknown
        return
      }
      childAuthState = .checking
      Task { @MainActor in
        let signedIn = await Task.detached {
          try? ChildOAuthSession.isSignedIn(profile: profile, server: server, mode: mode)
        }.value
        childAuthState = signedIn.map { $0 ? .signedIn : .signedOut } ?? .unknown
      }
    case .env:
      break
    }
  }

  private func authorize() {
    // Before `authorizing` is set, all of it: a guard that returns after the
    // spinner is on leaves the spinner on.
    guard let mode = authMode else { return }

    // A profile has to exist before it can hold a login. For `.oauth` that is
    // the Keychain account `<profile>/<server>/oauth`, which an unsaved name
    // would file under a profile that may never be saved. For `.childOAuth` it
    // is stronger — the login runs *in* the child, and there is no child until
    // there is a saved profile to spawn one for.
    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
      authError = "Give the profile a name first — the login is filed under it."
      return
    }
    if mode.kind == .childOAuth,
      ProfileStore.lookup(name: name, server: server.id) == nil
    {
      authError =
        "Save the profile first — signing in runs \(server.displayName) with these settings."
      return
    }

    authorizing = true
    authError = nil
    let profile = draftProfile
    let server = server
    Task { @MainActor in
      defer { authorizing = false }
      do {
        switch mode.kind {
        case .oauth:
          try await RemoteOAuthSession.shared.authorize(profile: profile, server: server)
        case .childOAuth:
          // Off the main actor, and for longer than the remote flow: this call
          // is a `tools/call` that blocks in the child until the browser comes
          // back, so on the main actor it would freeze the editor for as long
          // as the user takes to read a consent screen.
          let outcome = await Task.detached { () -> Result<Bool, Error> in
            do {
              return .success(
                try ChildOAuthSession.logIn(profile: profile, server: server, mode: mode))
            } catch { return .failure(error) }
          }.value
          switch outcome {
          case .success(let signedIn):
            childAuthState = signedIn ? .signedIn : .signedOut
            if !signedIn {
              authError = "\(server.displayName) did not report a signed-in account."
            }
            return
          case .failure(let error): throw error
          }
        case .env:
          return
        }
        refreshAuthorization()
      } catch {
        authError = error.localizedDescription
      }
    }
  }

  private func signOut() {
    let profile = draftProfile
    let server = server
    guard let mode = authMode else { return }
    authorizing = true
    authError = nil
    Task { @MainActor in
      defer { authorizing = false }
      // Off the main actor: revocation is a network call, and the editor
      // freezing while somebody's provider is slow is the kind of thing that
      // reads as the app hanging.
      let outcome = await Task.detached { () -> Error? in
        do {
          switch mode.kind {
          case .oauth:
            try RemoteOAuthSession.shared.signOut(profile: profile, server: server)
          case .childOAuth:
            try ChildOAuthSession.logOut(profile: profile, server: server, mode: mode)
          case .env:
            break
          }
          return nil
        } catch { return error }
      }.value
      if let outcome { authError = outcome.localizedDescription }
      refreshAuthorization()
    }
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
          name: trimmed, serverID: server.id, values: keep, allowWrites: allowWrites,
          captureMode: CallCapture.Mode(rawValue: capture)))
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
