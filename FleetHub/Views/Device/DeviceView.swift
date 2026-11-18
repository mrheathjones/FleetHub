//
//  DeviceView.swift
//  FleetHub
//
//  Comprehensive device detail view for computer inventory. A thin shell:
//  header + section tabs + the selected section, with device actions
//  executed by DeviceCommandExecutor and presented by DeviceActionOverlays.
//

import SwiftUI

struct DeviceView: View {
    let computer: Computer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var actionLogService = ActionLogService.shared
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    /// Observed so every policy gate re-evaluates when the user's
    /// capabilities land after sign-in (they are resolved post-login).
    @ObservedObject private var session = UserSession.shared
    @State private var selectedSection: DeviceSection = .overview
    /// Height of the section content beside the Actions card, so the card
    /// can end level with it.
    @State private var sectionContentHeight: CGFloat = 0

    // State for loading full details
    @State private var fullComputer: Computer?
    @State private var isLoadingDetails: Bool = false
    @State private var loadError: String?

    // Device history (Jamf Policy Logs + MDM command history). Lazy-loaded the
    // first time the History section is opened.
    @State private var history: ComputerHistory?
    @State private var isLoadingHistory: Bool = false
    @State private var historyError: String?

    /// Search / filter / page state for the inventory sections. Held here so
    /// it survives switching between sections.
    @State private var inventory = DeviceInventoryState()

    /// Runs MDM commands and the erase-acknowledgment flow for this device.
    @State private var executor: DeviceCommandExecutor
    /// Which confirmation stage or action sheet is showing.
    @State private var actionFlow = DeviceActionFlow()

    /// False when the view is embedded beside a device list (the Devices
    /// split view), where there is nothing to go back to.
    private let showsBackButton: Bool

    init(computer: Computer, showsBackButton: Bool = true) {
        self.computer = computer
        self.showsBackButton = showsBackButton
        _executor = State(initialValue: DeviceCommandExecutor(computer: computer))
    }

    /// Policy for this device's Actions menu (strict fail-closed — see
    /// DeviceActionPolicy). Recomputed on configuration reload via
    /// `configManager` and on capability change via `session`; the policy is
    /// a value type, so it must be rebuilt from the CURRENT capabilities.
    private var actionPolicy: DeviceActionPolicy {
        configManager.configuration.computerActionPolicy(capabilities: session.capabilities)
    }

    // The computer to display - use full details if loaded, otherwise initial
    private var displayComputer: Computer {
        fullComputer ?? computer
    }

