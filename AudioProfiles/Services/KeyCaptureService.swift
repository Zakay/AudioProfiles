import Foundation
import SwiftUI
import Carbon
import AppKit

/// Handles key capture business logic with direct binding updates
class KeyCaptureService: ObservableObject {
    
    // MARK: - Published State
    @Published var isCapturing = false
    @Published var capturedKeys: Set<UInt32> = []
    @Published var capturedModifiers: UInt32 = 0
    
    // MARK: - Private State
    private var keyMonitor: Any?
    
    // MARK: - Direct Binding Reference (Simple Approach)
    private var hotkeyBinding: Binding<Hotkey?>?
    
    // MARK: - Public Interface
    
    /// Start capturing key combinations with direct binding update
    /// - Parameter hotkeyBinding: Direct binding to update when hotkey is captured
    func startCapturing(hotkeyBinding: Binding<Hotkey?>) {
        self.hotkeyBinding = hotkeyBinding
        isCapturing = true
        capturedKeys.removeAll()
        capturedModifiers = 0
        setupKeyCapture()
    }
    
    /// Reset capture state and stop monitoring
    func resetCapture() {
        isCapturing = false
        capturedKeys.removeAll()
        capturedModifiers = 0
        hotkeyBinding = nil
        
        removeKeyMonitor()
    }
    
    /// Clean up resources when service is deallocated
    deinit {
        removeKeyMonitor()
    }
    
    // MARK: - Private Implementation
    
    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
    
    private func setupKeyCapture() {
        // Remove any existing monitor first
        removeKeyMonitor()
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self, self.isCapturing else { return event }
            
            switch event.type {
            case .flagsChanged:
                self.capturedModifiers = self.carbonModifiersFromNSEvent(event)
                return nil // Consume the event
                
            case .keyDown:
                let keyCode = UInt32(event.keyCode)
                self.capturedKeys.insert(keyCode)
                
                // Create hotkey and finish capture
                if !self.capturedKeys.isEmpty {
                    // Use the first key for now (could be enhanced to support key combinations)
                    if let mainKey = self.capturedKeys.first {
                        let newHotkey = Hotkey(keyCode: mainKey, modifiers: self.capturedModifiers)
                        
                        // Validate the hotkey has at least one modifier (good practice for global hotkeys)
                        if self.capturedModifiers != 0 {
                            // DIRECT ASSIGNMENT - like the original working code!
                            self.hotkeyBinding?.wrappedValue = newHotkey
                            self.resetCapture()
                        }
                    }
                }
                return nil // Consume the event
                
            default:
                return event
            }
        }
    }
    
    /// Convert NSEvent modifier flags to Carbon API modifiers
    private func carbonModifiersFromNSEvent(_ event: NSEvent) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        
        if event.modifierFlags.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if event.modifierFlags.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if event.modifierFlags.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if event.modifierFlags.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        
        return carbonModifiers
    }
} 