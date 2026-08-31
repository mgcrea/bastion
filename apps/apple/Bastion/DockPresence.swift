import AppKit

/// Whether Bastion is in the Dock right now, and why that changes.
///
/// `LSUIElement` is YES, which is right for what this app mostly is: a gateway
/// that starts at login, holds every credential you own and gets out of the
/// way. It should not sit in the Dock or in ⌘-Tab for the 99% of its life when
/// nobody is looking at it.
///
/// But it is wrong the moment a real window is on screen. A titled window with
/// no Dock icon, no app menu and no ⌘-Tab entry is a window you cannot get back
/// to once it goes behind something, and it reads as broken rather than as
/// restrained. It is also what makes the SwiftUI `Settings` scene unusable
/// here: `showSettingsWindow:` is routed through an app menu that an accessory
/// app does not have, which is why `SettingsWindowController` is a
/// `HostedWindow` like every other window in this app.
///
/// So the policy follows the windows. `.regular` while one is open — Dock icon,
/// app menu, ⌘-Tab, ⌘W — and back to `.accessory` when the last one closes.
///
/// This is a presentation setting only. Nothing about the gateway depends on
/// it: the listener is already bound, the children are already running, and
/// Keychain access follows the bundle identifier and the signature rather than
/// how the app chooses to appear.
@MainActor
enum DockPresence {
  /// The `MenuBarExtra` panel is a panel that cannot become main, so it does
  /// not count. That is the important exclusion: opening the menu must not put
  /// Bastion in the Dock.
  private static var hasVisibleWindow: Bool {
    NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
  }

  static func update() {
    let wanted: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
    guard NSApp.activationPolicy() != wanted else { return }
    NSApp.setActivationPolicy(wanted)
    // Becoming `.regular` does not bring the app forward on its own, and the
    // window that triggered this is the reason the user is here.
    //
    // Not under a capture, for the reason `HostedWindow.show()` gives at
    // length. Guarding one of the two calls and not the other guards neither:
    // this one fires on every demo launch, because a capture opens exactly one
    // window into a fresh process and that is the `.accessory` -> `.regular`
    // transition. The `setActivationPolicy` above still runs, which is what
    // brings the app forward at all.
    if wanted == .regular, !DemoSeed.isEnabled {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  /// `NSWindow.willCloseNotification` fires while the window is still visible,
  /// so counting immediately would always find the one that is going away.
  nonisolated static func updateAfterClose() {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(50))
      update()
    }
  }

  /// One observer for every window the app will ever own, rather than a hook on
  /// each. Windows arrive from two different places — a SwiftUI scene and an
  /// AppKit controller — and only one of them is ours to add code to.
  nonisolated static func observe() {
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { _ in
      updateAfterClose()
    }
  }
}
