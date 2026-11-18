//
//  DashboardContentView.swift
//  FleetHub
//
//  Main dashboard content with health scorecard, device counts, and search
//

import SwiftUI
// AppKit removed - using pure SwiftUI

// PlatformType is defined in Models/PlatformType.swift

// MARK: - Health Navigation Item

struct HealthNavigationItem: Hashable {
    let metricType: HealthMetricType
    let segmentType: HealthSegmentType
    let metricData: HealthMetricData
    
    var title: String {
        switch segmentType {
        case .compliant:
            return metricType.compliantLabel
        case .nonCompliant:
            return metricType.nonCompliantLabel
        case .unknown:
            return metricType.unknownLabel
        }
    }
    
    var deviceCount: Int {
        switch segmentType {
        case .compliant:
            return metricData.compliantCount
        case .nonCompliant:
            return metricData.nonCompliantCount
        case .unknown:
            return metricData.unknownCount
        }
    }
    
    var percentageDisplay: Int {
        switch segmentType {
        case .compliant:
            return metricData.compliantPercentageDisplay
        case .nonCompliant:
            return metricData.nonCompliantPercentageDisplay
        case .unknown:
            return metricData.unknownPercentageDisplay
        }
    }
}

// MARK: - Dashboard Content View

struct DashboardContentView: View {
    @Bindable var viewModel: DashboardViewModel
    @Binding var isInNestedView: Bool
    var initialDeviceCounts: DeviceCounts = DeviceCounts()
    /// Switches the window to another module (Reports, Cleanup, Logs…).
    var onOpenModule: (NavigationDestination) -> Void = { _ in }
    
