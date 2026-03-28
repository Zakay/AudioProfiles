import SwiftUI

// Legacy dialog — auto-switching is now a simple on/off toggle.
// This file is kept to avoid breaking WindowManager references.
// It can be deleted in a future cleanup.

struct AutoSwitchingDialogView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        Text("Auto-switching is now controlled via the Profiles toggle.")
            .padding(24)
            .frame(width: 300)
    }
}
