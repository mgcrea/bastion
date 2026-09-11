import Foundation
import SupportKit

/// Bastion's identity for the shared support package.
///
/// One constant; the feedback URL, the support page, the prefilled issue and the
/// mail draft are all derived from it. Nothing here opens a connection — the
/// package builds a URL and hands it to `openURL`, and the browser does whatever
/// sending happens. That is what keeps the privacy page's inventory at one
/// request: Help ▸ Send Feedback is not a second one, because the app never
/// makes it.
///
/// `trackerURL` is this project's own repository, not the shared `mgcrea/support`
/// tracker. The App Store apps file there because none of them has a public repo
/// to file against; Bastion does, and its README and site already point at it.
///
/// It has to be the repository ROOT, not `/issues`. `SupportApp.issuesPath`
/// appends `issues/new` to whatever it is handed, so a URL that already ends in
/// `/issues` would build `/issues/issues/new`.
///
/// `preferIssueTracker` is true, for the reason it is in Cupertino: whoever
/// installs an MCP gateway has a GitHub account before they have this app, and
/// a public issue is one the next person with the same client can find. The form
/// sits one item below for the reports that cannot go there — a useful Bastion
/// bug often quotes a server's output, a profile name or a hostname, and the
/// tracker is public and permanent.
enum Support {
  static let app = SupportApp(
    slug: "bastion",
    displayName: "Bastion",
    siteURL: URL(string: "https://bastion.mgcrea.io")!,
    trackerURL: URL(string: "https://github.com/mgcrea/bastion")!
  )

  /// Whether the Help menu lists the public tracker above the feedback form.
  static let preferIssueTracker = true
}
