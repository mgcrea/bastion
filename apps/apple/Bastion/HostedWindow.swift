import AppKit
import SwiftUI

/// A SwiftUI view in a real `NSWindow`, openable from anywhere.
///
/// Both of this app's windows are held this way rather than declared as SwiftUI
/// `Window` scenes, and the reason is the same for each: they have to be
/// openable from `AppDelegate` and from a `MenuBarExtra` menu, neither of which
/// has a view hierarchy to read `openWindow` out of. The main window needs it
/// for `applicationShouldHandleReopen`, which is what a click on the Dock icon
/// becomes; the Settings window needs it because SwiftUI's `Settings` scene
/// opens via `showSettingsWindow:`, routed through an app menu an `LSUIElement`
/// app does not have.
///
/// This file previously carried a note saying cupertino's `OpeningResizeGuard`
/// was deliberately not copied, because "a workaround without its symptom is
/// just unexplained code" — the windows here were plain stacks and did not
/// resize themselves. `MainView` is a `NavigationSplitView` now, which is the
/// symptom arriving. The guard and the degenerate-frame check come with it, and
/// both are load-bearing rather than defensive: the comments below record what
/// each one was measured preventing.
@MainActor
final class HostedWindow {
  private let title: String
  private let autosaveName: String
  private let contentSize: NSSize?
  private let content: () -> AnyView

  /// Not released on close, so reopening restores the same window and AppKit
  /// keeps the frame it autosaved.
  private var window: NSWindow?

  /// Lives only long enough to see off SwiftUI's opening resize. See `show()`.
  private var resizeGuard: OpeningResizeGuard?

  /// `contentSize` is the size the window opens at the very first time, before
  /// there is an autosaved frame to restore. A window that gives none takes
  /// SwiftUI's own fitting size instead, floored by the content's
  /// `minWidth`/`minHeight` — which is right for the main window and wrong for
  /// a grouped `Form`, whose fitting width is whatever the longest footer
  /// sentence would like.
  init(
    title: String, autosaveName: String, contentSize: NSSize? = nil,
    content: @escaping () -> some View
  ) {
    self.title = title
    self.autosaveName = autosaveName
    self.contentSize = contentSize
    self.content = { AnyView(content()) }
  }

  /// The floor under which a restored frame is corrupt rather than merely
  /// small. `contentMinSize` is the real answer wherever AppKit has one — an
  /// `NSHostingController` propagates the content's `minWidth`/`minHeight` into
  /// it — but it is zero for content that declares no minimum, and zero accepts
  /// the 1x32 frame this exists to reject. Small enough that no window anyone
  /// dragged by hand lands under it.
  private static let degenerateContentSize = NSSize(width: 200, height: 150)

  /// Whether `window` is currently sized to hold its own content.
  ///
  /// The tolerance is for the equality case, which is the common one and must
  /// not trip: AppKit clamps a drag at `contentMinSize`, autosaves exactly that,
  /// and restores it back. Rejecting a frame the user themselves resized to the
  /// minimum would trade a crash for a window that forgets its size.
  fileprivate static func canHoldContent(_ window: NSWindow) -> Bool {
    let content = window.contentRect(forFrameRect: window.frame).size
    let minimum = window.contentMinSize
    let required = NSSize(
      width: max(minimum.width, degenerateContentSize.width),
      height: max(minimum.height, degenerateContentSize.height))
    return content.width >= required.width - 1 && content.height >= required.height - 1
  }

