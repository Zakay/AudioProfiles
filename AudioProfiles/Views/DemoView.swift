import SwiftUI

struct DemoView: View {
    @State private var selectedTab = 0
    @State private var showProfileEditor = false
    @State private var selectedProfile: DemoProfile? = nil
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // Profile List View
            DemoProfileListView(showEditor: $showProfileEditor, selectedProfile: $selectedProfile)
                .tabItem {
                    Image(systemName: "list.bullet")
                    Text("Profiles")
                }
                .tag(0)
            
            // Status Bar Menu Demo
            DemoStatusBarView()
                .tabItem {
                    Image(systemName: "menubar.rectangle")
                    Text("Menu")
                }
                .tag(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showProfileEditor) {
            if let profile = selectedProfile {
                DemoProfileEditorView(profile: profile)
            }
        }
    }
}

struct DemoProfileListView: View {
    @Binding var showEditor: Bool
    @Binding var selectedProfile: DemoProfile?
    
    private let demoProfiles = [
        DemoProfile(
            name: "Work Setup",
            icon: "briefcase",
            hotkey: "⌘⌥1",
            mode: "Public",
            outputDevice: "Studio Display Speakers",
            inputDevice: "MacBook Pro Microphone",
            triggerDevice: "Studio Display",
            hasTrigger: true
        ),
        DemoProfile(
            name: "Gaming",
            icon: "gamecontroller",
            hotkey: "⌘⌥2", 
            mode: "Private",
            outputDevice: "SteelSeries Arctis 7",
            inputDevice: "SteelSeries Arctis 7",
            triggerDevice: "SteelSeries Arctis 7",
            hasTrigger: true
        ),
        DemoProfile(
            name: "Music Production",
            icon: "music.note",
            hotkey: "⌘⌥3",
            mode: "Private",
            outputDevice: "Audio-Technica ATH-M50x",
            inputDevice: "Blue Yeti Nano",
            triggerDevice: "Blue Yeti Nano",
            hasTrigger: true
        ),
        DemoProfile(
            name: "Video Calls",
            icon: "video",
            hotkey: "⌘⌥4",
            mode: "Private",
            outputDevice: "AirPods Pro",
            inputDevice: "AirPods Pro",
            triggerDevice: "None",
            hasTrigger: false
        ),
        DemoProfile(
            name: "System Default",
            icon: "speaker.wave.2",
            hotkey: "",
            mode: "Public",
            outputDevice: "Default",
            inputDevice: "Default", 
            triggerDevice: "",
            hasTrigger: false
        )
    ]
    
