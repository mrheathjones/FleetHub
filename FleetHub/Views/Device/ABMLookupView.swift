//
//  ABMLookupView.swift
//  FleetHub
//
//  Apple Business Manager org-inventory lookup. Renders the full ABM device
//  sweep from ABMDeviceCache (populated on demand via ABMAPIService: MDM
//  server list → org device sweep → deviceId→serverId assignment map), with
//  search over serial / model / asset tag, Assigned/Unassigned filter chips,
//  a per-MDM-server filter menu, and a detail sheet that lazily fetches
//  AppleCare coverage per device. Asset tags come from a serial→assetTag
//  join against the Jamf computer inventory cache — ABM itself carries no
//  asset tags. If the core domain's appleBusinessManager block is not
//  delivered by profile, the whole tab is a not-configured notice.
//

import SwiftUI

// MARK: - Assignment Filter

private enum ABMAssignmentFilter: String, CaseIterable, Identifiable {
    case all
    case assigned
    case unassigned

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .assigned: return "Assigned"
        case .unassigned: return "Unassigned"
        }
    }
}

// MARK: - ABM Lookup View

struct ABMLookupView: View {
    @ObservedObject private var abmService = ABMAPIService.shared
    @ObservedObject private var cache = ABMDeviceCache.shared
    /// Observed so assign/unassign gates re-evaluate on role change.
    @ObservedObject private var session = UserSession.shared

    @State private var searchText = ""
    @State private var assignmentFilter: ABMAssignmentFilter = .all
    @State private var selectedServerId: String?
    @State private var selectedDeviceType: ABMDeviceType = .all
    @State private var selectedDevice: ABMOrgDevice?
    @State private var isLoading = false
    @State private var loadError: String?

    /// Config-profile default filters (defaultMdmServerName / defaultDeviceType)
    /// are a STARTING POINT applied once — after that the operator's choices
    /// stand, so we never re-override a filter they cleared. Tracked
    /// INDEPENDENTLY: device type has no dependency and applies immediately,
    /// while the server default must wait for the server list to resolve its
    /// name→id. A shared flag made a configured server default (with a slow or
    /// failed server-list load) also swallow the device-type default.
    @State private var didApplyDefaultDeviceType = false
    @State private var didApplyDefaultServer = false

    // Assign / unassign flow state
    @State private var assignSheetDevice: ABMOrgDevice?
    @State private var unassignConfirmDevice: ABMOrgDevice?
    @State private var isUnassigning = false
    @State private var actionResultTitle: String?
    @State private var actionResultMessage = ""
    @State private var actionResultSuccess = false

    /// serial (uppercased) → asset tag, joined from the Jamf computer
    /// inventory cache. Rebuilt on load/refresh — never inside `body`,
    /// where an O(n) sweep per evaluation would be far too hot.
    @State private var assetTagsBySerial: [String: String] = [:]

    @FocusState private var isSearchFocused: Bool

    /// Width of the table card; decides which optional columns fit.
    @State private var tableWidth: CGFloat = 0

    // MARK: - Derived Data

    /// `cache.devices` after the assignment / server / device-type filters and
    /// the search query. Stored rather than computed: `body` reads it in
    /// several places per render, and recomputing an O(n) sweep over the
    /// whole ABM org on each read is far too hot. Rebuilt by
    /// `recomputeDerivedData()` whenever one of its inputs changes.
    @State private var filteredDevices: [ABMOrgDevice] = []

    /// Number of devices in `cache.devices` with an MDM-server assignment.
    /// Stored for the same reason: the filter chips read it several times
    /// per render.
    @State private var assignedCount: Int = 0

    /// Column sort from the table headers; nil key = Apple's own order.
    @State private var sort = TableSort<String>()

    private func recomputeDerivedData() {
        assignedCount = cache.devices.filter { $0.isAssigned }.count
        filteredDevices = computeFilteredDevices().sorted(by: sort) { device, column in
            switch column {
            case "Asset Tag": .text(assetTagsBySerial[device.serialNumber.uppercased()])
            case "MDM Server": .text(device.isAssigned ? cache.assignedServer(forDeviceId: device.id)?.serverName : nil)
            case "Added": .date(device.addedToOrgDate)
            case "Status": .flag(device.isAssigned)
            default: .text(device.serialNumber)
            }
        }
    }

    private func computeFilteredDevices() -> [ABMOrgDevice] {
        let query = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return cache.devices.filter { device in
            switch assignmentFilter {
            case .all:
                break
            case .assigned:
                if !device.isAssigned { return false }
            case .unassigned:
                if device.isAssigned { return false }
            }

            if let serverId = selectedServerId,
               cache.assignmentMap[device.id] != serverId {
                return false
            }

            if !selectedDeviceType.matches(productFamily: device.productFamily) {
                return false
            }

            if !query.isEmpty {
                let assetTag = assetTagsBySerial[device.serialNumber.uppercased()] ?? ""
                let matches = device.serialNumber.lowercased().contains(query)
                    || (device.deviceModel ?? "").lowercased().contains(query)
                    || assetTag.lowercased().contains(query)
                if !matches { return false }
            }

            return true
        }
    }

