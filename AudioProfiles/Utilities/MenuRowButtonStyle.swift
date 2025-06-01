import SwiftUI

struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: Configuration
        @State private var hover = false

        // Apple's pop-over hover colour is selectedContentBackground at ~0.6 α
        private var bg: Color {
            Color(nsColor: .selectedContentBackgroundColor)
                .opacity(hover || configuration.isPressed ? 1 : 0)   // dim grey
        }
        
        // Text color should be light when hovering/pressed, normal otherwise
        private var textColor: Color {
            if hover || configuration.isPressed {
                return Color(nsColor: .selectedMenuItemTextColor)
            } else {
                return Color.primary
            }
        }

        var body: some View {
            HStack(spacing: 8) {
                configuration.label
                Spacer(minLength: 0)
            }
            .foregroundColor(textColor)  // Apply dynamic text color
            .padding(.horizontal, 12)       // ← Apple's horizontal inset
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(bg)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hover = $0 }
            .animation(.easeInOut(duration: 0.12), value: hover)
            .animation(.easeInOut(duration: 0.12), value: textColor)  // Animate text color changes too
        }
    }
} 