import SwiftUI

struct SoundModesTabView: View {
    @StateObject private var store = SoundModesStore.shared
    @State private var editingMode: ContentModeType?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with master toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Content Modes")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Adjust EQ based on what you're listening to")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $store.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if store.isEnabled {
                // Mode selector — Auto or manual override
                modeSelector

                Divider()

                // Mode list with Edit buttons
                modesList

                Divider()

                // Night mode
                nightModeSection
            } else {
                // Feature description when disabled
                VStack(alignment: .leading, spacing: 8) {
                    Label("Voice calls get speech clarity boost", systemImage: "mic.fill")
                    Label("Movies get cinematic bass and dialogue clarity", systemImage: "film")
                    Label("Night mode reduces bass during quiet hours", systemImage: "moon.fill")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.vertical, 8)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.bottom)
        .padding(.top, 8)
        .sheet(item: $editingMode) { mode in
            SoundModeEditorView(mode: mode)
        }
    }

    // MARK: - Mode Selector

    /// The mode to display — uses override directly if set, otherwise auto-detected
    private var displayedMode: ContentModeType {
        store.manualOverride ?? store.activeContentMode
    }

    private var modeSelector: some View {
        HStack(spacing: 10) {
            Image(systemName: displayedMode.iconName)
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(displayedMode.displayName)
                        .font(.callout)
                        .fontWeight(.medium)

                    if store.manualOverride == nil, let source = store.activeSourceApp {
                        Text("(\(source))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if store.isNightModeActive {
                    HStack(spacing: 4) {
                        Image(systemName: "moon.fill")
                            .font(.caption2)
                        Text("Night mode active")
                            .font(.caption)
                    }
                    .foregroundColor(.indigo)
                }
            }

            Spacer()

            // Mode picker — use separate state to avoid Combine lag
            Menu {
                Button {
                    store.manualOverride = nil
                } label: {
                    HStack {
                        Text("Auto")
                        if store.manualOverride == nil {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                ForEach(ContentModeType.allCases.filter { $0 != .none }, id: \.self) { mode in
                    Button(mode.displayName) {
                        store.manualOverride = mode
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.manualOverride?.displayName ?? "Auto")
                        .font(.callout)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Modes List

    private var modesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Modes")
                .font(.headline)

            ForEach(ContentModeType.allCases.filter { $0 != .none }, id: \.self) { mode in
                HStack(spacing: 10) {
                    Image(systemName: mode.iconName)
                        .foregroundColor(mode == store.activeContentMode ? .accentColor : .secondary)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(mode.displayName)
                            .font(.callout)
                        Text(mode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button("Edit") {
                        editingMode = mode
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Night Mode

    @State private var editingNightMode = false

    private var nightModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "moon.fill")
                    .foregroundColor(.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Night Mode")
                        .font(.headline)
                    Text("Reduce bass and compress dynamic range for quiet listening")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $store.nightMode.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if store.nightMode.isEnabled {
                HStack(spacing: 12) {
                    DatePicker("From", selection: nightTimeBinding(hour: $store.nightMode.startHour, minute: $store.nightMode.startMinute), displayedComponents: .hourAndMinute)
                        .font(.caption)
                        .labelsHidden()

                    Text("–")
                        .foregroundColor(.secondary)

                    DatePicker("To", selection: nightTimeBinding(hour: $store.nightMode.endHour, minute: $store.nightMode.endMinute), displayedComponents: .hourAndMinute)
                        .font(.caption)
                        .labelsHidden()

                    Spacer()

                    Button("Edit EQ") {
                        editingNightMode = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .sheet(isPresented: $editingNightMode) {
            NightModeEditorView()
        }
    }

    /// Bridge between hour/minute Int bindings and DatePicker's Date binding
    private func nightTimeBinding(hour: Binding<Int>, minute: Binding<Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                var comps = DateComponents()
                comps.hour = hour.wrappedValue
                comps.minute = minute.wrappedValue
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                hour.wrappedValue = comps.hour ?? 22
                minute.wrappedValue = comps.minute ?? 0
            }
        )
    }
}

// MARK: - ContentModeType Identifiable conformance for sheet

extension ContentModeType: Identifiable {
    var id: String { rawValue }
}
