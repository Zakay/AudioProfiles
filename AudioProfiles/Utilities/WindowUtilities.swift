import AppKit

/// Utility functions for window management and positioning
struct WindowUtilities {
    
    /// Centers a window on the main screen with an optional vertical offset
    /// - Parameters:
    ///   - window: The window to center
    ///   - offset: Optional vertical offset from center (positive moves up)
    static func centerWindow(_ window: NSWindow, withOffset offset: CGFloat = 0) {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        
        let x = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        let y = screenFrame.origin.y + (screenFrame.height - windowSize.height) / 2 + offset
        
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    /// Gets the screen where the user is currently interacting (based on mouse location)
    /// - Returns: The screen containing the mouse cursor, or main screen as fallback
    static func getCurrentInteractionScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        
        // Find the screen containing the mouse cursor
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        
        // Fallback to main screen if mouse not found on any screen
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }
    
    /// Centers a window on a specific screen with optional offset
    /// - Parameters:
    ///   - window: The window to center
    ///   - screen: The target screen
    ///   - offset: Optional vertical offset from center
    static func centerWindow(_ window: NSWindow, onScreen screen: NSScreen, withOffset offset: CGFloat = 0) {
        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        
        let x = screenFrame.origin.x + (screenFrame.width - windowSize.width) / 2
        let y = screenFrame.origin.y + (screenFrame.height - windowSize.height) / 2 + offset
        
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    /// Checks if a window is on the same screen as user's current interaction
    /// - Parameter window: The window to check
    /// - Returns: true if window is on the same screen as mouse cursor
    static func isWindowOnCurrentScreen(_ window: NSWindow) -> Bool {
        let currentScreen = getCurrentInteractionScreen()
        let windowScreen = window.screen ?? NSScreen.main
        return windowScreen == currentScreen
    }
    
    /// Creates a standard application window with consistent styling
    /// - Parameters:
    ///   - title: Window title
    ///   - size: Window size
    ///   - offset: Optional vertical offset from center
    /// - Returns: Configured NSWindow
    static func createStandardWindow(title: String, size: NSSize, offset: CGFloat = 0) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = title
        window.isReleasedWhenClosed = false
        window.level = .normal
        
        centerWindow(window, withOffset: offset)
        
        return window
    }
} 