import AppKit
import SwiftUI

/// One installed server: where its code is, which profiles exist for it, and
/// what each of those profiles still needs before it can start.
///
/// This is where a credential gets typed. Until now there was no such place —
/// profiles arrived only through `DevSeed`, from a file dropped into
/// Application Support by hand, in Debug builds only. The machinery underneath
/// was complete the whole time; what was missing was a caller.
///
/// The environment table below is read-only for a catalog server and editable
/// for a custom one, and that asymmetry is not an oversight: a catalog entry's
/// shape is a fact about a package `servers.json` describes, and letting it be
/// edited here would fork it from the definition every future update re-resolves
/// against. Either way the *values* live on a profile, because two profiles of
/// one server are two identities and that is the entire reason profiles exist.
struct ServerDetail: View {
  let server: BastionServer
  /// Opens the editor sheet, which `MainView` owns — a sheet presented from
  /// this pane would be torn down by the selection change that follows a rename.
  let edit: () -> Void

  /// The profile being edited, or a blank one being created. Not a `Bool` plus
  /// a separate payload: a sheet driven by two pieces of state can be presented
  /// with the wrong one, and this cannot.
  @State private var editing: ProfileEditor.Subject?
  /// The profile whose check sheet is open. Owned here rather than by the row
  /// for the reason `editing` is: a sheet presented from a row is torn down by
  /// the state churn behind it, and `ProfileRow` redraws on a five-second clock.
  @State private var checking: Profile?
  @State private var lastError: String?
  @State private var confirmingServerRemoval = false

