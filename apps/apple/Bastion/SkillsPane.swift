import AppKit
import SwiftUI

/// Settings → Skills. Every edit saves and reconciles at once, as the
/// Workspaces pane does, so there is no Apply button to forget. Adding a source
/// is the one exception: it shows what it would change first.
struct SkillsPane: View {
  @State private var error: String?
  @State private var preview: SkillStore.Preview?
  @State private var pendingOverwrite: PendingOverwrite?

  private struct PendingOverwrite: Identifiable {
    let target: String
    let name: String
    var id: String { target + "/" + name }
  }

  private var store: SkillStore { SkillStore.shared }

  var body: some View {
    Form {
      Section {
        Text(
          "Bastion links the skills in these folders into each agent's skills folder, and never "
            + "writes into the folders themselves. When two sources hold a skill of the same "
            + "name, the one higher in this list wins."
        )
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        // Not shown in demo mode: a demo or capture run is a Debug build, so
        // without this exception the banner would appear in every store
        // screenshot, which is not the story that screenshot is telling.
        if !SkillStore.reconciles && !DemoSeed.isEnabled {
          Text(
            "Linking is off in this build: Bastion shows what it would change but writes "
              + "nothing. Launch with -reconcileSkills YES to turn it on."
          )
          .font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(Array(store.sources.enumerated()), id: \.element.id) { index, source in
          sourceRow(source, index: index)
        }
        HStack {
          Button("Add Source…", action: pickSource)
          Button("Rescan") {
            // New clones under a workspace's parent folder first, as the
            // Workspaces pane's Rescan finds them, so the reconcile sees them.
            WorkspaceStore.shared.rescan()
            store.reconcile()
          }
        }
        if let error {
          Text(error).font(.caption).foregroundStyle(.red)
        }
        // A failure filed under a folder that has no section any more.
        ForEach(orphanedFailures, id: \.self) { failure in
          Text("\(failure.target) \(failure.name): \(failure.message)")
            .font(.caption).foregroundStyle(.red)
        }
      } header: {
        Text("Sources")
      }

      if !store.catalog.isEmpty {
        Section {
          ForEach(store.catalog) { skill in skillRow(skill) }
        } header: {
          Text("Skills")
        }
      }

      ForEach(store.targets) { target in targetSection(target) }

      // A repository folder only when it has something to say: a clean one
      // is most of them, and twenty quiet sections would bury the rest.
      ForEach(store.repositoryTargets.filter(hasNews)) { target in repositorySection(target) }
    }
    .formStyle(.grouped)
    .sheet(item: $preview) { preview in
      SkillPreviewSheet(
        preview: preview,
        onApply: {
          perform { try store.commit(preview) }
          self.preview = nil
        },
        onCancel: { self.preview = nil })
    }
    .alert(
      "Move it to the Trash?",
      isPresented: Binding(
        get: { pendingOverwrite != nil }, set: { if !$0 { pendingOverwrite = nil } }),
      presenting: pendingOverwrite
    ) { pending in
      Button("Move to Trash and Link", role: .destructive) {
        perform { try store.overwrite(target: pending.target, name: pending.name) }
      }
      Button("Cancel", role: .cancel) {}
    } message: { pending in
      Text(
        "'\(pending.name)' was not created by Bastion. It goes to the Trash, where you can "
          + "restore it, and the skill is linked in its place.")
    }
  }

  // MARK: - Rows

  private func sourceRow(_ source: SkillSource, index: Int) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(source.name)
        Text((source.path as NSString).abbreviatingWithTildeInPath)
          .font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.head)
      }
      Spacer()
      if source.retired {
        Text("removing").font(.caption).foregroundStyle(.orange)
      } else if !store.available.contains(source.name) {
        Text("unavailable").font(.caption).foregroundStyle(.orange)
          .help("The folder is missing. Its links are left alone until it is back.")
      }
      Button {
        perform { try store.move(source.name, by: -1) }
      } label: {
        Image(systemName: "chevron.up")
      }
      .buttonStyle(.borderless).disabled(index == 0).help("Move up")
      Button {
        perform { try store.move(source.name, by: 1) }
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless).disabled(index == store.sources.count - 1).help("Move down")
      Button {
        perform { try store.removeSource(named: source.name) }
      } label: {
        Image(systemName: "minus.circle")
      }
      .buttonStyle(.borderless).disabled(source.retired)
      .help("Remove this source and every link Bastion made into it")
    }
  }

  private func skillRow(_ skill: Skill) -> some View {
    let scopes = WorkspaceStore.shared.workspaces.filter { $0.skills.contains(skill.id) }.map(
      \.name)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(skill.name).font(.body.monospaced())
        Text(skill.source).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Text("\(skill.description.count) characters")
          .font(.caption).foregroundStyle(.secondary)
      }
      ForEach(skill.problems, id: \.self) { problem in
        Text(problem).font(.caption).foregroundStyle(.red)
      }
      ForEach(skill.warnings, id: \.self) { warning in
        Text(warning).font(.caption).foregroundStyle(.orange)
      }
      if !scopes.isEmpty {
        Text("Linked only into the repositories of \(scopes.joined(separator: ", ")).")
          .font(.caption).foregroundStyle(.secondary)
        Button("Edit Workspaces…") { SettingsWindowController.show(.workspaces) }
          .controlSize(.small)
      } else if skill.isValid {
        HStack(spacing: 16) {
          ForEach(store.targets) { target in
            Toggle(
              target.label,
              isOn: Binding(
                get: { store.isOn(skill.id, target.id) },
                set: { on in perform { try store.set(skill.id, target: target.id, on: on) } })
            )
            .toggleStyle(.checkbox)
          }
        }
        if store.targets(of: skill.id).isEmpty {
          Text("Not linked anywhere.").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func targetSection(_ target: SkillTarget) -> some View {
    let report = store.plan.reports[target.id] ?? SkillLinks.TargetReport()
    let others = report.foreign.filter { !report.collisions.contains($0) }
    return Section {
      Text((target.path as NSString).abbreviatingWithTildeInPath)
        .font(.caption.monospaced()).textSelection(.enabled)
      if target.id == SkillLinks.sharedID {
        Text(Self.sharedCaption).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Text(
        "Descriptions linked here: \(store.descriptionCharacters(in: target.id)) characters, "
          + "loaded into every session that reads this folder."
      )
      .font(.caption).foregroundStyle(.secondary)
      reportRows(target, report)
      if !others.isEmpty {
        DisclosureGroup("Not managed by Bastion (\(others.count))") {
          ForEach(others, id: \.self) { name in
            Text(name).font(.caption.monospaced())
          }
        }
      }
    } header: {
      Text(target.label)
    }
  }

  private func repositorySection(_ target: SkillTarget) -> some View {
    let report = store.plan.reports[target.id] ?? SkillLinks.TargetReport()
    return Section {
      Text((target.path as NSString).abbreviatingWithTildeInPath)
        .font(.caption.monospaced()).textSelection(.enabled)
      reportRows(target, report)
      if !report.unadopted.isEmpty {
        Text("Links Bastion did not make; left alone.")
          .font(.caption).foregroundStyle(.secondary)
        Text(report.unadopted.sorted().joined(separator: ", ")).font(.caption.monospaced())
          .textSelection(.enabled)
      }
    } header: {
      Text(target.label)
    }
  }

  private func hasNews(_ target: SkillTarget) -> Bool {
    let quiet = store.plan.reports[target.id]?.isQuiet ?? true
    return !quiet || store.failures.contains { $0.target == target.id }
  }

  private var orphanedFailures: [SkillLinker.Failure] {
    let shown = Set((store.targets + store.repositoryTargets).map(\.id))
    return store.failures.filter { !shown.contains($0.target) }
  }

  /// What a global and a repository folder both report: a refusal,
  /// collisions with their Overwrite Anyway, what is left alone, and what
  /// failed.
  @ViewBuilder
  private func reportRows(_ target: SkillTarget, _ report: SkillLinks.TargetReport) -> some View {
    if let refused = report.refused {
      Text(refused).font(.caption).foregroundStyle(.orange)
    }
    ForEach(report.collisions, id: \.self) { name in
      HStack {
        Text("'\(name)' is taken by something Bastion did not create.")
          .font(.caption).foregroundStyle(.orange)
        Spacer()
        // Shown in demo mode the same as in Release, even though linking is
        // off there too: `overwrite` throws before it would touch anything,
        // so the button is harmless, and a capture wants it to look real.
        if SkillStore.reconciles || DemoSeed.isEnabled {
          Button("Overwrite Anyway…") {
            pendingOverwrite = PendingOverwrite(target: target.id, name: name)
          }
          .controlSize(.small)
        }
      }
    }
    if !report.unavailable.isEmpty {
      Text(
        "Left alone while their source is unavailable: "
          + report.unavailable.joined(separator: ", ")
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    if !report.shadowed.isEmpty {
      Text("Lost this folder to an earlier source: " + report.shadowed.joined(separator: ", "))
        .font(.caption).foregroundStyle(.secondary)
    }
    if !report.invalid.isEmpty {
      Text(
        "Left alone because the skill no longer validates (fix its SKILL.md, or deselect it): "
          + report.invalid.joined(separator: ", ")
      )
      .font(.caption).foregroundStyle(.secondary)
    }
    ForEach(store.failures.filter { $0.target == target.id }, id: \.self) { failure in
      Text("\(failure.name): \(failure.message)").font(.caption).foregroundStyle(.red)
    }
  }

  /// Which clients read `~/.agents/skills`, from each vendor's documentation
  /// as of 2026-09-28. See the spec's table.
  static let sharedCaption =
    "Read by Codex, Cursor, VS Code Copilot, Gemini CLI, Windsurf, OpenCode, Goose and Amp."

  // MARK: - Actions

  private func pickSource() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Add"
    panel.message = "Choose a folder of skills, or one skill folder."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    perform { preview = try store.preview(adding: url.path) }
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

/// What adding a source would change, shown before anything is written.
private struct SkillPreviewSheet: View {
  let preview: SkillStore.Preview
  let onApply: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add '\(preview.source.name)'").font(.headline)
      Text(
        "\(preview.skills.count) skill\(preview.skills.count == 1 ? "" : "s") found. "
          + "\(preview.choices.count) already linked somewhere keep their places"
          + (preview.scopes.isEmpty
            ? "."
            : ", and \(preview.scopes.values.reduce(0) { $0 + $1.count }) join a workspace whose repositories all link them already.")
      )
      .font(.callout).fixedSize(horizontal: false, vertical: true)
      let unadopted = preview.plan.reports.values.reduce(0) { $0 + $1.unadopted.count }
      if unadopted > 0 {
        Text(
          "\(unadopted) link\(unadopted == 1 ? "" : "s") in repositories Bastion did not make \(unadopted == 1 ? "is" : "are") left alone, and listed under the repository's folder."
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      if preview.plan.actions.isEmpty {
        Text("Nothing on disk changes.").font(.callout).foregroundStyle(.secondary)
      } else {
        Text("Changes on disk:").font(.callout)
        ScrollView {
          VStack(alignment: .leading, spacing: 2) {
            ForEach(preview.plan.actions, id: \.self) { action in
              Text(action.summary).font(.caption.monospaced()).textSelection(.enabled)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 200)
      }
      let collisions = preview.plan.reports.values.reduce(0) { $0 + $1.collisions.count }
      if collisions > 0 {
        Text(
          "\(collisions) name\(collisions == 1 ? " is" : "s are") taken by something Bastion did not create, and will be left alone."
        )
        .font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
        Button("Add Source", action: onApply).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 520)
  }
}