    var body: some View {
        ZStack {
            // Background
            FleetHubTheme.ground.ignoresSafeArea()
                #if DEBUG
                // Documentation aid: the snapshot walk picks the section.
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FleetHubSnapshotSection"))) { note in
                    if let raw = note.object as? String, let section = DeviceSection(rawValue: raw) {
                        selectedSection = section
                    }
                }
                #endif
            
            if isLoadingDetails {
                // Loading state
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(FleetHubTheme.ink)
                    Text("Loading device details...")
                        .font(.headline)
                        .foregroundColor(FleetHubTheme.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = loadError {
                // Error state with fallback to show partial data
                VStack(spacing: 0) {
                    // Header
                    deviceHeader
                    
                    // Show error banner but still show content
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Some details may be incomplete: \(error)")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    
                    // Content
                    VStack(spacing: 0) {
                        sectionTabs
                        detailBody
                    }
                }
            } else {
                VStack(spacing: 0) {
                    // Header
                    deviceHeader
                    
                    // Content
                    VStack(spacing: 0) {
                        sectionTabs
                        
                        // Detail Content
                        detailBody
                    }
                }
            }
            
            // Command result, confirmation, progress, and secret overlays
            DeviceActionOverlays(computer: displayComputer, executor: executor, flow: actionFlow)
        }
        .navigationBarBackButtonHidden(true)
        .task {
            await loadFullDetails()
        }
        .sheet(isPresented: $actionFlow.showingABMAssignSheet) {
            ABMAssignmentSheet(
                serialNumber: displayComputer.serialNumber ?? "",
                deviceName: displayComputer.displayName,
                title: ActionBranding.label(for: .abmAssign),
                policyProvider: { actionPolicy },
                onFinished: { success, _, error in
                    executor.logABMAction(.abmAssign, serial: displayComputer.serialNumber ?? "Unknown",
                                 success: success, error: error)
                }
            )
        }
        .sheet(isPresented: $actionFlow.showingPreStageAssignSheet) {
            PreStageAssignmentSheet(
                serialNumber: displayComputer.serialNumber ?? "",
                deviceName: displayComputer.displayName,
                title: ActionBranding.label(for: .assignPreStage),
                policyProvider: { actionPolicy },
                onFinished: { success, _, detail in
                    executor.logABMAction(.assignPreStage, serial: displayComputer.serialNumber ?? "Unknown",
                                 success: success, error: detail)
                }
            )
        }
        .sheet(isPresented: $actionFlow.showingSiteMoveSheet) {
            SiteMoveSheet(
                deviceID: displayComputer.id,
                deviceName: displayComputer.displayName,
                serialNumber: displayComputer.serialNumber ?? "",
                currentSiteID: displayComputer.general?.site?.id,
                currentSiteName: displayComputer.general?.site?.name,
                title: ActionBranding.label(for: .moveToSite),
                policyProvider: { actionPolicy },
                performMove: { siteID in
                    try await JamfSiteService.shared.moveComputer(computerID: displayComputer.id, toSiteID: siteID)
                },
                onFinished: { success, _, detail in
                    executor.logABMAction(.moveToSite, serial: displayComputer.serialNumber ?? "Unknown",
                                 success: success, error: detail)
                }
            )
        }
    }

    // MARK: - Load Full Details
    
    /// - Parameter force: `true` always refetches (the Refresh button).
    ///   `false` (initial load) skips the fetch when `computer` already
    ///   carries the detail-only sections, so a device opened from search or
    ///   a deep link doesn't double-fetch on appear.
    @MainActor
    private func loadFullDetails(force: Bool = false) async {
        #if DEBUG
        if DemoMode.isEnabled {
            if let demo = DemoMode.computer(id: computer.id) {
                // Pass through the loading state like a real fetch does, so
                // the sections are built from the full record.
                isLoadingDetails = true
                await Task.yield()
                fullComputer = demo
                executor.computer = demo
                isLoadingDetails = false
            }
            return
        }
        #endif
        // Skip the fetch only when this computer clearly came from the detail
        // endpoint. APPLICATIONS alone is NOT proof: the bulk inventory fetch
        // uses features.computers.inventorySections, which commonly includes
        // APPLICATIONS but not the detail-only sections below — skipping on
        // apps alone leaves those sections permanently empty in this view.
        let hasDetailOnlySections = computer.localUserAccounts != nil
            && computer.certificates != nil
            && computer.printers != nil
        if !force, hasDetailOnlySections, !(computer.applications?.isEmpty ?? true) {
            AppLog.notice("📱 DeviceView: Already have full details for \(computer.displayName)")
            return
        }
        
        AppLog.notice("📱 DeviceView: Loading full details for \(computer.displayName) (id: \(computer.id))")
        isLoadingDetails = true
        
        do {
            let searchService = ComputerSearchService()
            let fullDetails = try await searchService.fetchComputerDetails(id: computer.id)
            
            self.fullComputer = fullDetails
            executor.computer = fullDetails
            self.isLoadingDetails = false
            AppLog.notice("✅ DeviceView: Loaded full details - \(fullDetails.applications?.count ?? 0) apps, \(fullDetails.configurationProfiles?.count ?? 0) profiles")
        } catch {
            self.loadError = error.localizedDescription
            self.isLoadingDetails = false
            AppLog.error("❌ DeviceView: Failed to load details: \(error.localizedDescription)")
        }
    }
    
    /// Lazy-load Policy Logs + MDM command history for this device. Skips work
    /// if already loaded (unless `force`, used by the Retry button).
    @MainActor
    private func loadHistory(force: Bool = false) async {
        if !force, history != nil { return }

        isLoadingHistory = true
        historyError = nil
        do {
            let service = ComputerHistoryService()
            history = try await service.fetchHistory(id: computer.id)
        } catch {
            historyError = error.localizedDescription
            AppLog.error("❌ DeviceView: Failed to load history: \(error.localizedDescription)")
        }
        isLoadingHistory = false
    }

    // MARK: - Device Header

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                if showsBackButton {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(FleetHubTheme.ink)
                            .frame(width: 36, height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                    .stroke(FleetHubTheme.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    .help("Back to the device list")
                }

                DeviceIconView(
                    modelIdentifier: displayComputer.hardware?.modelIdentifier,
                    modelName: displayComputer.modelName,
                    size: 76
                )
                .frame(width: 104, height: 104)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(FleetHubTheme.accent.opacity(0.12))
                )

                VStack(alignment: .leading, spacing: 7) {
                    Text(displayComputer.displayName)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(FleetHubTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(displayComputer.displayName)
                        .textSelection(.enabled)

                    Text(headerSubtitle)
                        .font(.system(size: 14))
                        .foregroundColor(FleetHubTheme.muted)
                        .lineLimit(1)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        if displayComputer.isManaged {
                            StatusBadge("Managed", color: .green, size: .compact)
                        }
                        if displayComputer.isSupervised {
                            StatusBadge("Supervised", color: .blue, size: .compact)
                        }
                        if displayComputer.isFileVaultEnabled {
                            StatusBadge("Encrypted", color: .purple, size: .compact)
                        }
                        if let site = displayComputer.general?.site?.name, !site.isEmpty {
                            StatusBadge("Site: \(site)", color: .indigo, size: .compact)
                        }
                    }
                    .padding(.top, 2)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    // Screen Share is the one action promoted to the header;
                    // it is left out of the Actions card. Same fail-closed
                    // gate and same flow as every other action.
                    if actionPolicy.isAllowed(.screenShare) {
                        Button {
                            executor.computer = displayComputer
                            actionFlow.trigger(.screenShare, executor: executor)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: ActionBranding.icon(for: .screenShare))
                                    .font(.system(size: 13, weight: .semibold))
                                Text(ActionBranding.label(for: .screenShare))
                                    .font(.system(size: 13, weight: .semibold))
                                    .fixedSize()
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                    .fill(FleetHubTheme.accentFill)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(executor.isExecutingCommand)
                    }

                    RefreshButton(isLoading: isLoadingDetails) {
                        // Force: the initial-load short-circuit would otherwise
                        // make Refresh a no-op for any device that arrived with
                        // detail sections already attached.
                        Task { await loadFullDetails(force: true) }
                    }
                }
            }

            // Health at a glance: one tag per check. Clicking a tag opens the
            // explanation for that verdict.
            Rectangle()
                .fill(FleetHubTheme.border)
                .frame(height: 1)

            DeviceHealthSection(computer: displayComputer, style: .chips)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    /// "MacBook Pro (14-inch, M4) · macOS 26.1 · Alex Chen" — whichever parts exist.
    private var headerSubtitle: String {
        var parts: [String] = []
        if let model = displayComputer.modelName { parts.append(model) }
        if let os = displayComputer.osVersion { parts.append("macOS \(os)") }
        if let user = displayComputer.assignedUserRealName ?? displayComputer.assignedUser { parts.append(user) }
        if let serial = displayComputer.serialNumber { parts.append(serial) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Detail Body

    /// The selected section on the left and, when the user has any granted
    /// action, the Actions panel in its own scrolling column on the right —
    /// about a third of the width, visible on every tab.
    private var detailBody: some View {
        // Bound once per render: the computed policy rebuilds its grants
        // dictionary on every access.
        let policy = actionPolicy
        return GeometryReader { geometry in
          HStack(alignment: .top, spacing: 20) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sectionContent
                }
                .background(
                    GeometryReader { content in
                        Color.clear
                            .onAppear { sectionContentHeight = content.size.height }
                            .onChange(of: content.size.height) { _, newHeight in
                                sectionContentHeight = newHeight
                            }
                    }
                )
                // Everything in a section can be selected and copied.
                .textSelection(.enabled)
                .padding(.leading, 28)
                .padding(.trailing, DeviceAction.allCases.contains(where: { $0 != .screenShare && policy.isAllowed($0) }) ? 0 : 28)
                .padding(.top, 6)
                .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity)

            // Strict fail-closed: no granted action, no column.
            if DeviceAction.allCases.contains(where: { $0 != .screenShare && policy.isAllowed($0) }) {
                // The card is as tall as the section content beside it (so on
                // Overview it ends level with the summary cards), never taller
                // than the pane, and scrolls inside itself.
                let available = geometry.size.height - 6 - 28
                DeviceActionsPanel(
                    policy: policy,
                    isExecuting: executor.isExecutingCommand,
                    columns: 1,
                    scrollsInside: true,
                    excluded: [.screenShare]   // lives in the header
                ) { action in
                    // Act on exactly the device the header shows.
                    executor.computer = displayComputer
                    actionFlow.trigger(action, executor: executor)
                }
                .frame(height: max(220, min(available, sectionContentHeight)))
                .padding(.trailing, 28)
                .padding(.top, 6)
                // A third of the pane, kept between a usable minimum and a
                // width past which the buttons only get emptier.
                .frame(width: min(440, max(320, geometry.size.width / 3)))
            }
          }
        }
    }

