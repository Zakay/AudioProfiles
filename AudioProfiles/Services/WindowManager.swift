import SwiftUI
import AppKit

// MARK: - Window Configuration

enum WindowType: String, CaseIterable {
    case configuration = "configuration"
    case about = "about"
    case onboarding = "onboarding"
    case autoSwitching = "autoSwitching"
    case demo = "demo"
}

struct WindowConfiguration {
    let title: String
    let size: NSSize
    let minSize: NSSize
    let maxSize: NSSize
    let isResizable: Bool
    let centerOffset: CGFloat
    let requiresRegularApp: Bool
    let activateOnOpen: Bool
    
    static let configurations: [WindowType: WindowConfiguration] = [
        .configuration: WindowConfiguration(
            title: "Configure AudioProfiles",
            size: NSSize(width: 530, height: 600),
            minSize: NSSize(width: 480, height: 480),
            maxSize: NSSize(width: 800, height: 800),
            isResizable: true,
            centerOffset: 80,
            requiresRegularApp: true,
            activateOnOpen: true
        ),
        .about: WindowConfiguration(
            title: "About AudioProfiles",
            size: NSSize(width: 400, height: 600),
            minSize: NSSize(width: 350, height: 600),
            maxSize: NSSize(width: 500, height: 800),
            isResizable: false,
            centerOffset: 0,
            requiresRegularApp: true,
            activateOnOpen: true
        ),
        .onboarding: WindowConfiguration(
            title: "Welcome to AudioProfiles",
            size: NSSize(width: 700, height: 600),
            minSize: NSSize(width: 600, height: 500),
            maxSize: NSSize(width: 900, height: 800),
            isResizable: false,
            centerOffset: 40,
            requiresRegularApp: true,
            activateOnOpen: true
        ),
        .autoSwitching: WindowConfiguration(
            title: "Auto-Switching",
            size: NSSize(width: 320, height: 300),
            minSize: NSSize(width: 280, height: 250),
            maxSize: NSSize(width: 400, height: 400),
            isResizable: false,
            centerOffset: 20,
            requiresRegularApp: true,
            activateOnOpen: true
        ),
        .demo: WindowConfiguration(
            title: "Demo Window",
            size: NSSize(width: 800, height: 800),
            minSize: NSSize(width: 600, height: 600),
            maxSize: NSSize(width: 1200, height: 1200),
            isResizable: true,
            centerOffset: 0,
            requiresRegularApp: true,
            activateOnOpen: true
        )
    ]
}

// MARK: - Window Manager

class WindowManager: NSObject, ObservableObject {
    static let shared = WindowManager()
    
    // Window storage
    private var windows: [WindowType: NSWindow] = [:]
    private var delegates: [WindowType: UniversalWindowDelegate] = [:]
    
    // Published states
    @Published var isConfigurationWindowOpen = false
    @Published var isAboutWindowOpen = false
    @Published var isOnboardingWindowOpen = false
    @Published var isAutoSwitchingWindowOpen = false
    @Published var isDemoWindowOpen = false
    
    // MARK: - App Activation Policy Management
    
    /// Makes the app behave like a regular app (shows in dock, cmd+tab) when configuration window is open
    private func makeAppRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    /// Reverts the app back to menu bar only behavior
    internal func makeAppAccessory() {
        NSApp.setActivationPolicy(.accessory)
    }
    
    // MARK: - Public Window Methods
    
    func openConfigurationWindow() {
        openWindow(type: .configuration, view: ConfigurationView())
    }
    
    func openAboutWindow() {
        openWindow(type: .about, view: AboutView())
    }
    
    func openOnboardingWindow() {
        openWindow(type: .onboarding, view: OnboardingView())
    }
    
    func openAutoSwitchingDialog() {
        openWindow(type: .autoSwitching, view: AutoSwitchingDialogView())
    }
    
    func openDemoWindow() {
        openWindow(type: .demo, view: DemoView())
    }
    
    func closeAllWindows() {
        windows.values.forEach { $0.close() }
    }
    
    // MARK: - Generic Window Management
    
    private func openWindow<T: View>(type: WindowType, view: T) {
        guard let config = WindowConfiguration.configurations[type] else {
            assertionFailure("No configuration found for window type: \(type)")
            return
        }
        
        // Close any popovers
        NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
        
        // Handle existing window
        if let existingWindow = windows[type], existingWindow.isVisible {
            handleExistingWindow(existingWindow, config: config)
            return
        }
        
        // Create new window
        let window = createWindow(type: type, view: view, config: config)
        windows[type] = window
        updatePublishedState(for: type, isOpen: true)
        
        // Handle app activation
        if config.requiresRegularApp {
            makeAppRegular()
        }
        if config.activateOnOpen {
            NSApp.activate(ignoringOtherApps: false)
        }
    }
    
    private func handleExistingWindow(_ window: NSWindow, config: WindowConfiguration) {
        // Move to current screen if needed
        if !WindowUtilities.isWindowOnCurrentScreen(window) {
            WindowUtilities.centerWindow(
                window, 
                onScreen: WindowUtilities.getCurrentInteractionScreen(), 
                withOffset: config.centerOffset
            )
        }
        
        // Handle app activation for existing windows
        if config.requiresRegularApp {
            makeAppRegular()
        }
        
        // Bring to front
        window.makeKeyAndOrderFront(nil)
        if config.activateOnOpen {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func createWindow<T: View>(type: WindowType, view: T, config: WindowConfiguration) -> NSWindow {
        let hostingController = NSHostingController(rootView: view)
        
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if config.isResizable {
            styleMask.insert(.resizable)
        }
        
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: config.size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        window.title = config.title
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.level = .normal
        
        // Set size constraints
        window.setContentSize(config.size)
        window.minSize = config.minSize
        window.maxSize = config.maxSize
        
        // Center window
        WindowUtilities.centerWindow(window, withOffset: config.centerOffset)
        window.makeKeyAndOrderFront(nil)
        
        // Set up delegate
        let delegate = UniversalWindowDelegate(windowType: type, windowManager: self)
        delegates[type] = delegate
        window.delegate = delegate
        
        return window
    }
    
    // MARK: - Internal Methods
    
    internal func windowDidClose(type: WindowType) {
        windows[type] = nil
        delegates[type] = nil
        updatePublishedState(for: type, isOpen: false)
        
        // Handle app policy changes
        if type == .configuration {
            makeAppAccessory()
        }
    }
    
    private func updatePublishedState(for type: WindowType, isOpen: Bool) {
        switch type {
        case .configuration:
            isConfigurationWindowOpen = isOpen
        case .about:
            isAboutWindowOpen = isOpen
        case .onboarding:
            isOnboardingWindowOpen = isOpen
        case .autoSwitching:
            isAutoSwitchingWindowOpen = isOpen
        case .demo:
            isDemoWindowOpen = isOpen
        }
    }
}

// MARK: - Universal Window Delegate

private class UniversalWindowDelegate: NSObject, NSWindowDelegate {
    private let windowType: WindowType
    private weak var windowManager: WindowManager?
    
    init(windowType: WindowType, windowManager: WindowManager) {
        self.windowType = windowType
        self.windowManager = windowManager
        super.init()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        windowManager?.windowDidClose(type: windowType)
        sender.orderOut(nil)
        return false
    }
} 