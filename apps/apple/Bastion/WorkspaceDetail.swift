import SwiftUI

/// A workspace's page in the main window: its folders, what they reach, its
/// profiles and its skills.
///
/// What Settings → Workspaces held for one workspace, moved beside the
/// sidebar sections that now hold the same profiles, so there is one place
/// that edits a workspace. Every edit saves and rewires at once, as the
/// sidebar's moves do, so there is no Apply button to forget.
struct WorkspaceDetail: View {
  let workspace: Workspace
  /// Told the old and new name, so the selection follows a rename.
  let renamed: (String, String) -> Void

  @State private var sheet: WorkspaceSheet?
  @State private var pendingDeletion: String?
  @State private var error: String?
  @State private var showsReach = false

  private var store: WorkspaceStore { WorkspaceStore.shared }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        header
        foldersCard
        profilesCard
        skillsCard
      }
      .padding(16)
    }
    .workspaceSheet($sheet, renamed: renamed)
    .workspaceDeletion($pendingDeletion) { error = $0 }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(workspace.name)
        .font(.title2).bold()
      Text(
        "Only Claude Code sessions started in these folders get these profiles. Other clients "
          + "do not get them."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack(spacing: 8) {
        Button("Rename…") { sheet = .rename(workspace.name) }
        Button("Delete…", role: .destructive) { pendingDeletion = workspace.name }
      }
      .controlSize(.small)
      if let error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Folders

  private var foldersCard: some View {
    Card(title: "Folders") {
      Button("Add Folder…") {
        let picked = pickWorkspaceFolders()
        guard !picked.isEmpty else { return }
        update { $0.folders += picked }
      }
      .controlSize(.small)
    } content: {
      ForEach(workspace.folders, id: \.self) { folder in
        HStack {
          Image(systemName: "folder").foregroundStyle(.secondary)
          Text((folder as NSString).abbreviatingWithTildeInPath)
            .lineLimit(1).truncationMode(.head)
          Spacer()
          Button {
            update { $0.folders.removeAll { $0 == folder } }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Remove this folder")
        }
      }
      let reached = store.resolvedKeys(workspace).sorted()
      if reached.isEmpty {
        Text("These folders reach nothing yet, so the profiles here reach no client at all.")
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        // The list Claude Code actually keys on: each repository, and each
        // plain folder on the way to one. Collapsed, because under a parent
        // folder it runs to dozens of lines.
        //
        // "Applies in", not "written into": read as "written into", the list
        // looked like a config file dropped in each folder, when it is one
        // entry per folder in Claude Code's own `~/.claude.json`.
        DisclosureGroup(isExpanded: $showsReach) {
          VStack(alignment: .leading, spacing: 2) {
            Text(
              "One entry per folder in ~/.claude.json. Nothing is written into the folders "
                + "themselves."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 4)
            ForEach(reached, id: \.self) { key in
              Text((key as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
          Text("Applies in \(reached.count) folder\(reached.count == 1 ? "" : "s")")
            .font(.caption).foregroundStyle(.secondary)
            .help("Claude Code sessions started in these folders get this workspace's profiles")
        }
      }
      HStack {
        Text("A repository cloned below these folders is picked up by itself.")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Rescan") {
          store.rescan()
          ClientWiring.rewire()
        }
        .controlSize(.small)
        .help("Look for repositories again, for a folder on a volume that does not report changes")
      }
    }
  }

  // MARK: - Profiles

  private var profilesCard: some View {
    let profiles = ProfileStore.shared.profiles
    let live = Set(profiles.map(\.id))
    let others = profiles.map(\.id).filter { !workspace.profiles.contains($0) }.sorted()
    return Card(title: "Profiles") {
      // The way in for anybody not dragging rows in the sidebar.
      Menu("Add Profile") {
        ForEach(others, id: \.self) { id in
          Button(id) { perform { try store.setScope(id, to: workspace.name) } }
        }
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .disabled(others.isEmpty)
    } content: {
      if workspace.profiles.isEmpty {
        Text("None yet. Drag a server here from the sidebar, or add a profile.")
          .font(.callout).foregroundStyle(.secondary)
      }
      ForEach(workspace.profiles.sorted(), id: \.self) { id in
        HStack {
          Text(id).font(.system(.body, design: .monospaced))
          // Kept rather than pruned, as `Workspace` explains, and shown so it
          // can be cleared.
          if !live.contains(id) {
            Text("(missing)").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button {
            update { $0.profiles.removeAll { $0 == id } }
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Take this profile out of the workspace")
        }
      }
    }
  }

  // MARK: - Skills

  private var skillsCard: some View {
    let catalog = SkillStore.shared.catalog.filter(\.isValid)
    let valid = Set(catalog.map(\.id))
    return Card(title: "Skills") {
      if catalog.isEmpty && workspace.skills.isEmpty {
        Text("No skills yet. Add a skills source in Settings › Skills.")
          .font(.callout).foregroundStyle(.secondary)
      }
      // By id, because three sources can each hold a skill of the same name
      // and only the id says which.
      ForEach(catalog) { skill in
        Toggle(
          skill.id,
          isOn: Binding(
            get: { workspace.skills.contains(skill.id) },
            set: { on in
              update { draft in
                if on {
                  draft.skills.append(skill.id)
                } else {
                  draft.skills.removeAll { $0 == skill.id }
                }
              }
            }))
      }
      // An id saved on the workspace whose skill is gone or invalid still
      // scopes nothing, but is listed so it can be cleared.
      ForEach(workspace.skills.filter { !valid.contains($0) }, id: \.self) { id in
        Toggle(
          "\(id) (unavailable)",
          isOn: Binding(
            get: { true },
            set: { on in
              guard !on else { return }
              update { $0.skills.removeAll { $0 == id } }
            }))
      }
    }
  }

  // MARK: - Saving

  private func update(_ change: (inout Workspace) -> Void) {
    var draft = workspace
    change(&draft)
    perform { try store.upsert(draft) }
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
