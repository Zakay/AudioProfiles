import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentPage = 0
    @State private var neverShowAgain = false
    
    private let pages = OnboardingPage.allPages
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Skip") {
                    saveCheckboxPreference()
                    dismiss()
                }
                .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Welcome to AudioProfiles")
                    .font(.headline)
                    .fontWeight(.semibold)
                
                Spacer()
                
                // Invisible button for balance
                Button("Skip") {
                    saveCheckboxPreference()
                    dismiss()
                }
                .opacity(0)
                .disabled(true)
            }
            .padding()
            .onAppear {
                // Initialize checkbox state - default to checked if no previous preference exists
                if UserDefaults.standard.object(forKey: "OnboardingCompleted") == nil {
                    // First time - default to checked and save it
                    neverShowAgain = true
                    UserDefaults.standard.set(true, forKey: "OnboardingCompleted")
                } else {
                    // Use existing preference
                    neverShowAgain = UserDefaults.standard.bool(forKey: "OnboardingCompleted")
                }
            }
            
            // Page indicators
            HStack(spacing: 12) {
                ForEach(0..<pages.count, id: \.self) { index in
                    HStack(spacing: 6) {
                        // Step number
                        Text("\(index + 1)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundColor(index == currentPage ? .white : .secondary)
                            .frame(width: 16, height: 16)
                            .background(
                                Circle()
                                    .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                            )
                        
                        // Step name (only for current page)
                        if index == currentPage {
                            Text(pages[index].title)
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: currentPage)
                }
            }
            .padding(.bottom, 20)
            
            // Content
            TabView(selection: $currentPage) {
                ForEach(0..<pages.count, id: \.self) { index in
                    OnboardingPageView(page: pages[index])
                        .tag(index)
                        .id(index) // Force view recreation when page changes
                }
            }
            .animation(.easeInOut, value: currentPage)
            .onChange(of: currentPage) {
                // Small delay to ensure smooth transitions
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // This will trigger onAppear for the new page
                }
            }
            
            // Bottom controls
            VStack(spacing: 16) {
                if currentPage == pages.count - 1 {
                    // Last page - show "never show again" option
                    HStack {
                        Spacer()
                        Button(action: {
                            neverShowAgain.toggle()
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: neverShowAgain ? "checkmark.square.fill" : "square")
                                    .foregroundColor(neverShowAgain ? .accentColor : .secondary)
                                Text("Don't show this again at startup")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                
                HStack {
                    if currentPage > 0 {
                        Button("Previous") {
                            withAnimation {
                                currentPage = max(0, currentPage - 1)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Spacer()
                    
                    Button(currentPage < pages.count - 1 ? "Next" : "Get Started") {
                        if currentPage < pages.count - 1 {
                            withAnimation {
                                currentPage = min(pages.count - 1, currentPage + 1)
                            }
                        } else {
                            completeOnboarding()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 700, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func completeOnboarding() {
        saveCheckboxPreference()
        dismiss()
        
        // Open configuration window after dismissing onboarding
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            WindowManager.shared.openConfigurationWindow()
        }
    }
    
    private func saveCheckboxPreference() {
        UserDefaults.standard.set(neverShowAgain, forKey: "OnboardingCompleted")
    }
}

// MARK: - Onboarding Page View

struct OnboardingPageView: View {
    let page: OnboardingPage
    
    var body: some View {
        VStack(spacing: 30) {
            // Icon or visual demo
            Group {
                switch page.type {
                case .welcome:
                    WelcomeVisual()
                case .profiles:
                    ProfilesVisual()
                case .smartSwitching:
                    SmartSwitchingVisual()
                case .gettingStarted:
                    GettingStartedVisual()
                }
            }
            .frame(maxHeight: 300)
            
            // Content
            VStack(spacing: 16) {
                Text(page.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(page.description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .padding()
    }
}

// MARK: - Visual Components

struct WelcomeVisual: View {
    @State private var animationTrigger = false
    @State private var viewDidAppear = false
    
    var body: some View {
        VStack(spacing: 20) {
            // App icon representation
            Group {
                if let appIcon = NSApp.applicationIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 30))
                } else {
                    // Fallback if app icon not available
                    RoundedRectangle(cornerRadius: 30)
                        .fill(LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 180, height: 180)
                        .overlay {
                            Image(systemName: "speaker.wave.3")
                                .font(.system(size: 75))
                                .foregroundColor(.white)
                        }
                }
            }
            .shadow(radius: 10)
            .scaleEffect(viewDidAppear ? 1.0 : 0.8)
            .opacity(viewDidAppear ? 1.0 : 0.5)
            .animation(.easeOut(duration: 0.6), value: viewDidAppear)
            
            // Animated audio waves
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    let baseHeight: CGFloat = [25, 45, 60, 35, 30][index]
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor.opacity(0.7))
                        .frame(width: 4, height: animationTrigger ? baseHeight : 10)
                        .animation(
                            .easeInOut(duration: 1.2)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                            value: animationTrigger
                        )
                }
            }
            .opacity(viewDidAppear ? 1.0 : 0.0)
            .animation(.easeIn(duration: 0.4).delay(0.3), value: viewDidAppear)
        }
        .onAppear {
            // Ensure animations start after a proper delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                viewDidAppear = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                animationTrigger = true
            }
        }
        .onDisappear {
            // Reset animation state when view disappears
            viewDidAppear = false
            animationTrigger = false
        }
    }
}

struct ProfilesVisual: View {
    var body: some View {
        VStack(spacing: 16) {
            // Mock profile menu
            VStack(alignment: .leading, spacing: 8) {
                // Header
                HStack {
                    Image(systemName: "house.fill")
                        .foregroundColor(.blue)
                        .frame(width: 20, height: 20)
                    
                    Text("Home Office")
                        .font(.headline)
                    
                    Spacer()
                    
                    // Mode toggle
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2")
                            .font(.caption)
                        Text("Public")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
                }
                
                Divider()
                
                // Profile list
                VStack(spacing: 4) {
                    MockProfileRow(icon: "house.fill", name: "Home Office", isActive: true)
                    MockProfileRow(icon: "building.2.fill", name: "Work Meeting", isActive: false)
                    MockProfileRow(icon: "headphones", name: "Focus Time", isActive: false)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
            .frame(width: 250)
        }
    }
}

struct MockProfileRow: View {
    let icon: String
    let name: String
    let isActive: Bool
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 16, height: 16)
                .frame(width: 24)
            
            Text(name)
            
            Spacer()
            
            if isActive {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
    }
}

struct SmartSwitchingVisual: View {
    @State private var isConnected = false
    @State private var viewDidAppear = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Device connection animation
            HStack(spacing: 40) {
                // Laptop
                VStack {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("MacBook")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Connection line
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: 80, height: 4)
                    
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green)
                        .frame(width: isConnected ? 80 : 0, height: 4)
                        .animation(.easeInOut(duration: 1.5), value: isConnected)
                }
                
                // External device
                VStack {
                    Image(systemName: "headphones")
                        .font(.system(size: 40))
                        .foregroundColor(isConnected ? .green : .secondary)
                        .animation(.easeInOut, value: isConnected)
                    Text("AirPods Max")
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .secondary)
                        .animation(.easeInOut, value: isConnected)
                }
            }
            .opacity(viewDidAppear ? 1.0 : 0.0)
            .animation(.easeIn(duration: 0.5), value: viewDidAppear)
            
            // Arrow down
            Image(systemName: "arrow.down")
                .font(.title2)
                .foregroundColor(.accentColor)
                .opacity(isConnected ? 1 : 0.3)
                .animation(.easeInOut, value: isConnected)
            
            // Profile activation
            VStack {
                Text(isConnected ? "Focus Time Profile" : "Waiting for trigger...")
                    .font(.headline)
                    .foregroundColor(isConnected ? .primary : .secondary)
                    .animation(.easeInOut, value: isConnected)
                
                if isConnected {
                    Text("✓ Switched automatically")
                        .font(.caption)
                        .foregroundColor(.green)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut.delay(0.5), value: isConnected)
        }
        .onAppear {
            // Start animation after a delay when view appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                viewDidAppear = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                isConnected = true
            }
        }
        .onDisappear {
            // Reset animation state when view disappears
            viewDidAppear = false
            isConnected = false
        }
    }
}

struct GettingStartedVisual: View {
    var body: some View {
        VStack(spacing: 20) {
            // Steps illustration
            VStack(spacing: 16) {
                StepView(number: 1, text: "Create your first profile", icon: "plus.circle.fill")
                StepView(number: 2, text: "Set device priorities", icon: "list.bullet")
                StepView(number: 3, text: "Configure triggers", icon: "bolt.fill")
                StepView(number: 4, text: "Enjoy automatic switching!", icon: "checkmark.circle.fill")
            }
        }
    }
}

struct StepView: View {
    let number: Int
    let text: String
    let icon: String
    
    var body: some View {
        HStack {
            // Step number
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())
            
            // Step text
            Text(text)
                .font(.body)
            
            Spacer()
            
            // Step icon
            Image(systemName: icon)
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal)
    }
}

// MARK: - Data Models

struct OnboardingPage {
    let type: PageType
    let title: String
    let description: String
    
    enum PageType {
        case welcome, profiles, smartSwitching, gettingStarted
    }
    
    static let allPages = [
        OnboardingPage(
            type: .welcome,
            title: "Welcome to AudioProfiles",
            description: "Automatically switch your audio settings based on connected devices. Never manually change your sound setup again."
        ),
        OnboardingPage(
            type: .profiles,
            title: "Create Audio Profiles",
            description: "Set up different audio configurations for different scenarios. Choose your preferred input/output devices and switch between public and private modes."
        ),
        OnboardingPage(
            type: .smartSwitching,
            title: "Smart Device Switching",
            description: "When you connect headphones, dock your laptop, or plug in external speakers, AudioProfiles automatically activates the right profile for that setup."
        ),
        OnboardingPage(
            type: .gettingStarted,
            title: "Ready to Get Started?",
            description: "Click 'Get Started' to begin creating your first audio profile. The app will guide you through the setup process."
        )
    ]
}

#Preview {
    OnboardingView()
} 