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
            
            // Page indicators — simple dots
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 20)

            // Content — no TabView to avoid system tab chrome
            OnboardingPageView(page: pages[currentPage])
                .id(currentPage)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: currentPage)
            
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
                case .equalizer:
                    EqualizerVisual()
                case .contentModes:
                    ContentModesVisual()
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

struct EqualizerVisual: View {
    @State private var viewDidAppear = false

    /// Load a real headphone from the preset database for the demo
    private var demoData: (headphone: EQPresetHeadphone, target: String, settings: EQSettings)? {
        let service = EQPresetService.shared
        // Try a well-known headphone
        let candidates = ["Sony WH-1000XM5", "Sony WH-1000XM4", "AirPods Max", "AirPods Pro"]
        for name in candidates {
            if let hp = service.headphone(named: name),
               let target = hp.targets.first,
               let settings = service.toEQSettings(headphone: hp, target: target) {
                return (hp, target, settings)
            }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            if let data = demoData {
                // Real EQ graph using Canvas
                OnboardingEQGraph(
                    settings: data.settings,
                    frequencyResponse: data.headphone.frequencyResponse,
                    animated: viewDidAppear
                )
                .frame(height: 180)
                .frame(maxWidth: 440)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(viewDidAppear ? 1 : 0)
                .animation(.easeIn(duration: 0.5), value: viewDidAppear)

                // Preset pill
                HStack(spacing: 6) {
                    Image(systemName: "headphones")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(data.headphone.name)
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("·")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(data.target)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                .opacity(viewDidAppear ? 1 : 0)
                .animation(.easeIn(duration: 0.5).delay(0.2), value: viewDidAppear)

                // Stats
                HStack(spacing: 16) {
                    Label("4,800+ headphones", systemImage: "headphones")
                    Label("6 target curves", systemImage: "waveform")
                    Label("10-band EQ", systemImage: "slider.horizontal.3")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .opacity(viewDidAppear ? 1 : 0)
                .animation(.easeIn(duration: 0.5).delay(0.4), value: viewDidAppear)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                viewDidAppear = true
            }
        }
        .onDisappear {
            viewDidAppear = false
        }
    }
}

struct ContentModesVisual: View {
    @State private var appeared = false
    private let modes: [ContentModeType] = [.music, .voice, .movie, .gaming]
    private let autoDetected: Set<ContentModeType> = [.music, .voice]

    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                    VStack(spacing: 6) {
                        Image(systemName: mode.iconName)
                            .font(.system(size: 22))
                            .foregroundColor(.green)
                            .frame(width: 48, height: 48)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.12)))
                        Text(mode.displayName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if autoDetected.contains(mode) {
                            Text("Auto")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.green)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                        }
                    }
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeIn(duration: 0.4).delay(Double(index) * 0.1), value: appeared)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.caption)
                    .foregroundColor(.green)
                Text("Voice and music switch automatically. Pick any mode yourself.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .opacity(appeared ? 1 : 0)
            .animation(.easeIn(duration: 0.4).delay(0.4), value: appeared)
        }
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
    }
}

/// Lightweight EQ graph for onboarding — draws EQ curve, band dots, and optional FR overlay
private struct OnboardingEQGraph: View {
    let settings: EQSettings
    let frequencyResponse: [(hz: Float, db: Float)]?
    let animated: Bool

    private let minFreq: Double = 20
    private let maxFreq: Double = 20_000
    private let displayMin: Double = -13
    private let displayMax: Double = 13
    private let sampleCount = 200

