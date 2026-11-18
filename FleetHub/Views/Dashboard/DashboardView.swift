//
//  DashboardView.swift
//  FleetHub
//
//  Main dashboard container with sidebar navigation and view routing
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var authViewModel: AuthViewModel
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter
    /// Observed so the route gates re-evaluate when capabilities land after
    /// sign-in (matches SidebarView).
    @ObservedObject private var session = UserSession.shared
    /// Observed so the route gates re-evaluate when a profile push changes
    /// the machine layer mid-session (matches DeviceView).
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @State private var viewModel = DashboardViewModel()
    @State private var selectedDestination: NavigationDestination = .dashboard
    /// Whether each tab is showing a pushed screen (a device's page, a
    /// search). One flag per tab, because tabs stay alive in the
    /// background and one tab's pushed screen must not mark another as
    /// nested. These are plain @State values with real `$` bindings on
    /// purpose: a hand-built `Binding(get:set:)` here is a new, unequal
    /// value on every render, which made every tab redraw endlessly.
    @State private var dashboardNested = false
    @State private var devicesNested = false
    @State private var myDevicesNested = false
    @State private var cleanupNested = false
    /// For tabs with no pushed screens; never changes.
    @State private var neverNested = false

    /// Tabs opened so far this session. A tab is built the first time it is
    /// opened and then KEPT ALIVE: switching back shows it instantly, where
    /// rebuilding it used to reload and re-evaluate the whole inventory on
    /// every switch.
    @State private var visited: Set<NavigationDestination> = []

    /// The nested flag of the tab on screen, for the top bar.
    private var selectedNestedBinding: Binding<Bool> {
        switch selectedDestination {
        case .dashboard: $dashboardNested
        case .devices: $devicesNested
        case .myDevices: $myDevicesNested
        case .cleanup: $cleanupNested
        default: $neverNested
        }
    }

    private func clearNested(_ destination: NavigationDestination) {
        switch destination {
        case .dashboard: if dashboardNested { dashboardNested = false }
        case .devices: if devicesNested { devicesNested = false }
        case .myDevices: if myDevicesNested { myDevicesNested = false }
        case .cleanup: if cleanupNested { cleanupNested = false }
        default: break
        }
    }

    // Initial device counts passed from loading screen
    var initialDeviceCounts: DeviceCounts = DeviceCounts()
    
    // Navigation reset triggers - increment to force view reset
    @State private var dashboardResetTrigger: UUID = UUID()
    @State private var devicesResetTrigger: UUID = UUID()
    
    @State private var showLogoutModal = false

    var body: some View {
        VStack(spacing: 0) {
            // Window bar: brand, module pills, account controls
            TopNavigationBar(
                selectedDestination: $selectedDestination,
                isInNestedView: selectedNestedBinding,
                onNavigate: handleNavigation,
                onLogout: { showLogoutModal = true }
            )

            // Main Content
            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(FleetHubTheme.ground)
        // The bar draws under the hidden title bar, beside the traffic lights.
        .ignoresSafeArea(edges: .top)
        .overlay {
            if showLogoutModal {
                LogoutConfirmationModal(
                    isPresented: $showLogoutModal,
                    sidebarWidth: 352,
                    onConfirm: { authViewModel.logout() }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showLogoutModal)
        .onAppear {
            landOnAvailableDestination(config: configManager.configuration)
            if deepLinkRouter.pendingRequest != nil {
                handleDeepLinkNavigation()
            }
        }
        // Warm the ABM inventory in the background right after sign-in so the
        // ABM Lookup tab opens already populated. No-op when ABM isn't
        // configured or the cache is already valid; failures stay silent and
        // the tab falls back to its own on-demand load.
        .task {
            await ABMDeviceCache.shared.preloadIfNeeded()
        }
        #if DEBUG
        // Test aid (`-FleetHubTourTabs`, DEBUG builds only): opens every tab
        // in turn and ends on Settings, so idle CPU can be measured with
        // all tabs alive. Compiled out of release builds.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-FleetHubTourTabs") else { return }
            for destination in NavigationDestination.allCases {
                try? await Task.sleep(for: .seconds(1.5))
                selectedDestination = destination
            }
        }
        // Test aid (`-FleetHubScreenSharePanelTest` / `-FleetHubPasswordPanelTest`,
        // DEBUG builds only): opens the companion panel with sample details,
        // saves pictures of its states and quits. It never touches Apple's
        // Screen Sharing app or Jamf. `-FleetHubPanelMinutes n` sets the
        // time left; `-FleetHubPanelEstimate` shows the estimated state.
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            let screenShare = arguments.contains("-FleetHubScreenSharePanelTest")
            let keyPanel = arguments.contains("-FleetHubKeyPanelTest")
            guard screenShare || keyPanel || arguments.contains("-FleetHubPasswordPanelTest") else { return }
            let minutes = arguments.firstIndex(of: "-FleetHubPanelMinutes")
                .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 28.5
            let estimate = arguments.contains("-FleetHubPanelEstimate")
            let info = SSHSessionInfo(
                deviceName: "DEMO-MBP-0001", serialNumber: "C02DEMO0001", deviceID: "1000",
                username: "fleetadmin", host: "10.99.0.20", viaVPN: true, startedAt: Date(),
                rotatesAt: keyPanel ? nil : Date().addingTimeInterval(minutes * 60), rotationIsEstimate: estimate,
                kind: screenShare ? .screenShare : keyPanel ? .fileVaultKey : .localAdminPassword,
                rotationNote: estimate ? "Estimated from now. The Jamf API role needs View Local Admin Password Audit History to show the real time." : nil,
                details: keyPanel ? [.init(label: "Key Status", value: "Valid", isGood: true),
                                     .init(label: "Encryption", value: "Encrypted", isGood: nil)] : [])
            let secret = keyPanel ? "ABCD-EFGH-IJKL-MNOP-QRST-UVWX" : "Sample-Passw0rd-Only"
            let sample: () async throws -> FetchedPassword = {
                FetchedPassword(username: keyPanel ? "" : "fleetadmin", password: secret, rotatesAt: info.rotatesAt,
                                rotationIsEstimate: estimate, rotationNote: info.rotationNote)
            }
            if screenShare {
                SSHWindowManager.shared.openScreenSharePanel(info: info, fetchPassword: sample)
            } else {
                SSHWindowManager.shared.openPasswordPanel(info: info, password: secret, fetchPassword: sample)
            }
            let name = screenShare ? "screenshare-panel" : keyPanel ? "filevault-panel" : "password-panel"
            let title = screenShare ? "Screen Share" : keyPanel ? "FileVault Recovery Key" : "Local Admin Password"
            try? await Task.sleep(for: .seconds(2))
            DemoMode.snapshot(name, titled: title)
            if arguments.contains("-FleetHubPanelReveal") {
                SSHWindowManager.shared.debugRevealAll()
                try? await Task.sleep(for: .seconds(1))
                DemoMode.snapshot(name + "-revealed", titled: title)
            }
            if arguments.contains("-FleetHubPanelHold") { return }
            exit(0)
        }
        // Test aid (`-FleetHubRotationTest`, DEBUG builds only): runs the
        // rotation calculation on sample audit histories and prints each
        // answer in minutes from now.
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-FleetHubRotationTest") else { return }
            let now = Date()
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func audit(password: String, expiresIn: Double?, viewsAgo: [Double]) -> Data {
                let views = viewsAgo.map { "{\"viewedBy\":\"t\",\"dateSeen\":\"\(iso.string(from: now.addingTimeInterval(-$0 * 60)))\"}" }
                let expiry = expiresIn.map { "\"\(iso.string(from: now.addingTimeInterval($0 * 60)))\"" } ?? "null"
                return Data("{\"totalCount\":2,\"results\":[{\"password\":\"old\",\"expirationTime\":\"\(iso.string(from: now.addingTimeInterval(-86400)))\",\"audits\":[]},{\"password\":\"\(password)\",\"expirationTime\":\(expiry),\"audits\":[\(views.joined(separator: ","))]}]}".utf8)
            }
            func show(_ label: String, _ json: Data?, _ status: Int?, jamf: Double?) {
                let result = LAPSRotation.resolve(auditJSON: json, auditStatus: status, password: "pw", fetchedAt: now,
                                                  jamfPeriod: jamf.map { $0 * 60 }, configuredPeriod: 3600)
                let left = result.rotatesAt.map { String(format: "%.1f", $0.timeIntervalSince(now) / 60) } ?? "nil"
                print("ROTATION \(label): \(left) min, estimate=\(result.isEstimate), note=\(result.note ?? "-")")
            }
            show("viewed 30 min ago, expiry agrees", audit(password: "pw", expiresIn: 30, viewsAgo: [30, 0]), 200, jamf: nil)
            show("viewed 30 min ago, no expiry, Jamf period 60", audit(password: "pw", expiresIn: nil, viewsAgo: [30, 0]), 200, jamf: 60)
            show("viewed 30 min ago, no expiry, profile period", audit(password: "pw", expiresIn: nil, viewsAgo: [30, 0]), 200, jamf: nil)
            show("viewed 30 min ago, expiry is 90-day date", audit(password: "pw", expiresIn: 129600, viewsAgo: [30, 0]), 200, jamf: nil)
            show("viewed 10 min ago, Jamf period 120", audit(password: "pw", expiresIn: 110, viewsAgo: [10]), 200, jamf: 120)
            show("first view just now", audit(password: "pw", expiresIn: 60, viewsAgo: [0]), 200, jamf: nil)
            show("view not recorded yet, 90-day expiry", audit(password: "pw", expiresIn: 129600, viewsAgo: []), 200, jamf: nil)
            show("rotation overdue", audit(password: "pw", expiresIn: -5, viewsAgo: [65]), 200, jamf: nil)
            show("password not in audit", audit(password: "other", expiresIn: 30, viewsAgo: [30]), 200, jamf: nil)
            show("no audit privilege", nil, 403, jamf: nil)
            show("audit unreachable", nil, nil, jamf: nil)
            exit(0)
        }
        // Test aid (`-FleetHubSSHWindowTest host port user alias`, DEBUG
        // builds only): signs in with the test key, opens the SSH window,
        // types one command, saves a picture, closes the window and quits.
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-FleetHubSSHWindowTest"), arguments.count > index + 4 else { return }
            let target = SSHTarget(host: arguments[index + 1], port: Int(arguments[index + 2]) ?? 22,
                                   username: arguments[index + 3], hostKeyAlias: arguments[index + 4])
            do {
                let session = try SSHSession(target: target)
                try await session.connect(password: "unused", timeout: 15)
                SSHWindowManager.shared.open(session: session, info: SSHSessionInfo(
                    deviceName: "DEMO-MBP-0001", serialNumber: "C02DEMO0001", deviceID: "1000",
                    username: "fleetadmin", host: "10.99.0.20", viaVPN: true, startedAt: Date(),
                    rotatesAt: Date().addingTimeInterval(58 * 60), rotationIsEstimate: true),
                    fetchPassword: { () async throws -> FetchedPassword in
                        throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "demo mode has no Jamf connection"]) })
                try? await Task.sleep(for: .seconds(3))
                NSLog("SSHTEST window open: %d", SSHWindowManager.shared.hasOpenSessions ? 1 : 0)
                SSHWindowManager.shared.debugType("echo FLEETHUB_SSH_OK; uname -s\n")
                try? await Task.sleep(for: .seconds(2))
                if arguments.contains("-FleetHubSSHCopyTest") {
                    SSHWindowManager.shared.debugCopyPassword()
                    try? await Task.sleep(for: .seconds(1))
                }
                DemoMode.snapshot("ssh-window", titled: "SSH")
                SSHWindowManager.shared.debugCloseAll()
                try? await Task.sleep(for: .seconds(2))
                NSLog("SSHTEST after close, sessions open: %d", SSHWindowManager.shared.hasOpenSessions ? 1 : 0)
            } catch {
                NSLog("SSHTEST failed: %@", String(describing: error))
            }
            exit(0)
        }
        // Documentation aid (`-FleetHubSnapshots <folder>`, DEBUG builds
        // only): pictures of each screen, then quits.
        .task {
            guard DemoMode.snapshotDirectory != nil else { return }
            @MainActor func shot(_ name: String, wait: Double = 3) async {
                try? await Task.sleep(for: .seconds(wait))
                DemoMode.snapshot(name)
            }
            try? await Task.sleep(for: .seconds(1))
            NSApp.appearance = NSAppearance(named: .aqua)
            DemoMode.resizeWindow(width: 1440, height: 960)
            await shot("overview", wait: 4)
            DemoMode.resizeWindow(width: 1440, height: 1900)
            await shot("overview-full")
            DemoMode.resizeWindow(width: 1440, height: 960)
            selectedDestination = .devices
            await shot("devices")
            NotificationCenter.default.post(name: Notification.Name("FleetHubSnapshotOpenDevice"), object: nil)
            await shot("device-overview", wait: 5)
            for section in ["security", "diskEncryption", "compliance", "applications", "management", "history"] {
                NotificationCenter.default.post(name: Notification.Name("FleetHubSnapshotSection"), object: section)
                await shot("device-\(section)", wait: 3)
            }
            DemoMode.resizeWindow(width: 1440, height: 960)
            let rest: [(NavigationDestination, String)] = [
                (.myDevices, "my-devices"), (.reports, "reports"), (.cleanup, "cleanup"),
                (.logs, "logs"), (.announcements, "announcements"), (.settings, "settings")
            ]
            for (destination, name) in rest {
                selectedDestination = destination
                await shot(name)
                if destination == .reports, let folder = DemoMode.snapshotDirectory {
                    // A sample export, to check the PDF's banner header.
                    var table = HealthScorecardExportBuilder.table(generatedAt: Date())
                    table.criteria = [.init(category: "Site", detail: "Member of Central or East")]
                    try? ReportPDF.render(table).write(to: folder.appendingPathComponent("sample-export.pdf"))
                }
                if destination == .reports {
                    for filter in ["Site", "Building", "Department"] {
                        NotificationCenter.default.post(name: Notification.Name("FleetHubSnapshotReportFilter"), object: filter)
                        await shot("report-filter-\(filter.lowercased())", wait: 2)
                    }
                }
            }
            exit(0)
        }
        #endif
        .onChange(of: session.capabilities) { _, _ in
            landOnAvailableDestination(config: configManager.configuration)
        }
        // A mid-session profile push can kill the module the user is sitting
        // on; move them off it rather than leaving them on Not Authorized.
        // The publisher carries the NEW configuration — @Published fires
        // before the property is stored, so don't re-read the manager here.
        .onReceive(configManager.$configuration) { configuration in
            landOnAvailableDestination(config: configuration)
        }
        .onChange(of: deepLinkRouter.pendingRequest) { oldValue, newValue in
            if newValue != nil {
                handleDeepLinkNavigation()
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.herojoneslabs.fleethub.deeplink"))) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                deepLinkRouter.checkForPendingDeepLink()
                if deepLinkRouter.pendingRequest != nil {
                    handleDeepLinkNavigation()
                }
            }
        }
    }
    
    /// The route the user can actually reach — `nil` when they can reach
    /// none, which is the real "nothing to show" condition: it accounts for
    /// the machine layer's kill switches and for granted module ids that have
    /// no route at all, neither of which a bare
    /// "has any module" test can see.
    private var reachableDestination: NavigationDestination? {
        SidebarView.availableDestination(
            matching: selectedDestination,
            config: configManager.configuration,
            capabilities: session.capabilities
        )
    }

    /// The default selection is `.dashboard`, which a user's roles may not
    /// grant — move them to a row they can actually reach rather than opening
    /// on Not Authorized. Re-runs when capabilities change (sign-in, unlock)
    /// and when the configuration changes (profile push). Nothing reachable →
    /// nothing to land on; noModulesView covers that.
    private func landOnAvailableDestination(config: MDMConfiguration) {
        if let destination = SidebarView.availableDestination(
            matching: selectedDestination,
            config: config,
            capabilities: session.capabilities
        ), destination != selectedDestination {
            selectedDestination = destination
        }
    }

    /// Defense in depth: the sidebar already hides rows the user's roles
    /// don't grant, but EVERY route re-checks BOTH layers here — this
    /// codebase never lets enforcement live only in navigation visibility.
    @ViewBuilder
    private var mainContent: some View {
        if reachableDestination == nil {
            noModulesView
        } else {
            // Every tab opened so far stays in the hierarchy; only the
            // selected one is visible and interactive. Hidden tabs keep
            // their data, scroll position and pushed screens.
            ZStack {
                ForEach(NavigationDestination.allCases) { destination in
                    if destination == selectedDestination || visited.contains(destination) {
                        let isSelected = destination == selectedDestination
                        page(for: destination)
                            .opacity(isSelected ? 1 : 0)
                            .allowsHitTesting(isSelected)
                            .accessibilityHidden(!isSelected)
                            .zIndex(isSelected ? 1 : 0)
                    }
                }
            }
            .onAppear { markVisited(selectedDestination) }
            .onChange(of: selectedDestination) { _, destination in
                markVisited(destination)
            }
        }
    }

    /// Records a tab as opened. Writes only when it is new, so it never
    /// invalidates the view for nothing.
    private func markVisited(_ destination: NavigationDestination) {
        if !visited.contains(destination) { visited.insert(destination) }
    }

    /// One tab's content, behind its access gate.
    @ViewBuilder
    private func page(for destination: NavigationDestination) -> some View {
        switch destination {
        case .dashboard:
            gated(.dashboard) {
                DashboardContentView(
                    viewModel: viewModel,
                    isInNestedView: $dashboardNested,
                    initialDeviceCounts: initialDeviceCounts,
                    onOpenModule: handleNavigation
                )
                .id(dashboardResetTrigger)
            }
        case .devices:
            gated(.devices) {
                DevicesHomeView(isInNestedView: $devicesNested)
                    .environmentObject(deepLinkRouter)
                    .id(devicesResetTrigger)
            }
        case .myDevices:
            gated(.myDevices) { MyDevicesView(isInNestedView: $myDevicesNested) }
        case .announcements:
            gated(.announcements) { AnnouncementsView() }
        case .logs:
            gated(.logs) { LogsView() }
        case .reports:
            gated(.reports) { ReportsView() }
        case .cleanup:
            gated(.cleanup) { CleanupView(isInNestedView: $cleanupNested) }
        case .settings:
            gated(.settings) { SettingsView() }
        }
    }

    /// Renders `content` only when BOTH layers allow the route: the machine
    /// layer (this Mac's kill switches — SidebarView.machineAllows, the same
    /// predicate the sidebar prunes rows with) AND the user layer (the roles
    /// grant the module id). Either denial shows Not Authorized — a route
    /// reached without a click, e.g. by deep link, gets the same treatment.
    @ViewBuilder
    private func gated<Content: View>(
        _ destination: NavigationDestination,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if SidebarView.machineAllows(destination, config: configManager.configuration),
           session.capabilities.canAccess(module: destination.rawValue) {
            content()
        } else {
            notAuthorizedView(module: destination.title)
        }
    }

    private func notAuthorizedView(module: String) -> some View {
        emptyState(
            icon: "lock.shield",
            tint: .orange,
            title: "Not Authorized",
            subtitle: "\(module) is not available for your account."
        )
    }

    /// Shown when the user's roles grant no module at all — without it the
    /// window would render blank. Log Out stays available in the sidebar.
    private var noModulesView: some View {
        emptyState(
            icon: "square.dashed",
            tint: .orange,
            title: "Nothing to Show",
            subtitle: "No modules are available for your account.\nContact your administrator to request access."
        )
    }

    private func emptyState(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        ZStack {
            FleetHubTheme.ground.ignoresSafeArea()

            VStack(spacing: 24) {

                ZStack {
                    Circle()
                        .fill(tint.opacity(0.1))
                        .frame(width: 120, height: 120)

                    Image(systemName: icon)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(tint.opacity(0.6))
                }

                VStack(spacing: 12) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(FleetHubTheme.ink)

                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundColor(FleetHubTheme.muted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func handleNavigation(to destination: NavigationDestination) {
        // Choosing a tab always shows its first screen: a device page or a
        // search left open there is closed. The tab is NOT rebuilt (that
        // reloaded the whole inventory and made Overview hang), it is only
        // asked to pop back.
        clearNested(destination)
        NotificationCenter.default.post(name: .fleetHubShowTabRoot, object: destination.rawValue)
        selectedDestination = destination
    }

    /// Handle a deep link navigation request from the menu bar companion app.
    /// Simply switches to the Devices tab — DevicesView reads from the router directly.
    private func handleDeepLinkNavigation() {
        // Devices may already be alive in the background; rebuild it so it
        // picks up the pending request as it does on first open.
        if visited.contains(.devices) {
            clearNested(.devices)
            devicesResetTrigger = UUID()
        }
        selectedDestination = .devices
    }
}

@Observable
@MainActor
class DashboardViewModel {
    var isLoading = false
    var selectedNavigationItem: String = "dashboard"
    
    func refresh() async {
        isLoading = true
        try? await Task.sleep(for: .seconds(1))
        isLoading = false
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Dashboard View") {
    DashboardView()
        .environmentObject(AuthViewModel())
        .environmentObject(DeepLinkRouter())
        .frame(width: 1400, height: 900)
}
#endif