  private var profiles: [Profile] {
    ProfileStore.shared.profiles
      .filter { $0.serverID == server.id }
      .sorted { $0.name < $1.name }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        packageCard
        profilesCard
        environmentCard
      }
      .padding(16)
    }
    .sheet(item: $editing) { subject in
      ProfileEditor(server: server, subject: subject)
    }
    .sheet(item: $checking) { profile in
      ServerCheckSheet(server: server, profile: profile)
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(server.displayName)
        .font(.title2).bold()

      Text(server.summary)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 6) {
        // `.local` is not a footnote now that installs happen on demand: it is
        // the difference between an entry that installs and one that reports
        // "not published" when you press the button.
        switch server.distribution {
        case .npm: Badge(server.npmName, tint: .secondary)
        case .local: Badge("not published", tint: .orange)
        }
        if server.origin == .custom { Badge("custom", tint: .purple) }
        Badge(server.dialect.rawValue, tint: .secondary)
        if server.writeGate == nil {
          // Worth saying plainly. A server with no write path cannot be talked
          // into one by a profile, which makes it the safe thing to try first.
          Badge("read-only", tint: .green)
        }
        if let docs = server.docsURL {
          Link("Docs", destination: docs).font(.caption)
        }
        Spacer()
      }
    }
  }

  // MARK: - Package

  /// Where the code is, and the two buttons that change that.
  ///
  /// Its own card rather than a line in the header, because "is this thing even
  /// downloaded" is now a real state a server can be in. It used to be
  /// impossible: the servers were inside the app bundle, so the only answers
  /// were "yes" and "not in this build", and neither was actionable.
  private var packageCard: some View {
    Card(title: "Package") {
      VStack(alignment: .leading, spacing: 10) {
        let installer = ServerInstaller.shared
        let version = ServerInstaller.installedVersion(of: server)

        HStack(spacing: 8) {
          if installer.isRunning(server.id) {
            ProgressView().controlSize(.small)
            Text("Installing \(server.npmName)…").font(.callout)
          } else if let version {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("\(server.npmName) \(version)")
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
          } else {
            Circle().fill(Color.secondary).frame(width: 7, height: 7)
            Text("Not installed").font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
        }

        if let failure = installer.failures[server.id] {
          Text(failure)
            .font(.caption).foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
          Button(version == nil ? "Install" : "Update") {
            Task { await installer.install(server) }
          }
          .disabled(installer.isRunning(server.id))

          if server.origin == .custom {
            Button("Edit…") { edit() }
          }

          Spacer()

          Button("Remove server") { confirmingServerRemoval = true }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }

        Text(
          "Installed on demand into Bastion's own directory and run with the embedded Node "
            + "runtime. Nothing is fetched until you ask for it.")
          .font(.caption2).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .confirmationDialog(
      "Remove \(server.displayName)?",
      isPresented: $confirmingServerRemoval, titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) { removeServer() }
      Button("Cancel", role: .cancel) {}
    } message: {
      // Every consequence, said before it happens. The profile sweep is the
      // part nobody expects, and finding out afterwards is finding out too late.
      Text(
        profiles.isEmpty
          ? "Its downloaded code is deleted. Nothing else is affected."
          : "Its \(profiles.count) profile\(profiles.count == 1 ? "" : "s"), their credentials in "
            + "the Keychain, and its downloaded code are all deleted. Any client pointing at them "
            + "will stop working.")
    }
  }

  private func removeServer() {
    do {
      try ServerStore.shared.remove(server)
    } catch {
      lastError = "Could not remove '\(server.id)': \(error.localizedDescription)"
    }
  }

  // MARK: - Profiles

  private var profilesCard: some View {
    Card(title: "Profiles") {
      VStack(alignment: .leading, spacing: 10) {
        if profiles.isEmpty {
          Text(
            "No profile yet. This server cannot start without one — a profile is the credential "
              + "set a client's request runs as.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          ForEach(profiles) { profile in
            ProfileRow(
              server: server, profile: profile,
              edit: { editing = .existing(profile) },
              check: {
                ServerCheck.shared.start(profile: profile, server: server)
                checking = profile
              },
              report: { lastError = $0 })
            if profile.id != profiles.last?.id { Divider() }
          }
        }

        HStack(spacing: 8) {
          Button("Add profile…") { editing = .new }
          Spacer()
        }
        .padding(.top, 2)

        if let lastError {
          Text(lastError)
            .font(.caption).foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Environment

  private var environmentCard: some View {
    Card(title: "Environment") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          "What this server reads. Values are set per profile; anything marked secret is held in "
            + "the Keychain and never written to a client config or a log line.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        ForEach(server.env) { variable in
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
              Text(variable.name)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
              if variable.isRequired { Badge("required", tint: .secondary) }
              if variable.isSecret { Badge("secret", tint: .blue) }
              if server.callbackEnv.contains(variable.name) {
                // Named rather than quietly rewritten. The manifest says
                // Bastion should assign a loopback callback port per profile;
                // it does not do that yet, and a URL written as though it had
                // would not match the upstream app registration.
                Badge("callback — set by hand", tint: .orange)
              }
              Spacer()
            }
            Text(variable.summary)
              .font(.caption2).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }

        if !server.authModes.isEmpty {
          Divider()
          VStack(alignment: .leading, spacing: 3) {
            Text("A profile satisfies one of:")
              .font(.caption).foregroundStyle(.secondary)
            ForEach(server.authModes) { mode in
              Text("• \(mode.displayName) — \(mode.env.joined(separator: " + "))")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            }
          }
        }

        if let gate = server.writeGate {
          Divider()
          Text("Write gate: \(gate), set from each profile's own toggle.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        if !server.gateBypass.isEmpty {
          // Not settable, only neutralised — which is why these are not in
          // `env` and why the generator fails if one appears in both. Shown so
          // that "writes off" can be believed.
          Text(
            "Always forced off: \(server.gateBypass.joined(separator: ", ")). These would enable "
              + "writes independently of the gate.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

// MARK: - One profile

private struct ProfileRow: View {
  let server: BastionServer
  let profile: Profile
  let edit: () -> Void
  let check: () -> Void
  let report: (String?) -> Void

  @State private var confirmingRemoval = false

  private var instance: Activity.Instance? {
    Activity.shared.instances.first { $0.id == profile.id }
  }

  /// Recomputed rather than stored. A credential can be added, or a manifest
  /// variable can appear under a profile that was complete when it was written.
  private var missing: [String] {
    ProfileEnvironment.missing(for: profile, server: server)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Circle()
        .fill(dotTint)
        .frame(width: 7, height: 7)
        .padding(.top, 6)

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(profile.name).font(.system(.body, design: .monospaced)).bold()
          if profile.allowWrites { Badge("writes", tint: .orange) }
        }
        // A clock drives the running case, for the same reason `InstanceRow`
        // needs one: nothing else redraws a row while a server is quietly up.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(missing.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            .fixedSize(horizontal: false, vertical: true)
        }
        // The endpoint, always. It is what goes into a client config, and
        // someone debugging a 404 wants to read it rather than reconstruct it.
        Text("http://127.0.0.1:\(String(Gateway.shared.port))/s/\(profile.name)/\(profile.serverID)")
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.tertiary)
          .textSelection(.enabled)
          .lineLimit(1).truncationMode(.middle)
      }

      Spacer()

      VStack(alignment: .trailing, spacing: 4) {
        Button("Test") { check() }
          .help("Start this server, complete the handshake, and list its tools.")
          .disabled(ServerCheck.shared.isRunning(profile))
        Button("Edit…") { edit() }
        Button("Remove") { confirmingRemoval = true }
          .font(.caption)
          .buttonStyle(.borderless)
      }
    }
    .confirmationDialog(
      "Remove the profile '\(profile.name)'?",
      isPresented: $confirmingRemoval, titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) { remove() }
      Button("Cancel", role: .cancel) {}
    } message: {
      // Said plainly, because it is not recoverable and because the Keychain
      // sweep is the part nobody would otherwise expect.
      Text(
        "Its credentials are deleted from the Keychain. Any client still pointing at this profile "
          + "will stop working.")
    }
  }

  private var dotTint: Color {
    if let instance, instance.pid > 0 { return .green }
    if !missing.isEmpty { return .orange }
    return .secondary
  }

  private var subtitle: String {
    if let instance, instance.pid > 0 {
      let clients = instance.clients.count
      return "running · pid \(instance.pid) · \(clients) client\(clients == 1 ? "" : "s")"
        + " · \(instance.calls) call\(instance.calls == 1 ? "" : "s")"
    }
    if !missing.isEmpty {
      return "cannot start — missing \(missing.joined(separator: ", "))"
    }
    // Measured beats assumed. "Ready" was a claim about a code path nothing had
    // walked; once a check has walked it, the row says what was found instead.
    if let run = ServerCheck.shared.run(for: profile), !run.isRunning {
      let when = run.startedAt.formatted(.relative(presentation: .numeric))
      if run.failed { return "checked \(when) — the check found a problem" }
      let count = run.tools.count
      return "checked \(when) — \(count) tool\(count == 1 ? "" : "s"), not running now"
    }
    return "ready — starts on the first request that needs it"
  }

  private func remove() {
    do {
      try ProfileStore.shared.remove(profile)
      report(nil)
    } catch {
      report("Could not remove '\(profile.name)': \(error.localizedDescription)")
    }
  }
}