    var body: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Audio Profiles")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        selectedProfile = DemoProfile.newProfile()
                        showEditor = true
                    } label: {
                        Label("Add Profile", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                List {
                    ForEach(demoProfiles, id: \.name) { profile in
                        DemoProfileRow(
                            profile: profile,
                            onEdit: {
                                selectedProfile = profile
                                showEditor = true
                            }
                        )
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(height: 350)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            // Settings Section
            VStack(spacing: 12) {
                HStack {
                    Text("Settings")
                        .font(.headline)
                    Spacer()
                }
                
                HStack {
                    Toggle("Launch at Login", isOn: .constant(true))
                    Spacer()
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct DemoProfileRow: View {
    let profile: DemoProfile
    let onEdit: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Profile Icon
            Image(systemName: profile.icon)
                .font(.title2)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.1))
                )
                .foregroundColor(.accentColor)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(profile.name)
                        .font(.headline)
                    
                    if profile.name != "System Default" {
                        // Hotkey badge
                        if !profile.hotkey.isEmpty {
                            Text(profile.hotkey)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.gray.opacity(0.2))
                                .foregroundColor(.primary)
                                .cornerRadius(6)
                        }
                        
                        // Mode badge
                        HStack(spacing: 4) {
                            Image(systemName: profile.mode == "Public" ? "speaker.wave.2" : "headphones")
                                .font(.caption2)
                            Text(profile.mode)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(profile.mode == "Public" ? Color.blue.opacity(0.2) : Color.purple.opacity(0.2))
                        .foregroundColor(profile.mode == "Public" ? .blue : .purple)
                        .cornerRadius(6)
                        
                        // Trigger badge
                        if profile.hasTrigger {
                            HStack(spacing: 4) {
                                Image(systemName: "bolt")
                                    .font(.caption2)
                                Text(profile.triggerDevice)
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(6)
                        }
                    }
                    
                    Spacer()
                }
                
                // Device info
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(profile.outputDevice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "mic")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(profile.inputDevice)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
            }
            
            Spacer()
            
            if profile.name != "System Default" {
                Button("Edit") {
                    onEdit()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DemoStatusBarView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("Status Bar Menu")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 16) {
                // Show actual menubar icon
                VStack(spacing: 8) {
                    Text("Menu Bar Icon")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    // Mock menubar with our actual icon
                    HStack {
                        Spacer()
                        
                        // Mock other menubar items
                        Image(systemName: "wifi")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                        
                        Image(systemName: "battery.100")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                        
                        // Our actual StatusItemView
                        DemoStatusItemView()
                        
                        // Mock clock
                        Text("2:30 PM")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(6)
                    .frame(width: 200)
                    
                    Text("Click the AudioProfiles icon to open menu")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Arrow pointing down
                Image(systemName: "arrow.down")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                // Show actual ProfileMenuView
                VStack(spacing: 8) {
                    Text("Popover Menu")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    // Use demo version that shows static data
                    DemoProfileMenuView()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                        .shadow(radius: 10)
                        .frame(width: 240)
                }
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// Demo version of StatusItemView that shows how the menubar icon looks
struct DemoStatusItemView: View {
    var body: some View {
        ZStack {
            // Colored background based on mode
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.blue) // Show public mode
                .frame(width: 24, height: 18)
            
            // Profile icon on top
            Image(systemName: "briefcase.fill")
                .foregroundColor(.white)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(width: 28, height: 22)
    }
}

// Demo version of ProfileMenuView with static data
struct DemoProfileMenuView: View {
    private let demoProfiles = [
        ("briefcase.fill", "Work Setup", true),
        ("gamecontroller.fill", "Gaming", false),
        ("music.note", "Music Production", false),
        ("video.fill", "Video Calls", false),
        ("speaker.wave.2.fill", "System Default", false)
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current profile header with mode toggle
            HStack {
                // Profile icon
                Image(systemName: "briefcase.fill")
                    .foregroundColor(.blue)
                    .frame(width: 20, height: 20)
                    .frame(width: 24)
                
                VStack(alignment: .leading) {
                    Text("Work Setup")
                        .font(.headline)
                }
                
                Spacer()
                
                // Mode toggle
                HStack(spacing: 4) {
                    Image(systemName: "speaker.wave.2")
                        .font(.caption)
                    Text("Public")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.2))
                .foregroundColor(.blue)
                .cornerRadius(6)
            }
            .padding(.leading, 4)
            
            // Current devices section
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)
                    Text("Studio Display Speakers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 4)
                
                HStack(spacing: 8) {
                    Image(systemName: "mic")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)
                    Text("MacBook Pro Microphone")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 4)
            }
            
            Divider()
            
            // Profile list
            ForEach(Array(demoProfiles.enumerated()), id: \.offset) { index, profile in
                HStack {
                    Image(systemName: profile.0)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)
                    
                    Text(profile.1)
                    Spacer()
                    if profile.2 {
                        Image(systemName: "checkmark")
                            .foregroundColor(Color.accentColor)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(profile.2 ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            
            Divider()
            
            // Auto-switching status
            HStack {
                Image(systemName: "bolt")
                    .foregroundColor(.green)
                    .frame(width: 16, height: 16)
                    .frame(width: 24)
                
                Text("Auto-switching")
                Spacer()
                Text("Enabled")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            
            Divider()
            
            // Settings button
            HStack {
                Text("Configure")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            
            Divider()
            
            // About button
            HStack {
                Text("About")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            
            Divider()
            
            // Quit button
            HStack {
                Text("Quit")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}

struct DemoProfileEditorView: View {
    let profile: DemoProfile
    @Environment(\.dismiss) var dismiss
    @State private var profileName: String = ""
    @State private var selectedIcon = "briefcase"
    @State private var selectedMode = "Public"
    @State private var hotkeyEnabled = true
    
    let icons = ["briefcase", "gamecontroller", "music.note", "video", "headphones", "speaker.wave.2", "mic", "tv"]
    let demoDevices = [
        "MacBook Pro Speakers",
        "Studio Display Speakers", 
        "AirPods Pro",
        "SteelSeries Arctis 7",
        "Audio-Technica ATH-M50x",
        "Blue Yeti Nano",
        "MacBook Pro Microphone"
    ]
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Text(profile.name == "New Profile" ? "Add Profile" : "Edit Profile")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            
            // Profile Details
            VStack(alignment: .leading, spacing: 16) {
                // Name and Icon
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Profile Name")
                            .font(.headline)
                        TextField("Enter name", text: $profileName)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Icon")
                            .font(.headline)
                        HStack {
                            ForEach(icons.prefix(4), id: \.self) { icon in
                                Button {
                                    selectedIcon = icon
                                } label: {
                                    Image(systemName: icon)
                                        .font(.title2)
                                        .frame(width: 32, height: 32)
                                        .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // Mode Selection
                VStack(alignment: .leading) {
                    Text("Audio Mode")
                        .font(.headline)
                    Picker("Mode", selection: $selectedMode) {
                        Text("Public (Speakers)").tag("Public")
                        Text("Private (Headphones)").tag("Private")
                    }
                    .pickerStyle(.segmented)
                }
                
                // Device Selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("Device Priorities")
                        .font(.headline)
                    
                    HStack(spacing: 20) {
                        VStack(alignment: .leading) {
                            Text("Output Devices")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            VStack(spacing: 4) {
                                ForEach(demoDevices.prefix(3), id: \.self) { device in
                                    HStack {
                                        Image(systemName: "speaker.wave.2")
                                            .foregroundColor(.secondary)
                                        Text(device)
                                            .font(.caption)
                                        Spacer()
                                        Text("1")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.gray.opacity(0.2))
                                            .cornerRadius(4)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.05))
                                    .cornerRadius(6)
                                }
                            }
                        }
                        
                        VStack(alignment: .leading) {
                            Text("Input Devices")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            
                            VStack(spacing: 4) {
                                ForEach(demoDevices.suffix(2), id: \.self) { device in
                                    HStack {
                                        Image(systemName: "mic")
                                            .foregroundColor(.secondary)
                                        Text(device)
                                            .font(.caption)
                                        Spacer()
                                        Text("1")
                                            .font(.caption2)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.gray.opacity(0.2))
                                            .cornerRadius(4)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.gray.opacity(0.05))
                                    .cornerRadius(6)
                                }
                            }
                        }
                    }
                }
                
                // Hotkey Configuration
                VStack(alignment: .leading) {
                    Toggle("Enable Hotkey", isOn: $hotkeyEnabled)
                        .font(.headline)
                    
                    if hotkeyEnabled {
                        HStack {
                            Text("Hotkey:")
                            Spacer()
                            Text("⌘⌥2")
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.gray.opacity(0.1))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .frame(width: 500, height: 600)
        .onAppear {
            profileName = profile.name == "New Profile" ? "" : profile.name
        }
    }
}

struct DemoProfile {
    let name: String
    let icon: String
    let hotkey: String
    let mode: String
    let outputDevice: String
    let inputDevice: String
    let triggerDevice: String
    let hasTrigger: Bool
    
    static func newProfile() -> DemoProfile {
        return DemoProfile(
            name: "New Profile",
            icon: "briefcase",
            hotkey: "",
            mode: "Public",
            outputDevice: "Default",
            inputDevice: "Default",
            triggerDevice: "",
            hasTrigger: false
        )
    }
}

#Preview {
    DemoView()
} 