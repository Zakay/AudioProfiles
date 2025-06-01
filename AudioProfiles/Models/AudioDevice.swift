import Foundation

struct AudioDevice: Identifiable, Codable {
    let id: String
    let name: String
    let transportType: String
    let isInput: Bool
    let isOutput: Bool
}
