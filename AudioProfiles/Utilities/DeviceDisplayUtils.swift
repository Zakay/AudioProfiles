import SwiftUI

/// Centralizes device display formatting and icon logic to eliminate duplication across views
struct DeviceDisplayUtils {
    
    // MARK: - Device Type Descriptions
    
    /// Get standardized device type description (Input/Output/Input/Output)
    static func deviceTypeDescription(for device: AudioDevice) -> String {
        if device.isInput && device.isOutput {
            return "Input/Output"
        } else if device.isInput {
            return "Input"
        } else {
            return "Output"
        }
    }
    
    // MARK: - Device Icons
    
    /// Get appropriate SF Symbol icon for device based on transport type and capabilities
    static func deviceIcon(for device: AudioDevice) -> String {
        switch device.transportType {
        case "Built-In":
            return device.isInput ? "mic.fill" : "speaker.fill"
        case "USB":
            return "cable.connector"
        case "Bluetooth":
            return "headphones"
        default:
            return device.isInput ? "mic" : "speaker.wave.2"
        }
    }
    
    // MARK: - Formatted Device Info
    
    /// Get standardized device info line (e.g., "USB • Input/Output")
    static func deviceInfoLine(for device: AudioDevice) -> String {
        return "\(device.transportType) • \(deviceTypeDescription(for: device))"
    }
    
    // MARK: - Device Name Formatting
    
    /// Truncate device name if it exceeds specified length, adding ellipsis
    static func truncatedDeviceName(_ name: String, maxLength: Int = 20, truncateLength: Int = 17) -> String {
        return name.count > maxLength ? String(name.prefix(truncateLength)) + "..." : name
    }
    
    /// Format device name for multi-device summaries (e.g., "Device1, Device2 and 3 more")
    static func formatDeviceNames(_ deviceNames: [String], maxVisible: Int = 2) -> String {
        guard !deviceNames.isEmpty else { return "No devices" }
        
        if deviceNames.count == 1 {
            return deviceNames[0]
        } else if deviceNames.count == 2 {
            return "\(deviceNames[0]) and \(deviceNames[1])"
        } else if deviceNames.count > maxVisible {
            let visibleNames = deviceNames.prefix(maxVisible).map { truncatedDeviceName($0) }
            let remainingCount = deviceNames.count - maxVisible
            return "\(visibleNames.joined(separator: ", ")) and \(remainingCount) more"
        } else {
            return deviceNames.joined(separator: ", ")
        }
    }
    
    // MARK: - Connection Status
    
    /// Get color for device connection status indicator
    static func connectionStatusColor(isConnected: Bool) -> Color {
        return isConnected ? .green : .gray
    }
    
    /// Get standardized connection status indicator view
    static func connectionStatusIndicator(isConnected: Bool, size: CGFloat = 8) -> some View {
        Circle()
            .fill(connectionStatusColor(isConnected: isConnected))
            .frame(width: size, height: size)
    }
    
    // MARK: - Text Colors
    
    /// Get appropriate text color based on connection status
    static func deviceNameColor(isConnected: Bool) -> Color {
        return isConnected ? .primary : .secondary
    }
    
    // MARK: - Complete Device Info Views
    
    /// Get standardized device info VStack with name and transport info
    static func deviceInfoView(for device: AudioDevice, isConnected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(device.name)
                .font(.body)
                .foregroundColor(deviceNameColor(isConnected: isConnected))
            
            Text(deviceInfoLine(for: device))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    /// Get standardized device row content (status indicator + info)
    static func deviceRowContent(for device: AudioDevice, isConnected: Bool, spacing: CGFloat = 12) -> some View {
        HStack(spacing: spacing) {
            connectionStatusIndicator(isConnected: isConnected)
            deviceInfoView(for: device, isConnected: isConnected)
        }
    }
} 