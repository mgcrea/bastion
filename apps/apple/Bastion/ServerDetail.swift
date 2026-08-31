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
        switch server.origin {
        case .builtin:
          Badge("built-in", tint: .blue)
        case .custom:
          if let endpoint = server.endpoint {
            Badge(endpoint.host() ?? endpoint.absoluteString, tint: .secondary)
          } else if let package = server.package {
            Badge(package.npmName, tint: .secondary)
          }
          Badge("custom", tint: .purple)
        case .catalog:
          // `.local` is not a footnote now that installs happen on demand: it
          // is the difference between an entry that installs and one that
          // reports "not published" when you press the button.
          if let endpoint = server.endpoint {
            Badge("remote", tint: .blue)
            Badge(endpoint.host() ?? endpoint.absoluteString, tint: .secondary)
          } else {
            switch server.package?.distribution ?? .npm {
            case .npm: Badge(server.package?.npmName ?? server.id, tint: .secondary)
            case .local: Badge("not published", tint: .orange)
            }
          }
        }
        Badge(server.dialect.rawValue, tint: .secondary)
        if !server.hasWritePath {
          // Worth saying plainly. A server with no write path cannot be talked
          // into one by a profile, which makes it the safe thing to try first.
          //
          // A remote server never earns this badge, even with an empty
          // `writeTools`: it gates by name, and the names include whatever the
          // server annotates once a handshake has happened, so "read-only" is
          // not something Bastion can promise about one in advance.
          Badge("read-only", tint: .green)
        }
        if let docs = server.docsURL {
          Link("Docs", destination: docs).font(.caption)
        }
        Spacer()
      }

      enableSwitch
    }
  }

  /// The middle setting, and the sentence that says what it does not do.
  ///
  /// Worth spelling out on screen: the neighbouring red button deletes the
  /// profiles and sweeps the Keychain, so somebody reaching for a way to stop a
  /// server has every reason to expect this one costs something too.
  @ViewBuilder private var enableSwitch: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(
        "Enabled",
        isOn: Binding(
          get: { server.isEnabled },
          set: { wanted in
            do { try ServerStore.shared.setEnabled(wanted, for: server.id) } catch {
              lastError = error.localizedDescription
            }
          })
      )
      .toggleStyle(.switch)
      .controlSize(.small)

      if !server.isEnabled {
        Text(
          server.origin == .builtin
            ? "Off. Bastion's own tools are not served, and no agent can manage Bastion."
            : "Off. Requests are refused and nothing is running. Its profiles, their credentials "
              + "and its downloaded code are all kept.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.top, 2)
  }

  // MARK: - Package

  /// Where the code is, and the two buttons that change that.
  ///
  /// Its own card rather than a line in the header, because "is this thing even
  /// downloaded" is now a real state a server can be in. It used to be
  /// impossible: the servers were inside the app bundle, so the only answers
  /// were "yes" and "not in this build", and neither was actionable.
  @ViewBuilder private var packageCard: some View {
    switch server.transport {
    case .inProcess: builtinCard
    case .remote(let endpoint): remoteCard(endpoint)
    case .child: npmCard
    }
  }

  /// What stands in for the package card on the one server that has no package.
  ///
  /// Its own card rather than an empty one, because every question the package
  /// card answers — where is the code, is it downloaded, can I remove it — has
  /// a different answer here, and three struck-through rows would be a worse
  /// way to say so than one sentence.
  private var builtinCard: some View {
    Card(title: "Built in") {
      VStack(alignment: .leading, spacing: 8) {
        Text("Bastion itself. It runs inside this app, so there is nothing to download and "
          + "nothing to keep up to date — it ships with the version you are running.")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)

        Text("It cannot be removed. Switching it off is how you stop it, and that keeps its "
          + "profiles and their credentials.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Text("Secrets are write-only through it: a profile can set a credential, and no tool it "
          + "serves can read one back.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// What stands in for the package card on a server Bastion does not run.
  ///
  /// Its own card for the reason `builtinCard` gives: every question the
  /// package card asks has a different answer here. There is nothing to
  /// install, so an Install button would be a control with nothing to do; there
  /// is no version, so "Check for updates" would be asking npm about a package
  /// that does not exist; and "Remove server" means something narrower than it
  /// does there — it forgets an address and some credentials, and deletes no
  /// code, because Bastion never had any.
  private func remoteCard(_ endpoint: URL) -> some View {
    Card(title: "Remote") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Circle().fill(Color.blue).frame(width: 7, height: 7)
          Text(endpoint.absoluteString)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
          Spacer()
        }

        Text(
          "Somebody else runs this one. Bastion relays to it with the profile's credential and "
            + "records every call — there is nothing to download and no process to supervise.")
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)

        if !server.writeTools.isEmpty {
          // The one place a user decides whether to trust the switch, so the
          // limit belongs here rather than only in the docs.
          Text(
            "With writes off, Bastion will not forward: "
              + server.writeTools.joined(separator: ", ")
              + " — nor any tool the server marks as not read-only. That filters what Bastion "
              + "sends, not what the server accepts: anything holding this credential can call "
              + "the same API directly, so its own scopes are the real limit.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(
          "Every client on this profile shares one budget upstream, so a rate limit one of them "
            + "hits is a rate limit they all hit.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        HStack(spacing: 8) {
          if server.origin == .custom {
            Button("Edit…") { edit() }
          }
          Spacer()
          Button("Remove server") { confirmingServerRemoval = true }
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
        }
      }
    }
    .confirmationDialog(
      "Remove \(server.displayName)?",
      isPresented: $confirmingServerRemoval, titleVisibility: .visible
    ) {
      Button("Remove", role: .destructive) { removeServer() }
      Button("Cancel", role: .cancel) {}
    } message: {
      // Deliberately not the package card's sentence. No code is deleted here
      // because none was ever downloaded, and claiming otherwise would overstate
      // what removing this undoes.
      Text(
        profiles.isEmpty
          ? "Bastion forgets the address. Nothing is deleted anywhere else."
          : "Its \(profiles.count) profile\(profiles.count == 1 ? "" : "s") and their credentials "
            + "in the Keychain are deleted. Any client pointing at them will stop working. "
            + "Nothing changes at \(endpoint.host() ?? "the server itself").")
    }
  }

  private var npmCard: some View {
    Card(title: "Package") {
      VStack(alignment: .leading, spacing: 10) {
        let installer = ServerInstaller.shared
        let version = ServerInstaller.installedVersion(of: server)

        HStack(spacing: 8) {
          if installer.isRunning(server.id) {
            ProgressView().controlSize(.small)
            Text("Installing \(server.package?.npmName ?? server.id)…").font(.callout)
          } else if let version {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("\(server.package?.npmName ?? server.id) \(version)")
              .font(.system(.callout, design: .monospaced))
              .textSelection(.enabled)
            if case .newer(let latest) = installer.availability[server.id] {
              Badge("\(latest) available", tint: .orange)
            }
          } else {
            Circle().fill(Color.secondary).frame(width: 7, height: 7)
            Text("Not installed").font(.callout).foregroundStyle(.secondary)
          }
          Spacer()
        }

        checkStatus
        protocolLine

        if let failure = installer.failures[server.id] {
          Text(failure)
            .font(.caption).foregroundStyle(.red)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 8) {
          packageButton(installed: version != nil)

          if server.origin == .custom {
            Button("Edit…") { edit() }
          }

          Spacer()

          // Demoted, and the measurement is why. On a tree npm is happy with,
          // re-installing changes nothing: `npm install <pkg>@latest` leaves
          // every dependency that already satisfies a range alone — an SDK
          // pinned back to 1.29.0 by hand survived one untouched. So this is a
          // repair tool, not a second update button, and it sits with the other
          // maintenance action rather than beside the one people came for.
          if version != nil {
            Button("Reinstall") { Task { await installer.install(server) } }
              .font(.caption)
              .buttonStyle(.borderless)
              .disabled(installer.isRunning(server.id))
          }

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

  /// The one button that changes with what is known, rather than two that
  /// overlap.
  ///
  /// "Update" and "Check for updates" side by side left the first one with no
  /// answerable purpose: with nothing new published, an update is a no-op, and
  /// a button that usually does nothing teaches people to distrust the one time
  /// it does something. So the card asks before it acts — Install, then Check
  /// for updates, then the specific thing the check found — which is the shape
  /// the app already uses on itself through Sparkle.
  ///
  /// `pinnedOlder` gets "Install", never "Update": pressing it goes backwards,
  /// on purpose, and `checkStatus` right above says so.
  @ViewBuilder private func packageButton(installed: Bool) -> some View {
    let installer = ServerInstaller.shared
    let busy = installer.isRunning(server.id) || installer.isChecking(server.id)

    if !installed {
      Button("Install") { Task { await installer.install(server) } }
        .disabled(busy)
    } else if server.package?.distribution != .npm {
      // A `.local` entry resolves against a checkout, so there is nothing to
      // ask npm about. Update is all it can offer, and it is honest here.
      Button("Update") { Task { await installer.install(server) } }
        .disabled(busy)
    } else {
      switch installer.availability[server.id] {
      case .newer(let latest):
        Button("Update to \(latest)") { Task { await installer.install(server) } }
          .disabled(busy)
      case .pinnedOlder(let resolved):
        Button("Install \(resolved)") { Task { await installer.install(server) } }
          .disabled(busy)
      case .needsRepair:
        Button("Repair install") { Task { await installer.install(server) } }
          .disabled(busy)
      case .upToDate, .failed, .none:
        Button("Check for updates") { Task { await installer.checkForUpdate(server) } }
          .disabled(busy)
      }
    }
  }

  /// What the installed code speaks, against what this entry claims it speaks.
  ///
  /// The badge in the header is the catalog's number and stays the catalog's
  /// number: an npm update cannot change a hand-written manifest, and quietly
  /// rewriting the badge from a measurement would leave no way to see that the
  /// two had ever disagreed. So both are shown, and the disagreement is the
  /// thing worth saying out loud — it is the case where Bastion is pinning a
  /// child to an older protocol than the code on disk can speak.
  @ViewBuilder private var protocolLine: some View {
    if let measured = ServerInstaller.protocolCeiling(of: server) {
      let declared = server.dialect.rawValue
      if measured.protocol == declared {
        Text("Speaks \(measured.protocol), which is what this entry says (SDK \(measured.sdk)).")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Label(
          "The installed code speaks \(measured.protocol) (SDK \(measured.sdk)), but this entry "
            + "says \(declared) — and that is what Bastion asks it for at startup. Update "
            + "servers.json and rebuild to use the newer one.",
          systemImage: "arrow.triangle.branch")
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  /// What the last check said, or that one is running.
  ///
  /// Absent until somebody presses the button, rather than an "unknown" row.
  /// The version above is read off disk and is always true; a permanent line
  /// saying Bastion does not know whether it is current would be adding doubt
  /// to the one fact on this card that never needs any.
  @ViewBuilder private var checkStatus: some View {
    let installer = ServerInstaller.shared
    if installer.isChecking(server.id) {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Asking npm what it would install…").font(.caption).foregroundStyle(.secondary)
      }
    } else {
      switch installer.availability[server.id] {
      case .upToDate:
        Label("Up to date. npm would change nothing here.", systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      case .needsRepair(let count):
        Label(
          "\(server.package?.npmName ?? "The package") is current, but \(count) "
            + "\(count == 1 ? "package" : "packages") in its tree "
            + "\(count == 1 ? "is" : "are") missing or out of range. Repair install rebuilds it.",
          systemImage: "wrench.and.screwdriver")
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      case .newer:
        // The version itself is on the row above and on the button below.
        // What neither of those can say is what pressing it costs, so that is
        // all this line says.
        Label("Updating restarts anything currently running from this server.",
          systemImage: "arrow.down.circle.fill")
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      case .pinnedOlder(let resolved):
        // Not a failure, and not an update either. The minimum package age is
        // doing exactly what it was set to do, and the honest thing is to name
        // the direction: pressing Update here goes backwards.
        Label(
          "Your minimum package age holds this at \(resolved), which is older than what is "
            + "installed. Installing it goes backwards, not forwards.",
          systemImage: "clock.badge.exclamationmark")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case .failed(let reason):
        Label(reason, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      case .none:
        EmptyView()
      }
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
              chat: { ChatRequest.present(profile: profile, server: server) },
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
              if server.callbackEnv.contains(where: { $0.name == variable.name }) {
                // Assigned per profile, and still worth a badge: the URL has to
                // be registered upstream by hand, so a user who never sees the
                // word "callback" here finds out at a redirect_uri mismatch.
                Badge("callback — assigned per profile", tint: .blue)
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
              // Switched on kind, like `ProfileEditor.missingValues` and
              // `ProfileEnvironment.missing`. A mode satisfied by signing in
              // names no variables, and joining an empty list left this line
              // reading "• Sign in with Stripe — " with a dash to nowhere.
              Text(
                mode.isInteractive
                  ? "• \(mode.displayName) — sign in"
                  : "• \(mode.displayName) — \(mode.env.joined(separator: " + "))"
              )
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
        } else if server.transport.isRemote {
          Divider()
          Text(
            server.writeTools.isEmpty
              ? "Write gate: by tool name, set from each profile's own toggle. With writes off "
                + "Bastion will not forward any tool this server marks as not read-only."
              : "Write gate: by tool name, set from each profile's own toggle. With writes off "
                + "Bastion will not forward \(server.writeTools.joined(separator: ", ")) — nor "
                + "any tool this server marks as not read-only.")
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
  let chat: () -> Void
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
        // Two verbs, and the division between them is the point: Test proves
        // this server answers, Chat proves the credential behind it actually
        // works upstream. The second question is the one somebody has just
        // after typing a secret, and until now the pane that answers it was
        // reachable only from the sidebar, with the profile chosen again by
        // hand.
        //
        // Hidden rather than disabled when there is no model. A permanently
        // dead control next to a live one reads as something broken, and the
        // pane itself already carries the explanation for anyone who looks.
        if ToolProbe.isAvailable {
          Button("Chat…") { chat() }
            .help("Ask the on-device model something using this profile's tools.")
        }
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
    if let instance, instance.isLive { return .green }
    if !missing.isEmpty { return .orange }
    return .secondary
  }

  private var subtitle: String {
    if let instance, instance.isLive {
      let clients = instance.clients.count
      // "connected" rather than "running" for a remote server: nothing here is
      // running it, and claiming otherwise would be the app taking credit for
      // somebody else's uptime.
      let what =
        instance.pid.map { "running · pid \($0)" }
        ?? instance.remoteHost.map { "connected · \($0)" } ?? "running"
      return "\(what) · \(clients) client\(clients == 1 ? "" : "s")"
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
