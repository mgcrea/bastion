import SwiftUI

/// Settings › General › Sync with iCloud. See `ConfigSyncEngine`.
struct ICloudSyncSection: View {
  @State private var engine = ConfigSyncEngine.shared
  @State private var confirmingRemoval = false

  private var enabled: Binding<Bool> {
    Binding(get: { engine.isEnabled }, set: { engine.setEnabled($0) })
  }

  var body: some View {
    Section {
      Toggle("Sync with iCloud", isOn: enabled)
        .disabled(engine.status == .unavailable)
      Text(
        "Servers, profiles, workspaces and skills follow you to your other Macs signed in to the "
          + "same iCloud account. Profile values that are not secret sit in iCloud, encrypted by "
          + "Apple, end to end only with Advanced Data Protection. Credentials are not synced "
          + "yet: enter them on each Mac."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      status

      if engine.isEnabled, engine.status != .unavailable {
        Button("Remove from iCloud…") { confirmingRemoval = true }
          .confirmationDialog(
            "Remove Bastion's configuration from iCloud?", isPresented: $confirmingRemoval,
            titleVisibility: .visible
          ) {
            Button("Remove", role: .destructive) { engine.removeFromICloud() }
            Button("Cancel", role: .cancel) {}
          } message: {
            Text(
              "Every Mac still syncing will stop and ask what to do. Nothing on this Mac is deleted."
            )
          }
      }
    } header: {
      Text("iCloud")
    }
    .sheet(
      isPresented: Binding(
        get: { engine.firstRunOverwrites != nil },
        set: { if !$0 { engine.firstRunOverwrites = nil } })
    ) {
      SyncFirstRunSheet(replaced: engine.firstRunOverwrites ?? []) {
        engine.firstRunOverwrites = nil
      }
    }
  }

  @ViewBuilder private var status: some View {
    switch engine.status {
    case .unavailable:
      note("This build cannot reach iCloud.", warning: false)
    case .off:
      EmptyView()
    case .idle(let last):
      VStack(alignment: .leading, spacing: 2) {
        if let last {
          Text("Last synced \(last.formatted(.relative(presentation: .named))).")
        }
        ForEach(engine.recent) { change in
          Text("\(change.kind.rawValue) \(change.entity) from \(change.from)")
            .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      ForEach(engine.skipped, id: \.self) { file in
        note("Not syncing \(file): it could not be read.", warning: true)
      }
      if engine.newer > 0 {
        note(
          "\(engine.newer) items were updated on a newer Bastion and are left alone until this "
            + "one is updated.", warning: false)
      }
    case .paused(.account):
      note("Paused: the iCloud account changed.", warning: true)
      HStack {
        Button("Merge with This Account") { engine.resolveAccountChange(merge: true) }
        Button("Turn Sync Off") { engine.resolveAccountChange(merge: false) }
      }
    case .paused(.quota):
      note("Paused: iCloud's storage for Bastion is full.", warning: true)
      Button("Try Again") { engine.retryAfterQuota() }
    case .paused(.cloudEmptied):
      note(
        "Paused: Bastion's data in iCloud was removed or replaced, perhaps on another Mac.",
        warning: true)
      HStack {
        Button("Put This Mac's Back") { engine.resolveCloudEmptied(pushBack: true) }
        Button("Turn Sync Off") { engine.resolveCloudEmptied(pushBack: false) }
      }
    }
  }

  private func note(_ text: String, warning: Bool) -> some View {
    Label(text, systemImage: warning ? "exclamationmark.triangle.fill" : "info.circle")
      .font(.caption).foregroundStyle(warning ? .orange : .secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Once, after the first pass of a switch-on, when iCloud's version of
/// something replaced this Mac's: nothing changes unseen.
struct SyncFirstRunSheet: View {
  let replaced: [String]
  let done: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("These were newer in iCloud and replaced this Mac's version:")
        .font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(replaced, id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 240)
      HStack {
        Spacer()
        Button("OK", action: done).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 420)
  }
}

/// On a server that arrived from another Mac and waits for a yes here.
struct SyncArrivalBanner: View {
  let server: BastionServer
  @State private var approvals = ServerApprovalStore.shared
  @State private var problem: String?

  var body: some View {
    if let waiting = approvals.approvals.isPending(server.id) {
      VStack(alignment: .leading, spacing: 8) {
        Label(
          "From \(waiting.from) through iCloud. It does not run on this Mac until you allow it.",
          systemImage: "icloud.and.arrow.down"
        )
        .fixedSize(horizontal: false, vertical: true)
        Text(detail(waiting.value))
          .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
          .textSelection(.enabled)
        HStack {
          Button(server.package == nil ? "Allow" : "Install") { allow(waiting.value) }
          if let problem {
            Text(problem).font(.caption).foregroundStyle(.red)
          }
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  /// What a yes allows, said plainly: the package, or the endpoint.
  private func detail(_ value: String) -> String {
    if value.hasPrefix("url:") { return String(value.dropFirst(4)) }
    return String(value.dropFirst(4)).replacingOccurrences(of: "|", with: ", runs ")
  }

  private func allow(_ value: String) {
    do {
      try approvals.approve(server.id, value: value)
      problem = nil
      if server.package != nil {
        let server = server
        Task { await ServerInstaller.shared.install(server) }
      }
    } catch {
      problem = error.localizedDescription
    }
  }
}
