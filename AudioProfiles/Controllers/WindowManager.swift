import SwiftUI
import AppKit

class WindowManager: NSObject, ObservableObject {
    static let shared = WindowManager()
    
    // Direct window references - internal for delegate access
    internal var configurationWindow: NSWindow?
    internal var aboutWindow: NSWindow?
    internal var onboardingWindow: NSWindow?
    internal var autoSwitchingWindow: NSWindow?
    
    // Strong delegate references
    private var configurationDelegate: ConfigurationWindowDelegate?
    private var aboutDelegate: AboutWindowDelegate?
    private var onboardingDelegate: OnboardingWindowDelegate?
    private var autoSwitchingDelegate: AutoSwitchingWindowDelegate?
    
    @Published var isConfigurationWindowOpen = false
    @Published var isAboutWindowOpen = false
    @Published var isOnboardingWindowOpen = false
    @Published var isAutoSwitchingWindowOpen = false
    
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
    
    // MARK: - Configuration Window
    
    func openConfigurationWindow() {
        NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
        
        if let window = configurationWindow, window.isVisible {
            // Check if window is on the same screen as user interaction
            if !WindowUtilities.isWindowOnCurrentScreen(window) {
                // Move window to current screen first
                WindowUtilities.centerWindow(window, onScreen: WindowUtilities.getCurrentInteractionScreen(), withOffset: 80)
            }
            
            // Make sure app is in regular mode for proper window behavior
            makeAppRegular()
            
            // Bring existing window to front and give it focus
            window.makeKeyAndOrderFront(nil)
            return
        }
        
        // Switch to regular app behavior before creating window
        makeAppRegular()
        
        configurationWindow = createConfigurationWindow()
        isConfigurationWindowOpen = true
    }
    
    // MARK: - About Window
    
    func openAboutWindow() {
        NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
        
        if let window = aboutWindow, window.isVisible {
            // Check if window is on the same screen as user interaction
            if !WindowUtilities.isWindowOnCurrentScreen(window) {
                // Move window to current screen first
                WindowUtilities.centerWindow(window, onScreen: WindowUtilities.getCurrentInteractionScreen(), withOffset: 0)
            }
            
            // Bring existing window to front and give it focus
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        aboutWindow = createAboutWindow()
        isAboutWindowOpen = true
        
        // Activate app when opening new window from menu
        NSApp.activate(ignoringOtherApps: false)
    }
    
    // MARK: - Onboarding Window
    
    func openOnboardingWindow() {
        NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
        
        if let window = onboardingWindow, window.isVisible {
            // Check if window is on the same screen as user interaction
            if !WindowUtilities.isWindowOnCurrentScreen(window) {
                // Move window to current screen first
                WindowUtilities.centerWindow(window, onScreen: WindowUtilities.getCurrentInteractionScreen(), withOffset: 40)
            }
            
            // Bring existing window to front and give it focus
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        onboardingWindow = createOnboardingWindow()
        isOnboardingWindowOpen = true
        
        // Activate app when opening new window from menu
        NSApp.activate(ignoringOtherApps: false)
    }
    
    // MARK: - Auto-Switching Dialog
    
    func openAutoSwitchingDialog() {
        NSApp.sendAction(#selector(NSPopover.performClose(_:)), to: nil, from: nil)
        
        if let window = autoSwitchingWindow, window.isVisible {
            // Check if window is on the same screen as user interaction
            if !WindowUtilities.isWindowOnCurrentScreen(window) {
                // Move window to current screen first
                WindowUtilities.centerWindow(window, onScreen: WindowUtilities.getCurrentInteractionScreen(), withOffset: 20)
            }
            
            // Bring existing window to front and give it focus
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        autoSwitchingWindow = createAutoSwitchingWindow()
        isAutoSwitchingWindowOpen = true
        
        // Activate app when opening new window from menu
        NSApp.activate(ignoringOtherApps: false)
    }
    
    func closeAllWindows() {
        configurationWindow?.close()
        aboutWindow?.close()
        onboardingWindow?.close()
        autoSwitchingWindow?.close()
    }
    
    // MARK: - Private Implementation
    
    private func createConfigurationWindow() -> NSWindow {
        let window = createWindow(
            title: "Configure AudioProfiles",
            view: AnyView(ConfigurationView()),
            size: NSSize(width: 500, height: 600),
            offset: 80
        )
        
        configurationDelegate = ConfigurationWindowDelegate()
        window.delegate = configurationDelegate
        return window
    }
    
    private func createAboutWindow() -> NSWindow {
        let window = createWindow(
            title: "About AudioProfiles",
            view: AnyView(AboutView()),
            size: NSSize(width: 400, height: 500),
            offset: 0
        )
        
        aboutDelegate = AboutWindowDelegate()
        window.delegate = aboutDelegate
        return window
    }
    
    private func createOnboardingWindow() -> NSWindow {
        let window = createWindow(
            title: "Welcome to AudioProfiles",
            view: AnyView(OnboardingView()),
            size: NSSize(width: 700, height: 600),
            offset: 40
        )
        
        onboardingDelegate = OnboardingWindowDelegate()
        window.delegate = onboardingDelegate
        return window
    }
    
    private func createAutoSwitchingWindow() -> NSWindow {
        let window = createWindow(
            title: "Auto-Switching",
            view: AnyView(AutoSwitchingDialogView()),
            size: NSSize(width: 320, height: 300),
            offset: 20
        )
        
        autoSwitchingDelegate = AutoSwitchingWindowDelegate()
        window.delegate = autoSwitchingDelegate
        return window
    }
    
    private func createWindow(title: String, view: AnyView, size: NSSize, offset: CGFloat) -> NSWindow {
        let hostingController = NSHostingController(rootView: view)
        
        let window = WindowUtilities.createStandardWindow(title: title, size: size, offset: offset)
        window.contentViewController = hostingController
        
        window.makeKeyAndOrderFront(nil)
        
        return window
    }
}

// MARK: - Window Delegates
private class ConfigurationWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowManager.shared.configurationWindow = nil
        WindowManager.shared.isConfigurationWindowOpen = false
        
        // Revert to menu bar only behavior when configuration window closes
        WindowManager.shared.makeAppAccessory()
        
        sender.orderOut(nil)
        return false
    }
}

private class AboutWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowManager.shared.aboutWindow = nil
        WindowManager.shared.isAboutWindowOpen = false
        sender.orderOut(nil)
        return false
    }
}

private class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowManager.shared.onboardingWindow = nil
        WindowManager.shared.isOnboardingWindowOpen = false
        sender.orderOut(nil)
        return false
    }
}

private class AutoSwitchingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        WindowManager.shared.autoSwitchingWindow = nil
        WindowManager.shared.isAutoSwitchingWindowOpen = false
        sender.orderOut(nil)
        return false
    }
} 