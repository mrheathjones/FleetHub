//
//  DeviceListView.swift
//  FleetHub
//
//  Displays a paginated list of all devices for a specific platform type
//

import SwiftUI
// AppKit removed - using pure SwiftUI

struct DeviceListView: View {
    let platform: PlatformType
    @Binding var navigationPath: NavigationPath
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText: String = ""
    @State private var sortOrder: DeviceSortOrder = .nameAscending
    /// Column sort from the table headers. Starts on Device A–Z; rows that
    /// tie on the chosen column stay in name order.
    @State private var columnSort = TableSort<String>(key: "Device")
    /// Model type filter; nil = All Models.
    @State private var selectedModel: String?
    @State private var modelOptions: [ModelFilter.Option] = []
    @State private var isLoading: Bool = false
    @State private var devices: [DeviceListItem] = []
    @State private var loadError: String?
    
    // Platform filter (only used when platform == .all)
    @State private var selectedPlatformFilter: PlatformType = .all
    
    // Pagination state
    @State private var currentPage: Int = 1
    @State private var itemsPerPage: Int = 25
    @State private var totalDeviceCount: Int = 0
    
    @FocusState private var isSearchFocused: Bool
    
    // Services for fetching devices
    @StateObject private var computerInventoryService = ComputerInventoryService()
    @StateObject private var mobileDeviceService = MobileDeviceInventoryService()
    
    // Mobile device detail fetching
    @State private var isLoadingDeviceDetail: Bool = false
    @State private var loadingDeviceId: String?
    
    private let itemsPerPageOptions = [10, 25, 50, 100]
    
