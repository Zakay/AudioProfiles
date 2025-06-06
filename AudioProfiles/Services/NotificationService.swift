import Foundation
import UserNotifications

/// Service for showing user notifications
///
/// **Responsibility**: Manages all user-facing notifications for the application
/// **Architecture Role**: Service
/// **Usage**: Instantiated by other services; not a singleton
/// **Key Dependencies**: UserNotifications
class NotificationService {
    
    init() {
        requestNotificationPermission()
    }
    
    /// Request permission to show notifications
    private func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .badge]) { granted, error in
            if granted {
                AppLogger.info("Notification permission granted")
            } else if let error = error {
                AppLogger.warning("Notification permission denied: \(error.localizedDescription)")
            }
        }
    }
    
    /// Show notification for triggered profile switch
    /// - Parameters:
    ///   - profileName: Name of the activated profile
    ///   - triggerDevice: Device that triggered the switch
    ///   - matchCount: Number of trigger devices matched
    func notifyTriggeredSwitch(profileName: String, triggerDevice: String, matchCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Switched to '\(profileName)'"
        
        if matchCount == 1 {
            content.body = "\(triggerDevice) connected"
        } else {
            content.body = "\(triggerDevice) and \(matchCount - 1) other devices connected"
        }
        
        showNotification(content: content, identifier: "triggered-switch")
    }
    
    /// Show notification for fallback to System Default
    /// - Parameters:
    ///   - profileName: Name of the profile we switched to (should be "System Default")
    ///   - lostTriggerDevice: Device that was disconnected causing the fallback
    func notifyFallbackSwitch(profileName: String, lostTriggerDevice: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Switched to '\(profileName)'"
        
        if let device = lostTriggerDevice {
            content.body = "\(device) disconnected"
        } else {
            content.body = "No trigger devices connected"
        }
        
        showNotification(content: content, identifier: "fallback-switch")
    }
    
    /// Show notification for manual profile switch
    /// - Parameter profileName: Name of the manually selected profile
    func notifyManualSwitch(profileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Switched to '\(profileName)'"
        content.body = "Manually selected"
        
        showNotification(content: content, identifier: "manual-switch")
    }
    
    /// Send the notification
    /// - Parameters:
    ///   - content: Notification content
    ///   - identifier: Unique identifier for the notification
    private func showNotification(content: UNMutableNotificationContent, identifier: String) {
        // Set sound and other properties
        content.sound = .default
        
        // Create request
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )
        
        // Schedule notification
        let center = UNUserNotificationCenter.current()
        center.add(request) { error in
            if let error = error {
                AppLogger.warning("Failed to show notification: \(error.localizedDescription)")
            }
        }
    }
} 