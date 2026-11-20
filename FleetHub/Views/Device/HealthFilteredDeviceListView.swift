//
//  HealthFilteredDeviceListView.swift
//  FleetHub
//

//
//  Displays devices filtered by health metric status (compliant, non-compliant, unknown)
//

import SwiftUI
// AppKit removed - using pure SwiftUI

// MARK: - Health Filtered Device List View

struct HealthFilteredDeviceListView: View {
    let healthItem: HealthNavigationItem
    @Binding var navigationPath: NavigationPath
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText: String = ""
    @State private var sortOrder: DeviceSortOrder = .nameAscending
    /// Column sort from the table headers. Starts on Device A–Z; rows that
    /// tie on the chosen column stay in name order.
    @State private var columnSort = TableSort<String>(key: "Device")
    @State private var isLoading: Bool = false
    @State private var devices: [DeviceListItem] = []
    
    // Platform filter
    @State private var selectedPlatformFilter: PlatformType = .all
    
    // Pagination state
    @State private var currentPage: Int = 1
    @State private var itemsPerPage: Int = 25
    
    // Device detail loading state
    @State private var isLoadingDeviceDetail: Bool = false
    @State private var loadingDeviceId: String? = nil
    @State private var loadError: String? = nil
    
    @FocusState private var isSearchFocused: Bool
    @State private var cardWidth: CGFloat = 1100
    
    private let itemsPerPageOptions = [10, 25, 50, 100]
    
