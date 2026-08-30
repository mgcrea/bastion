import AppKit
import SwiftUI

/// A SwiftUI view in a real `NSWindow`, openable from anywhere.
///
/// Held this way rather than declared as a SwiftUI `Window` scene because it
/// has to be openable from `AppDelegate` and from a `MenuBarExtra` menu,
/// neither of which has a view hierarchy to read `openWindow` out of.
///
/// Simplified from cupertino's version, which carries an `OpeningResizeGuard`
/// for a `NavigationSplitView` that resizes its window unprompted a layout pass
/// after it appears. This window is a plain stack and does not do that; the
/// guard is not copied over on the principle that a workaround without its
/// symptom is just unexplained code.
@MainActor
final class HostedWindow {
  private let title: String
  private let autosaveName: String
  private let contentSize: NSSize
  private let content: () -> AnyView

  /// Not released on close, so reopening restores the same window and AppKit
  /// keeps the frame it autosaved.
  private var window: NSWindow?

  init(
    title: String, autosaveName: String, contentSize: NSSize,
    content: @escaping () -> some View
  ) {
    self.title = title
    self.autosaveName = autosaveName
    self.contentSize = contentSize
    self.content = { AnyView(content()) }
  }

  func show() {
    if window == nil {
      let hosting = NSHostingController(rootView: content())
      // The minimum and nothing else: for a window that names its own size,
      // SwiftUI's preferred size is not wanted, but the content's minimums
      // still have to become the resize floor.
      hosting.sizingOptions = [.minSize]

      let created = NSWindow(contentViewController: hosting)
      created.title = title
      created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      created.isReleasedWhenClosed = false

      // Read before `setFrameAutosaveName`, which both restores a remembered
      // frame and writes one. The question it answers is the only one that
      // matters: has anybody ever sized this window themselves?
      let remembered =
        UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
      created.setFrameAutosaveName(autosaveName)
      if !remembered { created.setContentSize(contentSize) }
      created.center()
      window = created
    }

    // An accessory app does not come forward on its own, so the window would
    // otherwise open behind whatever the user was looking at.
    //
    // `activate()`, not the deprecated `activate(ignoringOtherApps:)`: the
    // modern call cooperates with the window server rather than demanding the
    // foreground, and is the one that still works when the request comes from a
    // menu bar extra whose own panel is key at that moment.
    NSApp.activate()

    // `makeKeyAndOrderFront` does not restore a miniaturized window — it orders
    // the Dock tile front and leaves the window in the Dock, so the menu item
    // looks like a button that does nothing. The window is reused rather than
    // rebuilt, so this is a state it will genuinely be found in.
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil)
  }
}

enum ActivityWindowController {
  private static let hosted = HostedWindow(
    title: "Bastion Activity",
    autosaveName: "BastionActivity",
    contentSize: NSSize(width: 900, height: 620)
  ) {
    ActivityWindow()
  }

  static func show() { hosted.show() }
}