    private var unassignedCount: Int {
        cache.devices.count - assignedCount
    }

    private func count(for filter: ABMAssignmentFilter) -> Int {
        switch filter {
        case .all: return cache.devices.count
        case .assigned: return assignedCount
        case .unassigned: return unassignedCount
        }
    }

    private var selectedServerName: String? {
        guard let id = selectedServerId else { return nil }
        return cache.mdmServers.first { $0.id == id }?.serverName
    }

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || assignmentFilter != .all || selectedServerId != nil || selectedDeviceType != .all
    }

    /// Device types actually present in the inventory, in enum order, always
    /// including .all. Keeps the menu honest — no "iPad" option for a Mac-only
    /// org — while a configured default that no longer matches still resolves
    /// harmlessly to showing everything.
    private var availableDeviceTypes: [ABMDeviceType] {
        ABMDeviceType.allCases.filter { type in
            type == .all || cache.devices.contains { type.matches(productFamily: $0.productFamily) }
        }
    }

    // MARK: - Body

    var body: some View {
        // Same page frame as the Devices tab, so the module's three tabs
        // read as one screen: toolbar, then one table card.
        VStack(spacing: 14) {
            if !abmService.isConfigured {
                notConfiguredView
            } else {
                toolbarSection
                tableCard
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FleetHubTheme.ground.ignoresSafeArea())
        .task {
            recomputeDerivedData()
            rebuildAssetTagMap()
            applyConfigDefaultsIfNeeded()
            // Gate on isCacheValid, not hasCachedData: a tenant whose ABM
            // org is genuinely empty would otherwise re-sweep on every
            // tab entry (hasCachedData requires a non-empty device list).
            if abmService.isConfigured && !cache.isCacheValid && !isLoading {
                await loadInventory()
            }
            // Servers may have just landed via loadInventory — resolve a
            // configured default-server name now that the list exists.
            applyConfigDefaultsIfNeeded()
        }
        // The preload can populate the server list after this view's first
        // .task ran; re-attempt default resolution when it arrives.
        .onChange(of: cache.mdmServers.count) { _, _ in
            applyConfigDefaultsIfNeeded()
        }
        // Every input of the derived list / assigned count. Each fires the
        // one O(n) sweep; nothing in `body` sweeps the org inventory itself.
        .onChange(of: cache.devices) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: cache.assignmentMap) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: assetTagsBySerial) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: sort) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: searchText) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: assignmentFilter) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: selectedServerId) { _, _ in
            recomputeDerivedData()
        }
        .onChange(of: selectedDeviceType) { _, _ in
            recomputeDerivedData()
        }
        .sheet(item: $selectedDevice) { device in
            ABMDeviceDetailSheet(
                device: device,
                assignedServer: cache.assignedServer(forDeviceId: device.id),
                assetTag: assetTagsBySerial[device.serialNumber.uppercased()],
                canAssign: canAssign(device),
                canUnassign: canUnassign(device),
                // The detail sheet must close before the assign sheet /
                // confirmation can present — only one sheet may be up at a
                // time, so hand off on the next runloop pass.
                onAssign: {
                    selectedDevice = nil
                    Task { @MainActor in assignSheetDevice = device }
                },
                onUnassign: {
                    selectedDevice = nil
                    Task { @MainActor in unassignConfirmDevice = device }
                }
            )
        }
        .sheet(item: $assignSheetDevice) { device in
            ABMAssignmentSheet(
                serialNumber: device.serialNumber,
                deviceName: device.deviceModel ?? device.serialNumber,
                title: ActionBranding.label(for: .abmAssign),
                policyProvider: { policy(for: device) },
                onFinished: { success, _, error in
                    logAction(.abmAssign, device: device, success: success, error: error)
                }
            )
        }
        .confirmationDialog(
            DeviceAction.abmUnassign.title,
            isPresented: Binding(
                get: { unassignConfirmDevice != nil },
                set: { if !$0 { unassignConfirmDevice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Unassign", role: .destructive) {
                if let device = unassignConfirmDevice {
                    unassignConfirmDevice = nil
                    Task { await executeUnassign(device) }
                }
            }
            Button("Cancel", role: .cancel) { unassignConfirmDevice = nil }
        } message: {
            Text(DeviceAction.abmUnassign.message)
        }
        .alert(
            actionResultTitle ?? "",
            isPresented: Binding(
                get: { actionResultTitle != nil },
                set: { if !$0 { actionResultTitle = nil } }
            )
        ) {
            Button("OK") { actionResultTitle = nil }
        } message: {
            Text(actionResultMessage)
        }
    }

    // MARK: - Data Loading

    /// Full inventory load: server list → device sweep → assignment map,
    /// then one atomic cache update. @MainActor because ABMDeviceCache is
    /// main-actor isolated; the service calls themselves hop off to await.
    @MainActor
    private func loadInventory() async {
        guard abmService.isConfigured else { return }
        // Reentrancy guard: Try Again / empty-state Refresh can be clicked
        // while a sweep is already running — never stack a second sweep.
        guard !isLoading else { return }

        isLoading = true
        loadError = nil

        do {
            try await cache.loadFromNetwork()
            rebuildAssetTagMap()
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    /// Rebuilds the serial→assetTag join from the Jamf computer inventory
    /// cache. O(n) over the computer list, run only on load/refresh.
    @MainActor
    private func rebuildAssetTagMap() {
        var map: [String: String] = [:]
        let computers = ComputerInventoryCache.shared.computers
        map.reserveCapacity(computers.count)

        for computer in computers {
            if let serial = computer.hardware?.serialNumber,
               let assetTag = computer.general?.assetTag,
               !assetTag.isEmpty {
                map[serial.uppercased()] = assetTag
            }
        }

        assetTagsBySerial = map
    }

    /// Applies the config-profile default filters ONCE each, independently.
    /// Device type applies immediately (no dependency). The server default is
    /// named and needs the server list to resolve name→id, so it applies as
    /// soon as the list is present (re-attempted via the onChange below); a
    /// configured name that matches nothing settles on "Any Server". Called on
    /// appear, after a load, and whenever the server count changes.
    @MainActor
    private func applyConfigDefaultsIfNeeded() {
        let config = MDMConfigurationManager.shared.configuration

        if !didApplyDefaultDeviceType {
            selectedDeviceType = ABMDeviceType.from(config.abmDefaultDeviceType)
            didApplyDefaultDeviceType = true
            AppLog.notice("ABM: Applied default device-type filter '\(selectedDeviceType.rawValue)' (config: \(config.abmDefaultDeviceType ?? "nil"))")
        }

        if !didApplyDefaultServer {
            guard let name = config.abmDefaultMdmServerName else {
                didApplyDefaultServer = true  // none configured — nothing to do
                return
            }
            // Need the server list to resolve the name; retry when it arrives.
            guard !cache.mdmServers.isEmpty else { return }

            if let match = cache.mdmServers.first(where: {
                $0.serverName.caseInsensitiveCompare(name) == .orderedSame
            }) {
                selectedServerId = match.id
                AppLog.notice("ABM: Applied default MDM server filter '\(name)' → id \(match.id)")
            } else {
                AppLog.notice("ABM: Default MDM server '\(name)' matched no server in the \(cache.mdmServers.count) loaded — leaving 'Any Server'")
            }
            didApplyDefaultServer = true
        }
    }

    @MainActor
    private func refresh() async {
        // Deliberately NOT cache.clearCache() first: loadInventory commits
        // atomically on success, so fetching before swapping keeps the
        // last-known-good inventory on screen through a failed refresh.
        // Only the AppleCare coverage cache is dropped up front (stale
        // coverage is the one thing a refresh must not preserve).
        ABMAPIService.shared.clearCache()
        cache.invalidateCache()
        await loadInventory()
    }

    // MARK: - Toolbar Section

    /// The toolbar never compresses its controls: `ViewThatFits` picks the
    /// widest arrangement that fits intact, then progressively stacks rows as
    /// the window narrows. Every leaf is `.fixedSize()`d so SwiftUI can't
    /// "solve" a tight layout by squeezing chip labels into vertical text.
    private var toolbarSection: some View {
        ViewThatFits(in: .horizontal) {
            // Widest: one row — search, chips, menus, refresh.
            HStack(spacing: 12) {
                searchField.frame(width: 300)
                filterChipsRow
                serverFilterMenu
                deviceTypeFilterMenu
                Spacer(minLength: 8)
                refreshButton
            }

            // Medium: search and refresh on one row, filters below.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    searchField
                    refreshButton
                }
                HStack(spacing: 12) {
                    filterChipsRow
                    serverFilterMenu
                    deviceTypeFilterMenu
                    Spacer(minLength: 0)
                }
            }

            // Narrow: chips, then menus, then search.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    searchField
                    refreshButton
                }
                filterChipsRow
                HStack(spacing: 10) {
                    serverFilterMenu
                    deviceTypeFilterMenu
                    Spacer(minLength: 0)
                }
            }

            // Narrowest: one control per row.
            VStack(alignment: .leading, spacing: 10) {
                searchField
                filterChipsRow
                serverFilterMenu
                deviceTypeFilterMenu
                refreshButton
            }
        }
    }

    /// Refresh — clears the cache and reloads.
    private var refreshButton: some View {
        RefreshButton(isLoading: isLoading) {
            Task { await refresh() }
        }
        .fixedSize()
    }

    private var filterChipsRow: some View {
        HStack(spacing: 6) {
            ForEach(ABMAssignmentFilter.allCases) { filter in
                filterChip(
                    title: filter.title,
                    count: count(for: filter),
                    isSelected: assignmentFilter == filter
                ) {
                    assignmentFilter = filter
                }
            }
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(FleetHubTheme.muted)

            TextField("", text: $searchText, prompt: Text("Serial number, model, or asset tag")
                .foregroundColor(FleetHubTheme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.ink)
                .focused($isSearchFocused)
                .frame(minWidth: 140)

            if !searchText.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        searchText = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
        )
    }

    private func menuLabel(icon: String, title: String, isActive: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(isActive ? FleetHubTheme.accent : FleetHubTheme.muted)
        }
        .foregroundColor(isActive ? FleetHubTheme.accent : FleetHubTheme.control)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(isActive ? FleetHubTheme.accent.opacity(0.12) : FleetHubTheme.surface))
        .overlay(Capsule().stroke(isActive ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1))
        .contentShape(Capsule())
    }

    private var serverFilterMenu: some View {
        Menu {
            Button("Any Server") {
                selectedServerId = nil
            }

            if !cache.mdmServers.isEmpty {
                Divider()

                ForEach(cache.mdmServers) { server in
                    Button {
                        selectedServerId = server.id
                    } label: {
                        if selectedServerId == server.id {
                            Label(server.serverName, systemImage: "checkmark")
                        } else {
                            Text(server.serverName)
                        }
                    }
                }
            }
        } label: {
            menuLabel(
                icon: "server.rack",
                title: selectedServerName ?? "Any Server",
                isActive: selectedServerId != nil
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only devices assigned to one MDM server")
    }

    private var deviceTypeFilterMenu: some View {
        Menu {
            ForEach(availableDeviceTypes) { type in
                Button {
                    selectedDeviceType = type
                } label: {
                    if selectedDeviceType == type {
                        Label(type.title, systemImage: "checkmark")
                    } else {
                        Text(type.title)
                    }
                }
            }
        } label: {
            menuLabel(
                icon: selectedDeviceType.icon,
                title: selectedDeviceType.title,
                isActive: selectedDeviceType != .all
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show only one kind of device")
    }

    private func filterChip(title: String, count: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(title) \(count.formatted())")
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : FleetHubTheme.control)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Capsule().fill(isSelected ? FleetHubTheme.accentFill : FleetHubTheme.surface))
                .overlay(Capsule().stroke(isSelected ? Color.clear : FleetHubTheme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Table

    /// Below this table width the two labelled action buttons start fighting
    /// the device metadata for the same space, so the buttons collapse to
    /// icon-only (tooltip + accessibility label keep the meaning).
    private static let iconOnlyActionsWidthThreshold: CGFloat = 860

    private var columnLayout: ABMColumnLayout {
        ABMColumnLayout(
            showsAssetTag: tableWidth >= 980,
            showsAdded: tableWidth >= 1100,
            showsServer: tableWidth >= 700
        )
    }

    private var tableCard: some View {
        let layout = columnLayout
        let iconOnlyActions = tableWidth < Self.iconOnlyActionsWidthThreshold

        return VStack(spacing: 0) {
            ABMTableColumns(
                layout: layout,
                device: SortableHeaderText("Device", key: "Device", sort: $sort, fontSize: 12),
                assetTag: SortableHeaderText("Asset Tag", key: "Asset Tag", sort: $sort, fontSize: 12),
                server: SortableHeaderText("MDM Server", key: "MDM Server", sort: $sort, fontSize: 12),
                added: SortableHeaderText("Added", key: "Added", sort: $sort, fontSize: 12),
                status: SortableHeaderText("Status", key: "Status", sort: $sort, fontSize: 12),
                actions: Text("")
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(FleetHubTheme.ground.opacity(0.6))

            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            if isLoading && cache.devices.isEmpty {
                loadingView
            } else if let error = loadError, cache.devices.isEmpty {
                errorView(error: error)
            } else if cache.devices.isEmpty {
                emptyStateView
            } else if filteredDevices.isEmpty {
                emptySearchView
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredDevices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 {
                                Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                                    .padding(.leading, 18)
                            }
                            ABMDeviceRow(
                                device: device,
                                layout: layout,
                                serverName: cache.assignedServer(forDeviceId: device.id)?.serverName,
                                assetTag: assetTagsBySerial[device.serialNumber.uppercased()],
                                canAssign: canAssign(device),
                                canUnassign: canUnassign(device),
                                iconOnlyActions: iconOnlyActions,
                                onAssign: { assignSheetDevice = device },
                                onUnassign: { unassignConfirmDevice = device },
                                onTap: { selectedDevice = device }
                            )
                            .contextMenu { actionMenuItems(for: device) }
                        }
                    }
                }
            }

            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            tableFooter
        }
        .readWidth(into: $tableWidth)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    private var tableFooter: some View {
        HStack(spacing: 8) {
            Text(countSummary)
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: 8)

            if let lastFetch = cache.lastFetchDate {
                // Date + time: this inventory can be served from a
                // persisted cache written on an earlier launch, so
                // show how old it actually is, not just the time.
                Text("Updated \(lastFetch.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 48)
    }

    private var countSummary: String {
        let total = cache.devices.count
        if hasActiveFilters {
            return "\(filteredDevices.count.formatted()) of \(total.formatted()) Shown"
        }
        return "\(total.formatted()) Devices in Apple Business Manager"
    }

    // MARK: - Assign / Unassign Actions

    /// Policy for THIS device's platform: Macs consult the computer action
    /// grants, known non-Mac families the mobile-device grants. A device
    /// whose family is missing entirely gets .denyAll — when the platform
    /// cannot be determined, no policy branch may be assumed (fail-closed).
    private func policy(for device: ABMOrgDevice) -> DeviceActionPolicy {
        guard let family = device.productFamily,
              !family.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .denyAll
        }
        let config = MDMConfigurationManager.shared.configuration
        if family.caseInsensitiveCompare("Mac") == .orderedSame {
            return config.computerActionPolicy(capabilities: session.capabilities)
        }
        return config.mobileDeviceActionPolicy(capabilities: session.capabilities)
    }

    /// Single source of truth for whether the assign affordance is offered —
    /// shared by the inline row buttons, the detail sheet, and the context
    /// menu so the three can never drift apart.
    private func canAssign(_ device: ABMOrgDevice) -> Bool {
        policy(for: device).isAllowed(.abmAssign)
    }

    private func canUnassign(_ device: ABMOrgDevice) -> Bool {
        policy(for: device).isAllowed(.abmUnassign) && cache.assignmentMap[device.id] != nil
    }

    @ViewBuilder
    private func actionMenuItems(for device: ABMOrgDevice) -> some View {
        let devicePolicy = policy(for: device)
        if devicePolicy.isAllowed(.abmAssign) {
            Button {
                assignSheetDevice = device
            } label: {
                Label(ActionBranding.label(for: .abmAssign), systemImage: ActionBranding.icon(for: .abmAssign))
            }
        }
        if devicePolicy.isAllowed(.abmUnassign), cache.assignmentMap[device.id] != nil {
            Button(role: .destructive) {
                unassignConfirmDevice = device
            } label: {
                Label(ActionBranding.label(for: .abmUnassign), systemImage: ActionBranding.icon(for: .abmUnassign))
            }
        }
    }

    /// Unassigns `device` from its current server — the same rules as the
    /// Device Details flow: the grant's allowedMdmServers governs which
    /// servers the operator may unassign FROM, and the policy is re-checked
    /// here (defense in depth), never trusted from the menu.
    @MainActor
    private func executeUnassign(_ device: ABMOrgDevice) async {
        guard !isUnassigning else { return }
        let devicePolicy = policy(for: device)
        if devicePolicy.denialReason(for: .abmUnassign) != nil {
            // Defense-in-depth denial: surface AND audit-log it — never a
            // silent drop. Gating is role-only now, so the reason is always
            // the role capability.
            showResult(false, "Action Not Permitted",
                       "Unassigning from an MDM server is not available for your role.")
            logAction(.abmUnassign, device: device, success: false,
                      error: "Blocked by role capability (no held role grants 'abmUnassign' on computers)")
            return
        }

        isUnassigning = true
        defer { isUnassigning = false }

        do {
            let servers = try await ABMAssignmentExecutor.loadServers()
            guard let current = try await ABMAssignmentExecutor.currentServer(for: device, servers: servers) else {
                showResult(false, "Unassign from MDM Server",
                           "The device is not assigned to any MDM server — there is nothing to unassign.")
                return
            }

            guard devicePolicy.canAssignToMdmServer(named: current.serverName) else {
                showResult(false, "Not Permitted",
                           "Your role's grant does not permit unassigning devices from \(current.serverName).")
                logAction(.abmUnassign, device: device, success: false,
                          error: "Denied by allowedMdmServers for server \(current.serverName)")
                return
            }

            let outcome = try await ABMAPIService.shared.performAssignment(
                .unassignDevices, deviceId: device.id, mdmServerId: current.id
            )
            switch outcome {
            case .succeeded:
                cache.applyAssignment(deviceId: device.id, serverId: nil)
                showResult(true, "Unassigned from \(current.serverName)",
                           "Until the device is reassigned, it cannot enroll via Automated Device Enrollment.")
                logAction(.abmUnassign, device: device, success: true, error: nil)
            case .completedWithErrors(let detail):
                showResult(false, "Completed With Errors", detail)
                logAction(.abmUnassign, device: device, success: false, error: "COMPLETED_WITH_ERROR")
            case .failed(let status):
                showResult(false, "Unassign Failed", "Apple Business Manager reported the activity as \(status).")
                logAction(.abmUnassign, device: device, success: false, error: status)
            case .stillRunning(let activityId):
                showResult(false, "Still Processing",
                           "Apple accepted the request but it had not completed when polling stopped (activity \(activityId)). Refresh shortly to confirm.")
                logAction(.abmUnassign, device: device, success: false, error: "Timed out polling \(activityId)")
            }
        } catch {
            showResult(false, "Unassign Failed", error.localizedDescription)
            logAction(.abmUnassign, device: device, success: false, error: error.localizedDescription)
        }
    }

    @MainActor
    private func showResult(_ success: Bool, _ title: String, _ message: String) {
        actionResultSuccess = success
        actionResultTitle = title
        actionResultMessage = message
    }

    private func logAction(_ action: DeviceAction, device: ABMOrgDevice, success: Bool, error: String?) {
        ActionLogService.shared.logAction(
            actionName: action.logName,
            actionCategory: action.logCategory,
            deviceName: device.deviceModel ?? device.serialNumber,
            deviceSerialNumber: device.serialNumber,
            deviceId: device.id,
            devicePlatform: device.productFamily?.caseInsensitiveCompare("Mac") == .orderedSame ? "macOS" : (device.productFamily ?? "Unknown"),
            success: success,
            errorMessage: error
        )
    }

    // MARK: - States

    /// One centred message, used inside the table card (and on its own when
    /// the integration is not configured).
    private func stateMessage<Actions: View>(
        icon: String,
        iconColor: Color = FleetHubTheme.muted,
        title: String,
        message: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundColor(iconColor)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(FleetHubTheme.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            actions()
                .padding(.top, 6)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Not Configured

    private var notConfiguredView: some View {
        stateMessage(
            icon: "apple.logo",
            title: "Apple Business Manager Is Not Configured",
            message: "ABM lookups require the core domain's appleBusinessManager block and its credentials private key, delivered by configuration profile. Contact your administrator to enable the integration."
        ) { EmptyView() }
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading Apple Business Manager Inventory…")
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(error: String) -> some View {
        stateMessage(
            icon: "exclamationmark.triangle.fill",
            iconColor: FleetHubTheme.badText,
            title: "Unable to Load ABM Inventory",
            message: error
        ) {
            Button {
                Task {
                    await loadInventory()
                }
            } label: {
                SettingsButtonLabel(text: "Try Again", kind: .primary, icon: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Empty States

    /// Empty ORG INVENTORY — ABM answered but returned no devices.
    private var emptyStateView: some View {
        stateMessage(
            icon: "apple.logo",
            title: "No Devices in Apple Business Manager",
            message: "The organization's ABM inventory is empty.\nDevices will appear here once added to Apple Business Manager."
        ) {
            Button {
                Task {
                    await refresh()
                }
            } label: {
                SettingsButtonLabel(text: "Refresh", kind: .primary, icon: "arrow.clockwise")
            }
            .buttonStyle(.plain)
        }
    }

    /// Empty SEARCH RESULT — inventory exists, filters matched nothing.
    private var emptySearchView: some View {
        stateMessage(
            icon: "magnifyingglass",
            title: "No Matching Devices",
            message: "None of the \(cache.devices.count.formatted()) devices in Apple Business Manager match the current search and filters."
        ) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    searchText = ""
                    assignmentFilter = .all
                    selectedServerId = nil
                    selectedDeviceType = .all
                }
            } label: {
                SettingsButtonLabel(text: "Clear Filters", icon: "xmark.circle")
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Product Family Icon

/// SF Symbol for an ABM productFamily string. Shared by the row and the
/// detail sheet.
private func abmFamilyIcon(for productFamily: String?) -> String {
    let family = (productFamily ?? "").lowercased()
    if family.contains("iphone") { return "iphone" }
    if family.contains("ipad") { return "ipad" }
    if family.contains("tv") { return "appletv" }
    if family.contains("watch") { return "applewatch" }
    if family.contains("vision") { return "visionpro" }
    if family.contains("mac") { return "laptopcomputer" }
    return "questionmark.square"
}

// MARK: - Table Columns

/// Which optional columns the table currently has room for. The header and
/// every row share one value, so they can never disagree.
private struct ABMColumnLayout: Equatable {
    let showsAssetTag: Bool
    let showsAdded: Bool
    let showsServer: Bool
}

private struct ABMTableColumns<Device: View, AssetTag: View, Server: View, Added: View, Status: View, Actions: View>: View {
    let layout: ABMColumnLayout
    let device: Device
    let assetTag: AssetTag
    let server: Server
    let added: Added
    let status: Status
    let actions: Actions

    var body: some View {
        HStack(spacing: 16) {
            device.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            if layout.showsAssetTag {
                assetTag.frame(width: 110, alignment: .leading)
            }
            if layout.showsServer {
                server.frame(width: 180, alignment: .leading)
            }
            if layout.showsAdded {
                added.frame(width: 104, alignment: .leading)
            }
            status.frame(width: 96, alignment: .leading)
            actions
        }
    }
}

/// Assigned / Unassigned capsule shared by the row and the detail sheet.
private struct ABMStatusTag: View {
    let isAssigned: Bool

    var body: some View {
        Text(isAssigned ? "Assigned" : "Unassigned")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(isAssigned ? FleetHubTheme.goodText : FleetHubTheme.warnText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(isAssigned ? FleetHubTheme.goodFill : FleetHubTheme.warnFill))
    }
}

// MARK: - ABM Device Row

private struct ABMDeviceRow: View {
    let device: ABMOrgDevice
    let layout: ABMColumnLayout
    let serverName: String?
    let assetTag: String?
    /// Role-gated: mirrors the same policy check that governs the context menu.
    let canAssign: Bool
    let canUnassign: Bool
    /// Collapses the action buttons to their glyphs when the list is too
    /// narrow to carry the labels alongside the device metadata.
    let iconOnlyActions: Bool
    let onAssign: () -> Void
    let onUnassign: () -> Void
    let onTap: () -> Void

    @State private var isHovered = false

    private var subtitle: String {
        var parts: [String] = []
        if let model = device.deviceModel { parts.append(model) }
        if let color = device.color, !color.isEmpty { parts.append(color.capitalized) }
        return parts.joined(separator: " · ")
    }

    private func cell(_ text: String?) -> some View {
        Text(text ?? "—")
            .font(.system(size: 13))
            .foregroundColor(text == nil ? FleetHubTheme.muted : FleetHubTheme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        // NOTE: this is a tap-gesture container, not a Button — the row holds
        // real Buttons (Assign / Unassign) and nested buttons inside a Button
        // label do not reliably receive their own clicks on macOS.
        ABMTableColumns(
            layout: layout,
            device: HStack(spacing: 10) {
                Image(systemName: abmFamilyIcon(for: device.productFamily))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(FleetHubTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(FleetHubTheme.accent.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.serialNumber)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FleetHubTheme.ink)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(FleetHubTheme.muted)
                            .lineLimit(1)
                    }
                }
            },
            assetTag: cell(assetTag),
            server: cell(device.isAssigned ? serverName : nil),
            added: cell(device.addedToOrgDate?.formatted(date: .abbreviated, time: .omitted)),
            status: ABMStatusTag(isAssigned: device.isAssigned),
            // Role-gated actions — visible affordances, not hidden behind
            // the right-click menu (which stays as a secondary path).
            actions: HStack(spacing: 6) {
                if canAssign {
                    ABMActionButton(
                        title: ActionBranding.label(for: .abmAssign),
                        systemImage: ActionBranding.icon(for: .abmAssign),
                        isDestructive: false,
                        compact: true,
                        iconOnly: iconOnlyActions,
                        action: onAssign
                    )
                }
                if canUnassign {
                    ABMActionButton(
                        title: ActionBranding.label(for: .abmUnassign),
                        systemImage: ActionBranding.icon(for: .abmUnassign),
                        isDestructive: true,
                        compact: true,
                        iconOnly: iconOnlyActions,
                        action: onUnassign
                    )
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(FleetHubTheme.muted)
                    .padding(.leading, 4)
            }
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(isHovered ? FleetHubTheme.ground.opacity(0.7) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - ABM Action Button

/// A real, obviously-clickable button for the ABM assign/unassign actions:
/// outlined, with the destructive one in the warning colour, so it never
/// reads as a plain clickable label.
private struct ABMActionButton: View {
    let title: String
    let systemImage: String
    let isDestructive: Bool
    var compact: Bool = false
    /// Glyph only — the label moves to the tooltip and the accessibility
    /// label, so the control stays legible to VoiceOver when it collapses.
    var iconOnly: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    private var ink: Color { isDestructive ? FleetHubTheme.badText : FleetHubTheme.ink }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                if !iconOnly {
                    Text(title)
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .foregroundColor(ink)
            .padding(.horizontal, iconOnly ? 9 : (compact ? 11 : 14))
            .frame(height: compact ? 28 : 36)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(
                RoundedRectangle(cornerRadius: compact ? 9 : FleetHubTheme.controlRadius, style: .continuous)
                    .fill(isHovered ? FleetHubTheme.ground : FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 9 : FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(isDestructive ? FleetHubTheme.badText.opacity(0.35) : FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - ABM Device Detail Sheet

private struct ABMDeviceDetailSheet: View {
    let device: ABMOrgDevice
    let assignedServer: ABMMdmServer?
    let assetTag: String?
    /// Role-gated by the caller with the same policy the row and menu use.
    let canAssign: Bool
    let canUnassign: Bool
    let onAssign: () -> Void
    let onUnassign: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var coverages: [AppleCareCoverage] = []
    @State private var isLoadingCoverage = true
    @State private var coverageUnavailable = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: abmFamilyIcon(for: device.productFamily))
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(FleetHubTheme.accent)
                    .frame(width: 64, height: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(FleetHubTheme.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.serialNumber)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(FleetHubTheme.ink)
                        .textSelection(.enabled)

                    if let model = device.deviceModel {
                        Text(model)
                            .font(.system(size: 13))
                            .foregroundColor(FleetHubTheme.muted)
                    }

                    ABMStatusTag(isAssigned: device.isAssigned)
                        .padding(.top, 2)
                }

                Spacer(minLength: 8)

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FleetHubTheme.control)
                        .frame(width: 30, height: 30)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(FleetHubTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(22)

            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            // Content
            ScrollView {
                VStack(spacing: 14) {
                    deviceCard
                    identifiersCard
                    assignmentCard
                    datesCard
                    appleCareCard
                }
                .padding(20)
                .textSelection(.enabled)
            }
            .background(FleetHubTheme.ground)

            if canAssign || canUnassign {
                Rectangle().fill(FleetHubTheme.border).frame(height: 1)

                HStack(spacing: 10) {
                    if canUnassign {
                        ABMActionButton(
                            title: ActionBranding.label(for: .abmUnassign),
                            systemImage: ActionBranding.icon(for: .abmUnassign),
                            isDestructive: true,
                            action: onUnassign
                        )
                    }
                    if canAssign {
                        Button(action: onAssign) {
                            SettingsButtonLabel(
                                text: ActionBranding.label(for: .abmAssign),
                                kind: .primary,
                                icon: ActionBranding.icon(for: .abmAssign)
                            )
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                    .fill(FleetHubTheme.accentFill)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 540, height: 660)
        .background(FleetHubTheme.surface)
        .task {
            await loadCoverage()
        }
    }

    // MARK: - Cards

    private var deviceCard: some View {
        DetailCard(title: "Device", icon: abmFamilyIcon(for: device.productFamily)) {
            VStack(spacing: 12) {
                if let model = device.deviceModel {
                    DetailRow("Model", model)
                }

                if let family = device.productFamily {
                    DetailRow("Product Family", family)
                }

                if let productType = device.productType {
                    DetailRow("Product Type", productType, monospaced: true)
                }

                if let capacity = device.deviceCapacity {
                    DetailRow("Capacity", capacity)
                }

                if let color = device.color, !color.isEmpty {
                    DetailRow("Color", color.capitalized)
                }
            }
        }
    }

    private var identifiersCard: some View {
        DetailCard(title: "Identifiers", icon: "number") {
            VStack(spacing: 12) {
                DetailRow("Serial Number", device.serialNumber, monospaced: true)

                if let assetTag {
                    DetailRow("Asset Tag", assetTag)
                }
            }
        }
    }

    private var assignmentCard: some View {
        DetailCard(title: "Assignment", icon: "server.rack") {
            VStack(spacing: 12) {
                HStack {
                    // Same label column as DetailRow so the badge lines up
                    // with the values below it.
                    Text("Status")
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.muted)
                        .frame(width: 180, alignment: .leading)

                    ABMStatusTag(isAssigned: device.isAssigned)

                    Spacer()
                }

                if let server = assignedServer {
                    DetailRow("MDM Server", server.serverName)

                    if let serverType = server.serverType {
                        DetailRow("Server Type", serverType)
                    }
                }
            }
        }
    }

    private var datesCard: some View {
        DetailCard(title: "Dates", icon: "calendar") {
            VStack(spacing: 12) {
                if let added = formatISODate(device.addedToOrgDateTime) {
                    DetailRow("Added to Org", added)
                }

                if let updated = formatISODate(device.updatedDateTime) {
                    DetailRow("Last Updated", updated)
                }

                if let ordered = formatISODate(device.orderDateTime) {
                    DetailRow("Order Date", ordered)
                }

                if let orderNumber = device.orderNumber, !orderNumber.isEmpty {
                    DetailRow("Order Number", orderNumber, monospaced: true)
                }
            }
        }
    }

    private var appleCareCard: some View {
        DetailCard(title: "AppleCare", icon: "cross.case") {
            VStack(spacing: 12) {
                if isLoadingCoverage {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking Coverage…")
                            .font(.system(size: 13))
                            .foregroundColor(FleetHubTheme.muted)
                        Spacer()
                    }
                } else if coverageUnavailable {
                    HStack {
                        Text("AppleCare Information Unavailable")
                            .font(.system(size: 13))
                            .foregroundColor(FleetHubTheme.muted)
                        Spacer()
                    }
                } else if coverages.isEmpty {
                    HStack {
                        Text("No Coverage Records for This Device")
                            .font(.system(size: 13))
                            .foregroundColor(FleetHubTheme.muted)
                        Spacer()
                    }
                } else {
                    ForEach(coverages) { coverage in
                        coverageRow(coverage)

                        if coverage.id != coverages.last?.id {
                            Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func coverageRow(_ coverage: AppleCareCoverage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(coverage.description)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FleetHubTheme.ink)

                Text(coverage.isActive ? "Active" : "Inactive")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(coverage.isActive ? FleetHubTheme.goodText : FleetHubTheme.control)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(coverage.isActive ? FleetHubTheme.goodFill : FleetHubTheme.trough))

                Spacer()
            }

            if let end = coverage.endDate {
                HStack(spacing: 6) {
                    Text("Ends \(end.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 12))
                        .foregroundColor(FleetHubTheme.muted)

                    if let days = coverage.daysRemaining {
                        Text("•")
                            .foregroundColor(FleetHubTheme.muted)

                        if coverage.isExpired {
                            Text("Expired \(-days) day\(days == -1 ? "" : "s") ago")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(FleetHubTheme.badText)
                        } else {
                            Text("\(days) day\(days == 1 ? "" : "s") remaining")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(coverage.isExpiringSoon ? FleetHubTheme.warnText : FleetHubTheme.muted)
                        }
                    }
                }
            }
        }
    }

    // MARK: - AppleCare Loading

    /// Fail-soft: coverage is a nice-to-have on top of the org record, so
    /// any error collapses to a plain "unavailable" line, never an alert.
    @MainActor
    private func loadCoverage() async {
        isLoadingCoverage = true
        coverageUnavailable = false

        do {
            coverages = try await ABMAPIService.shared.getAppleCareCoverage(forSerialNumber: device.serialNumber)
        } catch {
            coverageUnavailable = true
        }

        isLoadingCoverage = false
    }

    // MARK: - Card Helpers

    private func formatISODate(_ isoString: String?) -> String? {
        guard let date = ABMDateParser.date(from: isoString) else { return nil }
        return Self.displayFormatter.string(from: date)
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Preview

#if DEBUG
#Preview("ABM Lookup") {
    ABMLookupView()
        .frame(width: 1200, height: 800)
}
#endif
