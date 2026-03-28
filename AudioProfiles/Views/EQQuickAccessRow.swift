import SwiftUI

/// Menu bar row for the EQ feature — shows EQ on/off toggle with current preset label.
/// Tapping toggles the global processing bypass.
struct EQQuickAccessRow: View {
    @ObservedObject private var eqStore = EQStore.shared
    @ObservedObject private var engine = EQEngineService.shared
    @ObservedObject private var installService = EQInstallationService.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    private var activeUID: String? {
        profileManager.activeOutputDeviceUID ?? engine.targetDeviceUID
    }

    private var presetLabel: String {
        guard let uid = activeUID else { return "No device" }
        let settings = eqStore.settings(for: uid)
        if settings.isFlat { return "Off" }
        switch eqStore.mode(for: uid) {
        case .custom: return "Custom"
        case .preset(let headphoneName, _): return headphoneName
        }
    }

    private var isBypassed: Bool { profileManager.isProcessingBypassed }

    private var hasEQ: Bool {
        guard let uid = activeUID else { return false }
        return !eqStore.settings(for: uid).isFlat
    }

    var body: some View {
        if installService.isInstalled {
            Button {
                profileManager.setProcessingBypassed(!profileManager.isProcessingBypassed)
            } label: {
                HStack {
                    Image(systemName: "slider.vertical.3")
                        .foregroundColor(hasEQ && !isBypassed ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)
                    Text("EQ")
                    Spacer()
                    if isBypassed {
                        Text("Off").font(.caption).foregroundColor(.secondary)
                    } else if hasEQ {
                        Text(presetLabel).font(.caption).foregroundColor(.green)
                    } else {
                        Text("No EQ").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(MenuRowButtonStyle())
        }
    }
}
