//
//  InventoryLoadingView.swift
//  FleetHub
//
//  Modern loading view displayed while inventory data loads after login
//

import SwiftUI
import Combine

struct InventoryLoadingView: View {
    /// When non-nil the progress section is replaced by an error block with
    /// Retry / Continue Anyway.
    var errorMessage: String? = nil
    var onRetry: (() -> Void)? = nil
    var onContinue: (() -> Void)? = nil

    @State private var isAnimating = false
    @State private var progressValue: Double = 0
    @State private var currentStatusIndex = 0
    @State private var showStatusText = false

    let statusMessages = [
        "Connecting to Jamf Pro…",
        "Authenticating…",
        "Fetching computer inventory…",
        "Fetching mobile devices…",
        "Processing device data…",
        "Almost ready…"
    ]

    var body: some View {
        // The same two-panel card as sign-in, so the hand-off from signing in
        // to loading does not change the frame around the content.
        SignInPanel {
            Spacer(minLength: 0)

            if let errorMessage {
                errorSection(message: errorMessage)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Loading Your Fleet")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Text("Fetching inventory from Jamf Pro. This takes a moment the first time.")
                        .font(.system(size: 14))
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    // Progress bar
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(FleetHubTheme.trough)
                            Capsule()
                                .fill(FleetHubTheme.accentFill)
                                .frame(width: max(8, geometry.size.width * progressValue))
                        }
                    }
                    .frame(height: 8)
                    .accessibilityElement()
                    .accessibilityLabel("Loading progress")
                    .accessibilityValue("\(Int(progressValue * 100)) percent")

                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusMessages[currentStatusIndex])
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FleetHubTheme.muted)
                            .opacity(showStatusText ? 1 : 0)
                            .animation(.easeInOut(duration: 0.3), value: showStatusText)
                    }
                }
                .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.3), value: errorMessage == nil)
        .onAppear {
            startAnimations()
        }
    }

    // MARK: - Error State

    /// Shown when either inventory service reported an error: first launch
    /// offline, a rejected API client, a truncated sweep. Without this the
    /// console completed the load with "0 devices" and no explanation.
    @ViewBuilder
    private func errorSection(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Inventory Could Not Be Loaded")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can try again, or continue with whatever loaded.")
                .font(.system(size: 14))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }

        ScrollView {
            SignInNotice(text: message)
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)

        VStack(spacing: 8) {
            SSOButton(icon: "arrow.clockwise", title: "Retry") {
                onRetry?()
            }
            .keyboardShortcut(.defaultAction)

            SSOButton(title: "Continue Anyway", kind: .secondary) {
                onContinue?()
            }
        }
    }

    private func startAnimations() {
        isAnimating = true

        // Show status text
        withAnimation(.easeIn(duration: 0.5)) {
            showStatusText = true
        }

        // Progress animation
        animateProgress()

        // Cycle through status messages
        cycleStatusMessages()
    }

    private func animateProgress() {
        // Animate progress in stages
        let stages: [(Double, Double)] = [
            (0.15, 0.3),  // Quick start
            (0.35, 0.8),  // Slower middle
            (0.55, 1.2),
            (0.75, 0.6),
            (0.90, 1.0),
            (0.98, 0.5)   // Almost done, slow down
        ]
        
        var totalDelay: Double = 0
        
        for (progress, duration) in stages {
            totalDelay += duration
            DispatchQueue.main.asyncAfter(deadline: .now() + totalDelay) {
                withAnimation(.easeOut(duration: duration)) {
                    progressValue = progress
                }
            }
        }
    }
    
    private func cycleStatusMessages() {
        // Cycle through messages with animation
        let messageInterval: Double = 1.0
        
        for (index, _) in statusMessages.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * messageInterval) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showStatusText = false
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    currentStatusIndex = index
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showStatusText = true
                    }
                }
            }
        }
    }
}

// MARK: - Inventory Loading Manager

@MainActor
class InventoryLoadingManager: ObservableObject {
    /// Non-nil when either inventory fetch failed. The view shows it with
    /// Retry / Continue anyway instead of completing the load with zeros.
    @Published private(set) var loadError: String?
    
    private var computerInventoryService: ComputerInventoryService?
    private var mobileDeviceService: MobileDeviceInventoryService?
    private var hasStartedLoading = false
    private var isLoading = false
    
    weak var launchState: AppLaunchStateManager?
    
