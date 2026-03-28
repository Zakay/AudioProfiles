import SwiftUI
import AppKit
import Combine

@MainActor
final class StatusItemManager: NSObject, ObservableObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var hostingView: NSHostingView<StatusItemView>?
    private var menuPopover: NSPopover?
    private var statusBarViewModel = StatusBarViewModel()
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var isPopoverPresented = false
    private var cancellables = Set<AnyCancellable>()

    func setupStatusItem() {
        // Create the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Create the SwiftUI view with initial state
        let pm = ProfileManager.shared
        let statusView = StatusItemView(
            mode: pm.activeMode,
            icon: pm.activeProfile?.iconName ?? "speaker.wave.2.fill",
            isDisabled: pm.isAutoSwitchingDisabled
        )
        hostingView = NSHostingView(rootView: statusView)

        // Configure the hosting view — use intrinsic size for variable-width content
        if let hostingView = hostingView {
            let size = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: size)
            statusItem?.button?.frame = hostingView.frame
            statusItem?.button?.addSubview(hostingView)
        }

        // Set up click action
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusItemClicked)

        // Observe state changes and push updated view
        setupStateBindings()
    }

    private func setupStateBindings() {
        let pm = ProfileManager.shared
        pm.$activeMode
            .combineLatest(pm.$activeProfile, pm.$isAutoSwitchingDisabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, profile, isDisabled in
                Task { @MainActor in
                    self?.updateStatusIcon(mode: mode, icon: profile?.iconName, isDisabled: isDisabled)
                }
            }
            .store(in: &cancellables)

        // Update when content mode changes (UI-only observation)
        SoundModesStore.shared.$activeContentMode
            .combineLatest(SoundModesStore.shared.$isEnabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                Task { @MainActor in
                    self?.updateStatusIcon()
                }
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func updateStatusIcon(mode: ProfileMode? = nil, icon: String? = nil, isDisabled: Bool? = nil) {
        let pm = ProfileManager.shared
        let sms = SoundModesStore.shared
        hostingView?.rootView = StatusItemView(
            mode: mode ?? pm.activeMode,
            icon: icon ?? pm.activeProfile?.iconName ?? "speaker.wave.2.fill",
            isDisabled: isDisabled ?? pm.isAutoSwitchingDisabled,
            contentMode: sms.isEnabled ? sms.activeContentMode : nil
        )
        // Resize button to fit new content (mode text may change width)
        if let hostingView = hostingView {
            let size = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: size)
            statusItem?.button?.frame = hostingView.frame
        }
    }

    @objc private func statusItemClicked() {
        toggleMenu()
    }

    private func toggleMenu() {
        if isPopoverPresented {
            closeMenu()
        } else {
            showMenu()
        }
    }

    private func closeMenu() {
        guard let popover = menuPopover else {
            isPopoverPresented = false
            return
        }

        popover.close()
    }

    private func showMenu() {
        guard !isPopoverPresented else { return }

        // Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 240, height: 400)
        popover.behavior = .applicationDefined  // We'll handle closing manually
        popover.animates = true  // Enable native fade animations like standard menus

        // Set the SwiftUI content
        let menuView = ProfileMenuView(viewModel: statusBarViewModel)
        popover.contentViewController = NSHostingController(rootView: menuView)
        popover.delegate = self

        menuPopover = popover
        isPopoverPresented = true

        // Show the popover
        if let button = statusItem?.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            setupClickDetection()
        } else {
            // If we cannot present the popover, reset our state
            isPopoverPresented = false
            menuPopover = nil
        }
    }

    private func setupClickDetection() {
        // Clean up any existing monitors
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
        }

        // Monitor clicks GLOBALLY to detect outside clicks anywhere on screen
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.menuPopover, popover.isShown else { return }

            // Close popover on any global click (outside our app)
            DispatchQueue.main.async {
                self.menuPopover?.close()
            }
        }

        // Monitor clicks LOCALLY within our app to handle clicks outside popover but inside app
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, let popover = self.menuPopover, popover.isShown else { return event }

            // Get click location and check if it's outside the popover
            let clickLocation = event.locationInWindow
            let clickLocationInScreen = event.window?.convertToScreen(NSRect(origin: clickLocation, size: .zero)).origin

            // Check if click is on the status item button - if so, let the button handle it
            if let button = self.statusItem?.button, let buttonWindow = button.window {
                let buttonFrame = buttonWindow.convertToScreen(button.frame)
                if let screenLocation = clickLocationInScreen, buttonFrame.contains(screenLocation) {
                    // This is a click on our status button - let the button's action handle it
                    return event
                }
            }

            // Check if click is outside the popover
            var isOutsidePopover = true
            if let popoverWindow = popover.contentViewController?.view.window {
                let popoverFrame = popoverWindow.frame
                if let screenLocation = clickLocationInScreen {
                    isOutsidePopover = !popoverFrame.contains(screenLocation)
                }
            }

            // Close if click is outside popover (and not on our button)
            if isOutsidePopover {
                DispatchQueue.main.async {
                    self.menuPopover?.close()
                }
            }

            return event
        }

        // Also monitor for other menu bar items being clicked
        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.menuPopover?.close()
        }
    }

    func removeStatusItem() {
        menuPopover?.close()
        menuPopover = nil
        statusItem = nil
        hostingView = nil
        isPopoverPresented = false
        cancellables.removeAll()

        // Clean up event monitors
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }

        // Clean up observers
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        menuPopover = nil
        isPopoverPresented = false

        // Clean up event monitors
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }

        // Clean up notification observers
        NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
    }
}

// MARK: - Status Item SwiftUI View (pure, no internal observation)
struct StatusItemView: View {
    let mode: ProfileMode
    let icon: String
    let isDisabled: Bool
    var contentMode: ContentModeType? = nil

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(backgroundColor)
                    .frame(width: 24, height: 18)

                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 12, weight: .medium))
            }

            // Show mode icon + name when content mode is active (not .none)
            if let contentMode = contentMode, contentMode != .none {
                Image(systemName: contentMode.iconName)
                    .foregroundColor(.primary.opacity(0.7))
                    .font(.system(size: 9, weight: .medium))
                Text(contentMode.displayName)
                    .foregroundColor(.primary.opacity(0.7))
                    .font(.system(size: 10, weight: .medium))
            }
        }
        .frame(height: 22)
    }

    private var backgroundColor: Color {
        if isDisabled {
            return Color.secondary.opacity(0.3)
        } else {
            return mode == .public ? Color.blue : Color.purple
        }
    }

    private var iconColor: Color {
        isDisabled ? .secondary : .white
    }
}
