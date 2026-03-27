import Foundation
import Combine

/// Evaluates whether night mode should be active based on the current time
/// and the user's quiet hours schedule. Uses precise timers that fire at
/// exact transition times — no polling.
@MainActor
final class NightModeScheduler: ObservableObject {

    static let shared = NightModeScheduler()

    @Published private(set) var isActive: Bool = false

    private var transitionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Re-evaluate when night mode config changes
        // Use .receive(on:) to ensure the store's property is updated before we read it
        SoundModesStore.shared.$nightMode
            .dropFirst() // skip initial value (handled by isEnabled sink)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // By the time this fires on next run loop, the property is updated
                self?.scheduleNextTransition()
            }
            .store(in: &cancellables)

        // Re-evaluate when master toggle changes
        SoundModesStore.shared.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.scheduleNextTransition()
                } else {
                    self?.cancelTimer()
                    self?.setActive(false)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Precise scheduling

    /// Evaluate current state and schedule a timer for the exact next transition.
    private func scheduleNextTransition() {
        cancelTimer()

        let config = SoundModesStore.shared.nightMode

        // Night mode must be explicitly enabled AND master Sound Modes must be on
        guard config.isEnabled, SoundModesStore.shared.isEnabled else {
            setActive(false)
            return
        }

        let shouldBeActive = config.isInQuietHours()
        setActive(shouldBeActive)

        // Calculate seconds until next transition (start or end of quiet hours)
        guard let nextFire = nextTransitionDate(config: config) else { return }
        let interval = nextFire.timeIntervalSinceNow
        guard interval > 0 else {
            // Already past — re-evaluate on next run loop
            DispatchQueue.main.async { [weak self] in self?.scheduleNextTransition() }
            return
        }

        transitionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleNextTransition()
            }
        }
    }

    /// Calculate the next Date when night mode state should flip.
    private func nextTransitionDate(config: NightModeConfig) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)

        // Build today's start and end dates
        let startToday = cal.date(bySettingHour: config.startHour, minute: config.startMinute, second: 0, of: todayStart)!
        let endToday = cal.date(bySettingHour: config.endHour, minute: config.endMinute, second: 0, of: todayStart)!

        let inQuietHours = config.isInQuietHours(now: now)

        if inQuietHours {
            // Currently in quiet hours — next transition is the END
            if endToday > now {
                return endToday
            } else {
                // End is tomorrow
                return cal.date(byAdding: .day, value: 1, to: endToday)
            }
        } else {
            // Not in quiet hours — next transition is the START
            if startToday > now {
                return startToday
            } else {
                // Start is tomorrow
                return cal.date(byAdding: .day, value: 1, to: startToday)
            }
        }
    }

    private func cancelTimer() {
        transitionTimer?.invalidate()
        transitionTimer = nil
    }

    private func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        SoundModesStore.shared.setNightModeActive(active)
        if active {
            AppLogger.info("Night mode activated (quiet hours)")
        } else {
            AppLogger.info("Night mode deactivated")
        }
    }
}
