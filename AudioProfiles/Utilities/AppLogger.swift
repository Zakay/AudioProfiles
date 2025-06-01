import Foundation
import os

struct AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "AudioProfiles"
    private static let core = Logger(subsystem: subsystem, category: "General")

    static func debug(_ message: String) {
        core.debug("\(message, privacy: .public)")
    }

    static func info(_ message: String) {
        core.info("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        core.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        core.error("\(message, privacy: .public)")
    }
}
