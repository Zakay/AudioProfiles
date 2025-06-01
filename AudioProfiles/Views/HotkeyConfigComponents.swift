import SwiftUI

struct HotkeyConfigView: View {
    @Binding var hotkey: Hotkey?
    @StateObject private var keyCaptureService = KeyCaptureService()
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                if keyCaptureService.isCapturing {
                    // Capturing state: ONLY show capture message
                    Text("Press keys combination...")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                } else {
                    // Normal state: show existing hotkey or None
                    if let hotkey = hotkey {
                        HotkeyKeysView(hotkey: hotkey)
                    } else {
                        Text("None")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                if hotkey != nil && !keyCaptureService.isCapturing {
                    Button("Clear") {
                        hotkey = nil
                        keyCaptureService.resetCapture()
                    }
                    .foregroundColor(.secondary)
                }
                
                Button(keyCaptureService.isCapturing ? "Cancel" : "Set") {
                    if keyCaptureService.isCapturing {
                        keyCaptureService.resetCapture()
                    } else {
                        // Pass the binding directly to the service - simple and direct!
                        keyCaptureService.startCapturing(hotkeyBinding: $hotkey)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .onDisappear {
            keyCaptureService.resetCapture()
        }
    }
}

// MARK: - Hotkey Visual Display Component
struct HotkeyKeysView: View {
    let hotkey: Hotkey
    
    var body: some View {
        HStack(spacing: 4) {
            // Modifier keys
            ForEach(hotkey.modifierKeys, id: \.self) { modifierKey in
                KeyView(key: modifierKey)
            }
            
            // Main key
            KeyView(key: hotkey.mainKey)
        }
    }
}

// MARK: - Individual Key Display Component
struct KeyView: View {
    let key: String
    
    var body: some View {
        Text(key)
            .font(.system(.caption, design: .monospaced, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                    )
            )
    }
} 