    private var statusIcon: String {
        switch healthItem.segmentType {
        case .compliant:
            return "checkmark.circle.fill"
        case .nonCompliant:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }
    
    /// Good / warn / bad token pair for the segment this list shows.
    private var statusInk: Color {
        switch healthItem.segmentType {
        case .compliant: FleetHubTheme.goodText
        case .nonCompliant: FleetHubTheme.badText
        case .unknown: FleetHubTheme.warnText
        }
    }

    private var statusFill: Color {
        switch healthItem.segmentType {
        case .compliant: FleetHubTheme.goodFill
        case .nonCompliant: FleetHubTheme.badFill
        case .unknown: FleetHubTheme.warnFill
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerSection

            VStack(spacing: 0) {
                toolbarSection
                HealthDeviceColumns(
                    device: columnTitle("Device"),
                    user: columnTitle("User"),
                    model: columnTitle("Model"),
                    os: columnTitle("OS"),
                    checkIn: columnTitle("Last Check-In"),
                    compact: cardWidth < 900
                )
                .padding(.horizontal, 20)
                .frame(height: 36)
                .background(FleetHubTheme.ground)

                if isLoading {
                    loadingView
                } else if filteredDevices.isEmpty {
                    emptyStateView
                } else {
                    deviceListSection
                }

                paginationFooter
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
        // re-sort the whole list on each of those reads.
        .onChange(of: devices) { _, _ in
            recomputeFilteredDevices()
        }
        .onChange(of: searchText) { _, _ in
            currentPage = 1
            recomputeFilteredDevices()
        }
        .onChange(of: columnSort) { _, _ in
            currentPage = 1
            recomputeFilteredDevices()
        }
        .onChange(of: sortOrder) { _, _ in
            recomputeFilteredDevices()
        }
    }

    // MARK: - Derived List

    /// `devices` after the platform filter, search filter and sort. Rebuilt by
    /// `recomputeFilteredDevices()` whenever one of its inputs changes.
    @State private var filteredDevices: [DeviceListItem] = []

    private func recomputeFilteredDevices() {
        var filtered = devices

        // Apply platform filter
        if selectedPlatformFilter != .all {
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
        filteredDevices.isEmpty ? 0 : (currentPage - 1) * itemsPerPage + 1
    }
    
    private var endItemIndex: Int {
        min(currentPage * itemsPerPage, filteredDevices.count)
    }
    
    // MARK: - Header Section

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                navigationPath.removeLast()
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
                HStack(spacing: 10) {
                    Text(healthItem.title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    HStack(spacing: 5) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 10, weight: .bold))
                        Text("\(healthItem.percentageDisplay)%")
                            .font(.system(size: 12, weight: .bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(statusInk)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(statusFill))
                    .fixedSize()
                }

                Text("\(healthItem.metricType.rawValue) · \(healthItem.deviceCount == 1 ? "1 device" : "\(healthItem.deviceCount) devices")")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
            }

            Spacer(minLength: 12)

            RefreshButton(isLoading: isLoading) {
                refreshDevices()
            }
        }
    }

    // MARK: - Toolbar Section

    private func menuLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.ink)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
        }
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

    private var searchField: some View {
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

            if !searchText.isEmpty {
                Button {
                    searchText = ""
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
        .frame(minWidth: 160, maxWidth: 340)
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
        )
    }

    private var toolbarMenus: some View {
        HStack(spacing: 8) {
            // Platform filter
            Menu {
                ForEach(PlatformType.filterCases, id: \.self) { platform in
                    Button {
                        selectedPlatformFilter = platform
                    } label: {
                        HStack {
                            Image(systemName: platform.icon)
                            Text(platform.rawValue)
                            if selectedPlatformFilter == platform {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                menuLabel(selectedPlatformFilter == .all ? "All Platforms" : selectedPlatformFilter.rawValue,
                          icon: selectedPlatformFilter.icon)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()

            // Items per page
            Menu {
                ForEach(itemsPerPageOptions, id: \.self) { count in
                    Button {
                        itemsPerPage = count
                    } label: {
                        HStack {
                            Text("\(count) Per Page")
                            if itemsPerPage == count {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                menuLabel("\(itemsPerPage) Per Page", icon: "list.number")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var toolbarSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                searchField
                Spacer(minLength: 8)
                toolbarMenus
            }
            VStack(alignment: .leading, spacing: 10) {
                searchField
                toolbarMenus
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func columnTitle(_ title: String) -> some View {
        SortableHeaderText(title, key: title, sort: $columnSort)
    }

    // MARK: - Device List Section

    private var deviceListSection: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(paginatedDevices) { device in
                    HealthDeviceListRow(
                        device: device,
                        healthItem: healthItem,
                        isLoading: loadingDeviceId == device.id,
                        compact: cardWidth < 900
                    ) {
                        handleDeviceTap(device)
                    }
                    Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            // Error banner
            if let error = loadError {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                    Text(error)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    Button {
                        loadError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                }
                .foregroundStyle(FleetHubTheme.warnText)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(FleetHubTheme.warnFill))
                .padding(16)
            }
        }
    }

    // MARK: - Device Navigation
    
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
                let mobileDevice = try await fetchMobileDeviceDetail(id: device.originalId)
                
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
    
    private func fetchMobileDeviceDetail(id: String) async throws -> MobileDevice {
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
            throw NSError(domain: "HealthFilteredDeviceList", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid device URL"])
        }
        
        AppLog.notice("📥 HealthFilteredDeviceListView: Fetching mobile device detail from \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "HealthFilteredDeviceList", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        AppLog.notice("📥 HealthFilteredDeviceListView: Mobile device detail response status \(httpResponse.statusCode)")
        
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
            AppLog.error("❌ HealthFilteredDeviceListView: Mobile device detail error (HTTP \(httpResponse.statusCode)): \(message)")
            throw NSError(domain: "HealthFilteredDeviceList", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        
        let device = try JSONDecoder().decode(MobileDevice.self, from: data)
        guard SiteScopeStore.includes(device) else { throw SiteScopeStore.outOfScopeError }
        return device
    }
    
    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading Devices…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State View

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? statusIcon : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)

            Text(searchText.isEmpty ? "No Devices Found" : "No Matching Devices")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)

            Text(searchText.isEmpty
                 ? "No devices match this health metric filter."
                 : "Try adjusting your search or filters.")
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)

            if !searchText.isEmpty {
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

    // MARK: - Pagination Footer

    private var paginationFooter: some View {
        HStack(spacing: 12) {
            Text(filteredDevices.isEmpty
                 ? "No Devices"
                 : "Showing \(startItemIndex)–\(endItemIndex) of \(filteredDevices.count)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                // First page
                healthPaginationButton(icon: "chevron.left.2", label: "First Page", isEnabled: currentPage > 1) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentPage = 1
                    }
                }

                // Previous page
                healthPaginationButton(icon: "chevron.left", label: "Previous Page", isEnabled: currentPage > 1) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentPage = max(1, currentPage - 1)
                    }
                }

                // Page numbers
                pageNumbers

                // Next page
                healthPaginationButton(icon: "chevron.right", label: "Next Page", isEnabled: currentPage < totalPages) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentPage = min(totalPages, currentPage + 1)
                    }
                }

                // Last page
                healthPaginationButton(icon: "chevron.right.2", label: "Last Page", isEnabled: currentPage < totalPages) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        currentPage = totalPages
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .background(FleetHubTheme.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
        }
    }

    private func healthPaginationButton(icon: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.control)
                .frame(width: 36, height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FleetHubTheme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(FleetHubTheme.border, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
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
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                        .frame(width: 24, height: 32)
                } else {
                    let isCurrent = currentPage == page
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentPage = page
                        }
                    } label: {
                        Text("\(page)")
                            .font(.system(size: 12, weight: isCurrent ? .bold : .medium))
                            .monospacedDigit()
                            .foregroundStyle(isCurrent ? FleetHubTheme.accent : FleetHubTheme.control)
                            .frame(minWidth: 32, minHeight: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isCurrent ? FleetHubTheme.accent.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
        }
    }

    private func calculateVisiblePages() -> [Int] {
        guard totalPages > 1 else { return [1] }
        
        var pages: [Int] = []
        
        if totalPages <= 7 {
            pages = Array(1...totalPages)
        } else {
            pages.append(1)
            
            if currentPage > 3 {
                pages.append(-1) // Ellipsis
            }
            
            let start = max(2, currentPage - 1)
            let end = min(totalPages - 1, currentPage + 1)
            
            for page in start...end {
                if !pages.contains(page) {
                    pages.append(page)
                }
            }
            
            if currentPage < totalPages - 2 {
                pages.append(-1) // Ellipsis
            }
            
            if !pages.contains(totalPages) {
                pages.append(totalPages)
            }
        }
        
        return pages
    }
    
    // MARK: - Data Loading
    
    private func loadDevices() {
        isLoading = true
        
        // Load real filtered devices from HealthMetricsCalculator
        Task { @MainActor in
            let calculator = HealthMetricsCalculator.shared
            let filteredDevices = calculator.getFilteredDevices(
                for: healthItem.metricType,
                segment: healthItem.segmentType
            )
            
            devices = filteredDevices
            isLoading = false
            
            AppLog.notice("📊 HealthFilteredDeviceListView: Loaded \(devices.count) devices for \(healthItem.metricType.rawValue) - \(healthItem.segmentType.rawValue)")
        }
    }
    
    private func refreshDevices() {
        isLoading = true
        
        Task { @MainActor in
            // Recalculate metrics first
            HealthMetricsCalculator.shared.recalculateMetrics()
            
            // Then get filtered devices
            let calculator = HealthMetricsCalculator.shared
            let filteredDevices = calculator.getFilteredDevices(
                for: healthItem.metricType,
                segment: healthItem.segmentType
            )
            
            devices = filteredDevices
            isLoading = false
        }
    }
    
    private func generateMockDevices() -> [DeviceListItem] {
        let count = healthItem.deviceCount
        var items: [DeviceListItem] = []
        
        let deviceNames = [
            "Mac Studio", "MacBook Pro 14\"", "MacBook Pro 16\"", "MacBook Air M2",
            "iMac 24\"", "Mac mini M2", "Mac Pro", "MacBook Air M3",
            "iPhone 15 Pro", "iPhone 15 Pro Max", "iPhone 15", "iPhone 14 Pro",
            "iPad Pro 12.9\"", "iPad Pro 11\"", "iPad Air", "iPad mini",
            "Apple Vision Pro"
        ]
        
        let users = [
            "John Smith", "Sarah Johnson", "Mike Chen", "Emily Davis",
            "Alex Wilson", "Chris Taylor", "Jordan Lee", "Sam Brown",
            nil, nil
        ]
        
        let platforms: [PlatformType] = [.macOS, .macOS, .macOS, .iOS, .iOS, .iPadOS, .visionOS]
        
        for i in 0..<min(count, 150) {
            let platform = platforms[i % platforms.count]
            let deviceName = deviceNames[i % deviceNames.count]
            let user = users[i % users.count]
            
            let item = DeviceListItem(
                id: UUID().uuidString,
                name: "\(deviceName) \(i + 1)",
                serialNumber: generateSerialNumber(),
                model: deviceName,
                modelIdentifier: generateModelIdentifier(for: deviceName),
                osVersion: generateOSVersion(for: platform),
                assignedUser: user,
                lastCheckIn: generateCheckInDate(),
                isManaged: true,
                isSupervised: Bool.random(),
                platform: platform
            )
            items.append(item)
        }
        
        return items
    }
    
    private func generateSerialNumber() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<12).map { _ in chars.randomElement()! })
    }
    
    private func generateOSVersion(for platform: PlatformType) -> String {
        switch platform {
        case .macOS:
            return ["15.2", "15.1", "15.0", "14.7", "14.6"].randomElement()!
        case .iOS:
            return ["18.2", "18.1", "18.0", "17.7", "17.6"].randomElement()!
        case .iPadOS:
            return ["18.2", "18.1", "18.0", "17.7"].randomElement()!
        case .visionOS:
            return ["2.2", "2.1", "2.0", "1.2"].randomElement()!
        case .all:
            return "N/A"
        }
    }
    
    private func generateCheckInDate() -> Date {
        let daysAgo = Double.random(in: 0...30)
        return Date().addingTimeInterval(-daysAgo * 24 * 60 * 60)
    }
    
    private func generateModelIdentifier(for model: String) -> String {
        let identifiers: [String: String] = [
            "Mac Studio": "Mac13,2",
            "MacBook Pro 14\"": "Mac15,3",
            "MacBook Pro 16\"": "Mac15,7",
            "MacBook Air M2": "Mac14,2",
            "MacBook Air M3": "Mac15,12",
            "iMac 24\"": "Mac15,4",
            "Mac mini M2": "Mac14,3",
            "Mac Pro": "Mac14,8",
            "iPhone 15 Pro": "iPhone16,1",
            "iPhone 15 Pro Max": "iPhone16,2",
            "iPhone 15": "iPhone15,4",
            "iPhone 14 Pro": "iPhone15,2",
            "iPad Pro 12.9\"": "iPad14,5",
            "iPad Pro 11\"": "iPad14,3",
            "iPad Air": "iPad13,16",
            "iPad mini": "iPad14,1",
            "Apple Vision Pro": "RealityDevice14,1"
        ]
        return identifiers[model] ?? "Unknown"
    }
}

// MARK: - Health Device List Row

/// Column layout shared by the header and every row.
private struct HealthDeviceColumns<Device: View, User: View, Model: View, OS: View, CheckIn: View>: View {
    let device: Device
    let user: User
    let model: Model
    let os: OS
    let checkIn: CheckIn
    /// True → the Model column is dropped (narrow windows).
    let compact: Bool

    var body: some View {
        HStack(spacing: 16) {
            device.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            user.frame(width: 160, alignment: .leading)
            if !compact {
                model.frame(width: 200, alignment: .leading)
            }
            os.frame(width: 110, alignment: .leading)
            checkIn.frame(width: 110, alignment: .leading)
            Color.clear.frame(width: 14, height: 1)
        }
    }
}

struct HealthDeviceListRow: View {
    let device: DeviceListItem
    let healthItem: HealthNavigationItem
    var isLoading: Bool = false
    var compact: Bool = false
    let onTap: () -> Void

    @State private var isHovered: Bool = false

    private func cell(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 13))
            .foregroundStyle(FleetHubTheme.ink)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(FleetHubTheme.control)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(FleetHubTheme.trough))
            .fixedSize()
    }

    var body: some View {
        Button(action: onTap) {
            HealthDeviceColumns(
                device: HStack(spacing: 12) {
                    DeviceIconView(
                        modelIdentifier: device.modelIdentifier,
                        modelName: device.model,
                        size: 30
                    )
                    .frame(width: 34, height: 34)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(device.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FleetHubTheme.ink)
                                .lineLimit(1)
                            if device.isSupervised {
                                tag("Supervised")
                            }
                            if !device.isManaged {
                                tag("Unmanaged")
                            }
                        }
                        Text(device.serialNumber)
                            .font(.system(size: 11))
                            .foregroundStyle(FleetHubTheme.muted)
                            .lineLimit(1)
                    }
                },
                user: Text(device.assignedUser ?? "Unassigned")
                    .font(.system(size: 13))
                    .foregroundStyle(device.assignedUser == nil ? FleetHubTheme.muted : FleetHubTheme.ink)
                    .lineLimit(1),
                model: cell(device.model),
                os: cell("\(device.platform.rawValue) \(device.osVersion)"),
                checkIn: cell(device.lastCheckIn.map(healthRelativeTimeString(from:)) ?? "Never"),
                compact: compact
            )
            .overlay(alignment: .trailing) {
                // Loading spinner or chevron
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
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

    private func healthRelativeTimeString(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Health Filtered - Compliant") {
    @Previewable @State var path = NavigationPath()
    
    let mockMetric = HealthMetricData(
        type: .checkedIn,
        compliantCount: 5420,
        nonCompliantCount: 489,
        unknownCount: 98
    )
    
    let healthItem = HealthNavigationItem(
        metricType: .checkedIn,
        segmentType: .compliant,
        metricData: mockMetric
    )
    
    HealthFilteredDeviceListView(
        healthItem: healthItem,
        navigationPath: $path
    )
    .frame(width: 1200, height: 800)
}

#Preview("Health Filtered - Non-Compliant") {
    @Previewable @State var path = NavigationPath()
    
    let mockMetric = HealthMetricData(
        type: .encrypted,
        compliantCount: 5650,
        nonCompliantCount: 287,
        unknownCount: 70
    )
    
    let healthItem = HealthNavigationItem(
        metricType: .encrypted,
        segmentType: .nonCompliant,
        metricData: mockMetric
    )
    
    HealthFilteredDeviceListView(
        healthItem: healthItem,
        navigationPath: $path
    )
    .frame(width: 1200, height: 800)
}

#Preview("Health Filtered - Unknown") {
    @Previewable @State var path = NavigationPath()
    
    let mockMetric = HealthMetricData(
        type: .upToDate,
        compliantCount: 4870,
        nonCompliantCount: 1039,
        unknownCount: 98
    )
    
    let healthItem = HealthNavigationItem(
        metricType: .upToDate,
        segmentType: .unknown,
        metricData: mockMetric
    )
    
    HealthFilteredDeviceListView(
        healthItem: healthItem,
        navigationPath: $path
    )
    .frame(width: 1200, height: 800)
}
#endif
