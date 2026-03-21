import Foundation
import Combine

// MARK: - Install state

enum EQInstallState: Equatable {
    case notInstalled       // driver bundle not on disk
    case notLoaded          // bundle on disk but virtual device not registered in HAL
    case installing         // install / repair / update in progress
    case installed          // bundle on disk AND virtual device registered in HAL
    case error(String)
}

// MARK: - EQInstallationService

/// Manages the lifecycle of the AudioProfilesDriver.driver bundle in
/// /Library/Audio/Plug-Ins/HAL/.
///
/// Responsibilities:
///   - Detect whether the driver is installed AND loaded by coreaudiod
///   - Install it (requires admin password — shown by osascript/Authorization)
///   - Repair it (restart coreaudiod when file exists but driver not loaded)
///   - Update it (overwrite with newer bundled version + restart)
///   - Uninstall it on demand
@MainActor
final class EQInstallationService: ObservableObject {

    static let shared = EQInstallationService()

    // MARK: - Published

    @Published private(set) var installState: EQInstallState = .notInstalled

    /// True only when the driver file is on disk AND coreaudiod has loaded it.
    var isInstalled: Bool { installState == .installed }

    /// Non-nil when a newer driver is bundled with the app than what's installed.
    @Published private(set) var availableUpdate: DriverVersionInfo? = nil

    // MARK: - Constants (nonisolated so they're reachable from detached tasks)

    private nonisolated static let halPluginsDir = "/Library/Audio/Plug-Ins/HAL"
    nonisolated static let installedPath         = "/Library/Audio/Plug-Ins/HAL/AudioProfilesDriver.driver"

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    private init() {
        NSLog("[EQ-DIAG] EQInstallationService.init() starting")
        refreshInstallState()
        NSLog("[EQ-DIAG] EQInstallationService.init() installState=\(installState)")
        startMonitoringDeviceChanges()
    }

