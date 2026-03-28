import SwiftUI

struct TriggerDeviceSummaryView: View {
    @Binding var triggerRules: [TriggerRule]
    @State private var showingSelectionSheet = false

    // Use new consolidated service
    private let deviceFilterService = DeviceFilterService()

    var body: some View {
        Button(action: {
            showingSelectionSheet = true
        }) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryText)
                        .font(.body)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .sheet(isPresented: $showingSelectionSheet) {
            TriggerDeviceSelectionView(triggerRules: $triggerRules)
        }
    }

    private var summaryText: String {
        if triggerRules.isEmpty {
            return "None"
        }

        var parts: [String] = []

        for rule in triggerRules {
            switch rule {
            case .specificDevice(let id):
                if let device = deviceFilterService.getDevice(by: id) {
                    parts.append(device.name)
                }
            case .transportType(let type):
                parts.append("Any \(type)")
            }
        }

        if parts.isEmpty {
            return "\(triggerRules.count) rule\(triggerRules.count == 1 ? "" : "s") selected"
        }

        return DeviceDisplayUtils.formatDeviceNames(parts)
    }
}
