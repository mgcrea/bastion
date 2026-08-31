import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LicenceLinks {
  /// Where to buy one. The site's own vanity path rather than the Stripe
  /// checkout URL, so the destination can move without shipping a new build —
  /// see `apps/website/public/_redirects`. A Stripe URL compiled into a binary
  /// would be a payment link nobody could ever repoint.
  static let buy = URL(string: "https://bastion.mgcrea.io/buy")!

  /// True as of 1.0.0: /buy resolves to the live Stripe payment link.
  ///
  /// The same flag, for the same reason, as `SHIPPED` on the website — a button
  /// here is a promise that there is something on the other end of it. The two
  /// move together, and this one is the slower half: the site can be redeployed
  /// in a minute, while a build that has shipped carries whatever it was
  /// compiled with until the next release.
  static let isSelling = true
}

/// Entering a licence key, seeing what happened to it, and — when there is none
/// — finding out what that actually means.
///
/// A Settings pane rather than a window of its own, which is what this was. A
/// key is 240 characters that arrive by paste or by drop from a mail client, so
/// it needs somewhere with room and somewhere that survives losing focus; that
/// is the same reason cupertino's is a pane. Having it be a second window as
/// well bought nothing, and left ⌘, and the menu item landing in different
/// places for the same question.
///
/// Most of this pane is explanation, deliberately. Somebody arrives here because
/// their assistant just said a server is not licensed, and the useful thing to
/// give them is the whole shape of it: what stopped, what did not, and what to
/// do next.
///
/// Every sentence here has to be true of *this* build, which is why there is no
/// price, no purchase button and no refund promise — Bastion has no checkout to
/// send anyone to, and copy describing some other build is read at exactly the
/// moment somebody is deciding whether to trust the app with every credential
/// they own.
struct LicencePane: View {
  @State private var entry = ""
  @State private var problem: String?
  /// Bumped by anything that changes the answer — a key entered, a key removed,
  /// a trial started. The status block reads `Entitlement.current` live rather
  /// than holding a copy, so what it needs is a reason to rebuild, not somewhere
  /// to store the result. Holding a copy is how the pane and the gate in
  /// `Gateway` come to disagree.
  @State private var revision = 0

  var body: some View {
    // The same grouped form as the other panes. This one is mostly prose rather
    // than controls, which is why the sections carry it in their footers: a
    // footer is where a form puts an explanation, and it keeps the two things
    // somebody came here to *do* — read the status, paste a key — as the only
    // rows in the cards.
    Form {
      Section {
        status
      } footer: {
        footer
      }

      Section {
        editor
      } header: {
        Text("Licence key")
      } footer: {
        Text("Paste your key, or drop the .license file anywhere in this window.")
      }
    }
    .formStyle(.grouped)
    // On this pane's own form rather than on `SettingsView`'s split view, so
    // the signal means "the pane the stage asked for has rendered" instead of
    // "a window exists".
    .task { DemoSeed.signalReady(from: .settings) }
    .onAppear { entry = LicenseStore.raw ?? "" }
    .onDrop(of: [.fileURL], isTargeted: nil, perform: accept)
  }

  private var status: some View {
    // On a schedule, because one of the three states is a countdown. A pane left
    // open across the end of a trial window has to stop claiming the servers are
    // running — the gate will already have stopped relaying to them. Fifteen
    // seconds is comfortably inside the minute the label rounds to.
    TimelineView(.periodic(from: .now, by: 15)) { _ in
      // Read once. The badge and the words beside it are two renderings of one
      // answer, and a trial that ended between two reads of `Entitlement.current`
      // would have them contradict each other — a blue clock next to a sentence
      // saying nothing is running.
      let entitlement = Entitlement.current

      HStack(alignment: .top, spacing: 14) {
        badge(for: entitlement)

        VStack(alignment: .leading, spacing: 4) {
          switch entitlement {
          case .licensed(let license):
            Text("Licensed to \(license.email)").foregroundStyle(.green)
            Text("Licence \(license.id) · covers \(license.major).x · issued \(day(license.issuedAt))")
              .font(.caption).foregroundStyle(.secondary)
          case .trial:
            Text("Trial · \(Trial.remainingText)").foregroundStyle(.blue)
            trialExplanation
          case .refused(let reason):
            Text("Unlicensed").foregroundStyle(.orange)
            Text(reason)
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            explanation
            trialOffer
          }
        }
      }
    }
    .id(revision)
    .textSelection(.enabled)
  }

  /// The glyph, alone in a column to the left of everything the state has to
  /// say. Filled, because a filled symbol reads as a state where an outlined one
  /// reads as a control nobody has switched on yet. Fixed width, because a
  /// triangle is narrower than a seal and without it every sentence in the block
  /// would shift sideways the moment a trial ended.
  private func badge(for entitlement: Entitlement) -> some View {
    let (symbol, tint): (String, Color) =
      switch entitlement {
      case .licensed: ("checkmark.seal.fill", .green)
      case .trial: ("clock.fill", .blue)
      case .refused: ("exclamationmark.triangle.fill", .orange)
      }

    return Image(systemName: symbol)
      .font(.system(size: 28))
      .foregroundStyle(tint)
      .frame(width: 32, alignment: .leading)
  }

