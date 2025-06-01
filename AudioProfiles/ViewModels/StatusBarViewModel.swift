import Foundation
import Combine
import SwiftUI

class StatusBarViewModel: ObservableObject {
    @Published var icon: String = "speaker.wave.2.fill"
    @Published var title: String = "AudioProfiles"
    @Published var iconColor: Color = .primary
    @Published var currentMode: ProfileMode = .public

    private let profileManager = ProfileManager.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
        updateDisplay()
    }

    private func setupBindings() {
        // Update display when active profile or mode changes
        profileManager.$activeProfile
            .combineLatest(profileManager.$activeMode, profileManager.$isAutoSwitchingDisabled)
            .sink { [weak self] _, _, _ in
                self?.updateDisplay()
            }
            .store(in: &cancellables)
    }

    private func updateDisplay() {
        guard let activeProfile = profileManager.activeProfile else {
            self.title = "No Profile"
            self.icon = "speaker.wave.2.fill"
            self.iconColor = profileManager.isAutoSwitchingDisabled ? .secondary : .primary
            return
        }
        
        let disabledSuffix = profileManager.isAutoSwitchingDisabled ? " - Auto-switching disabled" : ""
        
        self.title = activeProfile.name + disabledSuffix
        self.icon = "speaker.wave.2.fill"
        
        // Visual indicator for disabled auto-switching
        if profileManager.isAutoSwitchingDisabled {
            self.iconColor = .secondary // Grey when disabled
        } else {
            self.iconColor = .primary // Normal color when enabled
        }
    }
}
