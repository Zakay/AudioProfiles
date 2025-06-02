import SwiftUI

struct AboutView: View {
    @State private var tapCount = 0
    @State private var lastTapTime = Date()
    @State private var showSecretHint = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // App Icon and Title (Secret tap area)
                    VStack(spacing: 12) {
                        if let appIcon = NSApp.applicationIconImage {
                            Image(nsImage: appIcon)
                                .resizable()
                                .frame(width: 64, height: 64)
                        } else {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 64))
                                .foregroundColor(.accentColor)
                        }
                        
                        Text("AudioProfiles")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        
                        Text("macOS Audio Profile Manager")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        
                        // Secret hint when getting close
                        if showSecretHint {
                            Text("\(5 - tapCount) more taps...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .opacity(0.6)
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, 20)
                    .contentShape(Rectangle()) // Make entire area tappable
                    .onTapGesture {
                        handleSecretTap()
                    }
                    
                    // Purpose Description
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Purpose")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Text("AudioProfiles automatically switches audio input and output devices based on hardware presence. Create profiles for different scenarios (home, office, studio) with device priorities and trigger conditions. Switch between Public and Private modes, use global hotkeys, and let the app intelligently manage your audio setup.")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                    
                    Divider()
                    
                    // AI Development Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI-Powered Development")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Text("This app was totally vibe coded with AI assistance! From architecture to implementation, the entire development process leveraged AI pair programming. Even the app icon and visual assets were AI-generated, showcasing the power of human-AI collaboration in modern software development.")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                    
                    // Welcome Tutorial Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Getting Started")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Text("New to AudioProfiles? View the welcome tutorial to learn about the app's features and how to get started.")
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Button(action: {
                            WindowManager.shared.openOnboardingWindow()
                        }) {
                            HStack {
                                Image(systemName: "questionmark.circle")
                                Text("Show Welcome Tutorial")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                    
                    Spacer(minLength: 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Secret Demo Easter Egg
    
    private func handleSecretTap() {
        let now = Date()
        
        // Reset counter if last tap was more than 2 seconds ago
        if now.timeIntervalSince(lastTapTime) > 2.0 {
            tapCount = 0
            showSecretHint = false
        }
        
        tapCount += 1
        lastTapTime = now
        
        // Show hint when user reaches 3 taps
        if tapCount >= 3 && tapCount < 5 {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSecretHint = true
            }
        }
        
        // Open demo window on 5th tap
        if tapCount >= 5 {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSecretHint = false
            }
            
            // Small delay for dramatic effect
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                WindowManager.shared.openDemoWindow()
                tapCount = 0 // Reset counter
            }
        }
        
        // Auto-hide hint after 2 seconds if user stops tapping
        if showSecretHint {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                if Date().timeIntervalSince(lastTapTime) >= 1.8 {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showSecretHint = false
                        tapCount = 0
                    }
                }
            }
        }
    }
}

#Preview {
    AboutView()
} 