  func show() {
    if window == nil {
      let hosting = NSHostingController(rootView: content())
      // The minimum and nothing else: for a window that names its own size,
      // SwiftUI's preferred size is not wanted, but the content's minimums
      // still have to become the resize floor. A window naming no size wants
      // the preferred size, so it must not be suppressed there.
      if contentSize != nil {
        hosting.sizingOptions = [.minSize]
      }

      let created = NSWindow(contentViewController: hosting)
      created.title = title
      created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      created.isReleasedWhenClosed = false

      // Read before `setFrameAutosaveName`, which both restores a remembered
      // frame and writes one. The question it answers is the only one that
      // matters: has anybody ever sized this window themselves?
      let remembered =
        UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") != nil
      // SwiftUI's own fitting size, read before the autosave overwrites it. It
      // is the fallback for a remembered frame that turns out to be unusable,
      // and for a window naming no `contentSize` it is the only one there is.
      let natural = created.frame
      created.setFrameAutosaveName(autosaveName)

      // A remembered frame wins — but only if the content can live in it.
      // AppKit restores whatever was last written under that key, including a
      // frame no layout can satisfy, and a SwiftUI `NavigationSplitView` handed
      // one of those does not merely look wrong: it fails to converge. The
      // split item's edge insets and the hosting view's safe-area insets
      // invalidate each other, and past 193 constraint passes in one display
      // cycle AppKit throws an exception nobody catches. Measured in cupertino
      // with a saved frame of 1x32 — the app died 1.4s into launch, before a
      // window had ever been on screen.
      //
      // Self-perpetuating, which is what earns a guard rather than a one-time
      // reset of the key: `OpeningResizeGuard` below pins the window at whatever
      // it opened with, and the autosave writes that straight back out. One bad
      // frame poisons every launch that follows it.
      let unusable = remembered && !Self.canHoldContent(created)
      if unusable { created.setFrame(natural, display: false) }

      // After the autosave name, never before. Naming it resizes the window —
      // to a remembered frame when there is one, and to SwiftUI's own idea of
      // the content's width when there is not.
      if !remembered || unusable, let contentSize {
        created.setContentSize(contentSize)
      }
      created.center()

      // Overwrite the frame that was just rejected. Autosave writes on a user
      // resize, and nothing done here is one, so without this the bad value
      // sits in prefs forever — rediscovered and discarded on every launch, and
      // taking the window's remembered position down with it.
      if unusable { created.saveFrame(usingName: autosaveName) }
      window = created

      // SwiftUI sizes a `NavigationSplitView` window to its own idea of the
      // content's width on a layout pass that lands after `show()` has already
      // returned. Nothing set beforehand survives it: not `setContentSize`, not
      // `sizingOptions`, not an `idealWidth` on the content, and not a frame
      // restored from the autosave — which is the part that matters, because
      // without this a window the user had resized came back the wrong size.
      resizeGuard = OpeningResizeGuard(window: created, intended: created.frame)
    }

    // `makeKeyAndOrderFront` does not restore a miniaturized window — it orders
    // the Dock tile front and leaves the window in the Dock, so the menu item
    // looks like a button that does nothing. The window is reused rather than
    // rebuilt, so this is a state it will genuinely be found in.
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil)

    // Then the app itself, every time and not only on the first open. Ordering
    // a window front is order *within* an app; it says nothing about which app
    // the user is looking at, so an accessory app that skips this leaves its
    // window behind whatever was in front.
    //
    // `activate(ignoringOtherApps:)`, not the cooperative `activate()`. The
    // cooperative call asks the frontmost app to yield the foreground and is
    // refused when nobody yields — which is every time the request arrives from
    // a menu bar extra, because the user is in some other app and that app was
    // never asked. It is why "Open Bastion" on a window that was already open
    // looked like it did nothing: the first open only appeared to work because
    // `DockPresence.update()` fires the forceful call on the .accessory →
    // .regular transition, and every open after that early-returns straight
    // past it with the policy already .regular.
    NSApp.activate(ignoringOtherApps: true)

    // Last, and after the window is actually on screen: `DockPresence` counts
    // visible windows, and a window ordered front after the count is a Dock
    // icon that does not appear until the next window event.
    DockPresence.update()
  }
}

/// Holds a window at the size it was opened at, for as long as it takes SwiftUI
/// to stop arguing — and not one moment longer.
///
/// SwiftUI resizes a hosted `NavigationSplitView` window unprompted, a layout
/// pass or two after it is ordered front. Every resize after that is a person
/// dragging a corner, and undoing one of those is the bug this must not become,
/// so the whole thing expires on a deadline. Three quarters of a second is long
/// enough for a window that has only just appeared and far too short for anyone
/// to have grabbed its edge.
@MainActor
private final class OpeningResizeGuard {
  private var token: NSObjectProtocol?

  init?(window: NSWindow, intended: NSRect) {
    // Refusing here is what stops a bad frame becoming permanent: this observer
    // is what would hold the window at it long enough for the autosave to write
    // it back out. Nothing to see off is better than a size nothing can satisfy.
    guard HostedWindow.canHoldContent(window) else { return nil }
    token = NotificationCenter.default.addObserver(
      forName: NSWindow.didResizeNotification, object: window, queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        window.setFrame(intended, display: false)
      }
    }
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(750))
      self?.stop()
    }
  }

  func stop() {
    guard let token else { return }
    NotificationCenter.default.removeObserver(token)
    self.token = nil
  }
}
