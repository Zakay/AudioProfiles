import SwiftUI

/// Menu bar row for the Content Modes feature — shows on/off toggle and expanded mode list.
struct ContentModesRow: View {
    @StateObject private var store = SoundModesStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Master toggle
            Button {
                store.setEnabled(!store.isEnabled)
            } label: {
                HStack {
                    Image(systemName: "waveform")
                        .foregroundColor(store.isEnabled ? .accentColor : .secondary)
                        .frame(width: 16, height: 16)
                        .frame(width: 24)
                    Text("Content Modes")
                    Spacer()
                    Text(store.isEnabled ? "On" : "Off")
                        .font(.caption)
                        .foregroundColor(store.isEnabled ? .green : .secondary)
                }
            }
            .buttonStyle(MenuRowButtonStyle())

            // Expanded mode list when enabled
            if store.isEnabled {
                VStack(spacing: 0) {
                    // Auto option
                    Button { store.setManualOverride(nil) } label: {
                        HStack {
                            Image(systemName: "sparkles")
                                .foregroundColor(store.manualOverride == nil ? .accentColor : .secondary)
                                .frame(width: 14, height: 14)
                                .frame(width: 20)
                            Text("Auto").font(.caption)
                            Spacer()
                            if store.manualOverride == nil {
                                Image(systemName: "checkmark").font(.caption).foregroundColor(.accentColor)
                            }
                        }
                        .padding(.leading, 28)
                    }
                    .buttonStyle(MenuRowButtonStyle())

                    ForEach(ContentModeType.allCases.filter { $0 != .none }, id: \.self) { mode in
                        Button { store.setManualOverride(mode) } label: {
                            HStack {
                                Image(systemName: mode.iconName)
                                    .foregroundColor(mode == store.activeContentMode ? .accentColor : .secondary)
                                    .frame(width: 14, height: 14)
                                    .frame(width: 20)
                                Text(mode.displayName).font(.caption)
                                Spacer()
                                if store.manualOverride == mode {
                                    Image(systemName: "checkmark").font(.caption).foregroundColor(.accentColor)
                                }
                            }
                            .padding(.leading, 28)
                        }
                        .buttonStyle(MenuRowButtonStyle())
                    }
                }
            }
        }
    }
}
