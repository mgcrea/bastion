import SwiftUI

/// Adding a server, from the catalog or by hand.
///
/// Two halves of one sheet rather than two entrances, because they answer the
/// same question — "I want Bastion to run X" — and which half you need depends
/// on a fact about X you may not know yet. Someone looking for Stripe should
/// find out that it is in the catalog by looking, not by guessing wrong first.
///
/// The custom half asks for a **package**, never a command. That is the line
/// this whole change was careful not to cross: `spawn(whatever_you_typed)`
/// would make every local process one HTTP request away from arbitrary code
/// execution with the user's credentials in the environment. A package name
/// resolves through npm, lands in a directory Bastion owns, and is run by the
/// embedded runtime with an environment Bastion built.
/// Who is asking for the editor, held outside the view that presents it.
///
/// The menu bar has to be able to open this, and a `@State` in `MainView` is
/// unreachable from a `MenuBarExtra` — which has no view hierarchy to read an
/// environment out of, the same reason `MainWindowController` exists at all.
///
/// One source of truth rather than a `@State` copy alongside it. Two pieces of
/// state that can both present a sheet is how a sheet gets presented with the
/// wrong one, which is the failure `Subject` was made an enum to avoid in the
/// first place.
@MainActor
@Observable
final class ServerEditorHost {
  static let shared = ServerEditorHost()

  var subject: ServerEditor.Subject?

  /// Open the window, then the sheet. In that order: the sheet is presented by
  /// `MainView`, so asking for one before there is a `MainView` sets a flag
  /// nothing is watching.
  static func present(_ subject: ServerEditor.Subject = .adding) {
    MainWindowController.show()
    shared.subject = subject
  }
}

struct ServerEditor: View {
  enum Subject: Identifiable {
    case adding
    case editing(BastionServer)

    var id: String {
      switch self {
      case .adding: "adding"
      case .editing(let server): server.id
      }
    }
  }

  let subject: Subject

  @Environment(\.dismiss) private var dismiss
  @State private var tab: Tab = .catalog
  @State private var draft = Draft()
  @State private var error: String?

  private enum Tab: Hashable {
    case catalog
    case custom
  }

  /// The custom form's fields, as strings, because that is what a text field
  /// holds. Validation happens on save against `ServerStore`'s rules rather
  /// than here — one set of rules, enforced where the write happens.
  private struct Draft {
    var id = ""
    var displayName = ""
    var summary = ""
    /// Which shape this entry is. The custom form asks for a package OR an
    /// endpoint, never both, because the two are different servers rather than
    /// two ways of describing one.
    var kind: Kind = .child
    var npmName = ""
    var binName = ""
    var url = ""
    var docsUrl = ""
    var dialect = BastionServer.Dialect.v2025_11_25
    var writeGate = ""
    var variables: [Variable] = [Variable()]

    enum Kind: Hashable { case child, remote }

    /// Whether the chosen transport still lacks the one field it cannot do
    /// without. Shape only — `RemoteEndpoint` decides whether a URL is
    /// *allowed*, and it says why in a sentence, which is a better answer than
    /// a Save button that stays greyed out with no explanation.
    var transportIsIncomplete: Bool {
      switch kind {
      case .child: npmName.trimmed.isEmpty
      case .remote: url.trimmed.isEmpty
      }
    }

    struct Variable: Identifiable {
      let id = UUID()
      var name = ""
      var summary = ""
      var isRequired = false
      var isSecret = false
      var isState = false
      /// Remote only: the header this variable becomes, and the template that
      /// wraps it. `Authorization` + `Bearer {value}` is the common case and
      /// the placeholder says so.
      var headerName = ""
      var headerFormat = "{value}"
    }
  }

  private var isEditing: Bool {
    if case .editing = subject { return true }
    return false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(width: 560, height: 560)
    .onAppear(perform: seed)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(isEditing ? "Edit server" : "Add a server")
        .font(.title3).bold()

      if !isEditing {
        Picker("", selection: $tab) {
          Text("Catalog").tag(Tab.catalog)
          Text("Custom").tag(Tab.custom)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
      }
    }
    .padding(16)
  }

  @ViewBuilder
  private var content: some View {
    if tab == .catalog && !isEditing {
      catalogList
    } else {
      customForm
    }
  }

  // MARK: - Catalog

