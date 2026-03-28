import SwiftUI

/// Palette for coloring EQ bands consistently across the graph and parameter panel.
enum EQColors {
    static let palette: [Color] = [
        Color(hue: 0.52, saturation: 0.75, brightness: 0.9),  // cyan
        Color(hue: 0.60, saturation: 0.65, brightness: 0.95), // blue
        Color(hue: 0.72, saturation: 0.55, brightness: 0.85), // indigo
        Color(hue: 0.80, saturation: 0.55, brightness: 0.85), // purple
        Color(hue: 0.92, saturation: 0.55, brightness: 0.95), // pink
        Color(hue: 0.00, saturation: 0.65, brightness: 0.95), // red
        Color(hue: 0.08, saturation: 0.75, brightness: 0.95), // orange
        Color(hue: 0.15, saturation: 0.75, brightness: 0.95), // yellow
        Color(hue: 0.35, saturation: 0.60, brightness: 0.85), // green
        Color(hue: 0.45, saturation: 0.55, brightness: 0.85), // mint
    ]

    static func color(for index: Int) -> Color {
        palette[index % palette.count]
    }
}
