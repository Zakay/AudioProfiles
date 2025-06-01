import SwiftUI

/// Reusable device row component that consolidates repetitive HStack device row logic
struct DeviceRowView: View {
    let device: AudioDevice
    let isConnected: Bool
    let actions: [DeviceRowAction]
    let style: DeviceRowStyle
    let spacing: CGFloat
    
    init(
        device: AudioDevice,
        isConnected: Bool,
        actions: [DeviceRowAction] = [],
        style: DeviceRowStyle = .plain(),
        spacing: CGFloat = 12
    ) {
        self.device = device
        self.isConnected = isConnected
        self.actions = actions
        self.style = style
        self.spacing = spacing
    }
    
    var body: some View {
        HStack(spacing: spacing) {
            // Device content using consolidated utility
            DeviceDisplayUtils.deviceRowContent(for: device, isConnected: isConnected)
            
            Spacer()
            
            // Action buttons
            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        actionButton(for: action)
                    }
                }
            }
        }
        .padding(style.contentPadding)
        .background(style.background)
        .overlay(style.overlay)
    }
    
    @ViewBuilder
    private func actionButton(for action: DeviceRowAction) -> some View {
        Button(action: action.handler) {
            Image(systemName: action.icon)
                .foregroundColor(action.color)
                .font(.system(size: action.size))
        }
        .buttonStyle(.plain)
        .help(action.helpText)
    }
}

// MARK: - DeviceRowAction Configuration

struct DeviceRowAction {
    let icon: String
    let color: Color
    let size: CGFloat
    let helpText: String
    let handler: () -> Void
    
    // Common action types
    static func remove(helpText: String = "Remove", handler: @escaping () -> Void) -> DeviceRowAction {
        DeviceRowAction(
            icon: "minus.circle.fill",
            color: .red,
            size: 16,
            helpText: helpText,
            handler: handler
        )
    }
    
    static func add(helpText: String = "Add", handler: @escaping () -> Void) -> DeviceRowAction {
        DeviceRowAction(
            icon: "plus.circle.fill",
            color: .accentColor,
            size: 16,
            helpText: helpText,
            handler: handler
        )
    }
    
    static func trash(helpText: String = "Delete", handler: @escaping () -> Void) -> DeviceRowAction {
        DeviceRowAction(
            icon: "trash",
            color: .secondary,
            size: 14,
            helpText: helpText,
            handler: handler
        )
    }
}

// MARK: - DeviceRowStyle Configuration

struct DeviceRowStyle {
    let contentPadding: EdgeInsets
    let background: AnyView?
    let overlay: AnyView?
    
    /// Plain style with minimal padding (like DevicePriorityListView)
    static func plain(verticalPadding: CGFloat = 4) -> DeviceRowStyle {
        DeviceRowStyle(
            contentPadding: EdgeInsets(top: verticalPadding, leading: 0, bottom: verticalPadding, trailing: 0),
            background: nil,
            overlay: nil
        )
    }
    
    /// Styled with background and border (like DeviceSelectionSection)
    static func styled(
        horizontalPadding: CGFloat = 12,
        verticalPadding: CGFloat = 8,
        cornerRadius: CGFloat = 8
    ) -> DeviceRowStyle {
        DeviceRowStyle(
            contentPadding: EdgeInsets(
                top: verticalPadding,
                leading: horizontalPadding,
                bottom: verticalPadding,
                trailing: horizontalPadding
            ),
            background: AnyView(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(NSColor.controlBackgroundColor))
            ),
            overlay: AnyView(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        )
    }
}

// MARK: - Convenience Initializers

extension DeviceRowView {
    /// Priority list row with remove action
    static func priorityRow(
        device: AudioDevice,
        isConnected: Bool,
        onRemove: @escaping () -> Void
    ) -> DeviceRowView {
        DeviceRowView(
            device: device,
            isConnected: isConnected,
            actions: [.remove(helpText: "Remove from priority list", handler: onRemove)],
            style: .plain(verticalPadding: 2)
        )
    }
    
    /// Available device row with add action
    static func availableRow(
        device: AudioDevice,
        isConnected: Bool,
        onAdd: @escaping () -> Void
    ) -> DeviceRowView {
        DeviceRowView(
            device: device,
            isConnected: isConnected,
            actions: [.add(helpText: "Add to priority list", handler: onAdd)],
            style: .plain(verticalPadding: 4)
        )
    }
    
    /// Historical device row with trash and add actions
    static func historicalRow(
        device: AudioDevice,
        isConnected: Bool,
        onTrash: @escaping () -> Void,
        onAdd: @escaping () -> Void
    ) -> DeviceRowView {
        DeviceRowView(
            device: device,
            isConnected: isConnected,
            actions: [
                .trash(helpText: "Remove from device history", handler: onTrash),
                .add(helpText: "Add to priority list", handler: onAdd)
            ],
            style: .plain(verticalPadding: 4)
        )
    }
    
    /// Selection section row with configurable actions
    static func selectionRow(
        device: AudioDevice,
        isConnected: Bool,
        isSelectedSection: Bool,
        showRemoveButtons: Bool = false,
        onToggle: @escaping () -> Void,
        onTrash: (() -> Void)? = nil
    ) -> DeviceRowView {
        var actions: [DeviceRowAction] = []
        
        if isSelectedSection && showRemoveButtons {
            // Selected section: show remove button
            actions.append(.remove(helpText: "Remove from selection", handler: onToggle))
        } else if !isSelectedSection {
            // Available section: show trash button if needed, then add button
            if showRemoveButtons && !isConnected, let trashHandler = onTrash {
                actions.append(.trash(helpText: "Remove from device history", handler: trashHandler))
            }
            actions.append(.add(helpText: "Add to selection", handler: onToggle))
        }
        
        return DeviceRowView(
            device: device,
            isConnected: isConnected,
            actions: actions,
            style: .styled()
        )
    }
} 