import SwiftUI

/// Enter a key, or start the evaluation window.
///
/// Deliberately small. Cupertino's equivalent is a pane in a settings window
/// with purchase copy; Bastion has no settings window yet, and the two things
/// anyone needs here are a field and a button.
struct LicenceWindow: View {
  @State private var typed = LicenseStore.raw ?? ""
  @State private var refusal: String?
  @State private var entitlement = Entitlement.current

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      status

      VStack(alignment: .leading, spacing: 6) {
        Text("Licence key").font(.caption).foregroundStyle(.secondary)
        HStack {
          TextField("bas1.…", text: $typed)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
          Button("Apply") { apply() }
            .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let refusal {
          // The reason, not a generic failure. It is produced once in
          // `LicenseKey.check` precisely so the same sentence reaches the menu,
          // the client and this field.
          Text(refusal).font(.caption).foregroundStyle(.red)
        }
      }

      if case .refused = entitlement, !Trial.hasRun {
        Button("Start \(Int(Trial.duration / 60))-Minute Trial") {
          Trial.start()
          entitlement = Entitlement.current
        }
      }

      Text(
        "The trial is full-function and lives in memory: it ends when the window closes or when "
          + "Bastion quits, and starting it again is a relaunch away. There is no expiry state on "
          + "this Mac and nothing to invalidate."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

      Spacer()
    }
    .padding(18)
    .frame(minWidth: 420, minHeight: 260)
  }

  @ViewBuilder private var status: some View {
    switch entitlement {
    case .licensed(let license):
      VStack(alignment: .leading, spacing: 3) {
        Text("Licensed").font(.headline)
        Text("\(license.email) · \(license.major).x · issued \(license.issuedAt)")
          .font(.caption).foregroundStyle(.secondary)
        Button("Remove This Key") {
          LicenseStore.clear()
          typed = ""
          entitlement = Entitlement.current
        }
        .font(.caption).buttonStyle(.borderless)
      }
    case .trial:
      VStack(alignment: .leading, spacing: 3) {
        Text("Trial running").font(.headline)
        Text(Trial.remainingText).font(.caption).foregroundStyle(.secondary)
      }
    case .refused(let reason):
      VStack(alignment: .leading, spacing: 3) {
        Text(Trial.hasRun ? "Trial ended" : "Not licensed").font(.headline)
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func apply() {
    switch LicenseStore.store(typed) {
    case .valid:
      refusal = nil
    case .refused(let reason):
      refusal = reason
    }
    entitlement = Entitlement.current
  }
}

enum LicenceWindowController {
  private static let hosted = HostedWindow(
    title: "Bastion Licence",
    autosaveName: "BastionLicence",
    contentSize: NSSize(width: 460, height: 300)
  ) {
    LicenceWindow()
  }

  static func show() { hosted.show() }
}
