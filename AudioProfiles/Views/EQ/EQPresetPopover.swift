import SwiftUI

/// Popover for selecting a headphone EQ preset or switching back to Custom mode.
struct EQPresetPopover: View {
    let deviceName: String
    let mode: EQMode
    let onApplyPreset: (String, String, EQSettings) -> Void
    let onSwitchToCustom: () -> Void

    @State private var searchText = ""
    @State private var selectedHeadphone: EQPresetHeadphone? = nil

    private let presetService = EQPresetService.shared

    private var searchResults: [EQPresetHeadphone] {
        if searchText.isEmpty {
            return presetService.suggestions(forDeviceName: deviceName, limit: 40)
        }
        return presetService.search(query: searchText, limit: 40)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar

            Divider()

            if let hp = selectedHeadphone {
                targetSection(for: hp)
            } else {
                customOption
                Divider()
                resultsList
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 360)
        .onAppear {
            if let name = mode.presetHeadphoneName,
               let hp = presetService.headphone(named: name) {
                selectedHeadphone = hp
                searchText = hp.name
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Search audio devices…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit {
                    if let first = searchResults.first { selectedHeadphone = first }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    selectedHeadphone = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: - Custom Option

    private var customOption: some View {
        Button { onSwitchToCustom() } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .frame(width: 16)
                Text("Custom")
                    .font(.system(size: 12))
                    .fontWeight(mode.isPreset ? .regular : .medium)
                Spacer()
                if !mode.isPreset {
                    Image(systemName: "checkmark").font(.caption).foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Results List

    @ViewBuilder
    private var resultsList: some View {
        if searchResults.isEmpty && !searchText.isEmpty {
            Text("No devices found")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(10)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(searchResults) { hp in
                        Button {
                            selectedHeadphone = hp
                            searchText = hp.name
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(hp.name)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                    Text(hp.category)
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if mode.presetHeadphoneName == hp.name {
                                    Image(systemName: "checkmark").font(.caption).foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Target Section

    @ViewBuilder
    private func targetSection(for hp: EQPresetHeadphone) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back button
            Button {
                selectedHeadphone = nil
                searchText = ""
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10))
                    Text("Back").font(.system(size: 11))
                }
                .foregroundColor(.blue)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text(hp.name).font(.system(size: 12, weight: .medium))
                Text("\(hp.brand) · \(hp.category)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            ForEach(hp.targets, id: \.self) { target in
                let isActive = mode.presetTarget == target && mode.presetHeadphoneName == hp.name
                Button {
                    if let settings = presetService.toEQSettings(headphone: hp, target: target) {
                        onApplyPreset(hp.name, target, settings)
                    }
                } label: {
                    HStack {
                        Text(target)
                            .font(.system(size: 12))
                            .fontWeight(isActive ? .medium : .regular)
                        Spacer()
                        if isActive {
                            Image(systemName: "checkmark").font(.caption).foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
