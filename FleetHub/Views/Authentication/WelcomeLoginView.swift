//
//  WelcomeLoginView.swift
//  FleetHub
//


import SwiftUI
import Combine

// MARK: - App Launch State Manager
class AppLaunchStateManager: ObservableObject {
    @Published var inventoryLoadComplete = false
    @Published var deviceCounts = DeviceCounts()
    
    @MainActor
    func completeInventoryLoad(counts: DeviceCounts) {
        self.deviceCounts = counts
        self.inventoryLoadComplete = true
    }
    
    @MainActor
    func resetForNewLogin() {
        inventoryLoadComplete = false
        deviceCounts = DeviceCounts()
    }
}

struct WelcomeLoginView: View {
    @StateObject private var viewModel = AuthViewModel()
    @StateObject private var launchState = AppLaunchStateManager()
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @State private var showBiometricSetup = false
    /// Non-nil only in a DEBUG build launched with -FleetHubDemo; the app
    /// then opens straight on the dashboard with generated sample data.
    @State private var demoCounts: DeviceCounts? = WelcomeLoginView.activateDemoIfRequested()

    @MainActor
    private static func activateDemoIfRequested() -> DeviceCounts? {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.activate() }
        #endif
        return nil
    }

    /// DEBUG-only: `-FleetHubPreview signin|unlock|setup` opens one
    /// pre-dashboard screen directly so its layout can be looked at without
    /// signing in or changing this Mac's configuration.
    private var debugPreview: AnyView? {
        #if DEBUG
        switch DemoMode.previewScreen {
        case "signin": return AnyView(LoginView(viewModel: viewModel, showLogin: .constant(true)))
        case "unlock": return AnyView(BiometricPromptPreview(viewModel: viewModel))
        case "setup": return AnyView(CredentialsOnboardingView())
        default: return nil
        }
        #else
        return nil
        #endif
    }

    var body: some View {
        if let debugPreview {
            debugPreview
        } else {
            launchContent
        }
    }

    private var launchContent: some View {
        ZStack {
            // First-run onboarding: the profile names a Jamf Pro server and
            // client but no master client secret is in the Keychain yet.
            // Takes priority over every other state — nothing works without it.
            if demoCounts != nil {
                // DEBUG-only demo mode (-FleetHubDemo): sample data, no sign-in.
                DashboardView(initialDeviceCounts: demoCounts ?? DeviceCounts())
                    .environmentObject(viewModel)
            } else if configManager.needsCredentialOnboarding {
                CredentialsOnboardingView()
                    .transition(.opacity)
            } else if viewModel.isLoggedIn {
                if !launchState.inventoryLoadComplete {
                    // Show loading view while inventory loads
                    InventoryLoadingContainer(launchState: launchState)
                        .transition(.opacity)
                } else {
                    DashboardView(initialDeviceCounts: launchState.deviceCounts)
                        .environmentObject(viewModel)
                        .transition(.opacity)
                        .onAppear {
                            checkBiometricSetup()
                        }
                }
            } else if viewModel.isRestoringEntraSession {
                // Redeeming the persisted Entra refresh token — avoid a
                // login-form flash while the outcome is unknown.
                entraRestoreProgressView
            } else if viewModel.showBiometricPrompt {
                BiometricPromptView(viewModel: viewModel)
            } else {
                if viewModel.hasSeenWelcome {
                    LoginView(viewModel: viewModel, showLogin: .constant(true))
                } else {
                    WelcomeView(viewModel: viewModel)
                }
            }
            
            // Biometric setup overlay
            if showBiometricSetup {
                BiometricSetupPromptView(viewModel: viewModel, isPresented: $showBiometricSetup)
                    .zIndex(999)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: launchState.inventoryLoadComplete)
        .onChange(of: viewModel.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn {
                // Reset loading state when user logs in
                launchState.resetForNewLogin()
            }
        }
        // Warm the ABM inventory as early as the login screen — ABM auth is
        // app-level (ES256 client-credentials from the config profile), not
        // tied to the user's sign-in, so the 26k-device sweep can run while
        // the user is authenticating instead of starting cold at the tab.
        // No-op when ABM isn't configured or the cache is already valid; the
        // DashboardView .task remains as a post-login fallback (idempotent).
        .task {
            await ABMDeviceCache.shared.preloadIfNeeded()
        }
    }
    
    private var entraRestoreProgressView: some View {
        ZStack {
            FleetHubTheme.ground.ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: FleetHubTheme.accent))
                    .scaleEffect(1.2)

                Text("Signing you in…")
                    .font(.system(size: 16))
                    .foregroundColor(FleetHubTheme.muted)
            }
        }
        .transition(.opacity)
    }

    private func checkBiometricSetup() {
        // Only show if setup is allowed by managed policy
        // (ui.authentication allowBiometricSetup) and biometric hardware
        // is available but not enabled
        guard viewModel.isBiometricSetupAllowed,
              viewModel.biometricManager.biometricType != .none,
              !viewModel.biometricManager.isBiometricEnabled,
              !showBiometricSetup else {
            return
        }
        
        // Delay showing the prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak viewModel] in
            guard viewModel != nil else { return }
            showBiometricSetup = true
        }
    }
}

#if DEBUG
/// The unlock screen without its automatic Touch ID prompt.
private struct BiometricPromptPreview: View {
    @ObservedObject var viewModel: AuthViewModel

    var body: some View {
        BiometricPromptView(viewModel: viewModel, autoPrompt: false)
    }
}
#endif
