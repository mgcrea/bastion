import AppKit
import Observation
import Sparkle

/// The update check — the one thing in this app that opens a socket to anything
/// but loopback.
///
/// That is worth stating plainly, because the rest of Bastion's security story
/// is "it binds 127.0.0.1 and nothing else", and `scripts/audit-listener.sh`
/// asserts it. This is the documented exception: an outbound HTTPS GET to a
/// feed, made only after the user has said yes.
///
/// Everything here is built around one property: **a Bastion nobody has said
/// yes to has never resolved a name.** That is stronger than "the checkbox is
/// off", and it is why `SPUStandardUpdaterController` is not a stored property
/// built at launch but a `nil` that stays `nil`. Sparkle starts a scheduler the
/// moment it is constructed, so constructing one and then declining to check
/// would leave the claim resting on a flag rather than on the absence of the
/// machinery.
@MainActor
@Observable
final class UpdateController: NSObject {
  static let shared = UpdateController()

  /// Set once the user has answered, either way.
  static let choiceMade = "updateChoiceMade"

  private var controller: SPUStandardUpdaterController?
  private var idleWatch: Timer?

  private(set) var isChecking = false
  private(set) var lastCheck: Date?

  /// Whether automatic checks are on.
  ///
  /// The answer lives in Sparkle's own `UserDefaults` key, read through the
  /// updater when it exists and directly when it does not. A second mirror
  /// would be one more thing to drift, and the plist default
  /// (`SUEnableAutomaticChecks`, false) already answers for a fresh install.
  var automatic: Bool {
    controller?.updater.automaticallyChecksForUpdates
      ?? UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
  }

  var hasAnswered: Bool { UserDefaults.standard.bool(forKey: Self.choiceMade) }

  /// Called from `applicationDidFinishLaunching`. Builds nothing unless the
  /// user has already opted in.
  func startIfConsented() {
    guard UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks") else { return }
    start()
  }

  /// An explicit Check Now. Pressing it is asking, so it starts the updater
  /// even when automatic checks are off, and leaves them off.
  func checkNow() {
    start()
    isChecking = true
    lastCheck = Date()
    controller?.updater.checkForUpdates()
  }

  func setAutomatic(_ on: Bool) {
    UserDefaults.standard.set(true, forKey: Self.choiceMade)
    if on { start() }
    controller?.updater.automaticallyChecksForUpdates = on
    // Written through even when no updater exists, so a "no" is durable without
    // constructing one to record it.
    UserDefaults.standard.set(on, forKey: "SUEnableAutomaticChecks")
  }

  private func start() {
    guard controller == nil else { return }
    controller = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
  }

  /// Hold the relaunch until nothing is mid-request, then let it go.
  ///
  /// Polled rather than pushed, because the thing being waited on lives behind
  /// the supervisor's lock and is written from a dozen threads; a callback
  /// registered into that path would be a second mechanism for the sake of
  /// avoiding a one-second timer.
  ///
  /// Bounded. An update that waits forever for a request that never completes
  /// is worse than one that interrupts it: the user agreed to an update and
  /// nothing appears to happen.
  fileprivate func installWhenIdle(_ install: @escaping () -> Void) {
    let deadline = Date().addingTimeInterval(60)
    idleWatch?.invalidate()
    idleWatch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
      let inFlight = Supervisor.shared.inFlightCount
      guard inFlight == 0 || Date() >= deadline else { return }
      timer.invalidate()
      if inFlight > 0 {
        hostLog("update", .info, "installing with \(inFlight) request(s) still in flight")
      }
      Task { @MainActor in
        UpdateController.shared.idleWatch = nil
        install()
      }
    }
  }
}

extension UpdateController: SPUUpdaterDelegate {
  /// Sparkle asks on its own on second launch when `SUEnableAutomaticChecks` is
  /// absent. It is present and false, so this never fires — but the plist is a
  /// build input and this is code, and only one of the two survives somebody
  /// deleting a key they did not recognise.
  nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
    false
  }

  /// Do not restart out from under live work.
  ///
  /// A client mid-tool-call gets a dropped connection, which its host reports
  /// as a dead server — Bastion appearing to break at the moment it updates.
  ///
  /// A running child is deliberately NOT a reason to wait. Bastion keeps one
  /// alive for half an hour after the last call, so "wait for idle" in
  /// cupertino's sense would mean waiting out an idle timeout for an update the
  /// user already agreed to. What matters is a request in flight.
  nonisolated func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    let inFlight = Supervisor.shared.inFlightCount
    guard inFlight > 0 else { return false }
    hostLog("update", .info, "update ready — waiting for \(inFlight) request(s) to finish")
    Task { @MainActor in UpdateController.shared.installWhenIdle(installHandler) }
    return true
  }

  /// Children spawned by the outgoing bundle keep running from its inode after
  /// Sparkle replaces it, so a client would go on talking to the previous
  /// version's code through a gateway the new app never bound.
  ///
  /// SIGTERM rather than SIGKILL, for the reason `Instance.stop` gives: the
  /// child closes its own token file and its exit is recorded by the ordinary
  /// path, so the Activity window shows an update rather than a crash.
  nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    hostLog("update", .info, "relaunching — stopping every supervised server")
    Supervisor.shared.stopAll()
    Gateway.shared.stop()
  }
}

extension UpdateController: SPUStandardUserDriverDelegate {
  /// A scheduled check that finds something posts a notification instead of
  /// stealing focus. Bastion spends nearly all of its life as an accessory
  /// nobody is looking at, and an alert in front of the window someone *is*
  /// looking at is the wrong way to mention a point release.
  nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

  nonisolated func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
  ) {
    Task { @MainActor in UpdateController.shared.isChecking = false }
  }

  nonisolated func standardUserDriverWillFinishUpdateSession() {
    Task { @MainActor in UpdateController.shared.isChecking = false }
  }
}
