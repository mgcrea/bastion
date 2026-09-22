import AppKit
import SwiftUI

/// Settings → Workspaces. Every edit saves and rewires at once, the same as a
/// profile save, so there is no Apply button to forget.
struct WorkspacesPane: View {
  @State private var newName = ""
  @State private var error: String?

  private var store: WorkspaceStore { WorkspaceStore.shared }

  var body: some View {
    Form {
      Section {
        Text(
          "A profile in a workspace is written only into the folders listed here, and left out "
            + "of every other client. A folder inside a git repository means the whole "
            + "repository, its subfolders and its worktrees. A parent folder means every "
            + "repository found up to three levels below it. Only Claude Code supports this "
            + "today, and other clients do not get a profile that is in a workspace."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          TextField("New workspace name", text: $newName)
            .onSubmit(add)
          Button("Add", action: add)
            .disabled(newName.isEmpty)
          Button("Rescan") {
            store.rescan()
            ClientWiring.rewire()
          }
        }
        if let error {
          Text(error).font(.caption).foregroundStyle(.red)
        }
      }

      ForEach(store.workspaces) { workspace in
        Section {
          ForEach(workspace.folders, id: \.self) { folder in
            HStack {
              Text((folder as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.head)
              Spacer()
              Button {
                update(workspace) { $0.folders.removeAll { $0 == folder } }
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help("Remove this folder")
            }
          }
          HStack {
            Text(summary(workspace)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Add Folder…") { pickFolders(for: workspace) }
          }

          // Sorted by id, so one account's profiles sit together: that is what
          // a workspace is about, more than which server a profile runs.
          ForEach(ProfileStore.shared.profiles.sorted { $0.id < $1.id }) { profile in
            Toggle(
              profile.id,
              isOn: Binding(
                get: { workspace.profiles.contains(profile.id) },
                set: { on in
                  update(workspace) { draft in
                    if on {
                      draft.profiles.append(profile.id)
                    } else {
                      draft.profiles.removeAll { $0 == profile.id }
                    }
                  }
                }))
          }

          Button("Delete Workspace", role: .destructive) {
            perform { try store.remove(named: workspace.name) }
          }
        } header: {
          Text(workspace.name)
        }
      }
    }
    .formStyle(.grouped)
  }

  private func summary(_ workspace: Workspace) -> String {
    let count = store.resolvedKeys(workspace).count
    return count == 0
      ? "Resolves to no folder yet."
      : "Written into \(count) folder\(count == 1 ? "" : "s")."
  }

  private func add() {
    guard !newName.isEmpty else { return }
    perform {
      try store.upsert(Workspace(name: newName, folders: [], profiles: []))
      newName = ""
    }
  }

  private func update(_ workspace: Workspace, _ change: (inout Workspace) -> Void) {
    var draft = workspace
    change(&draft)
    perform { try store.upsert(draft) }
  }

  private func pickFolders(for workspace: Workspace) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add"
    guard panel.runModal() == .OK else { return }
    update(workspace) { $0.folders += panel.urls.map(\.path) }
  }

  private func perform(_ body: () throws -> Void) {
    do {
      try body()
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }
}
