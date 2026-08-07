#!/usr/bin/env swift

import Foundation

struct EndpointState: Equatable {
    var volume: Float?
    var muted: Bool?
}

struct RoutingSimulator {
    var hardware: EndpointState
    var virtual: EndpointState = .init(volume: 1, muted: false)
    var unrelated: EndpointState
    var isRunning = false

    mutating func start() {
        virtual = .init(
            volume: hardware.volume ?? 1,
            muted: hardware.muted ?? false
        )
        hardware = .init(
            volume: hardware.volume == nil ? nil : 1,
            muted: hardware.muted == nil ? nil : false
        )
        isRunning = true
    }

    mutating func selectOutput(isRepresentedHardware: Bool) {
        restoreRepresentedHardware()
        isRunning = false
        // An unrelated endpoint is deliberately never assigned here.
        _ = isRepresentedHardware
    }

    mutating func stop(defaultSwitchSucceeds: Bool) {
        restoreRepresentedHardware()
        if defaultSwitchSucceeds {
            isRunning = false
        } else {
            hardware = .init(
                volume: hardware.volume == nil ? nil : 1,
                muted: hardware.muted == nil ? nil : false
            )
        }
    }

    private mutating func restoreRepresentedHardware() {
        if hardware.volume != nil { hardware.volume = virtual.volume }
        if hardware.muted != nil { hardware.muted = virtual.muted }
    }
}

var passed = 0
var failed = 0

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        passed += 1
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name)")
    }
}

do {
    var route = RoutingSimulator(
        hardware: .init(volume: 0.5, muted: false),
        unrelated: .init(volume: 0.22, muted: true)
    )
    route.start()
    check(route.virtual == .init(volume: 0.5, muted: false), "start transfers hardware volume and mute to virtual")
    check(route.hardware == .init(volume: 1, muted: false), "start leaves hardware at full gain and unmuted")
}

do {
    var route = RoutingSimulator(
        hardware: .init(volume: 0.4, muted: true),
        unrelated: .init(volume: 0.8, muted: false)
    )
    route.start()
    check(route.virtual.muted == true, "muted hardware remains muted through virtual route")
    check(route.hardware.muted == false, "hardware behind virtual route is explicitly unmuted")
}

do {
    var route = RoutingSimulator(
        hardware: .init(volume: 0.5, muted: false),
        unrelated: .init(volume: 0.7, muted: false)
    )
    route.start()
    route.virtual = .init(volume: 0.31, muted: true)
    route.selectOutput(isRepresentedHardware: true)
    check(route.hardware == .init(volume: 0.31, muted: true), "manual selection of represented hardware transfers current virtual state")
    check(!route.isRunning, "manual selection tears down virtual route")
}

do {
    let otherState = EndpointState(volume: 0.23, muted: true)
    var route = RoutingSimulator(
        hardware: .init(volume: 0.5, muted: false),
        unrelated: otherState
    )
    route.start()
    route.virtual = .init(volume: 0.63, muted: false)
    route.selectOutput(isRepresentedHardware: false)
    check(route.hardware == .init(volume: 0.63, muted: false), "unrelated manual selection restores only the represented hardware")
    check(route.unrelated == otherState, "unrelated manual selection never receives virtual volume or mute")
}

do {
    var route = RoutingSimulator(
        hardware: .init(volume: 0.5, muted: false),
        unrelated: .init(volume: 0.2, muted: false)
    )
    route.start()
    route.virtual = .init(volume: 0.35, muted: true)
    route.stop(defaultSwitchSucceeds: false)
    check(route.isRunning, "failed default-output switch keeps virtual route running")
    check(route.hardware == .init(volume: 1, muted: false), "failed default-output switch rolls routed hardware back to full/unmuted")
}

do {
    var route = RoutingSimulator(
        hardware: .init(volume: nil, muted: nil),
        unrelated: .init(volume: 0.2, muted: false)
    )
    route.start()
    check(route.virtual == .init(volume: 1, muted: false), "fixed-volume hardware maps to full/unmuted virtual defaults")
    route.virtual = .init(volume: 0.2, muted: true)
    route.stop(defaultSwitchSucceeds: true)
    check(route.hardware == .init(volume: nil, muted: nil), "unsupported hardware controls are not treated as write failures")
}

print("\nAudio state handoff: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