    // MARK: - Section Tabs

    /// Two rows replace the old 18-row sidebar: the six section GROUPS as
    /// tabs, then the sections inside the selected group as chips. A group
    /// with a single section shows no second row.
    private var sectionTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(visibleGroups) { group in
                        groupTab(group)
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(FleetHubTheme.trough)
                )
            }

            let sections = visibleSections(in: selectedGroup)
            if sections.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sections, id: \.self) { section in
                            sectionChip(section)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedGroup: DeviceSectionGroup {
        DeviceSectionGroup.group(for: selectedSection)
    }

    /// Sections available on this Mac. History is gated behind the
    /// `features.computers.showDeviceHistory` flag (default off) and
    /// Compliance appears only when a Jamf Platform API integration is
    /// configured (benchmarks exist nowhere else); everything else is
    /// always visible.
    private var visibleSections: [DeviceSection] {
        DeviceSection.allCases.filter { section in
            switch section {
            case .compliance:
                return ComplianceBenchmarkService.isAvailable
            case .history:
                return configManager.configuration.features?.effectiveComputers.effectiveShowDeviceHistory ?? false
            default:
                return true
            }
        }
    }

    private func visibleSections(in group: DeviceSectionGroup) -> [DeviceSection] {
        let visible = visibleSections
        return group.sections.filter { visible.contains($0) }
    }

    /// Groups that still have at least one visible section.
    private var visibleGroups: [DeviceSectionGroup] {
        DeviceSectionGroup.allCases.filter { !visibleSections(in: $0).isEmpty }
    }

    private func groupTab(_ group: DeviceSectionGroup) -> some View {
        let isSelected = selectedGroup == group
        return Button {
            guard !isSelected, let first = visibleSections(in: group).first else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSection = first
            }
        } label: {
            Text(group.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                        .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sectionChip(_ section: DeviceSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSection = section
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: section.icon)
                    .font(.system(size: 12))
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .fixedSize()
                if let count = sectionItemCount(section) {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(isSelected ? FleetHubTheme.accent : FleetHubTheme.muted)
                }
            }
            .foregroundColor(isSelected ? FleetHubTheme.accent : FleetHubTheme.control)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(isSelected ? FleetHubTheme.accent.opacity(0.12) : FleetHubTheme.surface)
            )
            .overlay(
                Capsule().stroke(isSelected ? FleetHubTheme.accent.opacity(0.5) : FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func sectionItemCount(_ section: DeviceSection) -> Int? {
        switch section {
        case .applications:
            return displayComputer.applications?.count
        case .profiles:
            return displayComputer.configurationProfiles?.count
        case .localAccounts:
            return displayComputer.localUserAccounts?.count
        case .certificates:
            return displayComputer.certificates?.count
        case .printers:
            return displayComputer.printers?.count
        case .groupMemberships:
            return displayComputer.groupMemberships?.count
        case .extensionAttributes:
            return displayComputer.extensionAttributes?.count
        case .logs:
            let count = actionLogService.logs(forDeviceId: displayComputer.id).count
            return count > 0 ? count : nil
        default:
            return nil
        }
    }

    // MARK: - Section Content

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .overview:
            DeviceOverviewView(computer: displayComputer)
        case .hardware, .storage, .security, .operatingSystem, .userAndLocation,
             .diskEncryption, .purchasing, .management:
            DeviceDetailSectionsView(section: selectedSection, computer: displayComputer)
        case .applications, .profiles, .localAccounts, .certificates, .printers,
             .groupMemberships, .extensionAttributes:
            DeviceInventoryTabsView(section: selectedSection, computer: displayComputer, state: inventory)
        case .compliance:
            DeviceComplianceSectionView(serialNumber: displayComputer.serialNumber)
        case .declarativeManagement:
            DeviceDDMSectionView(
                managementId: displayComputer.general?.managementId,
                ddmEnabled: displayComputer.general?.declarativeDeviceManagementEnabled
            )
        case .logs:
            DeviceLogsSectionView(computer: displayComputer)
        case .history:
            DeviceHistorySectionView(
                history: history,
                isLoading: isLoadingHistory,
                errorMessage: historyError,
                pageSize: configManager.configuration.features?.effectiveComputers.effectiveHistoryPageSize ?? 25,
                onRetry: { Task { await loadHistory(force: true) } }
            )
            .task { await loadHistory() }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Device View") {
    DeviceView(computer: MockData.testComputer)
        .frame(width: 1200, height: 800)
}
#endif