    @State private var searchText: String = ""
    @State private var navigationPath = NavigationPath()
    @State private var hasSearched: Bool = false
    @State private var searchResults: [UnifiedSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String?
    /// The one search allowed in flight. Enter followed by a click used to
    /// spawn two untracked tasks and the slower one overwrote the newer
    /// results; now the previous task is cancelled before a new one starts.
    @State private var searchTask: Task<Void, Never>?
    
    // Unified search service for computers and mobile devices
    @StateObject private var unifiedSearchService = UnifiedDeviceSearchService()
    
    // Inventory services for device counts
    @StateObject private var computerInventoryService = ComputerInventoryService()
    @StateObject private var mobileDeviceService = MobileDeviceInventoryService()
    
    // Cache references for observing changes
    @ObservedObject private var computerCache = ComputerInventoryCache.shared
    @ObservedObject private var mobileCache = MobileDeviceInventoryCache.shared
    @ObservedObject private var healthCalculator = HealthMetricsCalculator.shared
    @ObservedObject private var session = UserSession.shared
    /// Observed so cards that depend on the configuration (Compliance
    /// Benchmarks) appear as soon as a profile or a policy-delivered secret
    /// arrives, without a relaunch.
    @ObservedObject private var configManager = MDMConfigurationManager.shared

    /// Coverage notes and dead-target warnings name sites, groups and device
    /// counts that the rest of the console does not expose. Fail-closed: a
    /// role must be granted allowScorecardDiagnostics to see them.
    private var diagnosticsVisible: Bool { session.capabilities.allowScorecardDiagnostics }
    
    @FocusState private var isSearchFocused: Bool
    
    // Device counts - populated from API or initial values
    @State private var deviceCounts: [PlatformType: Int] = [
        .macOS: 0,
        .iOS: 0,
        .iPadOS: 0,
        .visionOS: 0
    ]
    
    // Track if we've loaded the inventory
    @State private var hasLoadedInventory: Bool = false

    // Auto-refresh: driven by AppSettings.autoRefreshInterval (Off/1/5/15/30 min).
    @ObservedObject private var settings = AppSettings.shared
    /// When the dashboard counts were last (re)synced. Surfaced in the header.
    @State private var lastRefreshed: Date?
    /// True while a manual/auto refresh is fetching, to spin the Refresh button.
    @State private var isRefreshing: Bool = false
    /// Set when the last inventory sweep failed on either platform. Shown as a
    /// dismissible banner; `lastRefreshed` is deliberately left untouched so
    /// stale data never reads as freshly synced.
    @State private var refreshError: String?

    // Side-column sources. Each card is shown only when its module is
    // granted to the user and allowed on this Mac.
    @ObservedObject private var actionLog = ActionLogService.shared

    /// Counts behind the summary tiles that are not simple cache totals.
    /// Recomputed whenever the health metrics are recalculated.
    private struct FleetSummary {
        var checkedInThisMonth = 0
        var managedComputers = 0
        var unmanagedComputers = 0
        var needAttention = 0
        var stale = 0
        /// Macs reporting DDM enabled / Macs reporting the flag at all.
        var ddmEnabled = 0
        var ddmReporting = 0
    }
    @State private var summary: FleetSummary?
    /// Width this view was last offered; drives its wide/narrow layout.
    @State private var contentWidth: CGFloat = 1100
    /// Width this view was last offered; drives its wide/narrow layout.
    @State private var tilesWidth: CGFloat = 1100

    /// One OS version and how many devices run it.
    private struct OSVersionCount: Identifiable {
        let version: String
        let count: Int
        var id: String { version }
    }
    /// Device counts by OS version for each platform, most common first.
    @State private var osVersions: [PlatformType: [OSVersionCount]] = [:]
    /// The platform the OS Versions card is showing.
    @State private var osVersionsPlatform: PlatformType = .macOS
    /// Device counts by hardware model for each platform, most common first.
    @State private var hardwareModels: [PlatformType: [OSVersionCount]] = [:]
    /// The platform the Hardware card is showing.
    @State private var hardwarePlatform: PlatformType = .macOS

    /// 0 = unset → the profile's default (same rule as the Cleanup module).
    @AppStorage(CleanupSettings.Key.staleDays) private var staleDaysStored = 0
    private var staleDays: Int {
        staleDaysStored > 0 ? staleDaysStored : MDMConfigurationManager.shared.configuration.cleanupStaleDays
    }
    
    // Health metrics - computed from real inventory data
    private var healthMetrics: [HealthMetricData] {
        if healthCalculator.healthMetrics.isEmpty {
            // Return placeholder data while calculating
            return [
                HealthMetricData(type: .checkedIn, compliantCount: 0, nonCompliantCount: 0, unknownCount: 0),
                HealthMetricData(type: .protected, compliantCount: 0, nonCompliantCount: 0, unknownCount: 0),
                HealthMetricData(type: .encrypted, compliantCount: 0, nonCompliantCount: 0, unknownCount: 0),
                HealthMetricData(type: .secured, compliantCount: 0, nonCompliantCount: 0, unknownCount: 0),
                HealthMetricData(type: .upToDate, compliantCount: 0, nonCompliantCount: 0, unknownCount: 0)
            ]
        }
        return healthCalculator.healthMetrics
    }
    
    private var viewTitle: String {
        hasSearched ? "Device Search" : "Overview"
    }
    
    private var totalDeviceCount: Int {
        deviceCounts.values.reduce(0, +)
    }
    
    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                FleetHubTheme.ground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    headerSection
                    toolbarSection
                    refreshErrorBanner
                    
                    if hasSearched {
                        searchResultsSection
                    } else {
                        dashboardContent
                    }
                }
            }
            .navigationDestination(for: Computer.self) { computer in
                DeviceView(computer: computer)
            }
            .navigationDestination(for: MobileDevice.self) { device in
                MobileDeviceView(device: device)
            }
            .navigationDestination(for: PlatformType.self) { platform in
                DeviceListView(platform: platform, navigationPath: $navigationPath)
            }
            .navigationDestination(for: HealthNavigationItem.self) { item in
                HealthFilteredDeviceListView(
                    healthItem: item,
                    navigationPath: $navigationPath
                )
            }
        }
        .onShowTabRoot(.dashboard) {
            searchTask?.cancel()
            if !navigationPath.isEmpty { navigationPath = NavigationPath() }
            if hasSearched {
                hasSearched = false
                searchResults = []
                searchText = ""
            }
        }
        .task {
            await loadComputerInventory()
        }
        .task(id: healthCalculator.lastCalculationDate) {
            recomputeSummary()
        }
        // Auto-refresh loop. `.task(id:)` cancels and restarts whenever the
        // interval changes, so flipping the Settings segmented control takes
        // effect immediately. Interval 0 ("Off") returns without scheduling.
        .task(id: settings.autoRefreshInterval) {
            let interval = settings.autoRefreshInterval
            guard interval > 0 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double(interval)))
                if Task.isCancelled { break }
                await refreshInventory()
            }
        }
        .onChange(of: computerCache.totalCount) { _, newValue in
            // Update macOS count when cache changes
            if newValue > 0 {
                deviceCounts[.macOS] = newValue
            }
        }
        .onChange(of: mobileCache.iOSCount) { _, newValue in
            deviceCounts[.iOS] = newValue
        }
        .onChange(of: mobileCache.iPadOSCount) { _, newValue in
            deviceCounts[.iPadOS] = newValue
        }
        .onChange(of: mobileCache.visionOSCount) { _, newValue in
            deviceCounts[.visionOS] = newValue
        }
        .onChange(of: navigationPath.count) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                isInNestedView = newValue > 0 || hasSearched
            }
        }
        .onChange(of: hasSearched) { oldValue, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                isInNestedView = navigationPath.count > 0 || newValue
            }
        }
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(alignment: .center, spacing: 16) {
            if hasSearched {
                Button {
                    searchTask?.cancel()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        hasSearched = false
                        searchResults = []
                        searchText = ""
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .fill(FleetHubTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .stroke(FleetHubTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Overview")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(viewTitle)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)

                lastRefreshedLabel
            }

            Spacer()

            RefreshButton(isLoading: isRefreshing) {
                Task { await refreshInventory() }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 4)
    }

    /// Shows when the dashboard last synced, plus the active auto-refresh
    /// cadence when one is set. Times update passively as `lastRefreshed`
    /// changes; the string is recomputed on each render.
    @ViewBuilder
    private var lastRefreshedLabel: some View {
        if let lastRefreshed {
            let updated = "Updated \(lastRefreshed.formatted(date: .omitted, time: .shortened))"
            Text(settings.autoRefreshInterval > 0
                 ? "\(updated) · Auto-refresh every \(autoRefreshDescription)"
                 : updated)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .monospacedDigit()
        }
    }

    /// Human label for the current auto-refresh interval (seconds → "1 min").
    private var autoRefreshDescription: String {
        let minutes = settings.autoRefreshInterval / 60
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    /// Dismissible notice that the last inventory sweep failed. The previous
    /// counts and "Updated" stamp stay on screen untouched; this only says
    /// they are not as fresh as the refresh was meant to make them.
    @ViewBuilder
    private var refreshErrorBanner: some View {
        if let refreshError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Inventory refresh failed — showing the last successful data")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FleetHubTheme.ink)

                    Text(refreshError)
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.refreshError = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(8)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    // MARK: - Toolbar Section
    
    private var toolbarSection: some View {
        // Full-width search field: finding a device is the first thing most
        // people come here to do, so it leads the page.
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)

            TextField("", text: $searchText, prompt: Text("Find a device by name or serial number")
                .foregroundStyle(FleetHubTheme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(FleetHubTheme.ink)
                .focused($isSearchFocused)
                .onSubmit {
                    performSearch()
                }

            if !searchText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchText = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .transition(.scale.combined(with: .opacity))
            }

            Button(action: performSearch) {
                Text("Search")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(FleetHubTheme.accentFill)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: searchText.isEmpty)
        .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }
    
    // MARK: - Dashboard Content

    private var scorecardEnabled: Bool {
        // features domain: healthScorecard.enabled hides everything health-related.
        MDMConfigurationManager.shared.configuration
            .features?.effectiveHealthScorecard.effectiveEnabled != false
    }

    /// Both layers must allow a module before the dashboard links to it —
    /// the same test the navigation bar and the route gate use.
    private func canOpen(_ destination: NavigationDestination) -> Bool {
        SidebarView.machineAllows(destination, config: MDMConfigurationManager.shared.configuration)
            && session.capabilities.canAccess(module: destination.rawValue)
    }

    private var dashboardContent: some View {
        ScrollView {
            // Two columns when there is room, stacked when there is not.
            Group {
                if contentWidth >= 980 {
                    HStack(alignment: .top, spacing: 24) {
                        primaryColumn
                            .frame(maxWidth: .infinity)
                        secondaryColumn
                            .frame(width: min(420, contentWidth * 0.36))
                    }
                } else {
                    VStack(spacing: 24) {
                        primaryColumn
                        secondaryColumn
                    }
                }
            }
            .readWidth(into: $contentWidth)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
    }

    private var primaryColumn: some View {
        VStack(alignment: .leading, spacing: 24) {
            summaryTiles
            if scorecardEnabled {
                fleetHealthCard
            }
            // Platform API only: omitted entirely when no Platform
            // integration is configured, so a tenant without one sees no
            // empty or broken card.
            // When an integration IS named but cannot be used yet, the card
            // still appears and says what is missing.
            if ComplianceBenchmarkService.isAvailable || ComplianceBenchmarkService.unavailableReason != nil {
                ComplianceBenchmarksCard()
            }
        }
    }

    @ViewBuilder
    private var secondaryColumn: some View {
        VStack(spacing: 24) {
            osVersionsCard
            hardwareCard
            if visibleDashboardPlatforms.contains(.macOS), let summary {
                DeclarativeManagementCard(enabled: summary.ddmEnabled, reporting: summary.ddmReporting)
            }
            if canOpen(.logs) {
                recentActionsCard
            }
        }
    }

    /// Platforms whose dashboard device-count card the features domain
    /// allows (computers.showDashboardCard + mobileDevices.showDashboardCards
    /// per platform; all default true).
    private var visibleDashboardPlatforms: [PlatformType] {
        let features = MDMConfigurationManager.shared.configuration.features
        let mobileCards = features?.effectiveMobileDevices.effectiveShowDashboardCards
        return PlatformType.displayCases.filter { platform in
            switch platform {
            case .macOS:
                return features?.effectiveComputers.effectiveShowDashboardCard ?? true
            case .iOS:
                return mobileCards?.effectiveIOS ?? true
            case .iPadOS:
                return mobileCards?.effectiveIPadOS ?? true
            case .visionOS:
                return mobileCards?.effectiveVisionOS ?? true
            default:
                return true
            }
        }
    }
    
    // MARK: - Fleet Health

    private var fleetHealthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fleet Health")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(FleetHubTheme.ink)
                    Text("Select a check to see the devices behind it.")
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.muted)
                }

                Spacer(minLength: 8)

                let overallHealth = calculateOverallHealth()
                HStack(spacing: 6) {
                    Circle()
                        .fill(healthColor(for: overallHealth))
                        .frame(width: 8, height: 8)
                    Text("\(Int(overallHealth))% overall")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(FleetHubTheme.muted)
                        .fixedSize()
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(FleetHubTheme.ground))

                if canOpen(.reports) {
                    Button("Open Scorecard") { openScorecard() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FleetHubTheme.accent)
                        .fixedSize()
                }
            }

            if diagnosticsVisible {
                // Configuration problems only. The per-card coverage notes
                // were removed from this card at the owner's request.
                missingSectionsBanner
                unmatchedSitesBanner
            }

            VStack(spacing: 0) {
                ForEach(Array(healthMetrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 {
                        Rectangle()
                            .fill(FleetHubTheme.border)
                            .frame(height: 1)
                    }
                    HealthCheckRow(metric: metric) { segment in
                        navigationPath.append(
                            HealthNavigationItem(metricType: metric.type, segmentType: segment, metricData: metric)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
    }

    /// Opens Reports on its scorecard tab, where every card keeps its full
    /// compliant / non-compliant / unknown breakdown.
    private func openScorecard() {
        ReportsView.requestedTab = .scorecard
        onOpenModule(.reports)
    }

    /// States how many devices each card is NOT measuring.
    ///
    /// Non-dismissible by design. Under an inclusion model an untargeted device
    /// leaves the card silently and the percentage IMPROVES, because what remains
    /// is the healthier population — strictly harder to notice than a visible
    /// Unknown column. This footer is what keeps that honest, so it is not
    /// decoration and must not be made collapsible.
    @ViewBuilder
    private var coverageFooter: some View {
        let coverage = healthCalculator.cardCoverage
        let uncovered = coverage.filter { $0.value.untargeted > 0 }
        let dead = coverage.filter { !$0.value.deadTargets.isEmpty }

        if !uncovered.isEmpty || !dead.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(uncovered.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { metric in
                    if let c = coverage[metric] {
                        let sites = c.untargetedBySite.prefix(4)
                            .map { "\($0.siteName) (\($0.count))" }
                            .joined(separator: ", ")
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 11))
                                .foregroundStyle(FleetHubTheme.muted)
                            Text("**\(metric.rawValue)** is not measuring \(c.untargeted) device\(c.untargeted == 1 ? "" : "s") — no target covers \(sites)")
                                .font(.system(size: 11))
                                .foregroundStyle(FleetHubTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }

                ForEach(dead.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { metric in
                    if let c = coverage[metric] {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Text("**\(metric.rawValue)** has target\(c.deadTargets.count == 1 ? "" : "s") matching no devices: \(c.deadTargets.joined(separator: ", ")) — the id may be wrong or the site may no longer exist")
                                .font(.system(size: 11))
                                .foregroundStyle(FleetHubTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(FleetHubTheme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }

    /// Names metrics that could not be evaluated because the Jamf inventory
    /// sections they depend on are not being requested. Without this a missing
    /// section reads as "every device fails" — the failure mode that made
    /// Protected report 1% when APPLICATIONS was absent from the profile.
    @ViewBuilder
    private var missingSectionsBanner: some View {
        let gaps = healthCalculator.metricDataGaps
        if !gaps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.orange)

                    Text("\(gaps.count) metric\(gaps.count == 1 ? "" : "s") cannot be evaluated — required inventory data is not being fetched")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FleetHubTheme.ink)

                    Spacer(minLength: 0)
                }

                ForEach(gaps) { gap in
                    Text("• \(gap.metric.rawValue) (\(gap.platform.rawValue)) needs \(gap.missingSections.joined(separator: ", ")) — add to \(gap.configKey)")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 23)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.orange.opacity(0.3), lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }

    /// Names the Jamf sites that matched no Protected/Secured rule. Those devices
    /// score Unknown rather than silently passing, so the admin needs to see which
    /// sites are missing rules — this list is the exact input for configuring them.
    /// Rendered in-app deliberately: managed Macs often ship a logging profile that
    /// drops third-party NSLog, so a Console-only diagnostic is not dependable.
    @ViewBuilder
    private var unmatchedSitesBanner: some View {
        let sites = healthCalculator.unmatchedSiteCounts
        if !sites.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.yellow)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(sites.count) site\(sites.count == 1 ? "" : "s") have no Protected or Secured requirements defined")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FleetHubTheme.ink)

                    Text("Scored Unknown because there is nothing to evaluate them against: \(sites.map { "\($0.site) (\($0.count))" }.joined(separator: ", ")).")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.yellow.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.yellow.opacity(0.25), lineWidth: 1)
            )
            .cornerRadius(8)
        }
    }

    private func calculateOverallHealth() -> Double {
        guard !healthMetrics.isEmpty else { return 0 }
        let totalPercentage = healthMetrics.reduce(0.0) { $0 + $1.percentage }
        return totalPercentage / Double(healthMetrics.count)
    }
    
    private func healthColor(for percentage: Double) -> Color {
        HealthThresholds.color(forPercentage: percentage)
    }
    
    // MARK: - Summary Tiles

    private var visibleMobilePlatforms: [PlatformType] {
        visibleDashboardPlatforms.filter { $0 != .macOS }
    }

    private var mobileDeviceCount: Int {
        visibleMobilePlatforms.reduce(0) { $0 + (deviceCounts[$1] ?? 0) }
    }

    private var summaryTiles: some View {
        Group {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
                                count: tilesWidth >= 620 ? 4 : 2)
            LazyVGrid(columns: columns, spacing: 16) {
                if visibleDashboardPlatforms.contains(.macOS) {
                    SummaryTile(
                        icon: "laptopcomputer",
                        tint: FleetHubTheme.accent,
                        value: isLoadingPlatform(.macOS) ? nil : deviceCounts[.macOS] ?? 0,
                        title: "Computers",
                        subtitle: summary.map {
                            "\($0.managedComputers.formatted()) Managed · \($0.unmanagedComputers.formatted()) Unmanaged\n"
                                + "\($0.checkedInThisMonth.formatted()) checked in this month"
                        } ?? " \n ",
                        action: { navigationPath.append(PlatformType.macOS) }
                    )
                }

                if !visibleMobilePlatforms.isEmpty {
                    // One tile for all mobile platforms; the links underneath
                    // open each platform's own list.
                    SummaryTile(
                        icon: "iphone",
                        tint: Color(light: 0x6B3FD4, dark: 0xB79BFF),
                        value: isLoadingPlatform(.iOS) ? nil : mobileDeviceCount,
                        title: "Mobile Devices",
                        links: visibleMobilePlatforms.map { platform in
                            SummaryTile.Link(title: "\(platform.rawValue) \((deviceCounts[platform] ?? 0).formatted())") {
                                navigationPath.append(platform)
                            }
                        }
                    )
                }

                if scorecardEnabled {
                    SummaryTile(
                        icon: "exclamationmark.triangle",
                        tint: FleetHubTheme.warnText,
                        value: summary?.needAttention,
                        title: "Need Attention",
                        subtitle: "Failing one or more health checks",
                        isHighlighted: (summary?.needAttention ?? 0) > 0,
                        action: canOpen(.reports) ? { openScorecard() } : nil
                    )
                }

                if canOpen(.cleanup) {
                    SummaryTile(
                        icon: "clock",
                        tint: FleetHubTheme.control,
                        value: summary?.stale,
                        title: "Stale Devices",
                        subtitle: "No check-in for \(staleDays)+ days",
                        action: { onOpenModule(.cleanup) }
                    )
                }
            }
        }
        .readWidth(into: $tilesWidth)
    }

    /// Recomputes the tile counts that need a pass over the inventory.
    @MainActor
    private func recomputeSummary() {
        let now = Date()
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        let staleCutoff = now.addingTimeInterval(-Double(staleDays) * 86_400)

        var checkedIn = 0
        var stale = 0
        var ddmEnabled = 0
        var ddmReporting = 0
        var managed = 0
        for computer in computerCache.computers {
            if computer.isManaged { managed += 1 }
            if let ddm = computer.general?.declarativeDeviceManagementEnabled {
                ddmReporting += 1
                if ddm { ddmEnabled += 1 }
            }
            guard let lastContact = computer.lastContactTime else {
                stale += 1   // never checked in
                continue
            }
            if lastContact >= monthAgo { checkedIn += 1 }
            if lastContact < staleCutoff { stale += 1 }
        }

        // A device failing several checks is counted once.
        var failing = Set<String>()
        if scorecardEnabled {
            for metric in HealthMetricType.allCases {
                for device in healthCalculator.getFilteredDevices(for: metric, segment: .nonCompliant) {
                    failing.insert(device.id)
                }
            }
        }

        summary = FleetSummary(
            checkedInThisMonth: checkedIn, managedComputers: managed,
            unmanagedComputers: computerCache.computers.count - managed, needAttention: failing.count, stale: stale,
            ddmEnabled: ddmEnabled, ddmReporting: ddmReporting
        )

        // OS version tallies per platform, for the OS Versions card.
        // and hardware-model tallies for the Hardware card.
        var tallies: [PlatformType: [String: Int]] = [:]
        var modelTallies: [PlatformType: [String: Int]] = [:]
        for computer in computerCache.computers {
            let version = computer.operatingSystem?.version ?? "Unknown"
            tallies[.macOS, default: [:]][version, default: 0] += 1
            let model = computer.hardware?.model ?? "Unknown"
            modelTallies[.macOS, default: [:]][model, default: 0] += 1
        }
        for device in mobileCache.devices {
            let version = device.osVersion ?? "Unknown"
            tallies[device.platformType, default: [:]][version, default: 0] += 1
            modelTallies[device.platformType, default: [:]][device.displayModel, default: 0] += 1
        }
        func ranked(_ counts: [String: Int]) -> [OSVersionCount] {
            counts
                .map { OSVersionCount(version: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.version > $1.version }
        }
        osVersions = tallies.mapValues(ranked)
        hardwareModels = modelTallies.mapValues(ranked)
    }

    // MARK: - Side Column Cards

    private func sideCard<Content: View>(
        title: String,
        badge: String? = nil,
        linkTitle: String? = nil,
        link: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(FleetHubTheme.ink)

                if let badge {
                    Text(badge)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FleetHubTheme.badText)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(FleetHubTheme.badFill))
                }

                Spacer(minLength: 8)

                if let linkTitle, let link {
                    Button(linkTitle, action: link)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FleetHubTheme.accent)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
    }

    private func sideCardNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(FleetHubTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - OS Versions

    /// Leading number of a version string ("26.1.0" → 26); nil for "Unknown".
    private static func majorVersion(_ version: String) -> Int? {
        version.split(separator: ".").first.flatMap { Int($0) }
    }

    /// True when version `a` is OLDER than `b`, comparing each numeric part
    /// in turn ("15.7.2" is older than "26.1"; "26.1" is older than
    /// "26.1.1"). A version with no leading number ("Unknown") is treated
    /// as older than everything, so it lands last in a newest-first list.
    private static func versionPrecedes(_ a: String, _ b: String) -> Bool {
        func parts(_ version: String) -> [Int]? {
            let numbers = version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
            guard let first = numbers.first, first != nil else { return nil }
            return numbers.map { $0 ?? 0 }
        }
        switch (parts(a), parts(b)) {
        case (nil, nil): return a < b
        case (nil, _): return true
        case (_, nil): return false
        case (let left?, let right?):
            for index in 0..<max(left.count, right.count) {
                let l = index < left.count ? left[index] : 0
                let r = index < right.count ? right[index] : 0
                if l != r { return l < r }
            }
            return false
        }
    }

    private var osVersionsCard: some View {
        breakdownCard(
            title: "OS Versions",
            data: osVersions,
            platform: $osVersionsPlatform,
            labelWidth: 64,
            highlightsNewestMajor: true
        )
    }

    private var hardwareCard: some View {
        breakdownCard(
            title: "Hardware",
            data: hardwareModels,
            platform: $hardwarePlatform,
            labelWidth: 180,
            highlightsNewestMajor: false
        )
    }

    /// A card of labelled bars with a platform selector: the six most common
    /// values for the selected platform, the rest summed as "Other".
    private func breakdownCard(
        title: String,
        data: [PlatformType: [OSVersionCount]],
        platform: Binding<PlatformType>,
        labelWidth: CGFloat,
        highlightsNewestMajor: Bool
    ) -> some View {
        let platforms = visibleDashboardPlatforms
        let selected = platforms.contains(platform.wrappedValue) ? platform.wrappedValue : (platforms.first ?? .macOS)
        let all = data[selected] ?? []
        // The rows are the six most common entries. For OS versions they
        // are then listed newest to oldest (with "Unknown" last); hardware
        // stays most common first.
        let shown = highlightsNewestMajor
            ? Array(all.prefix(6)).sorted { Self.versionPrecedes($1.version, $0.version) }
            : Array(all.prefix(6))
        let otherCount = all.dropFirst(6).reduce(0) { $0 + $1.count }
        let largest = max(shown.map(\.count).max() ?? 0, otherCount, 1)
        let newestMajor = highlightsNewestMajor ? all.compactMap { Self.majorVersion($0.version) }.max() : nil

        return sideCard(title: title) {
            // Platform selector
            HStack(spacing: 4) {
                ForEach(platforms) { option in
                    let isSelected = option == selected
                    Button {
                        platform.wrappedValue = option
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                            .fixedSize()
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                                    .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(FleetHubTheme.trough)
            )

            if all.isEmpty {
                sideCardNote("No \(selected.rawValue) devices in inventory.")
            } else {
                VStack(spacing: 10) {
                    ForEach(shown) { entry in
                        osVersionRow(
                            label: entry.version,
                            count: entry.count,
                            fraction: Double(entry.count) / Double(largest),
                            // Without a newest/older split every bar is the accent.
                            isNewest: !highlightsNewestMajor || Self.majorVersion(entry.version) == newestMajor,
                            labelWidth: labelWidth
                        )
                    }
                    if otherCount > 0 {
                        osVersionRow(label: "Other", count: otherCount,
                                     fraction: Double(otherCount) / Double(largest),
                                     isNewest: !highlightsNewestMajor, labelWidth: labelWidth)
                    }
                }

                if highlightsNewestMajor {
                    // Colour is never the only cue: the legend names both.
                    HStack(spacing: 14) {
                        osVersionLegend(color: FleetHubTheme.accentFill,
                                        label: newestMajor.map { "\(selected.rawValue) \($0)" } ?? "Newest")
                        osVersionLegend(color: FleetHubTheme.muted.opacity(0.55), label: "Older")
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    private func osVersionRow(label: String, count: Int, fraction: Double, isNewest: Bool,
                              labelWidth: CGFloat) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FleetHubTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: labelWidth, alignment: .leading)
                .help(label)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(FleetHubTheme.trough)
                    Capsule()
                        .fill(isNewest ? FleetHubTheme.accentFill : FleetHubTheme.muted.opacity(0.55))
                        .frame(width: max(8, geometry.size.width * fraction))
                }
            }
            .frame(height: 8)

            Text(count.formatted())
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundColor(FleetHubTheme.ink)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(count.formatted()) devices")
    }

    private func osVersionLegend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
        }
    }

    private var recentActionsCard: some View {
        var recent = Array(actionLog.logs.sorted { $0.timestamp > $1.timestamp }.prefix(4))
        #if DEBUG
        if DemoMode.isEnabled { recent = DemoMode.recentActions }
        #endif
        return sideCard(title: "Recent Actions", linkTitle: "Open Logs", link: { onOpenModule(.logs) }) {
            if recent.isEmpty {
                sideCardNote("No actions have been performed yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(entry.actionName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(FleetHubTheme.ink)
                                        .lineLimit(1)
                                    if !entry.success {
                                        Text("Failed")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(FleetHubTheme.badText)
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(FleetHubTheme.badFill))
                                    }
                                }
                                Text("\(entry.deviceName) · \(entry.performedBy)")
                                    .font(.system(size: 12))
                                    .foregroundColor(FleetHubTheme.muted)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(entry.timestamp.formatted(.relative(presentation: .named)))
                                .font(.system(size: 12))
                                .foregroundColor(FleetHubTheme.muted)
                                .fixedSize()
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private func isLoadingPlatform(_ platform: PlatformType) -> Bool {
        switch platform {
        case .macOS:
            return computerInventoryService.isLoading
        case .iOS, .iPadOS, .visionOS:
            return mobileDeviceService.isLoading
        case .all:
            return computerInventoryService.isLoading || mobileDeviceService.isLoading
        }
    }
    
    // MARK: - Search Results Section
    
    private var searchResultsSection: some View {
        VStack(spacing: 0) {
            // Status bar
            HStack(spacing: 12) {
                if isSearching {
                    ProgressView()
                        .scaleEffect(0.8)
                        .frame(width: 16, height: 16)
                    Text("Searching...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(FleetHubTheme.muted)
                } else if let error = searchError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.orange)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("\(searchResults.count) device\(searchResults.count == 1 ? "" : "s") found")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .background(Color.clear)
            
            Rectangle()
                .fill(FleetHubTheme.border)
                .frame(height: 1)
            
            if isSearching {
                // Loading state
                VStack(spacing: 20) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Searching Jamf Pro...")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FleetHubTheme.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty {
                // Empty state
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(FleetHubTheme.muted)
                    Text(searchError ?? "No devices found")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FleetHubTheme.muted)
                    Text("Try searching by device name or serial number")
                        .font(.system(size: 14))
                        .foregroundStyle(FleetHubTheme.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Results list
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(searchResults) { result in
                            SearchResultRow(result: result) {
                                // Navigate to appropriate detail view
                                switch result {
                                case .computer(let computer):
                                    navigationPath.append(computer)
                                case .mobileDevice(let device):
                                    navigationPath.append(device)
                                }
                            }
                        }
                    }
                    .padding(28)
                }
            }
        }
    }
    
    // MARK: - Actions
    
    /// Manual/auto refresh entry point: always bypasses the cache fast-paths
    /// and pulls fresh inventory, spinning the header Refresh button while it
    /// runs. Guarded so overlapping taps/timers can't stack fetches.
    @MainActor
    private func refreshInventory() async {
        guard !isRefreshing else { return }
        #if DEBUG
        if DemoMode.isEnabled {
            lastRefreshed = Date()
            return
        }
        #endif
        isRefreshing = true
        await loadComputerInventory(forceRefresh: true)
        isRefreshing = false
    }

    @MainActor
    private func loadComputerInventory(forceRefresh: Bool = false) async {
        // A forced refresh skips every cache/initial-count fast path and goes
        // straight to the network fetch below.
        if !forceRefresh {
            // Use initial counts if provided (from loading screen)
            if initialDeviceCounts.total > 0 && !hasLoadedInventory {
                deviceCounts[.macOS] = initialDeviceCounts.macOS
                deviceCounts[.iOS] = initialDeviceCounts.iOS
                deviceCounts[.iPadOS] = initialDeviceCounts.iPadOS
                deviceCounts[.visionOS] = initialDeviceCounts.visionOS
                hasLoadedInventory = true

                // Calculate health metrics from cached data
                healthCalculator.recalculateMetrics()
                lastRefreshed = Date()

                AppLog.notice("📦 Dashboard: Using initial device counts - macOS: \(initialDeviceCounts.macOS), iOS: \(initialDeviceCounts.iOS), iPadOS: \(initialDeviceCounts.iPadOS), visionOS: \(initialDeviceCounts.visionOS)")
                return
            }

            // Skip if already loaded and caches are valid
            if hasLoadedInventory && computerCache.hasCachedData && mobileCache.hasCachedData {
                deviceCounts[.macOS] = computerCache.totalCount
                deviceCounts[.iOS] = mobileCache.iOSCount
                deviceCounts[.iPadOS] = mobileCache.iPadOSCount
                deviceCounts[.visionOS] = mobileCache.visionOSCount

                // Ensure health metrics are calculated
                if healthCalculator.healthMetrics.isEmpty {
                    healthCalculator.recalculateMetrics()
                }
                lastRefreshed = Date()

                AppLog.notice("📦 Dashboard: Using cached device counts")
                return
            }
        }

        AppLog.notice(forceRefresh ? "🔄 Dashboard: Force-refreshing device inventory..."
                                   : "📥 Dashboard: Loading device inventory...")

        // Fetch both in parallel
        async let computersTask: () = computerInventoryService.fetchAllComputers(forceRefresh: forceRefresh)
        async let mobilesTask: () = mobileDeviceService.fetchAllDevices(forceRefresh: forceRefresh)

        _ = await (computersTask, mobilesTask)

        // A failed sweep leaves the service's previous data intact and sets
        // errorMessage, so the counts below are still the last good ones.
        let failures = [computerInventoryService.errorMessage,
                        mobileDeviceService.errorMessage].compactMap { $0 }

        // Update counts
        deviceCounts[.macOS] = computerInventoryService.totalCount
        deviceCounts[.iOS] = mobileDeviceService.iOSCount
        deviceCounts[.iPadOS] = mobileDeviceService.iPadOSCount
        deviceCounts[.visionOS] = mobileDeviceService.visionOSCount

        // Health metrics recalculate once via the debounced cache observer in
        // HealthMetricsCalculator: every successful fetch assigns the cache's
        // @Published array, which emits regardless of content, so an explicit
        // recalculateMetrics() here only doubled the fleet-wide pass.

        guard failures.isEmpty else {
            // Keep the previous `lastRefreshed`: the data on screen is only
            // as fresh as the last sweep that actually succeeded.
            withAnimation(.easeInOut(duration: 0.2)) {
                refreshError = failures.joined(separator: "\n")
            }
            AppLog.error("❌ Dashboard: Inventory refresh failed - \(failures.joined(separator: " | "))")
            return
        }

        hasLoadedInventory = true
        withAnimation(.easeInOut(duration: 0.2)) {
            refreshError = nil
        }
        lastRefreshed = Date()

        AppLog.notice("✅ Dashboard: Loaded device counts - macOS: \(deviceCounts[.macOS] ?? 0), iOS: \(deviceCounts[.iOS] ?? 0), iPadOS: \(deviceCounts[.iPadOS] ?? 0), visionOS: \(deviceCounts[.visionOS] ?? 0)")
    }
    
    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        
        // A superseded search is cancelled; the service guards cancellation
        // before publishing and the task below guards it before reading back,
        // so only the newest query ever reaches the screen.
        searchTask?.cancel()

        isSearching = true
        searchError = nil
        
        searchTask = Task {
            // Use unified search service to search both computers and mobile devices
            await unifiedSearchService.searchDevices(query: query)
            guard !Task.isCancelled else { return }
            
            // Get results from the service
            searchResults = unifiedSearchService.searchResults
            searchError = unifiedSearchService.errorMessage
            
            AppLog.notice("✅ Unified search complete: \(searchResults.count) total results (computers: \(unifiedSearchService.computerResults.count), mobile: \(unifiedSearchService.mobileDeviceResults.count))")
            
            withAnimation(.easeInOut(duration: 0.3)) {
                hasSearched = true
                isSearching = false
            }
        }
    }
}

// MARK: - Summary Tile

/// One count on the Overview: icon, big number, title, and either a line of
/// supporting text (the whole tile is then a button) or a row of links.
private struct SummaryTile: View {
    struct Link: Identifiable {
        let id = UUID()
        let title: String
        let action: () -> Void
    }

    let icon: String
    let tint: Color
    /// nil while the count is still loading.
    let value: Int?
    let title: String
    var subtitle: String = ""
    var links: [Link] = []
    var isHighlighted: Bool = false
    var action: (() -> Void)? = nil

    @State private var isHovered = false

    var body: some View {
        if let action, links.isEmpty {
            Button(action: action) { tile }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .accessibilityLabel("\(title), \(value?.formatted() ?? "loading"). \(subtitle)")
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isHighlighted ? FleetHubTheme.surface : tint.opacity(0.14))
                )

            // Fixed height so the tile does not jump when the count arrives.
            Group {
                if let value {
                    Text(value.formatted())
                        .font(.system(size: 30, weight: .bold))
                        .foregroundColor(FleetHubTheme.ink)
                        .monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FleetHubTheme.ink)

                if links.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(isHighlighted ? FleetHubTheme.warnText : FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(links) { link in
                            Button(link.title, action: link.action)
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(FleetHubTheme.accent)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 192, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isHighlighted ? FleetHubTheme.warnFill : FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isHovered ? FleetHubTheme.accent.opacity(0.6)
                                  : (isHighlighted ? FleetHubTheme.warnText.opacity(0.3) : FleetHubTheme.border),
                        lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Health Check Row

/// One health check as a row: name, a bar for the passing share, the
/// percentage, and how many devices fail. Clicking opens the failing devices;
/// the context menu reaches the passing and unknown lists.
private struct HealthCheckRow: View {
    let metric: HealthMetricData
    let onSelect: (HealthSegmentType) -> Void

    @State private var isHovered = false

    private var statusColor: Color {
        metric.isConfigured
            ? HealthThresholds.color(forPercentage: metric.percentage, metricID: metric.type.configID)
            : FleetHubTheme.muted
    }

    private var caption: String {
        switch metric.type {
        case .checkedIn: return "Reported recently"
        case .protected: return "Protection active"
        case .encrypted: return "Disk encryption on"
        case .secured: return "Meets security rules"
        case .upToDate: return "Supported OS version"
        }
    }

    private var detail: String {
        guard metric.isConfigured else { return "Not scoped" }
        let failing = "\(metric.nonCompliantCount.formatted()) \(metric.type.nonCompliantLabel.lowercased())"
        return metric.unknownCount > 0
            ? "\(failing)\n\(metric.unknownCount.formatted()) unknown"
            : failing
    }

    var body: some View {
        Button {
            onSelect(.nonCompliant)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: metric.type.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(statusColor)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(statusColor.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.effectiveTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FleetHubTheme.ink)
                        .lineLimit(1)
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundColor(FleetHubTheme.muted)
                        .lineLimit(1)
                }
                .frame(width: 140, alignment: .leading)

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FleetHubTheme.trough)
                        Capsule()
                            .fill(statusColor)
                            .frame(width: max(0, geometry.size.width * min(1, metric.percentage / 100)))
                    }
                }
                .frame(height: 8)

                Text(metric.isConfigured ? "\(Int(metric.percentage.rounded()))%" : "—")
                    .font(.system(size: 16, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(FleetHubTheme.ink)
                    .frame(width: 50, alignment: .trailing)

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.muted)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 118, alignment: .trailing)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovered ? FleetHubTheme.ground : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Show \(metric.type.nonCompliantLabel)") { onSelect(.nonCompliant) }
            Button("Show \(metric.type.compliantLabel)") { onSelect(.compliant) }
            Button("Show \(metric.type.unknownLabel)") { onSelect(.unknown) }
        }
        .accessibilityLabel("\(metric.effectiveTitle), \(Int(metric.percentage.rounded())) percent. \(detail)")
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Dashboard") {
    @Previewable @State var isNested = false
    DashboardContentView(viewModel: DashboardViewModel(), isInNestedView: $isNested)
        .frame(width: 1400, height: 900)
}

#Preview("Dashboard - Narrow") {
    @Previewable @State var isNested = false
    DashboardContentView(viewModel: DashboardViewModel(), isInNestedView: $isNested)
        .frame(width: 940, height: 800)
}
#endif