  /// What a trial is, said where somebody is watching it run.
  ///
  /// The first line is the point of the whole feature: this is not a demo, so
  /// what it proves about this Mac stays true after paying. The second is the one
  /// worth being blunt about — the window really does close, on servers that are
  /// already running, and finding that out from an assistant that suddenly lost
  /// its tools would be a worse way to learn it.
  private var trialExplanation: some View {
    VStack(alignment: .leading, spacing: 3) {
      row(
        "Every server relays, write gates still obey their own switches, and nothing is held back. "
          + "This is the app, not a demo.")
      row(
        "When the window closes the supervised servers stop, including any your assistant is "
          + "already connected to. Its next call is refused.")
    }
    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
  }

  /// The offer, or the note that it has already been taken.
  ///
  /// Before and after are different questions. Before: does this work on my Mac
  /// against my clients, which only a running gateway can answer. After: there is
  /// nothing to say a second time, so it says what to do instead of pitching a
  /// window that has already done its job.
  @ViewBuilder private var trialOffer: some View {
    if Trial.hasRun {
      VStack(alignment: .leading, spacing: 3) {
        Text("The trial window has closed. Quitting and reopening Bastion starts another one.")
          .fixedSize(horizontal: false, vertical: true)
      }
      .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        // Reachable only from a button, here and in the menu. A trial that armed
        // itself when a stdio bridge launched the app would burn in a window
        // nobody was watching.
        Button("Start a \(Int(Trial.duration / 60))-minute trial") {
          Trial.start()
          revision += 1
        }
        .controlSize(.small)
        Text(
          "Full function, every server, no key — enough to see it working against your own "
            + "clients and your own credentials.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 6)
    }
  }

  /// What "unlicensed" costs, in the words somebody needs when their assistant
  /// has just been refused.
  ///
  /// The second line is the carve-out in `Gateway`, and it is worth saying out
  /// loud rather than leaving to be discovered: the one server that keeps
  /// answering is the one that can put the rest of this right.
  private var explanation: some View {
    VStack(alignment: .leading, spacing: 3) {
      row(
        "Bastion will not relay to a supervised server, so every tool your assistant reaches "
          + "through it is refused with this reason.")
      row(
        "Bastion's own server is exempt and keeps answering, so an assistant can still install "
          + "servers, set credentials and wire clients while you sort this out.")
      row(
        "Everything else is untouched: your credentials stay in the Keychain, your profiles and "
          + "settings are unchanged, and nothing has moved.")
      row("The write gates are a safety feature, not a paid one. They behave the same either way.")
      row(
        "A key takes effect at once. Nothing needs restarting — the next call your assistant makes "
          + "is relayed.")
    }
    .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
  }

  private func row(_ text: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text("·")
      Text(text).fixedSize(horizontal: false, vertical: true)
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 8) {
      // A `TextEditor` rather than the single-line field this used to be: the
      // key is 240 characters, and a key pasted out of a mail client can arrive
      // with the line breaks that client wrapped it at. `LicenseKey.check`
      // trims, and a box that shows the whole thing is what lets somebody see
      // they have pasted half of it.
      TextEditor(text: $entry)
        .font(.system(.caption, design: .monospaced))
        .frame(height: 92)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

      if let problem {
        // The reason, not a generic failure. It is produced once in
        // `LicenseKey.check` precisely so the same sentence reaches the menu,
        // the MCP client and this line.
        Text(problem)
          .font(.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Button("Use this key") { apply(entry) }
          .keyboardShortcut(.defaultAction)
          .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        Button("Remove") {
          LicenseStore.clear()
          entry = ""
          problem = nil
          revision += 1
        }
        .disabled(LicenseStore.raw == nil)
        if LicenceLinks.isSelling {
          Spacer()
          Button("Buy a licence…") { NSWorkspace.shared.open(LicenceLinks.buy) }
        }
      }
      .controlSize(.small)
    }
  }

  private var footer: some View {
    Text(
      "One key covers every \(AppInfo.major).x release and every Mac you own — it is issued to "
        + "you, not to a machine, and nothing counts your installs. Bastion verifies it on this "
        + "Mac and never asks anyone about it.")
      .fixedSize(horizontal: false, vertical: true)
  }

  /// Store it, or say why not. Refusing to persist a bad key is what stops the
  /// field and the status line disagreeing about what is installed.
  private func apply(_ text: String) {
    switch LicenseStore.store(text) {
    case .valid:
      problem = nil
      entry = LicenseStore.raw ?? ""
    case .refused(let reason):
      problem = reason
    }
    revision += 1
  }

  private func accept(_ providers: [NSItemProvider]) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
      guard
        let data,
        let url = URL(dataRepresentation: data, relativeTo: nil),
        let text = try? String(contentsOf: url, encoding: .utf8)
      else { return }
      Task { @MainActor in
        entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        apply(entry)
      }
    }
    return true
  }

  /// The date half of an ISO timestamp. The clock time is noise on a receipt.
  private func day(_ issuedAt: String) -> String {
    String(issuedAt.prefix(10))
  }
}