  private var catalogList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        let available = ServerStore.shared.available
        if available.isEmpty {
          ContentUnavailableView(
            "Everything in the catalog is installed",
            systemImage: "checkmark.circle",
            description: Text("Use Custom to add a server by npm package."))
            .padding(.top, 40)
        } else {
          ForEach(available) { entry in
            CatalogRow(entry: entry, add: { add(catalogEntry: entry) })
            if entry.id != available.last?.id { Divider() }
          }
        }
      }
      .padding(16)
    }
  }

  private struct CatalogRow: View {
    let entry: BastionServer
    let add: () -> Void

    var body: some View {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(entry.displayName).bold()
            if !entry.hasWritePath { Badge("read-only", tint: .green) }
            // Said here rather than discovered at install time. Four of the
            // nine are not published, and finding that out from a failed
            // install is finding it out one step too late.
            if entry.transport.isRemote {
              Badge("remote", tint: .blue)
            } else if entry.package?.distribution == .local {
              Badge("not published", tint: .orange)
            }
          }
          Text(entry.summary)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          // The package, or the endpoint — whichever this entry actually has.
          Text(entry.package?.npmName ?? entry.endpoint?.absoluteString ?? "")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 8)
        Button("Add") { add() }
      }
    }
  }

  // MARK: - Custom

  private var customForm: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        Card(title: "Identity") {
          VStack(alignment: .leading, spacing: 8) {
            Field(
              "Name", text: $draft.id, placeholder: "acme",
              help: "Lowercase, dashes. Becomes the URL: /s/<profile>/<name>.")
            Field("Display name", text: $draft.displayName, placeholder: "Acme")
            Field("Summary", text: $draft.summary, placeholder: "What this server does.")
          }
        }

        Card(title: "Transport") {
          VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $draft.kind) {
              Text("npm package").tag(Draft.Kind.child)
              Text("Remote URL").tag(Draft.Kind.remote)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if draft.kind == .child {
              Field(
                "npm package", text: $draft.npmName, placeholder: "@acme/mcp-acme",
                help:
                  "Installed on demand into Bastion's own directory, with the embedded runtime.")
              Field(
                "Binary", text: $draft.binName, placeholder: "acme-mcp",
                help: "The bin entry to run. Left empty, Bastion uses the package's only one.")
            } else {
              Field(
                "URL", text: $draft.url, placeholder: "https://mcp.example.com",
                help:
                  "https only, and it has to be somewhere else — an address on this machine or "
                  + "this network is refused.")
              Text(
                "Nothing is installed and no process is started. What Bastion adds is the "
                  + "credential in the Keychain instead of in every config file, one identity "
                  + "per profile, and a record of every call.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Field("Docs URL", text: $draft.docsUrl, placeholder: "https://…")
            HStack {
              Text("Protocol").frame(width: 96, alignment: .leading).font(.callout)
              Picker("", selection: $draft.dialect) {
                ForEach(BastionServer.Dialect.allCases, id: \.self) { dialect in
                  Text(dialect.rawValue).tag(dialect)
                }
              }
              .labelsHidden()
              .frame(width: 140)
              Spacer()
            }
            Text(
              "The version the server itself speaks. Bastion fronts clients with the newest one "
                + "either way and translates.")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }

        Card(title: "Environment") {
          VStack(alignment: .leading, spacing: 10) {
            Text(
              draft.kind == .child
                ? "The variables this server reads. Bastion passes these and nothing else — a "
                  + "variable that is not listed here can never be set on the child process."
                : "What Bastion sends with each request. A remote server has no environment, so "
                  + "each variable names the header it becomes — Authorization with a format of "
                  + "Bearer {value} is the usual one.")
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            ForEach($draft.variables) { $variable in
              VariableRow(
                variable: $variable, isRemote: draft.kind == .remote,
                remove: { draft.variables.removeAll { $0.id == variable.id } })
              Divider()
            }

            HStack {
              Button("Add variable") { draft.variables.append(.init()) }
              Spacer()
            }

            Field(
              "Write gate", text: $draft.writeGate, placeholder: "ACME_ALLOW_WRITES",
              help: "The variable that turns destructive tools on, if there is one. Bastion sets "
                + "it per profile — to \"0\" when the profile's toggle is off, never leaving it unset.")
          }
        }
      }
      .padding(16)
    }
  }

  private struct VariableRow: View {
    @Binding var variable: Draft.Variable
    var isRemote = false
    let remove: () -> Void

    var body: some View {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          TextField("ACME_TOKEN", text: $variable.name)
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
          Button(role: .destructive) { remove() } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
        }
        TextField("What it is", text: $variable.summary)
          .textFieldStyle(.roundedBorder)
          .font(.caption)
        if isRemote {
          HStack(spacing: 8) {
            TextField("Authorization", text: $variable.headerName)
              .textFieldStyle(.roundedBorder)
              .font(.system(.caption, design: .monospaced))
            TextField("Bearer {value}", text: $variable.headerFormat)
              .textFieldStyle(.roundedBorder)
              .font(.system(.caption, design: .monospaced))
          }
          Text(
            "The header this becomes, and the template around it. {value} is where the "
              + "credential goes, so a profile holds the key and not the word Bearer.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 12) {
          Toggle("Required", isOn: $variable.isRequired)
          Toggle("Secret", isOn: $variable.isSecret)
          // A remote server has no filesystem here to redirect.
          if !isRemote { Toggle("Per-profile file", isOn: $variable.isState) }
          Spacer()
        }
        .font(.caption)
        .toggleStyle(.checkbox)
        if variable.isSecret {
          Text("Held in the Keychain. Never written to a client config, a log line or the Activity window.")
            .font(.caption2).foregroundStyle(.secondary)
        }
        if variable.isState {
          Text("Points at a file or directory the server writes. Bastion redirects it into each profile's own directory, so two profiles are never one login.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
  }

  private struct Field: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var help: String?

    init(_ label: String, text: Binding<String>, placeholder: String = "", help: String? = nil) {
      self.label = label
      self._text = text
      self.placeholder = placeholder
      self.help = help
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(label).frame(width: 96, alignment: .leading).font(.callout)
          TextField(placeholder, text: $text).textFieldStyle(.roundedBorder)
        }
        if let help {
          Text(help)
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.leading, 104)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack(spacing: 10) {
      if let error {
        Text(error)
          .font(.caption).foregroundStyle(.red)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer()
      Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
      if tab == .custom || isEditing {
        Button(isEditing ? "Save" : "Add") { saveCustom() }
          .keyboardShortcut(.defaultAction)
          .disabled(draft.id.isEmpty || draft.transportIsIncomplete)
      }
    }
    .padding(16)
  }

  // MARK: - Actions

  private func seed() {
    guard case .editing(let server) = subject else { return }
    tab = .custom
    let state = Set(server.stateEnv)
    draft = Draft(
      id: server.id,
      displayName: server.displayName,
      summary: server.summary,
      // Without this the form opens on "npm package" for a server that has
      // none, showing an empty field and a Save button that will not enable.
      kind: server.transport.isRemote ? .remote : .child,
      npmName: server.package?.npmName ?? "",
      binName: server.package?.binName ?? "",
      url: server.endpoint?.absoluteString ?? "",
      docsUrl: server.docsURL?.absoluteString ?? "",
      dialect: server.dialect,
      writeGate: server.writeGate ?? "",
      variables: server.env.map {
        .init(
          name: $0.name, summary: $0.summary, isRequired: $0.isRequired, isSecret: $0.isSecret,
          isState: state.contains($0.name),
          // Round-tripped, or editing a remote server would silently rewrite
          // every variable's header to the Authorization default.
          headerName: $0.header?.name ?? "",
          headerFormat: $0.header?.format ?? "{value}")
      })
  }

  private func add(catalogEntry entry: BastionServer) {
    do {
      try ServerStore.shared.install(catalogEntry: entry.id)
      // Fetch the code straight away rather than on the first request. A server
      // whose first client sees a two-minute npm install as a timeout is a
      // server that looks broken on the one occasion it matters most.
      //
      // Except when it cannot be fetched. An unpublished entry would land a red
      // "not published to npm yet" on a server the user just added on purpose,
      // having already been told so on the row they added it from.
      if entry.package?.distribution == .npm {
        Task { await ServerInstaller.shared.install(entry) }
      }
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func saveCustom() {
    let variables = draft.variables.filter { !$0.name.trimmed.isEmpty }
    let gate = draft.writeGate.trimmed
    let isRemote = draft.kind == .remote
    let definition = ServerStore.Definition(
      displayName: draft.displayName.trimmed.isEmpty ? draft.id.trimmed : draft.displayName.trimmed,
      summary: draft.summary.trimmed,
      // Only the fields the chosen transport actually has. Writing both would
      // put a package name on a remote row, and the next load would read it
      // back as a server that installs something.
      npmName: isRemote ? nil : draft.npmName.trimmed,
      // Empty means "the package's only bin", which `entryScript` already
      // falls back to. Defaulting it to the id here would name a bin that does
      // not exist and turn that fallback off.
      binName: isRemote ? nil : draft.binName.trimmed,
      url: isRemote ? draft.url.trimmed : nil,
      docsUrl: draft.docsUrl.trimmed.isEmpty ? nil : draft.docsUrl.trimmed,
      dialect: draft.dialect.rawValue,
      writeGate: isRemote || gate.isEmpty ? nil : gate,
      writeTools: nil,
      stateEnv: isRemote ? [] : variables.filter(\.isState).map { $0.name.trimmed },
      env: variables.map { variable in
        .init(
          name: variable.name.trimmed, required: variable.isRequired, secret: variable.isSecret,
          description: variable.summary.trimmed.isEmpty
            ? "Set on the profile." : variable.summary.trimmed,
          header: isRemote
            ? .init(
              name: variable.headerName.trimmed.isEmpty
                ? "Authorization" : variable.headerName.trimmed,
              format: variable.headerFormat.contains("{value}")
                ? variable.headerFormat.trimmed : "{value}")
            : nil)
      })

    // A gate the server never reads gates nothing, and it would read as off in
    // every UI while the server did whatever it liked. Same check the manifest
    // generator makes, for the same reason.
    if let gate = definition.writeGate, !definition.env.contains(where: { $0.name == gate }) {
      error = "\(gate) is not one of the variables above — add it, or clear the write gate."
      return
    }

    do {
      let id = draft.id.trimmed
      var original: String?
      if case .editing(let server) = subject { original = server.id }
      try ServerStore.shared.upsert(custom: id, definition: definition, replacing: original)
      if let server = ServerStore.shared.server(id: id), !ServerInstaller.isInstalled(server) {
        Task { await ServerInstaller.shared.install(server) }
      }
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

extension String {
  var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
