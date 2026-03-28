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
                Toggle("", isOn: Binding(
                    get: { store.isEnabled },
                    set: { store.setEnabled($0) }
                ))
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

            // Mode picker
            Menu {
                Button {
                    store.setManualOverride(nil)
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
                        store.setManualOverride(mode)
                    }
                }
            } label: {
                Text(store.manualOverride?.displayName ?? "Auto")
                    .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
        }
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
                        HStack(spacing: 4) {
                            Text(mode.displayName)
                                .font(.callout)
                            if mode == .voice {
                                Text("Auto · Mic")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .cornerRadius(3)
                            }
                        }
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
                Toggle("", isOn: Binding(
                    get: { store.nightMode.isEnabled },
                    set: { newValue in
                        var config = store.nightMode
                        config.isEnabled = newValue
                        store.setNightMode(config)
                    }
                ))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if store.nightMode.isEnabled {
                HStack(spacing: 12) {
                    DatePicker("From", selection: nightTimeBinding(
                        getValue: { (store.nightMode.startHour, store.nightMode.startMinute) },
                        setValue: { hour, minute in
                            var config = store.nightMode
                            config.startHour = hour
                            config.startMinute = minute
                            store.setNightMode(config)
                        }
                    ), displayedComponents: .hourAndMinute)
                        .font(.caption)
                        .labelsHidden()

                    Text("\u{2013}")
                        .foregroundColor(.secondary)

                    DatePicker("To", selection: nightTimeBinding(
                        getValue: { (store.nightMode.endHour, store.nightMode.endMinute) },
                        setValue: { hour, minute in
                            var config = store.nightMode
                            config.endHour = hour
                            config.endMinute = minute
                            store.setNightMode(config)
                        }
                    ), displayedComponents: .hourAndMinute)
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
        .sheet(isPresented: $editingNightMode) {
            NightModeEditorView()
        }
    }

    /// Bridge between hour/minute getter/setter and DatePicker's Date binding
    private func nightTimeBinding(
        getValue: @escaping () -> (Int, Int),
        setValue: @escaping (Int, Int) -> Void
    ) -> Binding<Date> {
        Binding<Date>(
            get: {
                let (hour, minute) = getValue()
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                return Calendar.current.date(from: comps) ?? Date()
            },
            set: { date in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                setValue(comps.hour ?? 22, comps.minute ?? 0)
            }
        )
    }
}

// MARK: - ContentModeType Identifiable conformance for sheet

extension ContentModeType: Identifiable {
    var id: String { rawValue }
}
