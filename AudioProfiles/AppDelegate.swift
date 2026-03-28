import Cocoa
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private let statusItemManager = StatusItemManager()

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Register as notification delegate so notifications appear while app is in foreground
    UNUserNotificationCenter.current().delegate = self

    // Register default preference values
    UserDefaults.standard.register(defaults: [
      "showAutoSwitchNotifications": true
    ])

    // Set up the status item first
    statusItemManager.setupStatusItem()

    // Initialize device monitoring for real-time change detection
    _ = AudioDeviceMonitor.shared

    // Start auto-detection (after ProfileManager is fully initialized)
    ProfileManager.shared.startTriggerDetection()

    // Bootstrap Sound Modes services
    Task { @MainActor in
      // EQEngineService must be initialized first so its Combine subscriptions are active
      _ = EQEngineService.shared
      // Then start content mode detection
      _ = ContentModeDetectionService.shared
      _ = NightModeScheduler.shared
      NSLog("[AudioProfiles] All services initialized, soundModesEnabled=\(SoundModesStore.shared.isEnabled)")
    }

    // Show onboarding if this is the first launch
    if isFirstLaunch() {
      // Delay slightly to ensure the app is fully initialized
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        WindowManager.shared.openOnboardingWindow()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Synchronously tears down EQ, hides virtual device, restores real output.
    EQEngineService.shared.stopForTermination()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // For a menu bar app, we don't want to automatically show windows when the app is "reopened"
    // Users can access the configuration through the menu bar icon
    return false
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Keep the app running even when all windows are closed since it's a menu bar app
    return false
  }

  // MARK: - UNUserNotificationCenterDelegate

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show banner and play sound even when the app is in the foreground
    completionHandler([.banner, .sound])
  }

  // MARK: - Private Methods

  private func isFirstLaunch() -> Bool {
    let hasLaunchedBefore = UserDefaults.standard.bool(forKey: "HasLaunchedBefore")
    let onboardingCompleted = UserDefaults.standard.bool(forKey: "OnboardingCompleted")

    if !hasLaunchedBefore {
      UserDefaults.standard.set(true, forKey: "HasLaunchedBefore")
      return true
    }

    // Don't show onboarding if user previously chose "never show again"
    return !onboardingCompleted
  }
}
