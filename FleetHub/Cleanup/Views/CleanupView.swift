//
//  CleanupView.swift
//  FleetHub
//
//  Entry point for the Cleanup feature (Jamf stale-device cleanup),
//  hosted in FleetHub's main content area. Owns the CleanupViewModel and
//  provides internal navigation from dashboard cards to filtered lists.
//

import SwiftUI

struct CleanupView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Binding var isInNestedView: Bool
    @State private var model = CleanupViewModel()
    @State private var navigationPath = NavigationPath()

    var body: some View {
        ZStack {
            // Match FleetHub's native content background (animated gradient orbs).
            FleetHubTheme.ground.ignoresSafeArea()

            if isAvailable {
                NavigationStack(path: $navigationPath) {
                    CleanupDashboardView()
                        .navigationDestination(for: ProtectFilter.self) { filter in
                            ProtectDeviceListView(filter: filter)
                        }
                }
                .background(.clear)
            } else {
                notConfigured
            }
        }
        .environment(model)
        // Hide the sidebar while a filtered list is open, like the main app.
        .onChange(of: navigationPath.count) { _, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                isInNestedView = newValue > 0
            }
        }
        .onAppear { isInNestedView = false }
        .onShowTabRoot(.cleanup) {
            if !navigationPath.isEmpty { navigationPath = NavigationPath() }
        }
        // Release Jamf/Protect tokens server-side when leaving cleanup or
        // backgrounding the app (abandoned tokens hold a Jamf DB connection).
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Task { await model.invalidateSessions() }
            }
        }
        .onDisappear {
            Task { await model.invalidateSessions() }
        }
    }

    /// Cleanup needs a Jamf Pro server; the DEBUG demo stands in
    /// sample data instead.
    private var isAvailable: Bool {
        #if DEBUG
        if DemoMode.isEnabled { return true }
        #endif
        return model.settings.isConfigured
    }

    private var notConfigured: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)

            Text("Cleanup")
                .font(.largeTitle.bold())

            Text("Find devices that have gone quiet in Jamf Pro — then unmanage, regroup, re-site, or delete them in bulk.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Text("Cleanup needs a Jamf Pro server. Ask your administrator to deliver it in the \(Branding.title) configuration profile.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .glassCard()
        .padding(40)
    }
}
