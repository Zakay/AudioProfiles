import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Content
            ScrollView {
                VStack(spacing: 24) {
                    // App Icon and Title
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
                    }
                    .padding(.top, 20)
                    
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
        .frame(width: 400, height: 500)
    }
}

#Preview {
    AboutView()
} 
