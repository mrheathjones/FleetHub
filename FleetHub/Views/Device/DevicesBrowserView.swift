//
//  DevicesBrowserView.swift
//  FleetHub
//
//  The Devices tab: one full-width, filterable list of Macs or mobile
//  devices. Opening a row pushes that device's detail view at full width.
//  The list is built from the inventory caches; the detail views are the
//  existing DeviceView / MobileDeviceView.
//

import SwiftUI

struct DevicesBrowserView: View {
    @Binding var isInNestedView: Bool
    @EnvironmentObject var deepLinkRouter: DeepLinkRouter

    @ObservedObject private var computerCache = ComputerInventoryCache.shared
    @ObservedObject private var mobileCache = MobileDeviceInventoryCache.shared
    @ObservedObject private var healthCalculator = HealthMetricsCalculator.shared
    @StateObject private var computerService = ComputerInventoryService()
    @StateObject private var mobileService = MobileDeviceInventoryService()

    // MARK: - List state

    enum Kind: String, CaseIterable, Identifiable {
        case macs = "Macs"
        case mobile = "Mobile"
        var id: String { rawValue }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case needsAttention = "Needs Attention"
        case stale = "Stale"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .macs
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var page = 1
    @State private var items: [DeviceListItem] = []
    /// Ids of devices failing at least one health check.
    @State private var attentionIDs: Set<String> = []
    @State private var isLoadingList = false
    @FocusState private var isSearchFocused: Bool

    /// Model type filter; nil = All Models.
    @State private var selectedModel: String?
    /// Column sort. Starts on Device A–Z, the order the list always had.
    @State private var sort = TableSort<String>(key: "Device")

    // Derived state, rebuilt by `recomputeVisible()` when an input changes
    // rather than on every render: the list can hold the whole fleet.
    /// `items` after search, model and status filters, in sort order.
    @State private var visibleItems: [DeviceListItem] = []
    /// Devices per status chip, after the search and model filters.
    @State private var filterCounts: [Filter: Int] = [:]
    /// Model types in the current list (Macs or Mobile), with counts.
    @State private var modelOptions: [ModelFilter.Option] = []

    private let pageSize = 25

    /// 0 = unset → the profile's default (same rule as the Cleanup module).
    @AppStorage(CleanupSettings.Key.staleDays) private var staleDaysStored = 0
    private var staleDays: Int {
        staleDaysStored > 0 ? staleDaysStored : MDMConfigurationManager.shared.configuration.cleanupStaleDays
    }

    // MARK: - Navigation state

    @State private var navigationPath = NavigationPath()
    /// The row whose mobile record is being fetched before it can be opened.
    @State private var loadingItemID: String?
    @State private var detailError: String?

    var body: some View {
        NavigationStack(path: $navigationPath) {
            listPage
                .navigationDestination(for: Computer.self) { computer in
                    DeviceView(computer: computer)
                }
                .navigationDestination(for: MobileDevice.self) { device in
                    MobileDeviceView(device: device)
                }
        }
        .onShowTabRoot(.devices) {
            if !navigationPath.isEmpty { navigationPath = NavigationPath() }
        }
        .task { await reloadList() }
        .task(id: healthCalculator.lastCalculationDate) { recomputeAttention() }
        .onChange(of: kind) { _, _ in
            page = 1
            selectedModel = nil      // model types differ between Macs and Mobile
            rebuildItems()
        }
        .onChange(of: filter) { _, _ in page = 1; recomputeVisible() }
        .onChange(of: searchText) { _, _ in page = 1; recomputeVisible() }
        .onChange(of: selectedModel) { _, _ in page = 1; recomputeVisible() }
        .onChange(of: sort) { _, _ in page = 1; recomputeVisible() }
        .onChange(of: staleDays) { _, _ in recomputeVisible() }
        .onChange(of: computerCache.totalCount) { _, _ in rebuildItems() }
        .onChange(of: mobileCache.totalCount) { _, _ in rebuildItems() }
        .onChange(of: navigationPath.count) { _, newValue in
            // A pushed detail view hides the module's tab strip.
            withAnimation(.easeInOut(duration: 0.2)) {
                isInNestedView = newValue > 0
            }
        }
        .onAppear {
            isInNestedView = navigationPath.count > 0
            consumeDeepLinkIfPresent()
        }
        .onChange(of: deepLinkRouter.pendingRequest) { _, newValue in
            if newValue != nil { consumeDeepLinkIfPresent() }
        }
        #if DEBUG
        // Documentation aid: the snapshot walk opens the first device listed.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FleetHubSnapshotOpenDevice"))) { _ in
            if let first = pageItems.first { open(first) }
        }
        #endif
    }

