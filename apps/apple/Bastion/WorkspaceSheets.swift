import AppKit
import SwiftUI

/// Which workspace sheet the sidebar or a workspace page has up.
enum WorkspaceSheet: Identifiable {
  case create
  case rename(String)

  var id: String {
    switch self {
    case .create: "create"
    case .rename(let name): "rename:\(name)"
    }
  }
}

/// What is wrong with a workspace name as typed, or nil. Blank is not a
/// problem to report, only a name not yet given.
@MainActor
private func workspaceNameProblem(_ name: String, renaming old: String? = nil) -> String? {
  guard !name.isEmpty, name != old else { return nil }
  if let rule = Profile.nameProblem(name) { return rule }
  if WorkspaceStore.shared.workspaces.contains(where: { $0.name == name }) {
    return "A workspace named '\(name)' already exists."
  }
  return nil
}

/// The folder picker every workspace editor shares. Several at once, because a
/// workspace is usually a client's few parent folders.
@MainActor
func pickWorkspaceFolders() -> [String] {
  let panel = NSOpenPanel()
  panel.canChooseDirectories = true
  panel.canChooseFiles = false
  panel.allowsMultipleSelection = true
  panel.prompt = "Add"
  guard panel.runModal() == .OK else { return [] }
  return panel.urls.map(\.path)
}

/// A workspace's section header: its name, which opens its page, and what its
/// folders reach.
///
/// The reach is on the header rather than on the page alone because it is the
/// thing that goes wrong silently: a workspace whose folders resolve to
/// nothing still takes every profile dragged into it out of every client.
struct WorkspaceSectionHeader: View {
  let name: String
  let folderCount: Int
  let open: () -> Void
  let rename: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(name, action: open)
        .buttonStyle(.plain)
        .help("Show the workspace's folders, profiles and skills")
      Group {
        if folderCount == 0 {
          Text("No folders found").foregroundStyle(.orange)
        } else {
          Text("Claude Code · \(folderCount) folder\(folderCount == 1 ? "" : "s")")
            .foregroundStyle(.tertiary)
        }
      }
      .font(.caption2)
    }
    .lineLimit(1)
    .contextMenu {
      Button("Edit…", action: open)
      Button("Rename…", action: rename)
      Divider()
      Button("Delete…", role: .destructive, action: delete)
    }
  }
}

/// New workspace: a name and at least one folder.
///
/// The folder is required, not optional. A workspace with no folder resolves
/// to nothing, and every profile dragged into it would quietly leave every
/// client.
struct NewWorkspaceSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var folders: [String] = []
  @State private var error: String?

  private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
  private var problem: String? { workspaceNameProblem(trimmed) }
  private var canCreate: Bool { !trimmed.isEmpty && problem == nil && !folders.isEmpty }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("New Workspace").font(.headline)
      TextField("Name", text: $name, prompt: Text("rgis"))
        .textFieldStyle(.roundedBorder)
      if let problem {
        Label(problem, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      }
      VStack(alignment: .leading, spacing: 6) {
        ForEach(folders, id: \.self) { folder in
          HStack {
            Image(systemName: "folder").foregroundStyle(.secondary)
            Text((folder as NSString).abbreviatingWithTildeInPath)
              .lineLimit(1).truncationMode(.head)
            Spacer()
            Button {
              folders.removeAll { $0 == folder }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this folder")
          }
        }
        Button("Add Folder…") {
          folders = Array(Set(folders + pickWorkspaceFolders())).sorted()
        }
      }
      Text(
        "Claude Code sessions started in these folders, or in a repository or folder below "
          + "them, get the profiles you drag into this workspace. Other clients do not get them."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create") { create() }
          .keyboardShortcut(.defaultAction)
          .disabled(!canCreate)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  private func create() {
    do {
      try WorkspaceStore.shared.upsert(Workspace(name: trimmed, folders: folders, profiles: []))
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct RenameWorkspaceSheet: View {
  let oldName: String
  /// Told the new name, so whoever holds a selection naming the old one can
  /// follow it.
  let renamed: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var error: String?

  init(name: String, renamed: @escaping (String) -> Void) {
    oldName = name
    self.renamed = renamed
    _name = State(initialValue: name)
  }

  private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
  private var problem: String? { workspaceNameProblem(trimmed, renaming: oldName) }
  private var canRename: Bool { !trimmed.isEmpty && trimmed != oldName && problem == nil }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rename '\(oldName)'").font(.headline)
      TextField("Name", text: $name, prompt: Text(oldName))
        .textFieldStyle(.roundedBorder)
        .onSubmit { if canRename { rename() } }
      if let shown = problem ?? error {
        Label(shown, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.orange)
      }
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
    .frame(width: 380)
  }

  private func rename() {
    let store = WorkspaceStore.shared
    guard var workspace = store.workspaces.first(where: { $0.name == oldName }) else {
      error = "The workspace '\(oldName)' no longer exists."
      return
    }
    workspace.name = trimmed
    do {
      try store.upsert(workspace, replacing: oldName)
      renamed(trimmed)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

extension View {
  /// The sheets above, for `sheet` set by whoever presents them.
  func workspaceSheet(
    _ sheet: Binding<WorkspaceSheet?>, renamed: @escaping (String, String) -> Void
  ) -> some View {
    self.sheet(item: sheet) { which in
      switch which {
      case .create: NewWorkspaceSheet()
      case .rename(let name): RenameWorkspaceSheet(name: name) { renamed(name, $0) }
      }
    }
  }

  /// Asks before deleting the workspace named in `pending`. Only a workspace
  /// that holds profiles says where they go, since that is the only part of a
  /// delete anybody would not expect.
  func workspaceDeletion(
    _ pending: Binding<String?>, failed: @escaping (String) -> Void
  ) -> some View {
    confirmationDialog(
      "Delete the workspace “\(pending.wrappedValue ?? "")”?",
      isPresented: Binding(
        get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
      titleVisibility: .visible, presenting: pending.wrappedValue
    ) { name in
      Button("Delete", role: .destructive) {
        do {
          try WorkspaceStore.shared.remove(named: name)
        } catch {
          failed(error.localizedDescription)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { name in
      if WorkspaceStore.shared.workspaces.first(where: { $0.name == name })?.profiles.isEmpty
        == false
      {
        Text("Its profiles go back to every client.")
      }
    }
  }
}
