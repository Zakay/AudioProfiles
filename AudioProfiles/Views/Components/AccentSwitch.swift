import SwiftUI

/// A switch drawn from shapes rather than a system `Toggle(.switch)`.
///
/// System switches render in the inactive (grey) appearance while their window isn't key —
/// which happens in the menu-bar popover and, intermittently, in non-focused windows — so an
/// "on" switch can look grey until interacted with. Shape fills aren't subject to that control
/// dimming, so this stays accent-colored regardless of window-key state.
struct AccentSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 32, height: 18)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: isOn ? 7 : -7)
            )
    }
}