    // MARK: - Filtering

    private func isStale(_ item: DeviceListItem) -> Bool {
        guard let lastCheckIn = item.lastCheckIn else { return true }
        return lastCheckIn < Date().addingTimeInterval(-Double(staleDays) * 86_400)
    }

    private func matches(_ item: DeviceListItem, _ filter: Filter) -> Bool {
        switch filter {
        case .all: return true
        case .needsAttention: return attentionIDs.contains(item.id)
        case .stale: return isStale(item)
        }
    }

    /// The status shown in the Status column, as text, for sorting.
    private func statusText(_ item: DeviceListItem) -> String {
        flag(for: item)?.title ?? "OK"
    }

    /// Rebuilds everything the table and toolbar derive from `items`.
    private func recomputeVisible() {
        // A model type that is no longer in the list (after a refresh, or a
        // switch between Macs and Mobile) falls back to All Models.
        let options = ModelFilter.options(in: items)
        modelOptions = options
        if let chosen = selectedModel, !options.contains(where: { $0.name == chosen }) {
            selectedModel = nil
            return      // the change to `selectedModel` runs this again
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let narrowed = items.filter { item in
            if let selectedModel, item.modelType != selectedModel { return false }
            guard !query.isEmpty else { return true }
            return item.name.lowercased().contains(query)
                || item.serialNumber.lowercased().contains(query)
                || (item.assignedUser?.lowercased().contains(query) ?? false)
                || item.model.lowercased().contains(query)
        }

        var counts: [Filter: Int] = [:]
        for option in Filter.allCases {
            counts[option] = option == .all ? narrowed.count : narrowed.reduce(0) { $0 + (matches($1, option) ? 1 : 0) }
        }
        filterCounts = counts

        visibleItems = narrowed.filter { matches($0, filter) }.sorted(by: sort) { item, column in
            switch column {
            case "User": .text(item.assignedUser)
            case "Model": .text(item.model)
            case "OS": .text(item.osVersion)
            case "Last Check-In": .date(item.lastCheckIn)
            case "Status": .text(statusText(item))
            default: .text(item.name)
            }
        }
    }

    private var filteredItems: [DeviceListItem] { visibleItems }

    private var pageCount: Int {
        max(1, Int(ceil(Double(filteredItems.count) / Double(pageSize))))
    }

    private var pageItems: [DeviceListItem] {
        let all = filteredItems
        let start = (min(page, pageCount) - 1) * pageSize
        guard start < all.count else { return [] }
        return Array(all[start..<min(start + pageSize, all.count)])
    }

    // MARK: - List page

    private var listPage: some View {
        VStack(spacing: 14) {
            toolbar

            if let detailError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(FleetHubTheme.warnText)
                    Text(detailError)
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") { self.detailError = nil }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FleetHubTheme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .fill(FleetHubTheme.warnFill)
                )
            }

            table
        }
        .padding(.horizontal, 28)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FleetHubTheme.ground.ignoresSafeArea())
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Macs / Mobile
            HStack(spacing: 4) {
                ForEach(Kind.allCases) { option in
                    let isSelected = kind == option
                    Button {
                        kind = option
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                            .frame(width: 92, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                                    .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FleetHubTheme.trough))

            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FleetHubTheme.muted)
                TextField("", text: $searchText, prompt: Text("Name, serial number, user, or model")
                    .foregroundColor(FleetHubTheme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.ink)
                    .focused($isSearchFocused)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
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
            .frame(maxWidth: 420)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
            )

            // Filter chips, each with its count
            HStack(spacing: 6) {
                ForEach(Filter.allCases) { option in
                    let isSelected = filter == option
                    let count = filterCounts[option] ?? 0
                    Button {
                        filter = option
                    } label: {
                        Text("\(option.rawValue) \(count.formatted())")
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? .white : FleetHubTheme.control)
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
            }

            ModelFilterMenu(options: modelOptions, selection: $selectedModel, height: 38)

            Spacer(minLength: 0)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            DeviceTableColumns(
                device: SortableHeaderText("Device", key: "Device", sort: $sort, fontSize: 12),
                user: SortableHeaderText("User", key: "User", sort: $sort, fontSize: 12),
                model: SortableHeaderText("Model", key: "Model", sort: $sort, fontSize: 12),
                os: SortableHeaderText("OS", key: "OS", sort: $sort, fontSize: 12),
                checkIn: SortableHeaderText("Last Check-In", key: "Last Check-In", sort: $sort, fontSize: 12),
                status: SortableHeaderText("Status", key: "Status", sort: $sort, fontSize: 12)
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(FleetHubTheme.ground.opacity(0.6))

            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if isLoadingList && items.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading devices…")
                                .font(.system(size: 13))
                                .foregroundColor(FleetHubTheme.muted)
                        }
                        .padding(.vertical, 40)
                    } else if pageItems.isEmpty {
                        Text(searchText.isEmpty && selectedModel == nil ? "No devices here." : "No devices match that search or filter.")
                            .font(.system(size: 13))
                            .foregroundColor(FleetHubTheme.muted)
                            .padding(.vertical, 40)
                    } else {
                        ForEach(Array(pageItems.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                                    .padding(.leading, 18)
                            }
                            DeviceTableRow(
                                item: item,
                                flag: flag(for: item),
                                isLoading: loadingItemID == item.id
                            ) {
                                open(item)
                            }
                        }
                    }
                }
            }

            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            // Paging
            HStack(spacing: 8) {
                Text(pagingSummary)
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.muted)
                    .monospacedDigit()
                Spacer(minLength: 0)
                pageButton(icon: "chevron.left", label: "Previous page", isEnabled: page > 1) { page -= 1 }
                pageButton(icon: "chevron.right", label: "Next page", isEnabled: page < pageCount) { page += 1 }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
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

    private var pagingSummary: String {
        let total = filteredItems.count
        guard total > 0 else { return "0 devices" }
        let start = (min(page, pageCount) - 1) * pageSize + 1
        let end = min(start + pageSize - 1, total)
        return "\(start.formatted())–\(end.formatted()) of \(total.formatted())"
    }

    private func pageButton(icon: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isEnabled ? FleetHubTheme.ink : FleetHubTheme.muted.opacity(0.5))
                .frame(width: 34, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(FleetHubTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    /// Stale outranks Needs Attention: a device that stopped reporting is the
    /// more useful thing to say about it.
    private func flag(for item: DeviceListItem) -> DeviceTableRow.Flag? {
        if isStale(item) { return .stale }
        if attentionIDs.contains(item.id) { return .attention }
        return nil
    }

    // MARK: - Opening a device

    private func open(_ item: DeviceListItem) {
        detailError = nil

        if item.platform == .macOS {
            // DeviceView fetches the full record itself.
            navigationPath.append(Computer.fromDeviceListItem(item))
            return
        }

        #if DEBUG
        if DemoMode.isEnabled, let demo = DemoMode.mobileDevice(id: item.originalId) {
            navigationPath.append(demo)
            return
        }
        #endif

        // Mobile detail has to be fetched before MobileDeviceView can show it.
        guard loadingItemID == nil else { return }
        loadingItemID = item.id
        Task {
            do {
                let device = try await DeviceListView.fetchMobileDeviceDetail(id: item.originalId)
                navigationPath.append(device)
            } catch {
                detailError = "Could not open \(item.name): \(error.localizedDescription)"
            }
            loadingItemID = nil
        }
    }

    /// Opens the device a deep link names (from the menu bar companion).
    private func consumeDeepLinkIfPresent() {
        guard let request = deepLinkRouter.pendingRequest else { return }
        deepLinkRouter.clearRequest()
        detailError = nil

        // Brief delay so the stack has settled before the push.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            switch request.deviceType {
            case .computer:
                let json = Data(#"{"id":"\#(request.deviceID)","udid":""}"#.utf8)
                if let stub = try? JSONDecoder().decode(Computer.self, from: json) {
                    navigationPath.append(stub)
                }
            case .mobiledevice:
                let json = Data(#"{"id":"\#(request.deviceID)"}"#.utf8)
                if let stub = try? JSONDecoder().decode(MobileDevice.self, from: json) {
                    navigationPath.append(stub)
                }
            }
        }
    }

    // MARK: - Loading

    @MainActor
    private func reloadList() async {
        isLoadingList = true
        // Both services return the cached inventory when there is one.
        await computerService.fetchAllComputers()
        await mobileService.fetchAllDevices()
        rebuildItems()
        isLoadingList = false
    }

    private func rebuildItems() {
        let built: [DeviceListItem]
        switch kind {
        case .macs:
            built = computerCache.computers.map { computer in
                DeviceListItem(
                    id: "computer-\(computer.id)",
                    originalId: computer.id,
                    name: computer.general?.name ?? "Unknown",
                    serialNumber: computer.hardware?.serialNumber ?? "N/A",
                    model: computer.hardware?.model ?? "Mac",
                    modelIdentifier: computer.hardware?.modelIdentifier,
                    osVersion: computer.operatingSystem?.version ?? "N/A",
                    assignedUser: computer.userAndLocation?.realname
                        ?? computer.userAndLocation?.username
                        ?? computer.general?.lastLoggedInUsernameBinary,
                    // Same resolver the health checks and the other lists
                    // use: falls back to the last inventory report when Jamf
                    // gives no last-contact time (it read "Never" otherwise).
                    lastCheckIn: HealthEvaluator.resolveCheckIn(
                        lastContactTime: computer.general?.lastContactTime,
                        reportDate: computer.general?.reportDate
                    ),
                    isManaged: computer.isManaged,
                    isSupervised: computer.isSupervised,
                    platform: .macOS
                )
            }
        case .mobile:
            built = mobileCache.devices.map { device in
                DeviceListItem(
                    id: "mobile-\(device.id)",
                    originalId: device.id,
                    name: device.displayName ?? "Unknown Device",
                    serialNumber: device.serialNumber ?? "N/A",
                    model: device.displayModel,
                    modelIdentifier: device.modelIdentifier,
                    osVersion: device.osVersion ?? "N/A",
                    assignedUser: device.assignedUser,
                    lastCheckIn: device.lastInventoryUpdate,
                    isManaged: device.isManaged,
                    isSupervised: device.isSupervised,
                    platform: device.platformType
                )
            }
        }
        items = built.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // Called here rather than from an onChange(of: items): comparing two
        // fleet-sized arrays on every render would cost more than it saves.
        recomputeVisible()
    }

    /// A device failing several checks is counted once.
    private func recomputeAttention() {
        var failing = Set<String>()
        for metric in HealthMetricType.allCases {
            for device in healthCalculator.getFilteredDevices(for: metric, segment: .nonCompliant) {
                failing.insert(device.id)
            }
        }
        attentionIDs = failing
        recomputeVisible()
    }
}

// MARK: - Table

/// One shared column layout for the header and every row, so they cannot
/// drift out of alignment.
private struct DeviceTableColumns<Device: View, User: View, Model: View, OS: View, CheckIn: View, Status: View>: View {
    let device: Device
    let user: User
    let model: Model
    let os: OS
    let checkIn: CheckIn
    let status: Status

    var body: some View {
        HStack(spacing: 16) {
            device.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
            user.frame(width: 150, alignment: .leading)
            model.frame(width: 200, alignment: .leading)
            os.frame(width: 70, alignment: .leading)
            checkIn.frame(width: 120, alignment: .leading)
            status.frame(width: 96, alignment: .leading)
        }
    }
}

private struct DeviceTableRow: View {
    enum Flag {
        case stale
        case attention

        var title: String {
            switch self {
            case .stale: return "Stale"
            case .attention: return "Attention"
            }
        }
    }

    let item: DeviceListItem
    let flag: Flag?
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false

    private func cell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(FleetHubTheme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        Button(action: action) {
            DeviceTableColumns(
                device: HStack(spacing: 10) {
                    DeviceIconView(modelIdentifier: item.modelIdentifier, modelName: item.model,
                                   platform: item.platform, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(FleetHubTheme.ink)
                            .lineLimit(1)
                        Text(item.serialNumber)
                            .font(.system(size: 11))
                            .foregroundColor(FleetHubTheme.muted)
                            .lineLimit(1)
                    }
                },
                user: cell(item.assignedUser ?? "—"),
                model: cell(item.model),
                os: cell(item.osVersion),
                checkIn: cell(item.lastCheckIn?.formatted(.relative(presentation: .named)) ?? "Never"),
                status: HStack(spacing: 6) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else if let flag {
                        Text(flag.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(FleetHubTheme.warnText)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(FleetHubTheme.warnFill))
                    } else {
                        Text("OK")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(FleetHubTheme.goodText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(FleetHubTheme.goodFill))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(FleetHubTheme.muted)
                }
            )
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(isHovered ? FleetHubTheme.ground.opacity(0.7) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
