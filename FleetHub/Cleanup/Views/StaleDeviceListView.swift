//
//  StaleDeviceListView.swift
//  FleetHub
//
//  The stale-device table card on the Cleanup page: scope chips, search,
//  sortable columns, a tri-state select-all and the bulk-action bar. The
//  owning dashboard decides which devices it is handed.
//

import SwiftUI

// MARK: - Scope

/// Which slice of the stale set the table shows. Maps onto DeviceFilter so
/// the managed/unmanaged rules stay in one place.
enum StaleScope: String, CaseIterable, Identifiable {
    case allStale
    case overOneYear
    case unmanaged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allStale: "All Stale"
        case .overOneYear: "Over 1 Year"
        case .unmanaged: "Unmanaged"
        }
    }

    var filter: DeviceFilter {
        switch self {
        case .allStale: .allStale
        case .overOneYear: .overOneYear
        case .unmanaged: .unmanaged
        }
    }

    var help: String {
        switch self {
        case .allStale: "Managed computers past the stale threshold"
        case .overOneYear: "Managed computers silent for 365 days or more"
        case .unmanaged: "Stale records that are already unmanaged"
        }
    }
}

// MARK: - Sort

/// The stale table's column sort: the shared `TableSort`, starting on Days
/// Stale with the most stale first.
struct StaleSort: Equatable {
    enum Key: Hashable { case name, user, site, lastCheckIn, daysStale }

    var table = TableSort<Key>(key: .daysStale, ascending: false)

    func sorted(_ devices: [StaleDevice]) -> [StaleDevice] {
        devices.sorted(by: table) { device, key in
            switch key {
            case .name: .text(device.name)
            case .user: .text(device.userEmail.isEmpty ? device.username : device.userEmail)
            case .site: .text(device.siteName)
            case .lastCheckIn: .date(device.lastContactTime)
            // A device that never checked in is the most stale of all, not
            // a blank: it sorts above every counted day.
            case .daysStale: .number(device.daysSinceContact.map(Double.init) ?? .infinity)
            }
        }
    }
}

// MARK: - Table card

struct StaleDeviceTableCard: View {
    @Environment(CleanupViewModel.self) private var model
    /// Observed so the Actions gate re-evaluates when capabilities land
    /// after sign-in.
    @ObservedObject private var session = UserSession.shared

    let devices: [StaleDevice]
    /// Devices in the scope and site before search, for "8 of 41".
    let scopedCount: Int
    @Binding var scope: StaleScope
    @Binding var searchText: String
    @Binding var sort: StaleSort
    let scopeCount: (StaleScope) -> Int

    @State private var showActions = false
    @State private var cardWidth: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    /// False → the user's roles grant no cleanup action, so the Review
    /// Actions button is not rendered (CleanupActionsSheet enforces this too).
    private var hasAnyPermittedCleanupAction: Bool {
        CleanupAction.allCases.contains { session.capabilities.canRunCleanupAction($0) }
    }

    private var selectedVisibleCount: Int {
        devices.count(where: { model.selection.contains($0.id) })
    }

    private var checkAllState: CleanupCheckBox.State {
        if devices.isEmpty || selectedVisibleCount == 0 { return .off }
        return selectedVisibleCount == devices.count ? .on : .mixed
    }

