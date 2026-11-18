//
//  CleanupDashboardView.swift
//  FleetHub
//
//  Cleanup landing page: the stale count, a per-site breakdown and Jamf
//  Protect on the left; the selectable stale-device table on the right.
//  Scope, site and search narrow the table in place — there is no separate
//  filtered-list screen.
//

import SwiftUI

struct CleanupDashboardView: View {
    @Environment(CleanupViewModel.self) private var model
    /// 0 = unset → use the MDM profile's default (config = default, user-overridable).
    @AppStorage(CleanupSettings.Key.staleDays) private var staleDaysStored = 0

    @State private var scope: StaleScope = .allStale
    /// nil = every site.
    @State private var site: String?
    @State private var searchText = ""
    @State private var sort = StaleSort()
    @State private var contentWidth: CGFloat = 0

    /// The stale threshold actually in effect: the user's in-app choice if set,
    /// otherwise the config-profile default.
    private var effectiveStaleDays: Int {
        staleDaysStored > 0 ? staleDaysStored : MDMConfigurationManager.shared.configuration.cleanupStaleDays
    }

    /// Dropdown options — the common presets plus the current/MDM value so it's
    /// always selectable even if it isn't a preset.
    private var staleDayOptions: [Int] {
        Array(Set([7, 14, 30, 45, 60, 90, 120, 180, 365, effectiveStaleDays]))
            .filter { $0 > 0 }
            .sorted()
    }

    // MARK: - Filtering

    private func matches(_ device: StaleDevice, in scope: StaleScope) -> Bool {
        scope.filter.matches(device) && (site == nil || device.siteName == site)
    }

    /// Devices in the chosen scope and site, before search.
    private var scopedDevices: [StaleDevice] {
        model.devices.filter { matches($0, in: scope) }
    }

