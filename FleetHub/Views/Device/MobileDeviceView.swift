//
//  MobileDeviceView.swift
//  FleetHub
//
//  Comprehensive detail view for mobile devices (iOS, iPadOS, visionOS)
//  Matches the design language of DeviceView for computers
//

import SwiftUI
import Observation

// MARK: - Inventory List State

/// Search/page state for MobileDeviceView's paginated sections — the mobile
/// counterpart of DeviceInventoryState.
@Observable
final class MobileDeviceInventoryState {
    enum CertificateFilter: String, CaseIterable {
        case all = "All"
        case issued = "Issued"
        case expiring = "Expiring"
        case expired = "Expired"
    }

    let applications = PaginatedListState<MobileDeviceApplication> { app, text in
        (app.name ?? "").localizedCaseInsensitiveContains(text) ||
        (app.identifier ?? "").localizedCaseInsensitiveContains(text)
    }

    let profiles = PaginatedListState<MobileDeviceConfigurationProfile> { profile, text in
        (profile.displayName ?? "").localizedCaseInsensitiveContains(text) ||
        (profile.identifier ?? "").localizedCaseInsensitiveContains(text)
    }

    let certificates = PaginatedListState<MobileDeviceCertificate> { cert, text in
        (cert.commonName ?? "").localizedCaseInsensitiveContains(text) ||
        (cert.subjectName ?? "").localizedCaseInsensitiveContains(text)
    }

    let groups = PaginatedListState<MobileDeviceGroup> { group, text in
        (group.groupName ?? "").localizedCaseInsensitiveContains(text)
    }

    let extensionAttributes = PaginatedListState<MobileDeviceExtensionAttribute> { attr, text in
        (attr.name ?? "").localizedCaseInsensitiveContains(text) ||
        (attr.value?.joined(separator: " ") ?? "").localizedCaseInsensitiveContains(text)
    }

    // Groups filters
    var filterSmartGroups: Bool = true {
        didSet { if filterSmartGroups != oldValue { groups.resetPage() } }
    }
    var filterStaticGroups: Bool = true {
        didSet { if filterStaticGroups != oldValue { groups.resetPage() } }
    }

    // Certificates filter
    var certificateFilter: CertificateFilter = .all {
        didSet { if certificateFilter != oldValue { certificates.resetPage() } }
    }
}

struct MobileDeviceView: View {
    let device: MobileDevice
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @ObservedObject private var session = UserSession.shared

    @State private var selectedSection: MobileDeviceSection = .overview
    /// Height of the section content beside the Actions card, so the card
    /// can end level with it.
    @State private var sectionContentHeight: CGFloat = 0

    // MARK: - Action State
    @State private var showingSiteMoveSheet: Bool = false
    /// Width this view was last offered; drives its wide/narrow layout.
    @State private var summaryWidth: CGFloat = 1100

    /// The mobile-device action policy — the SAME role-capability gating as
    /// computers, but consulting the user's `mobileDeviceActions` grant
    /// (DeviceActionPolicy.Platform.mobileDevice). Recomputed on config or
    /// capability change via the observed managers. `.moveToSite` also gates
    /// on a non-empty `allowedSites` (shared with computers) — see
    /// DeviceActionPolicy.hasUsableScope.
    private var actionPolicy: DeviceActionPolicy {
        configManager.configuration.mobileDeviceActionPolicy(capabilities: session.capabilities)
    }

    /// Mobile actions that actually have a UI/execution path today. The
    /// `mobileDeviceActions` schema enum lists more (sendBlankPush, restart,
    /// shutdown, wipe) as forward-looking, but nothing renders them yet — so
    /// the menu is filtered to this set to avoid offering dead buttons. Add a
    /// case here when its mobile flow lands.
    private let implementedMobileActions: [DeviceAction] = [.moveToSite]
    
    // MARK: - Inventory List State
    /// Search, filter, and page state for the searchable sections — kept
    /// here so it survives switching sections.
    @State private var inventory = MobileDeviceInventoryState()

    // One sort per inventory table; a column key is the column's own title.
    @State private var applicationSort = TableSort<String>()
    @State private var profileSort = TableSort<String>()
    @State private var certificateSort = TableSort<String>()
    @State private var groupSort = TableSort<String>()
    @State private var attributeSort = TableSort<String>()
    
