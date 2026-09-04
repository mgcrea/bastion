import AppKit
import SwiftUI

/// A client's real app icon, asked of the system at runtime.
///
/// **Nothing is bundled.** LaunchServices is asked where the app with this
/// bundle id lives and IconServices is asked what it looks like, so Bastion
/// ships no Cursor, Claude or VS Code artwork: none to keep in step with a
/// rebrand, none to have a licensing conversation about, and none that can go
/// stale. An icon that changes in an app update changes here too.
///
/// The mechanism, the fallback rules and the capture rule below are the same
/// ones in Cupertino's `apps/apple/Cupertino/AppIcon.swift`, deliberately. The
/// two apps draw the same clients in the same kind of sidebar, and a person
/// running both should not see one of them name Cursor with a generic glyph.
@MainActor
enum AppIcon {
  /// `icon(forFile:)` reaches IconServices, and a SwiftUI list redraws far more
  /// often than an installed app changes. Keyed by bundle id, for the life of
  /// the process.
  ///
  /// Hits only. A miss costs one LaunchServices lookup per redraw and buys the
  /// property that matters more: a client installed while Bastion is running
  /// picks up its icon at the next redraw, instead of staying a glyph until
  /// somebody relaunches the app.
  private static var cache: [String: NSImage] = [:]

  /// The icon of the app with this bundle id, or `nil` when it is not on this
  /// Mac.
  ///
  /// LaunchServices rather than a path under /Applications: it finds the app in
  /// `~/Applications`, on a second volume, anywhere. Half the clients here are
  /// editors, and editors are exactly what people keep somewhere else.
  static func image(bundleID: String) -> NSImage? {
    if let hit = cache[bundleID] { return hit }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    cache[bundleID] = icon
    return icon
  }
}

/// One client's icon: the real one where its app is installed, the SF Symbol it
/// declares otherwise.
///
/// Never `app.dashed` — the "nothing is installed here" glyph Cupertino's
/// `SurfaceIconView` falls back to. Two of these clients are CLIs with no app
/// bundle at all, so it would be a lie about them, and the row already carries
/// a dot for how the client stands. The icon answers WHICH client; the dot
/// answers what state it is in.
struct ClientIconView: View {
  let client: ClientWiring.Client
  var size: CGFloat = 16

  /// Nil under a capture, deliberately. Which editors the capturing Mac happens
  /// to have would otherwise decide which rows get a colour icon and which get
  /// a glyph — a run on another machine would fail `make screenshots-check`
  /// with no code change behind it, and the plate would show a half-and-half
  /// sidebar that looks like a bug rather than a fixture. The fallback renders
  /// the same everywhere, which is worth more here than the prettier row.
  private var icon: NSImage? {
    if DemoSeed.isEnabled { return nil }
    guard let bundleID = client.bundleID else { return nil }
    return AppIcon.image(bundleID: bundleID)
  }

  var body: some View {
    if let icon {
      Image(nsImage: icon)
        .resizable()
        .interpolation(.high)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    } else {
      Image(systemName: client.symbol)
        .font(.system(size: size * 0.85))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
  }
}
