import SwiftUI

struct AutoSwitchingDialogView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var profileManager = ProfileManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack {
                Image(systemName: "bolt")
                    .foregroundColor(.green)
                    .font(.title2)
                
                Text("Auto-switching")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
            }
            
            // Current status
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Status")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                
                if profileManager.isAutoSwitchingDisabled {
                    HStack {
                        Image(systemName: "bolt.slash")
                            .foregroundColor(.orange)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Disabled")
                                .fontWeight(.medium)
                                .foregroundColor(.orange)
                            
                            if let remainingTime = profileManager.remainingDisableTime {
                                Text("Re-enables in \(remainingTime)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("Disabled forever")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                } else {
                    HStack {
                        Image(systemName: "bolt")
                            .foregroundColor(.green)
                        
                        Text("Enabled")
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                        
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            
            // Actions
            if profileManager.isAutoSwitchingDisabled {
                // Re-enable button
                DisableOptionBox(
                    title: "Enable Auto-switching",
                    icon: "bolt",
                    isDestructive: false,
                    isPositive: true,
                    action: {
                        profileManager.enableAutoSwitching()
                        dismiss()
                    }
                )
            } else {
                // Disable options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Disable Options")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    VStack(spacing: 8) {
                        DisableOptionBox(
                            title: "Disable for 1 hour",
                            icon: "clock",
                            action: {
                                profileManager.disableAutoSwitching(for: .hours(1))
                                dismiss()
                            }
                        )
                        
                        DisableOptionBox(
                            title: "Disable for 3 hours",
                            icon: "clock",
                            action: {
                                profileManager.disableAutoSwitching(for: .hours(3))
                                dismiss()
                            }
                        )
                        
                        DisableOptionBox(
                            title: "Disable for 5 hours", 
                            icon: "clock",
                            action: {
                                profileManager.disableAutoSwitching(for: .hours(5))
                                dismiss()
                            }
                        )
                        
                        DisableOptionBox(
                            title: "Disable until end of day",
                            icon: "moon",
                            action: {
                                profileManager.disableAutoSwitching(for: .untilEndOfDay)
                                dismiss()
                            }
                        )
                        
                        DisableOptionBox(
                            title: "Disable forever",
                            icon: "infinity",
                            isDestructive: true,
                            action: {
                                profileManager.disableAutoSwitching(for: .forever)
                                dismiss()
                            }
                        )
                    }
                }
            }
            
            // Cancel button
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .frame(height: 36)
            }
        }
        .padding(24)
        .frame(width: 300)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

/// Clickable disable option box that matches the current status design
struct DisableOptionBox: View {
    let title: String
    let icon: String
    let isDestructive: Bool
    let isPositive: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    init(title: String, icon: String, isDestructive: Bool = false, isPositive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.isDestructive = isDestructive
        self.isPositive = isPositive
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                
                Text(title)
                    .fontWeight(.medium)
                    .foregroundColor(textColor)
                
                Spacer()
            }
            .padding(12)
            .background(backgroundColor)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: isHovered ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
    
    private var backgroundColor: Color {
        if isDestructive {
            return isHovered ? Color.red.opacity(0.15) : Color.red.opacity(0.08)
        } else if isPositive {
            return isHovered ? Color.green.opacity(0.15) : Color.green.opacity(0.08)
        } else {
            return isHovered ? Color.gray.opacity(0.15) : Color.gray.opacity(0.08)
        }
    }
    
    private var iconColor: Color {
        isDestructive ? .red : (isPositive ? .green : .secondary)
    }
    
    private var textColor: Color {
        isDestructive ? .red : (isPositive ? .green : .primary)
    }
    
    private var borderColor: Color {
        isDestructive ? Color.red.opacity(0.3) : (isPositive ? Color.green.opacity(0.3) : Color.gray.opacity(0.3))
    }
} 