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
              + "and its downloaded code are all kept."
        )
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
        Text(
          "Bastion itself. It runs inside this app, so there is nothing to download and "
            + "nothing to keep up to date — it ships with the version you are running."
        )
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "It cannot be removed. Switching it off is how you stop it, and that keeps its "
            + "profiles and their credentials."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

        Text(
          "Secrets are write-only through it: a profile can set a credential, and no tool it "
            + "serves can read one back."
        )
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
            + "records every call — there is nothing to download and no process to supervise."
        )
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
              + "the same API directly, so its own scopes are the real limit."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        Text(
          "Every client on this profile shares one budget upstream, so a rate limit one of them "
            + "hits is a rate limit they all hit."
        )
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

        // Who wrote the thing about to run on this machine.
        //
        // The remote card has said "somebody else runs this one" from the day
        // remote entries existed. A catalog CHILD had no such line because it
        // did not need one: every one of them was ours. A third-party child is
        // the higher-trust ask of the two — not an endpoint Bastion relays to,
        // but code downloaded and executed here, unsandboxed, with the
        // profile's credentials in its environment — so the line it does not
        // get is the one it most needs. Keyed on the manifest's stated vendor
        // and not on the package name, so silence can never read as "ours".
        if server.package?.vendor == .thirdParty {
          Text(
            "Somebody else publishes this one. Bastion installs it from npm and runs it here "
              + "with the profile's credentials in its environment; what Bastion adds is the "
              + "profile, the write gate and the audit line, not a review of the code."
          )
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
        }

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
            + "runtime. Nothing is fetched until you ask for it."
        )
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
          systemImage: "arrow.triangle.branch"
        )
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
          systemImage: "wrench.and.screwdriver"
        )
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      case .newer:
        // The version itself is on the row above and on the button below.
        // What neither of those can say is what pressing it costs, so that is
        // all this line says.
        Label(
          "Updating restarts anything currently running from this server.",
          systemImage: "arrow.down.circle.fill"
        )
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
      case .pinnedOlder(let resolved):
        // Not a failure, and not an update either. The minimum package age is
        // doing exactly what it was set to do, and the honest thing is to name
        // the direction: pressing Update here goes backwards.
        Label(
          "Your minimum package age holds this at \(resolved), which is older than what is "
            + "installed. Installing it goes backwards, not forwards.",
          systemImage: "clock.badge.exclamationmark"
        )
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

  // MARK: - Load on demand

  /// Where the facade switch actually lives.
  ///
  /// It used to be stored per profile, with this control writing through to
  /// every row of the server — which is why it needed a "Mixed" position at
  /// all. Mixed was never a state anybody meant to reach; it was the shape of
  /// the storage showing through the UI.
  ///
  /// The question this answers is "is this listing big enough to be worth the
  /// trade", and that is a property of the SERVER: `appstore-connect` is 85
  /// tools and 26.2k tokens, `reddit` is 14 and 3.3k, and nobody wants the same
  /// answer for both. Two profiles of one server differ in credentials and in
  /// `allowWrites`, not in whether eighty-five is a lot. The disagreement that
  /// used to justify a per-profile override — "this profile feeds Claude Code,
  /// which defers by itself" — is now `ToolFacade.clientDefersSchemas`, per
  /// client, where a profile feeding two of them can be answered honestly.
  private var lazyToolsSelection: String {
    server.lazyTools.map(String.init) ?? ""
  }

  /// The measurement to quote, from whichever profile has a current one.
  ///
  /// Still keyed by profile, and deliberately: the SETTING is per server but the
  /// COST is not. `allowWrites` filters the catalog, and `mcp-stripe` varies its
  /// tools by auth mode, so two profiles of one server can honestly disagree
  /// about the number. This takes the first rather than summing, and the
  /// sentence says "on every connect" rather than claiming a total.
  private var lazyToolsMeasurement: ToolCostStore.Measurement? {
    profiles.compactMap { ToolCostStore.shared.current(for: $0, server: server) }.first
  }

  private func setLazyTools(_ raw: String) {
    do {
      try ServerStore.shared.setLazyTools(Bool(raw), for: server.id)
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// The control, under the profiles it applies to.
  ///
  /// Below the list rather than in the header, because what it changes is what
  /// those rows are sent — and the same three positions the rest of the app
  /// uses, because a control that means one thing in one place and another
  /// somewhere else is worse than one more click.
  @ViewBuilder private var lazyToolsControl: some View {
    let selection = lazyToolsSelection
    VStack(alignment: .leading, spacing: 6) {
      Picker(
        "Load tools on demand",
        selection: Binding(get: { selection }, set: { setLazyTools($0) })
      ) {
        Text("Default (\(ToolFacade.globalDefault ? "on" : "off"))").tag("")
        Text("On").tag("true")
        Text("Off").tag("false")
      }
      .pickerStyle(.segmented)
      .controlSize(.small)
      .fixedSize()

      Text(lazyToolsDetail)
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 2)
  }

  private var lazyToolsDetail: String {
    let scope =
      profiles.count == 1
      ? "This server's profile" : "All \(profiles.count) of this server's profiles"
    // Only where the facade is actually on for something here. Then it is a
    // live fact about what those profiles do; under a picker sitting at Off it
    // is a caveat about a feature nobody turned on, and the same sentence is
    // already in Settings, in the profile sheet and in the client's own pane.
    let exempt = server.loadsToolsOnDemand ? facadeExemptClause() : ""
    guard let measured = lazyToolsMeasurement else {
      return "\(scope). Clients get three Bastion tools — search, describe and call — instead of "
        + "every tool \(server.displayName) exposes." + exempt
    }
    // From the MEASUREMENT rather than from the manifest. `writeToolCount` is
    // both of `WriteGate`'s sources counted at the moment the list was taken,
    // which is the only place a view can learn about a server that classifies by
    // annotation alone — `ToolCost` is the one thing in the app that must not
    // round in its own favour, and reading `server.writeTools` here understated
    // every such server by the fourth declaration.
    let facade = ToolFacade.declarationBytes(
      displayName: server.displayName, summary: server.summary, toolCount: measured.toolCount,
      hasWriteDispatcher: (measured.writeToolCount ?? 0) > 0)
    return "\(scope). \(measured.toolCount) tools, "
      + "\(ToolCost.short(ToolCost.tokens(bytes: measured.bytes)))\(measured.partial ? "+" : "")"
      + " → \(ToolCost.short(ToolCost.tokens(bytes: facade))) tokens on every connect, with "
      + "everything still reachable through the three." + exempt + unclassifiedClause(measured)
  }

  /// The caveat for a server Bastion cannot tell reads from writes on.
  ///
  /// Where it CAN, `bastion_call_tool` refuses the writes and they go through
  /// `bastion_call_write_tool`, so an approval rule in an editor still has a
  /// boundary to sit on. Where it cannot, there is one dispatcher and one rule
  /// covering every call on the server, which is the version of this trade
  /// people should be told about rather than left to discover.
  ///
  /// Only when the facade is actually on and only when something has been
  /// measured: `nil` means nobody has looked, which is not the same claim as
  /// zero and must not be rendered as one.
  private func unclassifiedClause(_ measured: ToolCostStore.Measurement) -> String {
    guard server.loadsToolsOnDemand, measured.writeToolCount == 0 else { return "" }
    return
      " Bastion cannot tell this server's writes from its reads — it declares none and annotates "
      + "none — so there is one dispatcher and one approval rule in the editor covering every "
      + "call, writes included."
  }

  // MARK: - Profiles

  private var profilesCard: some View {
    Card(
      title: "Profiles",
      // Only once there is a list for it to sit above. With no profile yet the
      // one thing to do here is not a header affordance, it is the next step,
      // and the empty state below says so in a control nobody can miss.
      accessory: {
        if !profiles.isEmpty {
          Button {
            editing = .new
          } label: {
            Label("Add profile…", systemImage: "plus")
          }
          .buttonStyle(.borderless)
          .font(.caption)
        }
      }
    ) {
      VStack(alignment: .leading, spacing: 10) {
        if profiles.isEmpty {
          Text(
            "No profile yet. This server cannot start without one — a profile is the credential "
              + "set a client's request runs as."
          )
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          Button {
            editing = .new
          } label: {
            Label("Add profile…", systemImage: "plus")
          }
          .buttonStyle(.borderedProminent)
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

          Divider()
          lazyToolsControl
        }

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
            + "the Keychain and never written to a client config or a log line."
        )
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
                + "any tool this server marks as not read-only."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }

        if !server.gateBypass.isEmpty {
          // Not settable, only neutralised — which is why these are not in
          // `env` and why the generator fails if one appears in both. Shown so
          // that "writes off" can be believed.
          Text(
            "Always forced off: \(server.gateBypass.joined(separator: ", ")). These would enable "
              + "writes independently of the gate."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

// MARK: - One profile

/// The clients the tool facade will not apply to, by display name.
///
/// File scope rather than a member: `ServerDetail` writes the setting and
/// `ProfileRow` renders the badge, and a copy in each is the thing `ToolFacade`
/// exists to prevent. `@MainActor` because `ClientWiring.all` is — free here,
/// since both callers are view bodies, and exactly why the rule ITSELF lives in
/// `ToolFacade`, where the gateway's own thread can reach it.
///
/// The cheap question, and the one that is true. "Which clients are wired to
/// this profile" is `ClientWiring.status(of:profiles:)`, which opens seven
/// config files with no caching by design — per profile row, per redraw. This
/// asks which clients are exempt at all: a defaults read and a set lookup.
@MainActor private func facadeExemptClients() -> [String] {
  ClientWiring.all.filter { ToolFacade.clientDefersSchemas($0.id) }.map(\.displayName)
}

/// " Claude Code loads schemas on demand and gets the real list." — and the
/// empty string when nothing is exempt, so a caller can append it
/// unconditionally.
@MainActor private func facadeExemptClause() -> String {
  let names = facadeExemptClients()
  guard !names.isEmpty else { return "" }
  let list =
    names.count == 1
    ? names[0]
    : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
  // Both verbs agree, not just the first. "Claude Code loads schemas on demand
  // and get the real list" is the kind of sentence that reads as a bug in the
  // app rather than as a caption.
  let one = names.count == 1
  return " \(list) \(one ? "loads" : "load") schemas on demand and "
    + "\(one ? "gets" : "get") the real list."
}

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
          if let cost { Badge(cost.label, tint: .secondary).help(cost.help) }
        }
        // A clock drives the running case, for the same reason `InstanceRow`
        // needs one: nothing else redraws a row while a server is quietly up.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(
              missing.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange)
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        // The endpoint, always. It is what goes into a client config, and
        // someone debugging a 404 wants to read it rather than reconstruct it.
        Text(
          "http://127.0.0.1:\(String(Gateway.shared.port))/s/\(profile.name)/\(profile.serverID)"
        )
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .lineLimit(1).truncationMode(.middle)
      }

      Spacer()

      // One row rather than a column of four. Stacked, the verbs pushed the row
      // taller than the text beside them and read as a menu; side by side they
      // read as what they are, four things you can do to this profile.
      HStack(spacing: 8) {
        Button {
          check()
        } label: {
          Label("Test", systemImage: "stethoscope")
        }
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
          // The same glyph the sidebar uses for the pane this opens.
          Button {
            chat()
          } label: {
            Label("Chat…", systemImage: "bubble.left.and.text.bubble.right")
          }
          .help("Ask the on-device model something using this profile's tools.")
        }
        Button {
          edit()
        } label: {
          Label("Edit…", systemImage: "pencil")
        }
        Button {
          confirmingRemoval = true
        } label: {
          Label("Remove", systemImage: "trash")
        }
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

  /// What this profile's tool list costs a client, when something has measured
  /// it and nothing has moved since.
  ///
  /// A badge beside the name rather than a clause in `subtitle`, which is where
  /// it was first put and where it could not be seen: that line spends itself on
  /// the live instance the moment a server is up, so the number vanished exactly
  /// for the profiles being used. This is a standing property of the profile,
  /// not an event, and it belongs with the other one.
  ///
  /// Absent rather than stale. `ToolCostStore` returns nothing once the package
  /// version or the write gate has moved, so a badge that is here is a badge
  /// that still describes what a client would be sent.
  private var cost: (label: String, help: String)? {
    guard let measured = ToolCostStore.shared.current(for: profile, server: server) else {
      return nil
    }
    let tokens = ToolCost.short(ToolCost.tokens(bytes: measured.bytes))
    let count = measured.toolCount
    let when = measured.measuredAt.formatted(.relative(presentation: .numeric))

    // With the facade on, the measurement above is still the honest cost of the
    // SERVER — it is what a client would pay without it, and it is what makes
    // the saving legible. What the client is actually sent is the three
    // declarations, so the badge carries both and neither number is a claim the
    // other contradicts.
    if server.loadsToolsOnDemand {
      let facade = ToolFacade.declarationBytes(
        displayName: server.displayName, summary: server.summary, toolCount: count,
        hasWriteDispatcher: (measured.writeToolCount ?? 0) > 0)
      return (
        "\(ToolCost.short(ToolCost.tokens(bytes: facade))) of \(tokens)\(measured.partial ? "+" : "") tokens",
        "\(count) tool\(count == 1 ? "" : "s") behind three. Clients are sent "
          + ToolCost.phrase(bytes: facade) + " on connect instead of "
          + ToolCost.phrase(bytes: measured.bytes, partial: measured.partial)
          + ", and fetch a schema when they need one." + facadeExemptClause()
          + " Measured \(when)."
      )
    }

    return (
      // The "+" carries the paginated case into a label with no room for the
      // sentence the check sheet gets to write.
      "\(tokens)\(measured.partial ? "+" : "") tokens",
      "\(count) tool\(count == 1 ? "" : "s"), "
        + ToolCost.phrase(bytes: measured.bytes, partial: measured.partial)
        + " of a client's context window on every connect. Measured \(when)."
    )
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
