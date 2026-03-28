import Foundation

/// ViewModel for EQEditorView.
///
/// Owns all business logic for applying EQ settings — extracted from the view so
/// the view layer only handles layout and user interaction, not pipeline decisions.
///
/// Key design: when settings change, the ViewModel decides whether to hot-update
/// the running EQ engine (same device, non-flat) or route through `evaluateAndApply()`
/// (flat → stop pipeline, different device → handled by pipeline service).
@MainActor
final class EQEditorViewModel: ObservableObject {

    private let eqStore: EQStore
    private let eqEngine: EQEngineService
    private let installService: EQInstallationService

    init(
        eqStore: EQStore = .shared,
        eqEngine: EQEngineService = .shared,
        installService: EQInstallationService = .shared
    ) {
        self.eqStore = eqStore
        self.eqEngine = eqEngine
        self.installService = installService
    }

    // MARK: - Public Actions

    /// Apply settings and automatically switch to custom mode (user edited manually).
    func applySettingsAsCustom(_ newSettings: EQSettings, deviceUID: String, mode: EQMode) {
        if mode.isPreset {
            eqStore.setMode(.custom, for: deviceUID)
        }
        applySettings(newSettings, deviceUID: deviceUID, deviceName: nil)
    }

    /// Apply a preset: set the mode and EQ settings together.
    func applyPreset(headphoneName: String, target: String, settings: EQSettings, deviceUID: String) {
        eqStore.setMode(.preset(headphoneName: headphoneName, target: target), for: deviceUID)
        applySettings(settings, deviceUID: deviceUID, deviceName: nil)
    }

    /// Switch to custom mode without changing EQ values.
    func switchToCustom(deviceUID: String) {
        eqStore.setMode(.custom, for: deviceUID)
    }

    // MARK: - Core Apply Logic

    /// Applies new EQ settings for the given device.
    ///
    /// Decision tree (mirrors AudioPipelineService.apply() logic):
    /// - Same device + non-flat → hot-update (low latency, no state change)
    /// - Same device + flat     → route through evaluateAndApply (stops pipeline)
    /// - Different device running → pipeline handles via evaluateAndApply
    /// - Not running + non-flat → start pipeline via evaluateAndApply
    func applySettings(_ newSettings: EQSettings, deviceUID: String, deviceName: String?) {
        eqStore.setSettings(newSettings, for: deviceUID)

        guard installService.isInstalled else { return }

        if eqEngine.isRunning, eqEngine.targetDeviceUID == deviceUID {
            let effectiveEQ = eqStore.effectiveSettings(for: deviceUID)
            if effectiveEQ.isFlat {
                // EQ became flat — let the pipeline service tear down the virtual driver
                ProfileManager.shared.pipelineInvalidationSubject.send()
            } else {
                // Hot-update: minimal latency, no device switch
                eqEngine.updateSettings(effectiveEQ)
            }
        } else {
            // For all other cases (different device, not running) — route through
            // the unidirectional pipeline so fingerprint dedup and state machine apply
            ProfileManager.shared.pipelineInvalidationSubject.send()
        }
    }
}