    private var showsUser: Bool { cardWidth >= 640 }
    private var showsLastCheckIn: Bool { cardWidth >= 760 }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            columnHeader
            rows
            actionBar
        }
        .readWidth(into: $cardWidth)
        .background(FleetHubTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
        .sheet(isPresented: $showActions) {
            CleanupActionsSheet()
                .environment(model)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                title
                Spacer(minLength: 8)
                scopeChips
                searchField.frame(width: 240)
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    title
                    Spacer(minLength: 8)
                    searchField.frame(maxWidth: 260)
                }
                scopeChips
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Stale Devices")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            Text(devices.count == scopedCount ? "\(scopedCount)" : "\(devices.count) of \(scopedCount)")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)
        }
        .fixedSize()
    }

    private var scopeChips: some View {
        HStack(spacing: 6) {
            ForEach(StaleScope.allCases) { option in
                let isSelected = scope == option
                Button {
                    scope = option
                } label: {
                    HStack(spacing: 6) {
                        Text(option.title)
                        Text("\(scopeCount(option))")
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? FleetHubTheme.accent : FleetHubTheme.muted)
                    }
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? FleetHubTheme.accent : FleetHubTheme.control)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(
                        Capsule().fill(isSelected ? FleetHubTheme.accent.opacity(0.12) : FleetHubTheme.surface)
                    )
                    .overlay(
                        Capsule().stroke(isSelected ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(option.help)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
            TextField("", text: $searchText, prompt: Text("Name, serial, or user")
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
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
        )
    }

    // MARK: Columns

    private func columns<Computer: View, User: View, Site: View, CheckIn: View, Days: View>(
        @ViewBuilder computer: () -> Computer,
        @ViewBuilder user: () -> User,
        @ViewBuilder site: () -> Site,
        @ViewBuilder checkIn: () -> CheckIn,
        @ViewBuilder days: () -> Days
    ) -> some View {
        HStack(spacing: 14) {
            computer().frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
            if showsUser {
                user().frame(width: 170, alignment: .leading)
            }
            site().frame(width: 96, alignment: .leading)
            if showsLastCheckIn {
                checkIn().frame(width: 104, alignment: .leading)
            }
            days().frame(width: 88, alignment: .trailing)
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            CleanupCheckBox(state: checkAllState) {
                model.toggleSelectAll(in: devices)
            }
            .help("Select every device shown")
            .disabled(devices.isEmpty)

            columns(
                computer: { sortHeader("Computer", .name) },
                user: { sortHeader("User", .user) },
                site: { sortHeader("Site", .site) },
                checkIn: { sortHeader("Last Check-In", .lastCheckIn) },
                days: { sortHeader("Days Stale", .daysStale) }
            )
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(FleetHubTheme.ground)
    }

    private func sortHeader(_ title: String, _ key: StaleSort.Key) -> some View {
        SortableHeaderText(title, key: key, sort: $sort.table)
    }

    // MARK: Rows

    @ViewBuilder
    private var rows: some View {
        if devices.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(devices) { device in
                        StaleDeviceRow(
                            isSelected: model.selection.contains(device.id),
                            toggle: { model.toggleSelection(device.id) }
                        ) {
                            columns(
                                computer: { computerCell(device) },
                                user: { cell(device.userEmail.isEmpty ? device.username : device.userEmail) },
                                site: { cell(device.siteName) },
                                checkIn: { cell(Self.checkInString(device.lastContactTime)) },
                                days: { StaleBadge(days: device.daysSinceContact) }
                            )
                        }
                        Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func computerCell(_ device: StaleDevice) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                if !device.isManaged {
                    Text("Unmanaged")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(FleetHubTheme.trough))
                        .fixedSize()
                }
            }
            Text(device.serialNumber)
                .font(.system(size: 11))
                .foregroundStyle(FleetHubTheme.muted)
                .lineLimit(1)
        }
        .textSelection(.enabled)
    }

    private func cell(_ text: String) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 13))
            .foregroundStyle(text.isEmpty ? FleetHubTheme.muted : FleetHubTheme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    private static func checkInString(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView().controlSize(.regular)
                Text("Surveying the Fleet…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.muted)
            } else {
                Image(systemName: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(FleetHubTheme.muted)
                Text(searchText.isEmpty ? "No Stale Devices Here" : "No Matches")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text(searchText.isEmpty
                     ? "Nothing in this view has gone quiet."
                     : "Try a different name, serial, or user.")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
            }
        }
        .padding(24)
    }

    // MARK: Action bar

    private var actionBar: some View {
        let count = model.selection.count
        return HStack(spacing: 10) {
            Text(count == 0 ? "None Selected" : "\(count) Selected")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? FleetHubTheme.muted : FleetHubTheme.ink)

            Spacer(minLength: 8)

            if count > 0 {
                Button {
                    model.clearSelection()
                } label: {
                    CleanupOutlineLabel(text: "Clear")
                }
                .buttonStyle(.plain)
            }

            // No cleanup action granted to the user's roles → no button; the
            // sheet behind it would have nothing to offer.
            if hasAnyPermittedCleanupAction {
                Button {
                    showActions = true
                } label: {
                    Text("Review Actions")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .fill(FleetHubTheme.accentFill)
                        )
                        .opacity(count == 0 ? 0.45 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
                .help(count == 0 ? "Select devices to act on them" : "Choose what to do with the selected devices")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(FleetHubTheme.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
        }
    }
}

// MARK: - Row

private struct StaleDeviceRow<Content: View>: View {
    let isSelected: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CleanupCheckBox(state: isSelected ? .on : .off, action: toggle)
            content()
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 52)
        .background(
            isSelected ? FleetHubTheme.accent.opacity(0.08)
                : (isHovered ? FleetHubTheme.ground.opacity(0.7) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { isHovered = $0 }
    }
}

extension StaleDevice {
    /// Sorting needs a non-optional value; never-contacted sorts oldest.
    var sortableLastContact: Date { lastContactTime ?? .distantPast }
}
