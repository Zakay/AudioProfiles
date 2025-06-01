import SwiftUI

/// Device Priorities Section - handles mode selection and device priority lists
struct DevicePrioritiesComponents: View {
    @Binding var profile: Profile
    @Binding var selectedMode: ProfileMode
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section Header with Mode Picker
            DevicePrioritiesHeader(selectedMode: $selectedMode)
            
            // Two-Pane Device Lists
            DevicePrioritiesContent(
                profile: $profile,
                selectedMode: selectedMode
            )
        }
    }
}

/// Header with title and mode selection
struct DevicePrioritiesHeader: View {
    @Binding var selectedMode: ProfileMode
    
    var body: some View {
        HStack {
            Text("Device Priorities")
                .font(.headline)
                .foregroundColor(.primary)
            
            Spacer()
            
            // Clean segmented control
            Picker("Mode", selection: $selectedMode) {
                Text("Public").tag(ProfileMode.public)
                Text("Private").tag(ProfileMode.private)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)
        }
    }
}

/// Two-pane content with input and output device lists
struct DevicePrioritiesContent: View {
    @Binding var profile: Profile
    let selectedMode: ProfileMode
    
    var body: some View {
        HStack(spacing: 8) {
            // Input Devices (Left Pane)
            DevicePriorityPane(
                title: "Audio Input",
                iconName: "mic",
                deviceList: selectedMode == .public ? $profile.publicInputPriority : $profile.privateInputPriority,
                isInput: true
            )
            
            // Thin visual separator
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 1)
                .padding(.vertical, 8)
            
            // Output Devices (Right Pane)
            DevicePriorityPane(
                title: "Audio Output",
                iconName: "speaker.wave.2",
                deviceList: selectedMode == .public ? $profile.publicOutputPriority : $profile.privateOutputPriority,
                isInput: false
            )
        }
        .frame(minHeight: 320)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

/// Individual pane for input or output devices
struct DevicePriorityPane: View {
    let title: String
    let iconName: String
    @Binding var deviceList: [String]
    let isInput: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Pane Header
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(.secondary)
                    .font(.title3)
                    .frame(width: 20, height: 20)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
            }
            
            // Device Priority List
            DevicePriorityListView(
                deviceList: $deviceList,
                title: "\(title) Priority",
                isInput: isInput
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 250)
    }
} 