    func startLoadingIfNeeded() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        
        // Create services
        computerInventoryService = ComputerInventoryService()
        mobileDeviceService = MobileDeviceInventoryService()
        
        Task { @MainActor in
            await loadAllInventory()
        }
    }
    
    /// Re-run the fetches. A service whose previous sweep succeeded serves
    /// from its cache, so only the failed side actually hits Jamf again.
    func retry() {
        guard !isLoading else { return }
        loadError = nil
        Task { @MainActor in
            await loadAllInventory()
        }
    }
    
    /// Proceed to the dashboard with whatever loaded (possibly nothing).
    /// The operator has seen the error, so this is an informed choice rather
    /// than the silent "0 devices" the old path produced.
    func continueAnyway() {
        loadError = nil
        launchState?.completeInventoryLoad(counts: currentCounts())
    }
    
    private func currentCounts() -> DeviceCounts {
        let computerCache = ComputerInventoryCache.shared
        let mobileCache = MobileDeviceInventoryCache.shared
        return DeviceCounts(
            macOS: computerCache.totalCount,
            iOS: mobileCache.iOSCount,
            iPadOS: mobileCache.iPadOSCount,
            visionOS: mobileCache.visionOSCount
        )
    }
    
    private func loadAllInventory() async {
        isLoading = true
        defer { isLoading = false }
        
        // Small initial delay for UI animation
        try? await Task.sleep(nanoseconds: 800_000_000)
        
        let computerCache = ComputerInventoryCache.shared
        let mobileCache = MobileDeviceInventoryCache.shared
        
        // Check if we already have cached data
        if computerCache.hasCachedData && mobileCache.hasCachedData {
            let counts = DeviceCounts(
                macOS: computerCache.totalCount,
                iOS: mobileCache.iOSCount,
                iPadOS: mobileCache.iPadOSCount,
                visionOS: mobileCache.visionOSCount
            )
            try? await Task.sleep(nanoseconds: 500_000_000)
            launchState?.completeInventoryLoad(counts: counts)
            return
        }
        
        // Fetch computers using master API
        if let computerService = computerInventoryService {
            await computerService.fetchAllComputers()
        }
        
        // Small delay between calls
        try? await Task.sleep(nanoseconds: 300_000_000)
        
        // Fetch mobile devices using master API
        if let mobileService = mobileDeviceService {
            await mobileService.fetchAllDevices()
        }
        
        // Surface failures instead of completing with zeros. Both messages
        // are shown when both sides failed (typically the same root cause:
        // offline, bad URL, rejected API client).
        var problems: [String] = []
        if let message = computerInventoryService?.errorMessage {
            problems.append("Computers: \(message)")
        }
        if let message = mobileDeviceService?.errorMessage {
            problems.append("Mobile devices: \(message)")
        }
        if !problems.isEmpty {
            loadError = problems.joined(separator: "\n\n")
            AppLog.error("❌ InventoryLoadingManager: Inventory load failed — \(loadError ?? "")")
            return
        }
        
        // Get counts from cache (services populate the cache)
        let counts = currentCounts()
        
        // Small delay for smooth transition
        try? await Task.sleep(nanoseconds: 500_000_000)
        
        // Signal completion via the launch state manager
        launchState?.completeInventoryLoad(counts: counts)
    }
}

// MARK: - Loading View Container

struct InventoryLoadingContainer: View {
    @ObservedObject var launchState: AppLaunchStateManager
    @StateObject private var loadingManager = InventoryLoadingManager()
    
    var body: some View {
        InventoryLoadingView(
            errorMessage: loadingManager.loadError,
            onRetry: { loadingManager.retry() },
            onContinue: { loadingManager.continueAnyway() }
        )
        .onAppear {
            loadingManager.launchState = launchState
            loadingManager.startLoadingIfNeeded()
        }
    }
}

// MARK: - Device Counts

struct DeviceCounts {
    var macOS: Int = 0
    var iOS: Int = 0
    var iPadOS: Int = 0
    var visionOS: Int = 0
    
    var total: Int {
        macOS + iOS + iPadOS + visionOS
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Inventory Loading View") {
    InventoryLoadingView()
        .frame(width: 800, height: 600)
}

#Preview("Inventory Loading View — Error") {
    InventoryLoadingView(
        errorMessage: "Computers: Jamf Pro rejected the master API client (401): Unauthorized",
        onRetry: {},
        onContinue: {}
    )
    .frame(width: 800, height: 600)
}
#endif