    var body: some View {
        Canvas { ctx, size in
            let inset = (left: 30.0, right: 8.0, top: 8.0, bottom: 18.0)
            let area = CGRect(
                x: inset.left, y: inset.top,
                width: size.width - inset.left - inset.right,
                height: size.height - inset.top - inset.bottom
            )
            drawGrid(ctx, area: area)
            drawFreqLabels(ctx, area: area)
            drawDBLabels(ctx, area: area)
            if animated {
                if let fr = frequencyResponse {
                    drawFR(ctx, area: area, response: fr)
                }
                drawCompositeCurve(ctx, area: area)
                drawDots(ctx, area: area)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.1)))
    }

    private func freqToX(_ freq: Double, area: CGRect) -> CGFloat {
        area.minX + CGFloat(log10(freq / minFreq) / log10(maxFreq / minFreq)) * area.width
    }
    private func gainToY(_ gain: Double, area: CGRect) -> CGFloat {
        let n = (gain - displayMin) / (displayMax - displayMin)
        return area.maxY - CGFloat(n) * area.height
    }

    private func drawGrid(_ ctx: GraphicsContext, area: CGRect) {
        let gridColor = Color.white.opacity(0.08)
        let zeroColor = Color.white.opacity(0.2)
        for db in [-12.0, -6, 0, 6, 12] as [Double] {
            let y = gainToY(db, area: area)
            var p = Path(); p.move(to: CGPoint(x: area.minX, y: y)); p.addLine(to: CGPoint(x: area.maxX, y: y))
            ctx.stroke(p, with: .color(db == 0 ? zeroColor : gridColor), lineWidth: 0.5)
        }
        for freq in [32.0, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] {
            let x = freqToX(freq, area: area)
            var p = Path(); p.move(to: CGPoint(x: x, y: area.minY)); p.addLine(to: CGPoint(x: x, y: area.maxY))
            ctx.stroke(p, with: .color(gridColor), lineWidth: 0.5)
        }
    }

    private func drawFreqLabels(_ ctx: GraphicsContext, area: CGRect) {
        for (freq, label) in [(32.0, "32"), (125, "125"), (500, "500"), (2000, "2k"), (8000, "8k")] {
            ctx.draw(
                Text(label).font(.system(size: 7)).foregroundColor(Color.white.opacity(0.3)),
                at: CGPoint(x: freqToX(freq, area: area), y: area.maxY + 10), anchor: .center
            )
        }
    }

    private func drawDBLabels(_ ctx: GraphicsContext, area: CGRect) {
        for (db, label) in [(-12.0, "-12"), (0, "0"), (12, "+12")] as [(Double, String)] {
            ctx.draw(
                Text(label).font(.system(size: 7)).foregroundColor(Color.white.opacity(0.3)),
                at: CGPoint(x: area.minX - 4, y: gainToY(db, area: area)), anchor: .trailing
            )
        }
    }

    private func drawFR(_ ctx: GraphicsContext, area: CGRect, response: [(hz: Float, db: Float)]) {
        let pts: [CGPoint] = response.compactMap { p in
            let f = Double(p.hz)
            guard f >= minFreq && f <= maxFreq else { return nil }
            return CGPoint(x: freqToX(f, area: area),
                           y: gainToY(max(displayMin, min(displayMax, Double(p.db))), area: area))
        }
        guard pts.count >= 2 else { return }
        var path = Path(); path.move(to: pts[0])
        for i in 1..<pts.count { path.addLine(to: pts[i]) }
        let frColor = Color(hue: 0.08, saturation: 0.7, brightness: 0.95)
        ctx.stroke(path, with: .color(frColor.opacity(0.45)),
                   style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
    }

    private func drawCompositeCurve(_ ctx: GraphicsContext, area: CGRect) {
        let zeroY = gainToY(0, area: area)
        let pts: [CGPoint] = (0...sampleCount).map { s in
            let t = Double(s) / Double(sampleCount)
            let freq = minFreq * pow(maxFreq / minFreq, t)
            var gain = Double(settings.preamp)
            for (i, band) in settings.bands.enumerated() {
                gain += bandGain(band: band, bandIndex: i, at: freq)
            }
            gain = max(displayMin, min(displayMax, gain))
            return CGPoint(x: freqToX(freq, area: area), y: gainToY(gain, area: area))
        }
        // Fill
        var fill = Path(); fill.move(to: CGPoint(x: pts[0].x, y: zeroY))
        pts.forEach { fill.addLine(to: $0) }
        fill.addLine(to: CGPoint(x: pts.last!.x, y: zeroY)); fill.closeSubpath()
        ctx.fill(fill, with: .color(Color.white.opacity(0.06)))
        // Stroke
        var stroke = Path(); stroke.move(to: pts[0])
        pts.dropFirst().forEach { stroke.addLine(to: $0) }
        ctx.stroke(stroke, with: .color(Color.white.opacity(0.85)), lineWidth: 1.5)
    }

    private func drawDots(_ ctx: GraphicsContext, area: CGRect) {
        for (i, band) in settings.bands.enumerated() {
            let x = freqToX(Double(band.frequency), area: area)
            let y = gainToY(Double(band.gain), area: area)
            let color = EQColors.color(for: i)
            let dot = Path(ellipseIn: CGRect(x: x - 5, y: y - 5, width: 10, height: 10))
            ctx.fill(dot, with: .color(color.opacity(0.85)))
            ctx.stroke(dot, with: .color(.white.opacity(0.5)), lineWidth: 1)
        }
    }

    private func bandGain(band: EQBand, bandIndex: Int, at freq: Double) -> Double {
        let g = Double(band.gain)
        guard abs(g) >= 0.01 else { return 0 }
        let f0 = Double(band.frequency)
        let bw = max(Double(band.bandwidth), 0.1)
        let logRatio = log2(freq / f0)
        if bandIndex == 0 {
            return g * (1.0 - 1.0 / (1.0 + exp(-logRatio * 2.5 / bw)))
        } else if bandIndex == settings.bands.count - 1 {
            return g / (1.0 + exp(-logRatio * 2.5 / bw))
        } else {
            let sigma = bw / 2.0
            return g * exp(-0.5 * pow(logRatio / sigma, 2))
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
                StepView(number: 4, text: "Set up keyboard shortcuts for instant profile switching", icon: "keyboard.fill")
                StepView(number: 5, text: "Enjoy automatic switching!", icon: "checkmark.circle.fill")
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
        case welcome, profiles, smartSwitching, equalizer, contentModes, gettingStarted
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
            type: .equalizer,
            title: "Per-Device Equalizer",
            description: "Fine-tune your sound with a built-in 10-band EQ. Choose from 4,800+ headphone presets with calibrated target curves, or create your own custom EQ. Settings are saved per device."
        ),
        OnboardingPage(
            type: .contentModes,
            title: "Sound Modes for What You Play",
            description: "Beyond per-device EQ, AudioProfiles adds a matching sound profile: a clearer curve for voice on calls, a fuller curve for music. Voice and music switch automatically; pick Movie, Gaming, or other modes yourself. Night Mode softens the sound for late-night listening."
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