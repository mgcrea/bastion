import SwiftUI

/// Asks for a profile's new name, says what a rename changes, and does it.
///
/// A sheet rather than an alert, because the name is checked as it is typed
/// and an alert's message cannot change under its field.
struct RenameProfileSheet: View {
  let profile: Profile
  let server: BastionServer
  let report: (String?) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var error: String?

  init(profile: Profile, server: BastionServer, report: @escaping (String?) -> Void) {
    self.profile = profile
    self.server = server
    self.report = report
    _name = State(initialValue: profile.name)
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

  /// Why the typed name cannot be used, or nil. The current name and an empty
  /// field are not complaints, just nothing to do yet.
  private var problem: String? {
    guard !trimmed.isEmpty, trimmed != profile.name else { return nil }
    if let rule = Profile.nameProblem(trimmed) { return rule }
    if ProfileStore.shared.profile(named: trimmed, server: server.id) != nil {
      return "A profile named '\(trimmed)' already exists for \(server.displayName)."
    }
    return nil
  }

  private var canRename: Bool { !trimmed.isEmpty && trimmed != profile.name && problem == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename '\(profile.name)'").font(.headline)
      TextField("Name", text: $name, prompt: Text(profile.name))
        .textFieldStyle(.roundedBorder)
        .onSubmit { if canRename { rename() } }
      if let shown = problem ?? error {
        Label(shown, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      }
      Text(
        "Its credentials, sign-ins, workspaces and history move with it. Clients Bastion "
          + "configured are updated, and their tools appear under the new name, so permission "
          + "rules that name the old one stop matching. A client set up by hand keeps pointing "
          + "at the old address."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { rename() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canRename)
      }
    }
    .padding(20)
    .frame(width: 420)
  }

  private func rename() {
    do {
      try ProfileStore.shared.rename(profile, to: trimmed)
      report(nil)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}