    var body: some View {
        ZStack {
            FleetHubTheme.ground.ignoresSafeArea()
            
            VStack(spacing: 0) {
                deviceHeader
                sectionTabs
                detailBody
            }
        }
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showingSiteMoveSheet) {
            SiteMoveSheet(
                deviceID: device.id,
                deviceName: device.displayName,
                serialNumber: device.serialNumber ?? "",
                currentSiteID: device.site?.id,
                currentSiteName: device.site?.name,
                title: ActionBranding.label(for: .moveToSite),
                policyProvider: { actionPolicy },
                performMove: { siteID in
                    try await JamfSiteService.shared.moveMobileDevice(mobileDeviceID: device.id, toSiteID: siteID)
                },
                onFinished: { success, _, detail in
                    logMobileAction(.moveToSite, success: success, detail: detail)
                }
            )
        }
    }

    // MARK: - Device Header
    
    private var deviceHeader: some View {
        HStack(alignment: .center, spacing: 18) {
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

            Image(systemName: device.platformType.icon)
                .font(.system(size: 46, weight: .regular))
                .foregroundColor(FleetHubTheme.accent)
                .frame(width: 104, height: 104)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(FleetHubTheme.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 7) {
                Text(device.displayName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(FleetHubTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(device.displayName)
                    .textSelection(.enabled)

                Text(headerSubtitle)
                    .font(.system(size: 14))
                    .foregroundColor(FleetHubTheme.muted)
                    .lineLimit(1)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    if device.managed ?? false {
                        StatusBadge("Managed", color: .green, size: .compact)
                    }
                    if device.isSupervised {
                        StatusBadge("Supervised", color: .blue, size: .compact)
                    }
                    StatusBadge(device.platformType.rawValue, color: .purple, size: .compact)
                    if let site = device.site?.name, !site.isEmpty {
                        StatusBadge("Site: \(site)", color: .indigo, size: .compact)
                    }
                }
                .padding(.top, 2)
            }

            Spacer(minLength: 12)

            // (No Refresh control: this view is handed a fully-loaded
            // immutable `device`, so there is nothing to reload in place.)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    /// "iPhone 16 · iOS 26.1 · Alex Chen · F17…" — whichever parts exist.
    private var headerSubtitle: String {
        var parts: [String] = [device.model]
        if let os = device.osVersion {
            parts.append("\(device.platformType == .visionOS ? "visionOS" : "iOS") \(os)")
        }
        if let user = device.location?.realName ?? device.location?.username { parts.append(user) }
        if let serial = device.serialNumber { parts.append(serial) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Detail Body

    /// Mobile actions the user may run that also have a flow today.
    private var visibleActions: [DeviceAction] {
        let policy = actionPolicy
        return implementedMobileActions.filter { policy.isAllowed($0) }
    }

    /// The selected section on the left and, when the user has a usable
    /// action, the Actions card on the right third — same as the Mac view.
    private var detailBody: some View {
        let actions = visibleActions
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
                    .padding(.trailing, actions.isEmpty ? 28 : 0)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity)

                // Fail-closed: no granted, implemented action — no card.
                if !actions.isEmpty {
                    let available = geometry.size.height - 6 - 28
                    DeviceActionsPanel(
                        policy: actionPolicy,
                        isExecuting: false,
                        columns: 1,
                        scrollsInside: true,
                        // Only actions with a mobile flow are offered.
                        excluded: Set(DeviceAction.allCases).subtracting(actions)
                    ) { action in
                        trigger(action)
                    }
                    .frame(height: max(160, min(available, sectionContentHeight)))
                    .padding(.trailing, 28)
                    .padding(.top, 6)
                    .frame(width: min(440, max(320, geometry.size.width / 3)))
                }
            }
        }
    }

    // MARK: - Action Routing

    /// Routes a granted mobile action. Own-sheet actions (moveToSite) open
    /// their sheet after a defense-in-depth policy re-check; the menu already
    /// filters by policy, but never trust the UI filter alone. As more mobile
    /// actions gain flows, add their routing here.
    private func trigger(_ action: DeviceAction) {
        switch action {
        case .moveToSite:
            if actionPolicy.denialReason(for: .moveToSite) != nil {
                logMobileAction(.moveToSite, success: false, detail: "Denied by policy at trigger (menu filter bypassed)")
            } else {
                showingSiteMoveSheet = true
            }
        default:
            // Not reachable: the menu only offers implementedMobileActions.
            logMobileAction(action, success: false, detail: "No mobile flow implemented for '\(action.rawValue)'")
        }
    }

    /// Audit-logs a mobile action end state, mirroring the computer view's
    /// logABMAction. deviceId uses the mobile inventory id.
    private func logMobileAction(_ action: DeviceAction, success: Bool, detail: String?) {
        ActionLogService.shared.logAction(
            actionName: action.logName,
            actionCategory: action.logCategory,
            deviceName: device.displayName,
            deviceSerialNumber: device.serialNumber ?? "Unknown",
            deviceId: device.id,
            success: success,
            errorMessage: detail
        )
    }
    
    // MARK: - Section Tabs

    /// Group tabs, then the sections inside the selected group as chips —
    /// the same two rows as the Mac detail view.
    private var sectionTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(MobileDeviceSectionGroup.allCases) { group in
                        groupTab(group)
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(FleetHubTheme.trough)
                )
            }

            let sections = selectedGroup.sections
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

    private var selectedGroup: MobileDeviceSectionGroup {
        MobileDeviceSectionGroup.group(for: selectedSection)
    }

    private func groupTab(_ group: MobileDeviceSectionGroup) -> some View {
        let isSelected = selectedGroup == group
        return Button {
            guard !isSelected, let first = group.sections.first else { return }
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

    private func sectionChip(_ section: MobileDeviceSection) -> some View {
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

    private func sectionItemCount(_ section: MobileDeviceSection) -> Int? {
        switch section {
        case .applications:
            return device.applications?.count
        case .profiles:
            return device.configurationProfiles?.count
        case .certificates:
            return device.certificates?.count
        case .groups:
            return device.groups?.count
        case .extensionAttributes:
            return device.extensionAttributes?.count
        default:
            return nil
        }
    }
    
    // MARK: - Section Content
    
    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .overview:
            overviewSection
        case .hardware:
            hardwareSection
        case .security:
            securitySection
        case .userAndLocation:
            userAndLocationSection
        case .applications:
            applicationsSection
        case .profiles:
            profilesSection
        case .certificates:
            certificatesSection
        case .network:
            networkSection
        case .groups:
            groupsSection
        case .extensionAttributes:
            extensionAttributesSection
        case .purchasing:
            purchasingSection
        case .management:
            managementSection
        case .declarativeManagement:
            DeviceDDMSectionView(
                managementId: device.managementId,
                ddmEnabled: device.declarativeDeviceManagementEnabled
            )
        }
    }
    
    // MARK: - Overview Section
    
    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Counts, each jumping to its section.
            HStack(alignment: .top, spacing: 14) {
                countTile("Applications", device.applications?.count, icon: "app.badge", section: .applications)
                countTile("Profiles", device.configurationProfiles?.count, icon: "doc.badge.gearshape", section: .profiles)
                countTile("Certificates", device.certificates?.count, icon: "checkmark.seal", section: .certificates)
                countTile("Groups", device.groups?.count, icon: "person.3", section: .groups)
            }

            // Three summaries side by side when the pane has room for them.
            Group {
                if summaryWidth >= 690 {
                    HStack(alignment: .top, spacing: 14) {
                        generalCard
                        operatingSystemCard
                        managementCard
                    }
                    .detailRowsStacked()
                    .detailCardsFillHeight()
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 14) {
                        generalCard
                        operatingSystemCard
                        managementCard
                    }
                }
            }
            .readWidth(into: $summaryWidth)
        }
    }

    private func countTile(_ title: String, _ count: Int?, icon: String, section: MobileDeviceSection) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedSection = section
            }
        } label: {
            DeviceStatTile(
                icon: icon,
                tint: FleetHubTheme.accent,
                value: "\(count ?? 0)",
                title: title,
                caption: "Show list"
            )
        }
        .buttonStyle(.plain)
        // A button's label must not swallow the click as a text selection.
        .textSelection(.disabled)
    }

    private var generalCard: some View {
        DetailCard(title: "General") {
            DetailRow("Device Name", device.name ?? "N/A")
            DetailRow("Serial Number", device.serialNumber ?? "N/A")
            DetailRow("Model", device.model)
            DetailRow("Model Identifier", device.modelIdentifier ?? "N/A")
            DetailRow("Asset Tag", device.assetTag)
        }
    }

    private var operatingSystemCard: some View {
        DetailCard(title: "Operating System") {
            DetailRow("Version", device.osVersion ?? "N/A")
            DetailRow("Build", device.osBuild ?? "N/A")
            if let supplemental = device.osSupplementalBuildVersion {
                DetailRow("Supplemental", supplemental)
            }
            DetailRow("Last Inventory", formatDate(device.lastInventoryUpdateTimestamp))
        }
    }

    private var managementCard: some View {
        DetailCard(title: "Management") {
            DetailRow("Managed", device.managed ?? false ? "Yes" : "No")
            DetailRow("Supervised", device.isSupervised ? "Yes" : "No")
            if let enrollmentMethod = device.enrollmentMethod {
                DetailRow("Enrollment", enrollmentMethod)
            }
            DetailRow("Initial Enrollment", formatDate(device.initialEntryTimestamp))
            DetailRow("Last Enrollment", formatDate(device.lastEnrollmentTimestamp))
        }
    }

    // MARK: - Hardware Section
    
    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("Hardware", icon: "cpu")
            
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    DetailCard(title: "Storage") {
                        if let capacity = device.capacityMb {
                            DetailRow("Total Capacity", formatStorage(capacity))
                        }
                        if let available = device.availableMb {
                            DetailRow("Available", formatStorage(available))
                        }
                        if let used = device.percentageUsed {
                            DetailRow("Used", "\(used)%")
                            
                            // Storage bar
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(FleetHubTheme.trough)
                                        .frame(height: 8)

                                    Capsule()
                                        .fill(used > 90 ? FleetHubTheme.badText : used > 75 ? FleetHubTheme.warnText : FleetHubTheme.accentFill)
                                        .frame(width: geometry.size.width * CGFloat(used) / 100, height: 8)
                                }
                            }
                            .frame(height: 8)
                            .padding(.top, 4)
                        }
                    }
                    
                    if device.batteryLevel != nil {
                        DetailCard(title: "Battery") {
                            if let level = device.batteryLevel {
                                DetailRow("Level", "\(level)%")
                                
                                // Battery bar
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(FleetHubTheme.trough)
                                            .frame(height: 8)

                                        Capsule()
                                            .fill(level < 20 ? FleetHubTheme.badText : level < 50 ? FleetHubTheme.warnText : FleetHubTheme.goodText)
                                            .frame(width: geometry.size.width * CGFloat(level) / 100, height: 8)
                                    }
                                }
                                .frame(height: 8)
                                .padding(.top, 4)
                            }
                            if let health = device.ios?.batteryHealth ?? device.visionos?.batteryHealth {
                                DetailRow("Health", health)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 20) {
                    DetailCard(title: "Network") {
                        DetailRow("IP Address", device.ipAddress ?? "N/A")
                        DetailRow("Wi-Fi MAC", device.wifiMacAddress ?? "N/A")
                        DetailRow("Bluetooth MAC", device.bluetoothMacAddress ?? "N/A")
                    }
                    
                    DetailCard(title: "Identifiers") {
                        DetailRow("UDID", device.udid ?? "N/A")
                        DetailRow("Management ID", device.managementId ?? "N/A")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    // MARK: - Security Section
    
    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("Security", icon: "shield.checkered")
            
            if let security = device.security {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        DetailCard(title: "Passcode & Protection") {
                            securityRow("Passcode Present", security.passcodePresent ?? false)
                            securityRow("Passcode Compliant", security.passcodeCompliant ?? false)
                            securityRow("Passcode Compliant with Profile", security.passcodeCompliantWithProfile ?? false)
                            securityRow("Data Protected", security.dataProtected ?? false)
                        }
                        
                        DetailCard(title: "Device Security") {
                            securityRow("Activation Lock", security.activationLockEnabled ?? false)
                            securityRow("Jailbreak Detected", security.jailBreakDetected ?? false, invertColors: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 20) {
                        DetailCard(title: "Encryption") {
                            securityRow("Block Level Encryption Capable", security.blockLevelEncryptionCapable ?? false)
                            securityRow("File Level Encryption Capable", security.fileLevelEncryptionCapable ?? false)
                            if let hw = security.hardwareEncryption {
                                DetailRow("Hardware Encryption", "\(hw)")
                            }
                        }
                        
                        if security.attestationStatus != nil {
                            DetailCard(title: "Attestation") {
                                DetailRow("Status", security.attestationStatus ?? "N/A")
                                DetailRow("Last Attempt", formatDate(security.lastAttestationAttemptDate))
                                DetailRow("Last Success", formatDate(security.lastSuccessfulAttestationDate))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyStateView("No security information available", icon: "shield.checkered")
            }
        }
    }
    
    private func securityRow(_ label: String, _ value: Bool, invertColors: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
            
            Spacer()
            
            HStack(spacing: 6) {
                Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                Text(value ? "Yes" : "No")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle((invertColors ? !value : value) ? FleetHubTheme.goodText : FleetHubTheme.badText)
        }
    }
    
    // MARK: - User & Location Section
    
    private var userAndLocationSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("User & Location", icon: "person.fill")
            
            if let location = device.location,
               (location.username != nil || location.realName != nil || location.emailAddress != nil) {
                HStack(alignment: .top, spacing: 20) {
                    DetailCard(title: "Assigned User") {
                        DetailRow("Username", location.username ?? "N/A")
                        DetailRow("Real Name", location.realName ?? "N/A")
                        DetailRow("Email", location.emailAddress ?? "N/A")
                        DetailRow("Position", location.position ?? "N/A")
                        DetailRow("Phone", location.phoneNumber ?? "N/A")
                    }
                    .frame(maxWidth: .infinity)
                    
                    DetailCard(title: "Location") {
                        DetailRow("Room", location.room ?? "N/A")
                        DetailRow("Building ID", location.buildingId ?? "N/A")
                        DetailRow("Department ID", location.departmentId ?? "N/A")
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyStateView("No user assigned to this device", icon: "person.crop.circle.badge.questionmark")
            }
        }
    }
    
    // MARK: - Applications Section
    
    private var applicationsSection: some View {
        let apps = device.applications ?? []
        let filteredApps = inventory.applications.filter(apps).sorted(by: applicationSort) { app, column in
            switch column {
            case "Version": .text(app.shortVersion ?? app.version)
            case "Build": .text(app.shortVersion != nil ? app.version : nil)
            default: .text(app.name)
            }
        }

        return InventoryCardShell {
            if apps.isEmpty {
                InventoryToolbar(title: "Applications", countText: "0")
                InventoryEmptyState(icon: "app.badge", title: "No Applications Installed")
            } else {
                InventoryToolbar(
                    title: "Applications",
                    countText: inventoryCountText(shown: filteredApps.count, total: apps.count),
                    search: Bindable(inventory.applications).searchText,
                    searchPrompt: "Search applications"
                )
                InventoryHeaderRow {
                    InventoryColumns(widths: (140, 120)) {
                        SortableHeaderText("Application", key: "Application", sort: $applicationSort)
                    } second: {
                        SortableHeaderText("Version", key: "Version", sort: $applicationSort)
                    } third: {
                        SortableHeaderText("Build", key: "Build", sort: $applicationSort)
                    }
                }
                if filteredApps.isEmpty {
                    InventoryEmptyState(icon: "magnifyingglass", title: "No Applications Match Search")
                } else {
                    InventoryPagedRows(state: inventory.applications, rows: filteredApps) { app in
                        applicationRow(app)
                    }
                }
            }
        }
    }

    private func applicationRow(_ app: MobileDeviceApplication) -> some View {
        InventoryColumns(widths: (140, 120)) {
            InventoryPrimaryCell(title: app.name ?? "Unknown", subtitle: app.identifier ?? "N/A")
        } second: {
            InventoryCellText(app.shortVersion ?? app.version)
        } third: {
            InventoryCellText(app.shortVersion != nil ? app.version : nil)
        }
    }

    // MARK: - Profiles Section

    private var profilesSection: some View {
        let profiles = device.configurationProfiles ?? []
        let filteredProfiles = inventory.profiles.filter(profiles).sorted(by: profileSort) { profile, column in
            switch column {
            case "Version": .text(profile.version)
            default: .text(profile.displayName)
            }
        }

        return InventoryCardShell {
            if profiles.isEmpty {
                InventoryToolbar(title: "Configuration Profiles", countText: "0")
                InventoryEmptyState(icon: "doc.badge.gearshape", title: "No Configuration Profiles")
            } else {
                InventoryToolbar(
                    title: "Configuration Profiles",
                    countText: inventoryCountText(shown: filteredProfiles.count, total: profiles.count),
                    search: Bindable(inventory.profiles).searchText,
                    searchPrompt: "Search profiles"
                )
                InventoryHeaderRow {
                    InventoryColumns(widths: (10, 110)) {
                        SortableHeaderText("Profile", key: "Profile", sort: $profileSort)
                    } second: {
                        EmptyView()
                    } third: {
                        SortableHeaderText("Version", key: "Version", sort: $profileSort)
                    }
                }
                if filteredProfiles.isEmpty {
                    InventoryEmptyState(icon: "magnifyingglass", title: "No Profiles Match Search")
                } else {
                    InventoryPagedRows(state: inventory.profiles, rows: filteredProfiles) { profile in
                        profileRow(profile)
                    }
                }
            }
        }
    }

    private func profileRow(_ profile: MobileDeviceConfigurationProfile) -> some View {
        InventoryColumns(widths: (10, 110)) {
            InventoryPrimaryCell(title: profile.displayName ?? "Unknown Profile", subtitle: profile.identifier ?? "N/A")
        } second: {
            EmptyView()
        } third: {
            InventoryCellText(profile.version)
        }
    }

    // MARK: - Certificates Section

    private var certificatesSection: some View {
        let certs = device.certificates ?? []
        let filteredCerts = filteredCertificates(from: certs).sorted(by: certificateSort) { cert, column in
            switch column {
            case "Expires": .date(cert.expirationDateEpoch.flatMap { parseDate($0) })
            case "Status":
                .text(cert.certificateStatus?.capitalized
                      ?? (isCertificateExpired(cert) ? "Expired" : (isCertificateExpiring(cert) ? "Expiring" : "Valid")))
            default: .text(cert.commonName)
            }
        }

        return InventoryCardShell {
            if certs.isEmpty {
                InventoryToolbar(title: "Certificates", countText: "0")
                InventoryEmptyState(icon: "checkmark.seal", title: "No Certificates")
            } else {
                InventoryToolbar(
                    title: "Certificates",
                    countText: inventoryCountText(shown: filteredCerts.count, total: certs.count),
                    search: Bindable(inventory.certificates).searchText,
                    searchPrompt: "Search certificates"
                )
                // Certificate status filter
                InventoryFilterRow {
                    ForEach(MobileDeviceInventoryState.CertificateFilter.allCases, id: \.self) { filter in
                        InventoryChip(title: filter.rawValue, isSelected: inventory.certificateFilter == filter) {
                            inventory.certificateFilter = filter
                        }
                    }
                }
                InventoryHeaderRow {
                    InventoryColumns(widths: (170, 100)) {
                        SortableHeaderText("Certificate", key: "Certificate", sort: $certificateSort)
                    } second: {
                        SortableHeaderText("Expires", key: "Expires", sort: $certificateSort)
                    } third: {
                        SortableHeaderText("Status", key: "Status", sort: $certificateSort)
                    }
                }
                if filteredCerts.isEmpty {
                    InventoryEmptyState(icon: "line.3.horizontal.decrease.circle", title: "No Certificates Match Filters")
                } else {
                    InventoryPagedRows(state: inventory.certificates, rows: filteredCerts) { cert in
                        certificateRow(cert)
                    }
                }
            }
        }
    }

    private func filteredCertificates(from certs: [MobileDeviceCertificate]) -> [MobileDeviceCertificate] {
        // Apply search filter
        var result = inventory.certificates.filter(certs)
        
        // Apply status filter
        switch inventory.certificateFilter {
        case .all:
            break
        case .issued:
            result = result.filter { $0.certificateStatus == "ISSUED" || $0.lifecycleStatus == "ACTIVE" }
        case .expiring:
            result = result.filter { cert in
                guard let expiryString = cert.expirationDateEpoch,
                      let expiryDate = parseDate(expiryString) else {
                    return false
                }
                let thirtyDaysFromNow = Date().addingTimeInterval(30 * 24 * 60 * 60)
                return expiryDate > Date() && expiryDate <= thirtyDaysFromNow
            }
        case .expired:
            result = result.filter { cert in
                if cert.certificateStatus == "EXPIRED" {
                    return true
                }
                guard let expiryString = cert.expirationDateEpoch,
                      let expiryDate = parseDate(expiryString) else {
                    return false
                }
                return expiryDate < Date()
            }
        }
        
        return result
    }
    
    private func certificateRow(_ cert: MobileDeviceCertificate) -> some View {
        let isExpired = isCertificateExpired(cert)
        let isExpiring = isCertificateExpiring(cert)
        let tone: InventoryTag.Tone = isExpired ? .bad : (isExpiring ? .warn : .good)

        return InventoryColumns(widths: (170, 100)) {
            InventoryPrimaryCell(title: cert.commonName ?? "Unknown Certificate", subtitle: cert.subjectName) {
                if cert.identity == true {
                    InventoryTag(text: "Identity", tone: .accent)
                }
            }
        } second: {
            InventoryCellText(cert.expirationDateEpoch.map { formatDate($0) })
        } third: {
            if let status = cert.certificateStatus {
                InventoryTag(text: status.capitalized, tone: tone)
            } else {
                InventoryTag(text: isExpired ? "Expired" : (isExpiring ? "Expiring" : "Valid"), tone: tone)
            }
        }
    }

    private func isCertificateExpired(_ cert: MobileDeviceCertificate) -> Bool {
        if cert.certificateStatus == "EXPIRED" { return true }
        guard let expiryString = cert.expirationDateEpoch,
              let expiryDate = parseDate(expiryString) else { return false }
        return expiryDate < Date()
    }
    
    private func isCertificateExpiring(_ cert: MobileDeviceCertificate) -> Bool {
        guard let expiryString = cert.expirationDateEpoch,
              let expiryDate = parseDate(expiryString) else { return false }
        let thirtyDaysFromNow = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return expiryDate > Date() && expiryDate <= thirtyDaysFromNow
    }
    
    // MARK: - Network Section
    
    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("Network", icon: "antenna.radiowaves.left.and.right")
            
            if let network = device.network {
                HStack(alignment: .top, spacing: 20) {
                    VStack(spacing: 20) {
                        DetailCard(title: "Carrier Information") {
                            DetailRow("Current Carrier", network.currentCarrierNetwork ?? "N/A")
                            DetailRow("Home Carrier", network.homeCarrierNetwork ?? "N/A")
                            DetailRow("Carrier Settings", network.carrierSettingsVersion ?? "N/A")
                            DetailRow("Phone Number", network.phoneNumber ?? "N/A")
                        }
                        
                        DetailCard(title: "Cellular Identifiers") {
                            DetailRow("IMEI", network.imei ?? "N/A")
                            DetailRow("ICCID", network.iccid ?? "N/A")
                            DetailRow("MEID", network.meid ?? "N/A")
                            DetailRow("EID", network.eid ?? "N/A")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack(spacing: 20) {
                        DetailCard(title: "Network Status") {
                            securityRow("Roaming", network.roaming ?? false)
                            securityRow("Data Roaming Enabled", network.dataRoamingEnabled ?? false)
                            securityRow("Voice Roaming Enabled", network.voiceRoamingEnabled ?? false)
                            securityRow("Personal Hotspot", network.personalHotspotEnabled ?? false)
                        }
                        
                        DetailCard(title: "Mobile Network Codes") {
                            DetailRow("Current MCC", network.currentMobileCountryCode ?? "N/A")
                            DetailRow("Current MNC", network.currentMobileNetworkCode ?? "N/A")
                            DetailRow("Home MCC", network.homeMobileCountryCode ?? "N/A")
                            DetailRow("Home MNC", network.homeMobileNetworkCode ?? "N/A")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyStateView("No network information available", icon: "antenna.radiowaves.left.and.right")
            }
        }
    }
    
    // MARK: - Groups Section
    
    private var groupsSection: some View {
        let groups = device.groups ?? []
        let filteredGroupsList = filteredGroups(from: groups).sorted(by: groupSort) { group, column in
            switch column {
            case "ID": .text(group.groupId)
            case "Type": .text(group.smart == true ? "Smart Group" : "Static Group")
            default: .text(group.groupName)
            }
        }

        return InventoryCardShell {
            if groups.isEmpty {
                InventoryToolbar(title: "Group Memberships", countText: "0")
                InventoryEmptyState(icon: "person.3", title: "No Group Memberships")
            } else {
                InventoryToolbar(
                    title: "Group Memberships",
                    countText: inventoryCountText(shown: filteredGroupsList.count, total: groups.count),
                    search: Bindable(inventory.groups).searchText,
                    searchPrompt: "Search groups"
                )
                // Group type toggles
                InventoryFilterRow {
                    InventoryChip(title: "Smart", isSelected: inventory.filterSmartGroups) {
                        inventory.filterSmartGroups.toggle()
                    }
                    InventoryChip(title: "Static", isSelected: inventory.filterStaticGroups) {
                        inventory.filterStaticGroups.toggle()
                    }
                }
                InventoryHeaderRow {
                    InventoryColumns(widths: (90, 110)) {
                        SortableHeaderText("Group", key: "Group", sort: $groupSort)
                    } second: {
                        SortableHeaderText("ID", key: "ID", sort: $groupSort)
                    } third: {
                        SortableHeaderText("Type", key: "Type", sort: $groupSort)
                    }
                }
                if filteredGroupsList.isEmpty {
                    InventoryEmptyState(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "No Groups Match Filters",
                        buttonTitle: "Clear Filters"
                    ) {
                        inventory.filterSmartGroups = true
                        inventory.filterStaticGroups = true
                    }
                } else {
                    InventoryPagedRows(state: inventory.groups, rows: filteredGroupsList) { group in
                        groupRow(group)
                    }
                }
            }
        }
    }

    private func filteredGroups(from groups: [MobileDeviceGroup]) -> [MobileDeviceGroup] {
        let showSmart = inventory.filterSmartGroups
        let showStatic = inventory.filterStaticGroups
        
        // Apply search and type filters
        return inventory.groups.filter(groups) { group in
            group.smart == true ? showSmart : showStatic
        }
    }
    
    private func groupRow(_ group: MobileDeviceGroup) -> some View {
        InventoryColumns(widths: (90, 110)) {
            InventoryPrimaryCell(title: group.groupName ?? "Unknown Group", subtitle: group.groupDescription)
        } second: {
            InventoryCellText(group.groupId ?? "N/A")
        } third: {
            InventoryTag(
                text: group.smart == true ? "Smart Group" : "Static Group",
                tone: group.smart == true ? .accent : .neutral
            )
        }
    }

    // MARK: - Extension Attributes Section

    private var extensionAttributesSection: some View {
        let attrs = device.extensionAttributes ?? []
        let filteredAttrs = inventory.extensionAttributes.filter(attrs).sorted(by: attributeSort) { attr, column in
            switch column {
            case "Value": .text((attr.value ?? []).joined(separator: ", "))
            case "Type": .text(attr.type)
            default: .text(attr.name)
            }
        }

        return InventoryCardShell {
            if attrs.isEmpty {
                InventoryToolbar(title: "Extension Attributes", countText: "0")
                InventoryEmptyState(icon: "list.bullet.rectangle", title: "No Extension Attributes")
            } else {
                InventoryToolbar(
                    title: "Extension Attributes",
                    countText: inventoryCountText(shown: filteredAttrs.count, total: attrs.count),
                    search: Bindable(inventory.extensionAttributes).searchText,
                    searchPrompt: "Search attributes"
                )
                InventoryHeaderRow {
                    extensionAttributeColumns {
                        SortableHeaderText("Attribute", key: "Attribute", sort: $attributeSort)
                    } value: {
                        SortableHeaderText("Value", key: "Value", sort: $attributeSort)
                    } type: {
                        SortableHeaderText("Type", key: "Type", sort: $attributeSort)
                    }
                }
                if filteredAttrs.isEmpty {
                    InventoryEmptyState(icon: "magnifyingglass", title: "No Attributes Match Search")
                } else {
                    InventoryPagedRows(state: inventory.extensionAttributes, rows: filteredAttrs) { attr in
                        extensionAttributeRow(attr)
                    }
                }
            }
        }
    }

    /// Name and value share the width evenly — values are often long.
    private func extensionAttributeColumns<A: View, B: View, C: View>(
        @ViewBuilder name: () -> A,
        @ViewBuilder value: () -> B,
        @ViewBuilder type: () -> C
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            name().frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            value().frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            type().frame(width: 90, alignment: .trailing)
        }
    }

    private func extensionAttributeRow(_ attr: MobileDeviceExtensionAttribute) -> some View {
        let valueText = (attr.value ?? []).joined(separator: ", ")

        return extensionAttributeColumns {
            InventoryPrimaryCell(title: attr.name ?? "Unknown Attribute")
        } value: {
            if attr.value?.isEmpty ?? true {
                mutedValue("No Value")
            } else if valueText.isEmpty {
                mutedValue("Empty")
            } else {
                Text(valueText)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } type: {
            if let type = attr.type {
                InventoryTag(text: type)
            }
        }
    }

    private func mutedValue(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(FleetHubTheme.muted)
    }

    // MARK: - Purchasing Section
    
    private var purchasingSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("Purchasing", icon: "dollarsign.circle")
            
            if let purchasing = device.purchasing {
                HStack(alignment: .top, spacing: 20) {
                    DetailCard(title: "Purchase Information") {
                        DetailRow("Purchased", purchasing.purchased ?? false ? "Yes" : "No")
                        DetailRow("Leased", purchasing.leased ?? false ? "Yes" : "No")
                        DetailRow("PO Number", purchasing.poNumber ?? "N/A")
                        DetailRow("Vendor", purchasing.vendor ?? "N/A")
                        DetailRow("Purchase Price", purchasing.purchasePrice ?? "N/A")
                        DetailRow("Purchasing Account", purchasing.purchasingAccount ?? "N/A")
                        DetailRow("Purchasing Contact", purchasing.purchasingContact ?? "N/A")
                    }
                    .frame(maxWidth: .infinity)
                    
                    DetailCard(title: "Dates & Warranty") {
                        DetailRow("PO Date", formatDate(purchasing.poDate))
                        DetailRow("Warranty Expires", formatDate(purchasing.warrantyExpiresDate))
                        DetailRow("Lease Expires", formatDate(purchasing.leaseExpiresDate))
                        if let lifeExpectancy = purchasing.lifeExpectancy, lifeExpectancy > 0 {
                            DetailRow("Life Expectancy", "\(lifeExpectancy) years")
                        }
                        DetailRow("AppleCare ID", purchasing.appleCareId ?? "N/A")
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                EmptyStateView("No purchasing information", icon: "dollarsign.circle")
            }
        }
    }
    
    // MARK: - Management Section
    
    private var managementSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SectionHeader("Management", icon: "gearshape.2")
            
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    DetailCard(title: "MDM Status") {
                        DetailRow("Managed", device.managed ?? false ? "Yes" : "No")
                        DetailRow("Supervised", device.isSupervised ? "Yes" : "No")
                        DetailRow("DDM Enabled", device.declarativeDeviceManagementEnabled ?? false ? "Yes" : "No")
                        DetailRow("Enrollment Valid", device.enrollmentSessionTokenValid ?? false ? "Yes" : "No")
                    }
                    
                    DetailCard(title: "Enrollment") {
                        DetailRow("Method", device.enrollmentMethod ?? "N/A")
                        DetailRow("Device Ownership", device.deviceOwnershipLevel ?? "N/A")
                        DetailRow("Last Enrollment", formatDate(device.lastEnrollmentTimestamp))
                        DetailRow("MDM Profile Expires", formatDate(device.mdmProfileExpirationTimestamp))
                    }
                }
                .frame(maxWidth: .infinity)
                
                VStack(spacing: 20) {
                    DetailCard(title: "Site & Location") {
                        DetailRow("Site", device.site?.name ?? "None")
                        DetailRow("Site ID", device.site?.id ?? "N/A")
                        DetailRow("Time Zone", device.timeZone ?? "N/A")
                    }
                    
                    DetailCard(title: "Identifiers") {
                        DetailRow("Jamf ID", device.id)
                        DetailRow("Management ID", device.managementId ?? "N/A")
                        DetailRow("Asset Tag", device.assetTag ?? "N/A")
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func formatDate(_ dateString: String?) -> String {
        guard let dateString = dateString else { return "N/A" }
        guard let date = parseDate(dateString) else { return dateString }
        
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    /// Parses either an ISO-8601 timestamp or an epoch string. Jamf's
    /// `*Epoch` fields (e.g. `MobileDeviceCertificate.expirationDateEpoch`)
    /// arrive as a STRING holding milliseconds since 1970, not ISO-8601, so
    /// an ISO-only parser silently returns nil and empties every
    /// expiry-based filter.
    private func parseDate(_ dateString: String) -> Date? {
        let trimmed = dateString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Epoch string: digits only (optional leading minus). Jamf sends
        // milliseconds; accept seconds too so a 10-digit value still parses.
        let digits = trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        if !digits.isEmpty, digits.allSatisfy(\.isNumber), let epoch = Double(trimmed) {
            // Zero / 1970 means "unset" in Jamf — treat it as no date, matching
            // the ISO "1970-01-01T00:00:00Z" sentinel handling below.
            guard epoch != 0 else { return nil }
            // Anything beyond ~year 5138 in seconds is really milliseconds.
            let seconds = abs(epoch) >= 100_000_000_000 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }

        // Try ISO8601 with fractional seconds
        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601Formatter.date(from: trimmed) {
            return date
        }

        // Try ISO8601 without fractional seconds
        iso8601Formatter.formatOptions = [.withInternetDateTime]
        if let date = iso8601Formatter.date(from: trimmed) {
            return date
        }

        // Try epoch date format "1970-01-01T00:00:00Z"
        if trimmed == "1970-01-01T00:00:00Z" {
            return nil
        }

        return nil
    }
    
    private func formatStorage(_ mb: Int) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB", Double(mb) / 1024.0)
        }
        return "\(mb) MB"
    }
}

// MARK: - Mobile Device Section Enum

enum MobileDeviceSection: String, CaseIterable {
    case overview
    case hardware
    case security
    case userAndLocation
    case applications
    case profiles
    case certificates
    case network
    case groups
    case extensionAttributes
    case purchasing
    case management
    /// DDM enabled state and reported status items.
    case declarativeManagement
    
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .hardware: return "Hardware"
        case .security: return "Security"
        case .userAndLocation: return "User & Location"
        case .applications: return "Applications"
        case .profiles: return "Profiles"
        case .certificates: return "Certificates"
        case .network: return "Network"
        case .groups: return "Groups"
        case .extensionAttributes: return "Extension Attributes"
        case .purchasing: return "Purchasing"
        case .management: return "Management"
        case .declarativeManagement: return "Declarative Management"
        }
    }
    
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .hardware: return "cpu"
        case .security: return "shield.checkered"
        case .userAndLocation: return "person.fill"
        case .applications: return "app.badge"
        case .profiles: return "doc.badge.gearshape"
        case .certificates: return "checkmark.seal"
        case .network: return "antenna.radiowaves.left.and.right"
        case .groups: return "person.3"
        case .extensionAttributes: return "list.bullet.rectangle"
        case .purchasing: return "dollarsign.circle"
        case .management: return "gearshape.2"
        case .declarativeManagement: return "list.bullet.clipboard"
        }
    }
}

// MARK: - Mobile Device Section Groups

/// The tabs the mobile detail view groups its sections under. Every
/// `MobileDeviceSection` belongs to exactly one group.
enum MobileDeviceSectionGroup: String, CaseIterable, Identifiable {
    case overview
    case hardware
    case security
    case software
    case management

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .hardware: return "Hardware"
        case .security: return "Security"
        case .software: return "Software"
        case .management: return "Management"
        }
    }

    var sections: [MobileDeviceSection] {
        switch self {
        case .overview: return [.overview]
        case .hardware: return [.hardware, .network, .purchasing]
        case .security: return [.security, .certificates]
        case .software: return [.applications, .profiles]
        case .management: return [.userAndLocation, .groups, .extensionAttributes, .management, .declarativeManagement]
        }
    }

    static func group(for section: MobileDeviceSection) -> MobileDeviceSectionGroup {
        allCases.first { $0.sections.contains(section) } ?? .overview
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Mobile Device View") {
    MobileDeviceView(device: MobileDevice(
        id: "4",
        name: "iPhone-F17DEMO0001",
        enforceName: false,
        assetTag: nil,
        lastInventoryUpdateTimestamp: "2026-01-22T02:23:30.149Z",
        osVersion: "18.5",
        osBuild: "22F76",
        osSupplementalBuildVersion: "22F76",
        osRapidSecurityResponse: nil,
        softwareUpdateDeviceId: "iPhone17,5",
        serialNumber: "F17DEMO0001",
        udid: "00000000-0000000000000001",
        initialEntryTimestamp: "2025-10-30T19:25:58.28Z",
        ipAddress: "203.0.113.46",
        wifiMacAddress: "02:00:00:00:00:11",
        bluetoothMacAddress: "02:00:00:00:00:12",
        deviceOwnershipLevel: "Institutional",
        enrollmentMethod: "PreStage enrollment: Sample (1)",
        enrollmentSessionTokenValid: false,
        lastEnrollmentTimestamp: "2025-10-30T19:33:39.591Z",
        mdmProfileExpirationTimestamp: "2027-10-30T19:33:38Z",
        managed: true,
        timeZone: "America/New_York",
        site: MobileDeviceSite(id: "1", name: "Staging"),
        location: MobileDeviceLocation(
            username: "testuser",
            realName: "Test User",
            emailAddress: "testuser@example.com",
            position: "IT Admin",
            phoneNumber: nil,
            departmentId: nil,
            buildingId: nil,
            room: nil
        ),
        type: "ios",
        ios: MobileDeviceiOS(
            capacityMb: 131072,
            availableMb: 101673,
            percentageUsed: 22,
            model: "iPhone 16e",
            modelIdentifier: "iPhone17,5",
            modelNumber: "MD0D4LL",
            shared: false,
            supervised: true,
            batteryLevel: 85,
            batteryHealth: "NORMAL",
            lastBackupTimestamp: nil,
            deviceLocatorServiceEnabled: false,
            doNotDisturbEnabled: false,
            cloudBackupEnabled: false,
            lastCloudBackupTimestamp: nil,
            locationServicesEnabled: false,
            computer: nil,
            bleCapable: false,
            security: MobileDeviceSecurity(
                dataProtected: true,
                blockLevelEncryptionCapable: true,
                fileLevelEncryptionCapable: true,
                passcodePresent: true,
                passcodeCompliant: true,
                passcodeCompliantWithProfile: true,
                hardwareEncryption: 3,
                activationLockEnabled: false,
                jailBreakDetected: false,
                bootstrapToken: nil,
                bootstrapTokenEscrowed: nil,
                attestationStatus: "SUCCESS",
                lastAttestationAttemptDate: "2026-01-20T02:14:48.854Z",
                lastSuccessfulAttestationDate: "2026-01-20T02:14:50.435Z",
                passcodeLockGracePeriodEnforcedSeconds: nil,
                personalDeviceProfileCurrent: nil,
                lostModeEnabled: false,
                lostModePersistent: false,
                lostModeMessage: nil,
                lostModePhoneNumber: nil,
                lostModeFootnote: nil,
                lostModeLocation: nil,
                lostModeEnabledDate: nil
            ),
            purchasing: nil,
            network: nil,
            configurationProfiles: [
                MobileDeviceConfigurationProfile(displayName: "Sample Configuration", version: "1", uuid: "00000000-0000-4000-8000-000000000022", identifier: "00000000-0000-4000-8000-000000000022"),
                MobileDeviceConfigurationProfile(displayName: "MDM Profile", version: "1", uuid: "00000000-0000-0000-A000-4A414D460003", identifier: "00000000-0000-0000-A000-4A414D460003")
            ],
            attachments: nil,
            applications: [
                MobileDeviceApplication(name: "Self Service", identifier: "com.jamfsoftware.selfservice", version: "1080", shortVersion: "11.3.4", managementStatus: "Managed", validationStatus: true, bundleSize: "45.2 MB", dynamicSize: "50.1 MB"),
                MobileDeviceApplication(name: "Reset", identifier: "com.jamf.reset", version: "138", shortVersion: "3.3.2", managementStatus: "Managed", validationStatus: true, bundleSize: "12.5 MB", dynamicSize: "15.0 MB")
            ],
            certificates: [
                MobileDeviceCertificate(commonName: "Test Certificate", identity: true, expirationDate: "2027-10-30T19:33:38Z", expirationDateEpoch: "1824924818000", subjectName: "CN=Test,O=Test Org", serialNumber: "123456", sha1Fingerprint: "abc123", issuedDateEpoch: "1761766418000", certificateStatus: "ISSUED", lifecycleStatus: "ACTIVE")
            ],
            provisioningProfiles: nil,
            ebooks: nil,
            serviceSubscriptions: nil,
            mdmCapableUsers: nil,
            iTunesStoreAccountActive: false,
            unlockToken: nil
        ),
        tvos: nil,
        watchos: nil,
        visionos: nil,
        declarativeDeviceManagementEnabled: true,
        extensionAttributes: [
            MobileDeviceExtensionAttribute(id: "1", name: "Custom Attribute", type: "STRING", value: ["Test Value"], inventoryDisplay: "General", extensionAttributeCollectionAllowed: true)
        ],
        managementId: "00000000-0000-4000-8000-000000000023",
        groups: [
            MobileDeviceGroup(groupId: "5", groupName: "Sample Staging", groupDescription: "Sample staging group", smart: true),
            MobileDeviceGroup(groupId: "2", groupName: "All Managed iPhones", groupDescription: nil, smart: true)
        ]
    ))
    .frame(width: 1400, height: 900)
}
#endif