    /// Subscribe to CoreAudio device-list changes so we reactively detect
    /// when the driver appears or disappears (e.g. manual install, coreaudiod
    /// restart, or external uninstall).
    private func startMonitoringDeviceChanges() {
        AudioDeviceMonitor.shared.deviceChangesSubject
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Don't override an in-progress install
                if self.installState != .installing {
                    self.refreshInstallState()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Check both file existence AND whether the virtual device is registered in the HAL.
    /// Uses two independent signals:
    ///   1. Driver bundle exists on disk at the HAL plugins path
    ///   2. Virtual device is registered in CoreAudio (findDevice by UID)
    /// This means we detect the driver even if installed outside the app.
    /// Also checks for available updates when the file exists.
    func refreshInstallState() {
        let fileExists = FileManager.default.fileExists(atPath: Self.installedPath)
        let deviceRegistered = EQDriverService.shared.findDevice() != nil

        let newState: EQInstallState
        switch (fileExists, deviceRegistered) {
        case (false, false):
            newState = .notInstalled
        case (true, false):
            // Bundle on disk but device not in HAL — coreaudiod may not have loaded it yet
            newState = .notLoaded
        case (_, true):
            // Device registered in HAL — driver is functional regardless of whether we
            // can see the file (the file must exist for coreaudiod to have loaded it)
            newState = .installed
        }

        if installState != newState {
            AppLogger.info("EQ driver state: \(installState) → \(newState)")
            installState = newState
        }

        // Check for updates whenever the file exists, even if not loaded yet —
        // an available update means we can replace the broken/old driver.
        availableUpdate = fileExists ? checkForUpdate() : nil
    }

    /// Copy the bundled driver and restart coreaudiod.
    func install(completion: @escaping (Bool) -> Void) {
        guard let bundledDriverURL = bundledDriverURL() else {
            installState = .error("Driver bundle not found inside app.")
            completion(false)
            return
        }

        installState = .installing
        availableUpdate = nil

        let src = bundledDriverURL.path
        let dst = Self.halPluginsDir

        Task.detached(priority: .userInitiated) {
            // Copy the driver then restart coreaudiod so it loads the new bundle.
            // Developer ID Application signing is sufficient for coreaudiod to load the plugin.
            // Note: `spctl --add` was removed in macOS 15 and must not be used.
            let script = """
            do shell script \
            "rm -rf '\(dst)/AudioProfilesDriver.driver' && ditto '\(src)' '\(dst)/AudioProfilesDriver.driver' && killall coreaudiod" \
            with administrator privileges
            """
            let scriptOK = Self.runAppleScript(script)

            guard scriptOK else {
                await MainActor.run { [weak self] in
                    self?.installState = .notInstalled
                    AppLogger.error("EQ driver installation failed or was cancelled.")
                    completion(false)
                }
                return
            }

            // Wait for coreaudiod to restart and the driver to register.
            AppLogger.info("EQ driver copied; waiting for coreaudiod to reload…")
            try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5 s

            await MainActor.run { [weak self] in
                self?.refreshInstallState()
                let loaded = self?.installState == .installed
                AppLogger.info(loaded
                    ? "EQ driver installed and loaded."
                    : "EQ driver installed but not yet loaded by coreaudiod.")
                completion(loaded)
            }
        }
    }

    /// Overwrite the installed driver with the bundled version and restart coreaudiod.
    /// Identical to install() but semantically distinct for callsites.
    func update(completion: @escaping (Bool) -> Void) {
        install(completion: completion)
    }

    /// Restart coreaudiod so it picks up an already-copied driver (no file copy).
    func repair(completion: @escaping (Bool) -> Void) {
        installState = .installing

        Task.detached(priority: .userInitiated) {
            let script = """
            do shell script "killall coreaudiod" with administrator privileges
            """
            let ok = Self.runAppleScript(script)

            guard ok else {
                await MainActor.run { [weak self] in
                    self?.refreshInstallState()
                    completion(false)
                }
                return
            }

            AppLogger.info("coreaudiod restarted; waiting for driver to register…")
            try? await Task.sleep(nanoseconds: 2_500_000_000)

            await MainActor.run { [weak self] in
                self?.refreshInstallState()
                completion(self?.installState == .installed)
            }
        }
    }

    func uninstall(completion: @escaping (Bool) -> Void) {
        let path = Self.installedPath
        Task.detached(priority: .userInitiated) {
            let script = """
            do shell script \
            "rm -rf '\(path)' && killall coreaudiod" \
            with administrator privileges
            """
            let ok = Self.runAppleScript(script)
            await MainActor.run { [weak self] in
                self?.installState = ok ? .notInstalled : .installed
                self?.availableUpdate = nil
                completion(ok)
            }
        }
    }

    // MARK: - Version checking

    /// Returns update info if the bundled driver is newer than what's installed.
    private func checkForUpdate() -> DriverVersionInfo? {
        guard let bundledURL  = bundledDriverURL() else { return nil }
        guard let bundled    = driverVersion(at: bundledURL.path),
              let installed  = driverVersion(at: Self.installedPath) else { return nil }

        guard bundled.build > installed.build else { return nil }

        AppLogger.info("Driver update available: \(installed.short) → \(bundled.short)")
        return DriverVersionInfo(installedVersion: installed.short,
                                 bundledVersion:   bundled.short)
    }

    /// Read (shortVersion, buildNumber) from a driver bundle's Info.plist.
    private nonisolated static func driverVersion(at driverPath: String) -> (short: String, build: Int)? {
        let plistPath = driverPath + "/Contents/Info.plist"
        guard let dict  = NSDictionary(contentsOfFile: plistPath) as? [String: Any],
              let short = dict["CFBundleShortVersionString"] as? String,
              let buildStr = dict["CFBundleVersion"] as? String,
              let build = Int(buildStr) else { return nil }
        return (short, build)
    }

    // Instance wrapper so it can be called without Self.
    private func driverVersion(at driverPath: String) -> (short: String, build: Int)? {
        Self.driverVersion(at: driverPath)
    }

    // MARK: - Private helpers

    private func bundledDriverURL() -> URL? {
        Bundle.main.url(forResource: "AudioProfilesDriver", withExtension: "driver")
    }

    /// Execute an AppleScript string synchronously. Returns true on success.
    /// nonisolated so it can be called from a detached Task.
    private nonisolated static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&error)
        if let err = error {
            AppLogger.info("AppleScript error: \(err)")
            return false
        }
        return true
    }
}

// MARK: - DriverVersionInfo

struct DriverVersionInfo: Equatable {
    let installedVersion: String
    let bundledVersion:   String
}