    /// What the table shows: scope + site + search, sorted.
    private func visibleDevices(from scoped: [StaleDevice]) -> [StaleDevice] {
        let base = searchText.isEmpty ? scoped : scoped.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.userEmail.localizedCaseInsensitiveContains(searchText)
                || $0.username.localizedCaseInsensitiveContains(searchText)
                || $0.serialNumber.localizedCaseInsensitiveContains(searchText)
        }
        return sort.sorted(base)
    }

    private func count(in scope: StaleScope) -> Int {
        model.devices.count(where: { matches($0, in: scope) })
    }

    /// A hidden row must never stay selected: bulk actions run on the whole
    /// selection, so it is trimmed to what the scope and site still show.
    private func pruneSelection() {
        model.selection.formIntersection(scopedDevices.map(\.id))
    }

    private var filterTitle: String {
        site.map { "\(scope.title) — \($0)" } ?? scope.title
    }

    // MARK: - Body

    var body: some View {
        let scoped = scopedDevices
        let visible = visibleDevices(from: scoped)

        Group {
            if contentWidth >= 940 {
                VStack(alignment: .leading, spacing: 20) {
                    header(visible: visible)
                    HStack(alignment: .top, spacing: 20) {
                        ScrollView {
                            sideColumn
                        }
                        .scrollIndicators(.never)
                        .frame(width: 320)

                        tableCard(visible: visible, scopedCount: scoped.count)
                            .frame(maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(visible: visible)
                        sideColumn
                        tableCard(visible: visible, scopedCount: scoped.count)
                            .frame(height: 560)
                    }
                    .padding(20)
                }
            }
        }
        .readWidth(into: $contentWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            if model.devices.isEmpty {
                await model.refresh()
            }
        }
        .onChange(of: scope) { pruneSelection() }
        .onChange(of: site) { pruneSelection() }
        .onChange(of: staleDaysStored) {
            Task { await model.refresh() }
        }
    }

    // MARK: - Header

    private func header(visible: [StaleDevice]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                titleBlock
                Spacer(minLength: 16)
                headerControls(visible: visible)
            }
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                headerControls(visible: visible)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Cleanup")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        let lead = "Find devices that stopped checking in, then act on them in bulk."
        guard let lastRefresh = model.lastRefresh else { return lead }
        return "\(lead) Updated \(lastRefresh.formatted(date: .abbreviated, time: .shortened))."
    }

    private func headerControls(visible: [StaleDevice]) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            labelled("Stale After") { staleDaysMenu }
            if !model.staleBySite.isEmpty {
                labelled("Site") { siteMenu }
            }
            CleanupExportMenu(
                filename: ExportNaming.filename(Branding.title, filterTitle, date: Date()),
                makeTable: { buildTable(visible) }
            )
            .disabled(visible.isEmpty)
            RefreshButton(isLoading: model.isLoading) {
                Task { await model.refresh() }
            }
        }
        .fixedSize()
    }

    private func labelled<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
            control()
        }
    }

    private var staleDaysMenu: some View {
        Menu {
            Picker("Stale After", selection: Binding(
                get: { effectiveStaleDays },
                set: { staleDaysStored = $0 }
            )) {
                ForEach(staleDayOptions, id: \.self) { days in
                    Text("\(days) Days").tag(days)
                }
            }
            .pickerStyle(.inline)
        } label: {
            CleanupMenuLabel(text: "\(effectiveStaleDays) Days")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Devices with no Jamf check-in for this many days are stale. The default comes from your MDM profile; change it here anytime.")
    }

    private var siteMenu: some View {
        Menu {
            Picker("Site", selection: $site) {
                Text("All Sites").tag(String?.none)
                ForEach(model.staleBySite) { entry in
                    Text(entry.name).tag(String?.some(entry.name))
                }
            }
            .pickerStyle(.inline)
        } label: {
            CleanupMenuLabel(text: site ?? "All Sites")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Builds a report from exactly what the table currently shows.
    private func buildTable(_ devices: [StaleDevice]) -> ReportTable {
        var subtitle = "Filter: \(filterTitle)"
        if !searchText.isEmpty {
            subtitle += " • search “\(searchText)”"
        }
        return ReportBuilders.deviceTable(
            title: "\(Branding.title) Cleanup — \(filterTitle)",
            subtitle: subtitle,
            devices: devices,
            columns: ReportColumn.allCases,
            staleDays: model.settings.staleDays,
            includeSummary: true,
            generatedAt: Date()
        )
    }

    // MARK: - Side column

    private var sideColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let error = model.loadError, model.devices.isEmpty {
                errorCard(error)
            }
            staleTile
            if !model.staleBySite.isEmpty {
                sitesCard
            }
            if model.settings.isProtectConfigured || model.protectLoaded {
                protectCard
            }
        }
    }

    private var staleTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stale Computers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FleetHubTheme.warnText)
            Text(model.lastRefresh == nil ? "—" : "\(model.managedStale.count)")
                .font(.system(size: 40, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.ink)
            Text(staleCaption)
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.warnText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .fill(FleetHubTheme.warnFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.warnText.opacity(0.22), lineWidth: 1)
        )
        .textSelection(.enabled)
    }

    private var staleCaption: String {
        let lead = "No check-in for \(model.settings.staleDays)+ days"
        guard model.lastRefresh != nil, let total = model.totalComputers, total > 0 else { return lead }
        let share = Double(model.managedStale.count) / Double(total)
        return "\(lead) · \(share.formatted(.percent.precision(.fractionLength(0...1)))) of the fleet"
    }

    private var sitesCard: some View {
        let top = max(model.staleBySite.first?.count ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Stale by Site")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Spacer()
                Text(model.staleBySite.count == 1 ? "1 site" : "\(model.staleBySite.count) sites")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
            }
            .padding(.bottom, 4)

            ForEach(model.staleBySite) { entry in
                SiteBarRow(
                    name: entry.name,
                    count: entry.count,
                    fraction: CGFloat(entry.count) / CGFloat(top),
                    isSelected: site == entry.name
                ) {
                    site = (site == entry.name) ? nil : entry.name
                }
            }
        }
        .fleetHubCard()
    }

    private var protectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jamf Protect")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)

            if let error = model.protectError {
                Label(error, systemImage: "exclamationmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(protectSummary)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if model.protectLoaded {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { protectLinks }
                    VStack(alignment: .leading, spacing: 8) { protectLinks }
                }
            }
        }
        .fleetHubCard()
    }

    private var protectSummary: String {
        guard model.protectLoaded else { return "Jamf Protect records have not loaded yet." }
        let stale = model.protectStaleDevices.count
        let total = model.protectDevices.count
        return "\(stale) of \(total) records in Jamf Protect have not checked in for \(model.settings.staleDays)+ days. Removing them there leaves Jamf Pro untouched."
    }

    @ViewBuilder
    private var protectLinks: some View {
        NavigationLink(value: ProtectFilter.stale) {
            CleanupOutlineLabel(text: "Review Stale Records")
        }
        .buttonStyle(.plain)
        NavigationLink(value: ProtectFilter.all) {
            CleanupOutlineLabel(text: "All Records")
        }
        .buttonStyle(.plain)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unable to Load Stale Devices", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FleetHubTheme.badText)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button {
                Task { await model.refresh() }
            } label: {
                CleanupOutlineLabel(text: "Retry")
            }
            .buttonStyle(.plain)
        }
        .fleetHubCard()
    }

    // MARK: - Table card

    private func tableCard(visible: [StaleDevice], scopedCount: Int) -> some View {
        StaleDeviceTableCard(
            devices: visible,
            scopedCount: scopedCount,
            scope: $scope,
            searchText: $searchText,
            sort: $sort,
            scopeCount: count(in:)
        )
    }
}

// MARK: - Site bar row

private struct SiteBarRow: View {
    let name: String
    let count: Int
    let fraction: CGFloat
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? FleetHubTheme.accent : FleetHubTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(count)")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(FleetHubTheme.ink)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FleetHubTheme.trough)
                        Capsule()
                            .fill(Color(light: 0xC27A00, dark: 0xF2C26B))
                            .frame(width: max(8, geometry.size.width * fraction))
                    }
                }
                .frame(height: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? FleetHubTheme.accent.opacity(0.10)
                          : (isHovered ? FleetHubTheme.ground : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -10)
        .onHover { isHovered = $0 }
        .help(isSelected ? "Show every site" : "Show only \(name)")
        .accessibilityLabel("\(name), \(count) stale")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Shared control labels

/// Outlined pop-up label used by the header menus.
struct CleanupMenuLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
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
}

/// Outlined secondary button label.
struct CleanupOutlineLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(FleetHubTheme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
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
}
