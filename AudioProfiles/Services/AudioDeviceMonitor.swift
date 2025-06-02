import Foundation
import CoreAudio
import Combine

/// Service responsible for monitoring Core Audio device changes
/// Follows single responsibility principle - only detects and publishes device changes
class AudioDeviceMonitor: ObservableObject {
    static let shared = AudioDeviceMonitor()
    
    /// Published when device list changes (connect/disconnect events)
    let deviceChangesSubject = PassthroughSubject<[AudioDevice], Never>()
    
    private var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    
    private var lastKnownDeviceIDs: Set<String> = []
    
    private init() {
        setupDeviceMonitoring()
        
        // Initialize with current devices
        let currentDevices = AudioDeviceFactory.getCurrentDevices()
        lastKnownDeviceIDs = Set(currentDevices.map { $0.id })
        
        AppLogger.info("AudioDeviceMonitor initialized with \(currentDevices.count) devices")
    }
    
    private func setupDeviceMonitoring() {
        // Listen for Core Audio device list changes
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.handleDeviceListChange()
        }
    }
    
    private func handleDeviceListChange() {
        let newDevices = AudioDeviceFactory.getCurrentDevices()
        let newDeviceIDs = Set(newDevices.map { $0.id })
        
        // Log device changes for debugging
        let addedDevices = newDeviceIDs.subtracting(lastKnownDeviceIDs)
        let removedDevices = lastKnownDeviceIDs.subtracting(newDeviceIDs)
        
        if !addedDevices.isEmpty {
            let addedNames = addedDevices.compactMap { id in
                newDevices.first { $0.id == id }?.name
            }
            AppLogger.info("Audio devices connected: \(addedNames.joined(separator: ", "))")
        }
        
        if !removedDevices.isEmpty {
            // For removed devices, we need to look them up from history since they're no longer current
            let removedNames = removedDevices.compactMap { id in
                AudioDeviceHistoryService.shared.getDevice(by: id)?.name ?? "Unknown Device"
            }
            AppLogger.info("Audio devices disconnected: \(removedNames.joined(separator: ", "))")
        }
        
        // Update tracking and notify subscribers
        lastKnownDeviceIDs = newDeviceIDs
        deviceChangesSubject.send(newDevices)
    }
    
    deinit {
        // Clean up Core Audio listener
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { _, _ in }
    }
} 