    // Show platform filter only when viewing all devices
    private var showPlatformFilter: Bool {
        platform == .all
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection

            // Error banner
            if let error = loadError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text("Error loading devices: \(error)")
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        loadDevices()
                    } label: {
                        Text("Retry")
                            .font(.system(size: 13, weight: .semibold))
                            .underline()
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(FleetHubTheme.warnText)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FleetHubTheme.warnFill))
            }

            VStack(spacing: 0) {
                toolbarSection
                columnHeader

                if isLoading {
                    loadingView
                } else if filteredDevices.isEmpty {
                    emptyStateView
                } else {
                    deviceListSection
                }

                if !filteredDevices.isEmpty {
                    paginationFooter
                }
            }
            .readWidth(into: $cardWidth)
            .background(FleetHubTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FleetHubTheme.ground.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .onAppear {
            recomputeFilteredDevices()
            loadDevices()
        }
        .onChange(of: itemsPerPage) { _, _ in
            currentPage = 1
        }
        .onChange(of: selectedPlatformFilter) { _, _ in
            currentPage = 1
            recomputeFilteredDevices()
        }
        // The derived list is stored, not computed: `body` reads it through
        // totalPages / paginatedDevices / startItemIndex / endItemIndex several
        // times per render, and a computed property would re-filter and
        // re-sort the whole fleet on each of those reads.
        .onChange(of: devices) { _, _ in
            recomputeFilteredDevices()
        }
        .onChange(of: searchText) { _, _ in
            recomputeFilteredDevices()
        }
        .onChange(of: sortOrder) { _, _ in
            recomputeFilteredDevices()
        }
        .onChange(of: columnSort) { _, _ in
            currentPage = 1
            recomputeFilteredDevices()
        }
        .onChange(of: selectedModel) { _, _ in
            currentPage = 1
            recomputeFilteredDevices()
        }
    }

    // MARK: - Derived List

    /// `devices` after the platform filter, search filter and sort. Rebuilt by
    /// `recomputeFilteredDevices()` whenever one of its inputs changes.
    @State private var filteredDevices: [DeviceListItem] = []

    private func recomputeFilteredDevices() {
        var filtered = devices

        // Apply platform filter if showing all devices
        if platform == .all && selectedPlatformFilter != .all {
            filtered = filtered.filter { $0.platform == selectedPlatformFilter }
        }

        // Apply search filter
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.serialNumber.localizedCaseInsensitiveContains(searchText) ||
                ($0.assignedUser ?? "").localizedCaseInsensitiveContains(searchText) ||
                $0.model.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Model types come from the platform-filtered list, before search, so
        // the menu shows what can be chosen rather than what already matched.
        let modelSource = platform == .all && selectedPlatformFilter != .all
            ? devices.filter { $0.platform == selectedPlatformFilter } : devices
        let options = ModelFilter.options(in: modelSource)
        modelOptions = options
        if let chosen = selectedModel, !options.contains(where: { $0.name == chosen }) {
            // Gone after a refresh or a platform change: back to All Models.
            // The change to `selectedModel` runs this again.
            selectedModel = nil
            return
        }
        if let selectedModel {
            filtered = filtered.filter { $0.modelType == selectedModel }
        }

        // Name order first, then the chosen column on top (stable sort).
        filteredDevices = filtered.sorted(by: sortOrder.comparator).sorted(by: columnSort) { device, column in
            switch column {
            case "User": .text(device.assignedUser)
            case "Model": .text(device.model)
            case "OS": .text("\(device.platform.rawValue) \(device.osVersion)")
            case "Last Check-In": .date(device.lastCheckIn)
            default: .text(device.name)
            }
        }
    }

    // MARK: - Computed Properties

    private var totalPages: Int {
        max(1, Int(ceil(Double(filteredDevices.count) / Double(itemsPerPage))))
    }
    
    private var paginatedDevices: [DeviceListItem] {
        let startIndex = (currentPage - 1) * itemsPerPage
        let endIndex = min(startIndex + itemsPerPage, filteredDevices.count)
        
        guard startIndex < filteredDevices.count else { return [] }
        return Array(filteredDevices[startIndex..<endIndex])
    }
    
    private var startItemIndex: Int {
        (currentPage - 1) * itemsPerPage + 1
    }
    
    private var endItemIndex: Int {
        min(currentPage * itemsPerPage, filteredDevices.count)
    }
    
    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                dismiss()
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
            .help("Back")
            .accessibilityLabel("Back")

            VStack(alignment: .leading, spacing: 4) {
                Text(platform == .all ? "All Devices" : "\(platform.rawValue) Devices")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)

                Text("\(filteredDevices.count.formatted()) devices")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(FleetHubTheme.muted)
            }

            Spacer(minLength: 16)

            // Refresh button
            RefreshButton(isLoading: isLoading) {
                loadDevices(forceRefresh: true)
            }
        }
    }

    // MARK: - Platform Filter Menu

    private func menuLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .foregroundStyle(FleetHubTheme.ink)
        .padding(.horizontal, 12)
        .frame(height: 36)
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

    private var platformFilterMenu: some View {
        Menu {
            ForEach(PlatformType.filterCases) { filterPlatform in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedPlatformFilter = filterPlatform
                    }
                } label: {
                    HStack {
                        Image(systemName: filterPlatform.icon)
                        Text(filterPlatform == .all ? "All Platforms" : filterPlatform.rawValue)
                        if selectedPlatformFilter == filterPlatform {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            menuLabel(
                selectedPlatformFilter == .all ? "All Platforms" : selectedPlatformFilter.rawValue,
                icon: selectedPlatformFilter.icon
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: - Toolbar Section

    private var toolbarSection: some View {
        HStack(spacing: 10) {
            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.muted)

                TextField("", text: $searchText, prompt: Text("Name, serial number, user, or model")
                    .foregroundColor(FleetHubTheme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .focused($isSearchFocused)
                    .onChange(of: searchText) { _, _ in
                        currentPage = 1
                    }

                if !searchText.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            searchText = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(minWidth: 160, maxWidth: 360)
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
            )

            // Platform filter (only for All Devices view)
            if showPlatformFilter {
                platformFilterMenu
            }

            ModelFilterMenu(options: modelOptions, selection: $selectedModel)

            Spacer(minLength: 8)

            if !searchText.isEmpty || selectedModel != nil || (platform == .all && selectedPlatformFilter != .all) {
                Text("\(filteredDevices.count) of \(devices.count) Shown")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Columns

    @State private var cardWidth: CGFloat = 0

    private var showsModel: Bool { cardWidth >= 980 }
    private var showsUser: Bool { cardWidth >= 760 }

    private func columns<Device: View, User: View, Model: View, OS: View, CheckIn: View>(
        @ViewBuilder device: () -> Device,
        @ViewBuilder user: () -> User,
        @ViewBuilder model: () -> Model,
        @ViewBuilder os: () -> OS,
        @ViewBuilder checkIn: () -> CheckIn
    ) -> some View {
        HStack(spacing: 14) {
            device().frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            if showsUser {
                user().frame(width: 160, alignment: .leading)
            }
            if showsModel {
                model().frame(width: 200, alignment: .leading)
            }
            os().frame(width: 120, alignment: .leading)
            checkIn().frame(width: 110, alignment: .leading)
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func headerText(_ title: String) -> some View {
        SortableHeaderText(title, key: title, sort: $columnSort)
    }

    private var columnHeader: some View {
        columns(
            device: { headerText("Device") },
            user: { headerText("User") },
            model: { headerText("Model") },
            os: { headerText("OS") },
            checkIn: { headerText("Last Check-In") }
        )
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(FleetHubTheme.ground)
    }

    private func cell(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 13))
            .foregroundStyle(FleetHubTheme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    // MARK: - Device List Section
    
    private var deviceListSection: some View {
        ZStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(paginatedDevices) { device in
                        DeviceListTableRow(
                            isLoading: isLoadingDeviceDetail && loadingDeviceId == device.id,
                            action: { handleDeviceTap(device) }
                        ) {
                            columns(
                                device: {
                                    HStack(spacing: 12) {
                                        DeviceIconView(
                                            modelIdentifier: device.modelIdentifier,
                                            modelName: device.model,
                                            platform: device.platform,
                                            size: 32
                                        )
                                        .frame(width: 32, height: 32)

                                        VStack(alignment: .leading, spacing: 1) {
                                            HStack(spacing: 6) {
                                                Text(device.name)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(FleetHubTheme.ink)
                                                    .lineLimit(1)
                                                if !device.isManaged {
                                                    Text("Unmanaged")
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .foregroundStyle(FleetHubTheme.warnText)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 1)
                                                        .background(Capsule().fill(FleetHubTheme.warnFill))
                                                        .fixedSize()
                                                }
                                            }
                                            Text(device.serialNumber)
                                                .font(.system(size: 11))
                                                .foregroundStyle(FleetHubTheme.muted)
                                                .lineLimit(1)
                                        }
                                    }
                                },
                                user: { cell(device.assignedUser ?? "Unassigned") },
                                model: { cell(device.model) },
                                os: { cell("\(device.platform.rawValue) \(device.osVersion)") },
                                checkIn: { cell(device.lastCheckInFormatted) }
                            )
                        }
                        Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                    }
                }
            }

            // Loading overlay when fetching device details
            if isLoadingDeviceDetail {
                FleetHubTheme.surface.opacity(0.7)

                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading Device Details…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FleetHubTheme.ink)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func handleDeviceTap(_ device: DeviceListItem) {
        // Check if this is a mobile device (iOS, iPadOS, visionOS)
        if device.platform == .iOS || device.platform == .iPadOS || device.platform == .visionOS {
            // Fetch full mobile device details
            fetchMobileDeviceAndNavigate(device)
        } else {
            // It's a computer - create Computer object and navigate
            let computer = Computer.fromDeviceListItem(device)
            navigationPath.append(computer)
        }
    }
    
    private func fetchMobileDeviceAndNavigate(_ device: DeviceListItem) {
        isLoadingDeviceDetail = true
        loadingDeviceId = device.id
        
        Task {
            do {
                let mobileDevice = try await Self.fetchMobileDeviceDetail(id: device.originalId)
                
                await MainActor.run {
                    isLoadingDeviceDetail = false
                    loadingDeviceId = nil
                    navigationPath.append(mobileDevice)
                }
            } catch {
                await MainActor.run {
                    isLoadingDeviceDetail = false
                    loadingDeviceId = nil
                    loadError = "Failed to load device details: \(error.localizedDescription)"
                }
            }
        }
    }
    
    /// Static so the Devices split view can fetch a mobile record the same way.
    static func fetchMobileDeviceDetail(id: String) async throws -> MobileDevice {
        let jamfURL = MDMConfigurationManager.shared.configuration.jamfURL

        // Cached bearer token, routed per the profile's credential routing
        // for the device-search scope (master or per-user client).
        let token = try await JamfTokenProvider.token(for: .deviceSearch)

        // Fetch mobile device detail
        let sections = [
            "GENERAL", "HARDWARE", "USER_AND_LOCATION", "PURCHASING", "SECURITY",
            "APPLICATIONS", "EBOOKS", "NETWORK", "SERVICE_SUBSCRIPTIONS",
            "CERTIFICATES", "PROFILES", "GROUPS", "EXTENSION_ATTRIBUTES"
        ]
        
        let sectionParams = sections.map { "section=\($0)" }.joined(separator: "&")
        let endpoint = "/api/v2/mobile-devices/\(id)/detail"
        
        guard let url = URL(string: "\(jamfURL)\(endpoint)?\(sectionParams)") else {
            throw NSError(domain: "DeviceList", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid device URL"])
        }
        
        AppLog.notice("📥 DeviceListView: Fetching mobile device detail from \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "DeviceList", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        AppLog.notice("📥 DeviceListView: Mobile device detail response status \(httpResponse.statusCode)")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            // 404 is genuinely "not found"; everything else (401 after a token
            // revocation, 403 missing privilege, 500) gets Jamf's own message so
            // the operator sees the real cause instead of a bogus "not found".
            let message: String
            if httpResponse.statusCode == 404 {
                message = "Device not found (HTTP 404)"
            } else {
                message = JamfErrorFormatter.message(
                    status: httpResponse.statusCode,
                    body: data,
                    fallbackAction: "load the mobile device details"
                )
            }
            AppLog.error("❌ DeviceListView: Mobile device detail error (HTTP \(httpResponse.statusCode)): \(message)")
            throw NSError(domain: "DeviceList", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        
        let device = try JSONDecoder().decode(MobileDevice.self, from: data)
        return device
    }
    
    // MARK: - Pagination Footer
    
    private var paginationFooter: some View {
        HStack(spacing: 6) {
            Text("Showing \(startItemIndex)–\(endItemIndex) of \(filteredDevices.count)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)

            Menu {
                ForEach(itemsPerPageOptions, id: \.self) { count in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            itemsPerPage = count
                        }
                    } label: {
                        HStack {
                            Text("\(count) per page")
                            if itemsPerPage == count {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("\(itemsPerPage) per Page")
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                .foregroundStyle(FleetHubTheme.control)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FleetHubTheme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(FleetHubTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.leading, 8)

            Spacer(minLength: 12)

            pageButton("chevron.left.2", label: "First Page", enabled: currentPage > 1) {
                currentPage = 1
            }
            pageButton("chevron.left", label: "Previous Page", enabled: currentPage > 1) {
                currentPage = max(1, currentPage - 1)
            }

            pageNumbers

            pageButton("chevron.right", label: "Next Page", enabled: currentPage < totalPages) {
                currentPage = min(totalPages, currentPage + 1)
            }
            pageButton("chevron.right.2", label: "Last Page", enabled: currentPage < totalPages) {
                currentPage = totalPages
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(FleetHubTheme.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
        }
    }

    private func pageButton(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { action() }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.control)
                .frame(width: 36, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FleetHubTheme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(FleetHubTheme.border, lineWidth: 1)
                )
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var pageNumbers: some View {
        let visiblePages = calculateVisiblePages()

        HStack(spacing: 4) {
            ForEach(Array(visiblePages.enumerated()), id: \.offset) { _, page in
                if page == -1 {
                    Text("…")
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .frame(width: 24, height: 32)
                } else {
                    let isCurrent = page == currentPage
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentPage = page
                        }
                    } label: {
                        Text("\(page)")
                            .font(.system(size: 13, weight: isCurrent ? .semibold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(isCurrent ? FleetHubTheme.accent : FleetHubTheme.control)
                            .frame(minWidth: 32)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isCurrent ? FleetHubTheme.accent.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Page \(page)")
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
        }
    }

    private func calculateVisiblePages() -> [Int] {
        if totalPages <= 7 {
            return Array(1...totalPages)
        }
        
        var pages: [Int] = []
        
        if currentPage <= 3 {
            pages = [1, 2, 3, 4, -1, totalPages]
        } else if currentPage >= totalPages - 2 {
            pages = [1, -1, totalPages - 3, totalPages - 2, totalPages - 1, totalPages]
        } else {
            pages = [1, -1, currentPage - 1, currentPage, currentPage + 1, -1, totalPages]
        }
        
        return pages
    }
    
    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Devices…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        let unfiltered = searchText.isEmpty && selectedPlatformFilter == .all
        return VStack(spacing: 8) {
            Image(systemName: unfiltered ? platform.icon : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)

            Text(unfiltered ? "No Devices Found" : "No Results")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)

            Text(unfiltered
                 ? "There are no \(platform.rawValue) devices enrolled."
                 : "No devices match your search criteria.")
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)

            if !searchText.isEmpty || selectedPlatformFilter != .all {
                Button {
                    searchText = ""
                    selectedPlatformFilter = .all
                } label: {
                    SettingsButtonLabel(text: "Clear Filters")
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load Devices
    
    private func loadDevices(forceRefresh: Bool = false) {
        isLoading = true
        currentPage = 1
        loadError = nil
        
        Task {
            await loadAllDevicesFromCache(forceRefresh: forceRefresh)
        }
    }
    
    @MainActor
    private func loadAllDevicesFromCache(forceRefresh: Bool = false) async {
        var allDevices: [DeviceListItem] = []
        
        // Determine what to load based on platform
        let needsComputers = platform == .macOS || platform == .all
        let needsMobileDevices = platform == .iOS || platform == .iPadOS || platform == .visionOS || platform == .all
        
        // Get computer cache
        let computerCache = ComputerInventoryCache.shared
        let mobileCache = MobileDeviceInventoryCache.shared
        
        // Load computers from cache if needed
        if needsComputers {
            if forceRefresh || !computerCache.hasCachedData {
                // Only fetch if forced or no cache - uses master API
                await computerInventoryService.fetchAllComputers(forceRefresh: forceRefresh)
            }
            
            if computerInventoryService.errorMessage == nil || computerCache.hasCachedData {
                // Use cache data (populated either now or at app launch)
                let computers = computerCache.computers
                let computerDevices = computers.map { computer in
                    DeviceListItem(
                        id: "computer-\(computer.id)",
                        originalId: computer.id,
                        name: computer.general?.name ?? "Unknown",
                        serialNumber: computer.hardware?.serialNumber ?? "N/A",
                        model: computer.hardware?.model ?? "Mac",
                        modelIdentifier: computer.hardware?.modelIdentifier,
                        osVersion: computer.operatingSystem?.version ?? "N/A",
                        assignedUser: computer.userAndLocation?.realname ?? computer.userAndLocation?.username ?? computer.general?.lastLoggedInUsernameBinary,
                        lastCheckIn: computer.lastContactTime,
                        isManaged: computer.isManaged,
                        isSupervised: computer.isSupervised,
                        platform: .macOS
                    )
                }
                allDevices.append(contentsOf: computerDevices)
            } else if let error = computerInventoryService.errorMessage {
                loadError = parseAPIError(error)
            }
        }
        
        // Load mobile devices from cache if needed
        if needsMobileDevices {
            if forceRefresh || !mobileCache.hasCachedData {
                // Only fetch if forced or no cache - uses master API
                await mobileDeviceService.fetchAllDevices(forceRefresh: forceRefresh)
            }
            
            if mobileDeviceService.errorMessage == nil || mobileCache.hasCachedData {
                // Use cache data (populated either now or at app launch)
                let mobileDevicesToAdd: [MobileDeviceInventoryItem]
                if platform == .all {
                    mobileDevicesToAdd = mobileCache.devices
                } else {
                    mobileDevicesToAdd = mobileCache.devices.filter { $0.platformType == platform }
                }
                
                let mobileListItems = mobileDevicesToAdd.map { device in
                    DeviceListItem(
                        id: "mobile-\(device.id ?? "unknown")",
                        originalId: device.id ?? "unknown",
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
                allDevices.append(contentsOf: mobileListItems)
            } else if let error = mobileDeviceService.errorMessage, loadError == nil {
                loadError = parseAPIError(error)
            }
        }
        
        // Sort the combined list
        devices = sortDevices(allDevices)
        totalDeviceCount = devices.count
        isLoading = false
    }
    
    /// Parse API error JSON for cleaner display
    private func parseAPIError(_ error: String) -> String {
        // Try to extract meaningful message from JSON error
        if error.contains("INVALID_PRIVILEGE") {
            return "Permission denied. Please verify API client privileges in Jamf Pro."
        }
        
        // Try to parse JSON error
        if let data = error.data(using: .utf8) {
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [[String: Any]],
                   let firstError = errors.first,
                   let code = firstError["code"] as? String,
                   let description = firstError["description"] as? String {
                    return "\(code): \(description)"
                }
            } catch {
                // Not JSON, return original
            }
        }
        
        return error
    }
    
    private func sortDevices(_ deviceList: [DeviceListItem]) -> [DeviceListItem] {
        deviceList.sorted(by: sortOrder.comparator)
    }
    
}

// MARK: - Row

private struct DeviceListTableRow<Content: View>: View {
    let isLoading: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .overlay(alignment: .trailing) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.muted)
                    }
                }
                .padding(.horizontal, 20)
                .frame(minHeight: 52)
                .background(isHovered ? FleetHubTheme.ground.opacity(0.7) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Device List - All with Filter") {
    @Previewable @State var path = NavigationPath()
    DeviceListView(platform: .all, navigationPath: $path)
        .frame(width: 1200, height: 800)
}
#endif
