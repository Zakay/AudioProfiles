import SwiftUI

// MARK: - EQ Install Prompt (inline banner in EQTabView)

/// Compact inline banner shown when the driver is not installed.
struct EQInstallPromptView: View {
    let deviceName: String
    @Binding var showingSheet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text("EQ requires a one-time driver installation.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Button("Install Audio Component…") { showingSheet = true }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

// MARK: - EQ Driver Install Sheet

/// Full install sheet presented as a modal when user taps "Install Audio Component…".
struct EQDriverInstallSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var installService = EQInstallationService.shared
    @State private var isInstalling = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.blue)

            Text("EQ Audio Component")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "headphones",  text: "Apply per-device EQ curves to any output")
                FeatureRow(icon: "eye.slash",   text: "Invisible when not in use — no clutter")
                FeatureRow(icon: "lock.shield", text: "Runs inside macOS audio system, no background process")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            Text("This installs a small audio processing component into macOS's audio system (*/Library/Audio/Plug-Ins/HAL/*). You'll be asked for your admin password once. No restart is required.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let error = errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }

            HStack(spacing: 12) {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)

                Button(isInstalling ? "Installing…" : "Install Component") { performInstall() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func performInstall() {
        isInstalling = true
        errorMessage = nil
        installService.install { success in
            isInstalling = false
            if success {
                isPresented = false
            } else if installService.installState == .notLoaded {
                isPresented = false
            } else {
                errorMessage = "Installation failed or was cancelled. Please try again."
            }
        }
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundColor(.blue)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Level Meter

/// Real-time stereo level meter — shown as an overlay on the EQ graph when pipeline is running.
struct LevelMeterView: View {
    @ObservedObject private var monitor = AudioLevelMonitor.shared

    var body: some View {
        HStack(spacing: 2) {
            LevelBar(level: CGFloat(monitor.leftLevel))
            LevelBar(level: CGFloat(monitor.rightLevel))
        }
    }
}

struct LevelBar: View {
    let level: CGFloat

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.green, .green, .yellow, .red],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: geo.size.height * min(level, 1.0))
            }
        }
        .frame(width: 4)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}
