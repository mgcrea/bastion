import Foundation

/// A profile somebody asked to open the chat pane on.
///
/// `ChatPane` could always load a profile — it just had no way to be *told*
/// which one from outside itself. The picker in its header was the only way in,
/// so the pane was reachable only by arriving at it and choosing again, and the
/// moment it is worth the most — the one right after a credential is typed into
/// `ProfileEditor`, when the open question is whether that credential works —
/// had no route to it at all.
///
/// Modelled on `ServerEditorHost`, and for its stated reason: one source of
/// truth rather than a `@State` copy alongside it. The window is shown *before*
/// the request is set, the same ordering `ServerEditorHost.present` uses —
/// asking a pane for something before there is a pane sets a flag nothing is
/// watching.
@MainActor
@Observable
final class ChatRequest {
  static let shared = ChatRequest()

  /// Read once and cleared by `ChatPane`. Deliberately not a remembered
  /// selection: leaving it set would re-load the profile every time somebody
  /// came back to the pane, discarding whatever conversation was there — and
  /// the pane already treats "load a profile" as destructive enough to confirm.
  var pending: Pending?

  struct Pending: Identifiable, Equatable {
    let profile: Profile
    let server: BastionServer
    var id: String { profile.id }

    static func == (a: Pending, b: Pending) -> Bool { a.id == b.id }
  }

  /// Open the main window on the chat pane, loaded with this profile.
  static func present(profile: Profile, server: BastionServer) {
    MainWindowController.show(.chat)
    shared.pending = Pending(profile: profile, server: server)
  }

  /// Take the request, if there is one.
  func take() -> Pending? {
    defer { pending = nil }
    return pending
  }
}
