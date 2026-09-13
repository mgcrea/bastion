import Foundation

/// A profile somebody asked the app to show, from outside the window.
///
/// The menu bar panel lists what is running as `<profile> / <server>`, and that
/// was the end of the road: the panel could say a profile was up and had no way
/// to say *where it is*. The only route to a profile in the window is the
/// sidebar — pick the server, then find the row among its profiles — which is
/// navigation a reader who has just pointed at the thing should not have to
/// redo.
///
/// Modelled on `ChatRequest`, and for its stated reason: one source of truth
/// rather than a `@State` copy alongside it, and the window shown *before* the
/// request is set, because asking a pane for something before there is a pane
/// sets a flag nothing is watching.
@MainActor
@Observable
final class ProfileReveal {
  static let shared = ProfileReveal()

  /// Read once and cleared by the `ServerDetail` it names. Deliberately not a
  /// remembered selection: left set, it would re-scroll and re-light the row
  /// every time somebody came back to the pane, which is the opposite of what
  /// a highlight means.
  var pending: Pending?

  /// Both halves, because the pane that consumes this is one of many.
  /// `ServerDetail` is built per server and every one of them observes this, so
  /// a request carrying only a profile id would be taken by whichever pane
  /// happened to be on screen when it landed.
  struct Pending: Equatable {
    /// A `Profile.id` — `<name>/<serverID>`.
    let profileID: String
    let serverID: String
  }

  /// Open the main window on the server's pane, scrolled to this profile.
  ///
  /// Ids rather than a `Profile` and a `BastionServer`: the caller is the menu
  /// bar panel, which holds an `Activity.Instance` — a running child, not a row
  /// of `profiles.json`. `ServerDetail` resolves both against the stores, which
  /// is also what makes a profile removed between the click and the arrival a
  /// quiet no-op rather than a highlight on nothing.
  static func present(profileID: String, serverID: String) {
    MainWindowController.show(.server(serverID))
    shared.pending = Pending(profileID: profileID, serverID: serverID)
  }

  /// Take the request, if there is one and it is this server's.
  func take(server: String) -> String? {
    guard let pending, pending.serverID == server else { return nil }
    self.pending = nil
    return pending.profileID
  }
}
