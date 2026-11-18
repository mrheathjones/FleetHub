//
//  DeviceHistorySectionView.swift
//  FleetHub
//
//  Renders the Device Details "History" section: Jamf Policy Logs and MDM
//  command history (Management History), pulled from the Classic
//  `computerhistory` endpoint by ComputerHistoryService.
//
//  Two tabs (Policy Logs / Management History), mirroring the ABM Lookup /
//  Pre-Stage pill-tab strip. Each tab has its own "contains" search, status
//  filter chips, and pagination (page size is config-driven). Rows expand to
//  show all fields Jamf exposes — the Classic endpoint carries no per-run
//  execution detail (script/package output), so status + timestamps are the
//  full picture.
//
//  Standalone/parameterized on purpose — DeviceView owns the load state and
//  passes data (and page size) in, keeping this out of that large file and
//  free of any private-member coupling.
//

import SwiftUI

struct DeviceHistorySectionView: View {
    let history: ComputerHistory?
    let isLoading: Bool
    let errorMessage: String?
    let pageSize: Int
    let onRetry: () -> Void

    @State private var tab: HistoryTab = .policyLogs
    @State private var policySearch = ""
    @State private var policyFilter: PolicyStatusFilter = .all
    @State private var policyPage = 1
    @State private var commandSearch = ""
    @State private var commandFilter: CommandStatusFilter = .all
    @State private var commandPage = 1
    @State private var expanded: Set<String> = []
    /// Column sort, shared by both tabs. Starts on Time, newest first.
    @State private var historySort = TableSort<String>(key: "Time", ascending: false)

    /// Date order underneath any column sort: oldest first only while the
    /// Time column is sorted ascending. Rows that tie on another column
    /// therefore stay newest first.
    private var newestFirst: Bool { !(historySort.key == "Time" && historySort.ascending) }

    var body: some View {
        InventoryCardShell {
            InventoryToolbar(title: "History", countText: nil, search: searchBinding, searchPrompt: searchPrompt) {
                if isLoading && history != nil {
                    ProgressView().controlSize(.small)
                }
                tabStrip
            }

            if isLoading && history == nil {
                loadingState
            } else if let errorMessage {
                errorState(errorMessage)
            } else {
                switch tab {
                case .policyLogs: policyTab
                case .managementHistory: commandTab
                }
            }
        }
    }

    // MARK: - Toolbar

    /// The search box follows the visible tab; each tab keeps its own text.
    private var searchBinding: Binding<String> {
        tab == .policyLogs ? $policySearch : $commandSearch
    }

    private var searchPrompt: String {
        tab == .policyLogs ? "Policy name" : "Command name"
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(HistoryTab.allCases) { t in tabChip(t) }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FleetHubTheme.trough))
        .fixedSize()
    }

    private func tabChip(_ t: HistoryTab) -> some View {
        let isSelected = tab == t
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { tab = t }
        } label: {
            Text(t.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                .padding(.horizontal, 12)
                .frame(height: 28)
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

    private var columnHeader: some View {
        InventoryHeaderRow {
            historyColumns {
                SortableHeaderText("Time", key: "Time", sort: $historySort)
            } name: {
                SortableHeaderText(tab == .policyLogs ? "Policy" : "Command", key: "Name", sort: $historySort)
            } user: {
                SortableHeaderText("User", key: "User", sort: $historySort)
            } status: {
                SortableHeaderText("Status", key: "Status", sort: $historySort)
            }
        }
    }

    private func historyColumns<A: View, B: View, C: View, D: View>(
        @ViewBuilder time: () -> A,
        @ViewBuilder name: () -> B,
        @ViewBuilder user: () -> C,
        @ViewBuilder status: () -> D
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            time().frame(width: 170, alignment: .leading)
            name().frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            user().frame(width: 130, alignment: .leading)
            status().frame(width: 110, alignment: .trailing)
            Color.clear.frame(width: 12, height: 1)
        }
    }

    // MARK: - Policy Logs tab

    private var policyTab: some View {
        let source: [PolicyLogEntry] = history?.policyLogs ?? []
        let sorted = sortedByColumn(sortedByDate(source) { $0.date }) { entry, column in
            switch column {
            case "User": .text(entry.username)
            case "Status": .text(entry.status)
            default: .text(entry.policyName ?? entry.policyId.map { "Policy \($0)" })
            }
        }
        let filtered: [PolicyLogEntry] = sorted.filter { entry in
            guard policyFilter.matches(entry) else { return false }
            if policySearch.isEmpty { return true }
            return (entry.policyName ?? "").localizedCaseInsensitiveContains(policySearch)
        }

        let page = Pagination(total: filtered.count, pageSize: pageSize, current: policyPage)
        let rows = page.slice(filtered).enumerated().map {
            Self.rowModel(policy: $0.element, index: page.start + $0.offset)
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                FlowLayout(spacing: 6) {
                    ForEach(PolicyStatusFilter.allCases) { f in
                        InventoryChip(title: f.title, isSelected: policyFilter == f) { policyFilter = f }
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            columnHeader

            if filtered.isEmpty {
                emptyState(policySearch.isEmpty && policyFilter == .all
                           ? "No Policy Logs Recorded"
                           : "No Policy Logs Match Your Filter")
            } else {
                rowList(rows)
                if page.showControls {
                    paginationBar(page: $policyPage, p: page)
                }
            }
        }
        .onChange(of: policySearch) { policyPage = 1 }
        .onChange(of: policyFilter) { policyPage = 1 }
        .onChange(of: historySort) { policyPage = 1 }
    }

    // MARK: - Management History tab

    private var commandTab: some View {
        let source = sortedByColumn(sortedByDate(taggedCommands()) { $0.entry.date }) { item, column in
            switch column {
            case "User": .text(item.entry.username)
            case "Status": .text(item.state.label)
            default: .text(item.entry.name)
            }
        }
        let filtered = source.filter { item in
            guard commandFilter.matches(item.state) else { return false }
            if commandSearch.isEmpty { return true }
            return (item.entry.name ?? "").localizedCaseInsensitiveContains(commandSearch)
        }

        let page = Pagination(total: filtered.count, pageSize: pageSize, current: commandPage)
        let rows = page.slice(filtered).enumerated().map {
            Self.rowModel(command: $0.element.entry, state: $0.element.state, index: page.start + $0.offset)
        }

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                FlowLayout(spacing: 6) {
                    ForEach(CommandStatusFilter.allCases) { f in
                        InventoryChip(title: f.title, isSelected: commandFilter == f) { commandFilter = f }
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            columnHeader

            if filtered.isEmpty {
                emptyState(commandSearch.isEmpty && commandFilter == .all
                           ? "No Commands Recorded"
                           : "No Commands Match Your Filter")
            } else {
                rowList(rows)
                if page.showControls {
                    paginationBar(page: $commandPage, p: page)
                }
            }
        }
        .onChange(of: commandSearch) { commandPage = 1 }
        .onChange(of: commandFilter) { commandPage = 1 }
        .onChange(of: historySort) { commandPage = 1 }
    }

    /// Flatten the three command buckets into (entry, state). Ordering is
    /// applied later by `sortedByDate`.
    private func taggedCommands() -> [(entry: CommandEntry, state: CommandState)] {
        let c = history?.commands
        var tagged: [(entry: CommandEntry, state: CommandState)] = []
        tagged += (c?.failed ?? []).map { (entry: $0, state: CommandState.failed) }
        tagged += (c?.pending ?? []).map { (entry: $0, state: CommandState.pending) }
        tagged += (c?.completed ?? []).map { (entry: $0, state: CommandState.completed) }
        return tagged
    }

    /// Sort by date when any entry has a parseable date; otherwise fall back to
    /// Jamf's returned order (observed oldest-first) and just reverse it for
    /// "newest first". This keeps the toggle working even when Policy Logs
    /// carry no parseable timestamp.
    private func sortedByDate<T>(_ items: [T], date: (T) -> Date?) -> [T] {
        let hasDates = items.contains { date($0) != nil }
        if hasDates {
            return items.sorted { a, b in
                let ka = date(a) ?? .distantPast
                let kb = date(b) ?? .distantPast
                return newestFirst ? ka > kb : ka < kb
            }
        }
        return newestFirst ? items.reversed() : items
    }

    /// Applies a Policy/Command, User or Status column sort on top of the
    /// date order. The Time column is already handled by `sortedByDate`
    /// (which also copes with entries that carry no parseable date).
    private func sortedByColumn<T>(_ items: [T], value: (T, String) -> SortValue) -> [T] {
        guard let key = historySort.key, key != "Time" else { return items }
        return items.sorted(by: historySort, value: value)
    }

    // MARK: - Row list + row

    private func rowList(_ rows: [RowModel]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { rowView($0) }
        }
    }

    private func rowView(_ m: RowModel) -> some View {
        let isOpen = expanded.contains(m.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { toggle(m.id) }
            } label: {
                rowSummary(m, isOpen: isOpen)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isOpen ? "Hides details" : "Shows details")

            if isOpen {
                rowDetail(m)
            }

            Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
        }
        .background(isOpen ? FleetHubTheme.ground.opacity(0.6) : Color.clear)
    }

    private func rowSummary(_ m: RowModel, isOpen: Bool) -> some View {
        historyColumns {
            timestampLine(date: m.date, raw: m.rawDate)
        } name: {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                if let err = m.errorDetail, !err.isEmpty, !isOpen {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.badText)
                        .lineLimit(1)
                }
            }
        } user: {
            InventoryCellText(m.username)
        } status: {
            if let badge = m.badge, !badge.isEmpty {
                InventoryTag(text: badge, tone: m.color.tone)
            }
        }
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FleetHubTheme.muted)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
        }
    }

    private func rowDetail(_ m: RowModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 28) {
                ForEach(m.details) { pair in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.label)
                            .font(.system(size: 11))
                            .foregroundStyle(FleetHubTheme.muted)
                        Text(pair.value)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FleetHubTheme.ink)
                    }
                    .fixedSize()
                }
            }
            if let err = m.errorDetail, !err.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(err)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(FleetHubTheme.badText)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FleetHubTheme.badFill))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func timestampLine(date: Date?, raw: String?) -> some View {
        if let date {
            InventoryCellText(date.formatted(date: .abbreviated, time: .shortened))
        } else if let raw, !raw.isEmpty {
            // Parsing failed but Jamf gave us *some* date string — show it
            // verbatim rather than a useless dash.
            InventoryCellText(raw)
        } else {
            InventoryCellText(nil)
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: - Shared controls

    private func paginationBar(page: Binding<Int>, p: Pagination) -> some View {
        InventoryPager(
            page: Binding(get: { p.current }, set: { page.wrappedValue = $0 }),
            totalPages: p.totalPages,
            totalItems: p.total,
            startIndex: p.start,
            endIndex: p.end
        )
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text("Loading History…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    private func errorState(_ message: String) -> some View {
        InventoryEmptyState(
            icon: "exclamationmark.triangle",
            title: "Couldn't Load History",
            message: message,
            buttonTitle: "Retry",
            action: onRetry
        )
    }

    private func emptyState(_ text: String) -> some View {
        InventoryEmptyState(icon: "clock.arrow.circlepath", title: text)
    }
}

// MARK: - Pagination helper

private struct Pagination {
    let total: Int
    let pageSize: Int
    let current: Int
    let totalPages: Int
    let start: Int
    let end: Int

    init(total: Int, pageSize: Int, current: Int) {
        let size = max(1, pageSize)
        self.total = total
        self.pageSize = size
        self.totalPages = max(1, Int(ceil(Double(total) / Double(size))))
        let clamped = min(max(1, current), totalPages)
        self.current = clamped
        self.start = (clamped - 1) * size
        self.end = min(start + size, total)
    }

    var showControls: Bool { total > pageSize }

    func slice<T>(_ items: [T]) -> [T] {
        guard total > 0, start < items.count else { return [] }
        return Array(items[start..<min(end, items.count)])
    }
}

// MARK: - Tabs & filters

private enum HistoryTab: String, CaseIterable, Identifiable {
    case policyLogs
    case managementHistory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .policyLogs: return "Policy Logs"
        case .managementHistory: return "Management History"
        }
    }
    var icon: String {
        switch self {
        case .policyLogs: return "doc.text"
        case .managementHistory: return "terminal"
        }
    }
}

private enum PolicyStatusFilter: String, CaseIterable, Identifiable {
    case all, completed, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
    func matches(_ e: PolicyLogEntry) -> Bool {
        switch self {
        case .all: return true
        case .completed: return e.isSuccess
        case .failed: return !e.isSuccess
        }
    }
}

private enum CommandStatusFilter: String, CaseIterable, Identifiable {
    case all, completed, pending, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .completed: return "Completed"
        case .pending: return "Pending"
        case .failed: return "Failed"
        }
    }
    func matches(_ state: CommandState) -> Bool {
        switch self {
        case .all: return true
        case .completed: return state == .completed
        case .pending: return state == .pending
        case .failed: return state == .failed
        }
    }
}

private enum CommandState {
    case completed, pending, failed
    var label: String {
        switch self {
        case .completed: return "Completed"
        case .pending: return "Pending"
        case .failed: return "Failed"
        }
    }
}

// MARK: - Row model (precomputed so SwiftUI's type-checker stays fast)

private enum RowColor {
    case green, red, yellow
    var tone: InventoryTag.Tone {
        switch self {
        case .green: return .good
        case .red: return .bad
        case .yellow: return .warn
        }
    }
}

private struct DetailPair: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

private struct RowModel: Identifiable {
    let id: String
    let color: RowColor
    let title: String
    let badge: String?
    let date: Date?
    /// Raw date string to display when `date` couldn't be parsed.
    let rawDate: String?
    let username: String?
    let errorDetail: String?
    let details: [DetailPair]
}

extension DeviceHistorySectionView {
    fileprivate static func rowModel(policy: PolicyLogEntry, index: Int) -> RowModel {
        let title: String
        if let name = policy.policyName, !name.isEmpty {
            title = name
        } else if let pid = policy.policyId {
            title = "Policy \(pid)"
        } else {
            title = "Policy"
        }

        var details: [DetailPair] = []
        if let pid = policy.policyId { details.append(.init(label: "Policy ID", value: "\(pid)")) }
        if let status = policy.status, !status.isEmpty { details.append(.init(label: "Status", value: status)) }
        if let user = policy.username, !user.isEmpty { details.append(.init(label: "User", value: user)) }
        if let when = policy.dateTime, !when.isEmpty { details.append(.init(label: "Executed", value: when)) }

        return RowModel(
            id: "policy-\(index)-\(policy.id)",
            color: policy.isSuccess ? .green : .red,
            title: title,
            badge: policy.status,
            date: policy.date,
            rawDate: policy.dateTime ?? policy.dateTimeUtc ?? policy.dateTimeEpoch,
            username: policy.username,
            errorDetail: nil,
            details: details
        )
    }

    fileprivate static func rowModel(command: CommandEntry, state: CommandState, index: Int) -> RowModel {
        let color: RowColor
        switch state {
        case .completed: color = .green
        case .pending: color = .yellow
        case .failed: color = .red
        }
        let title = (command.name?.isEmpty == false) ? command.name! : "Command"

        var details: [DetailPair] = []
        details.append(.init(label: "Type", value: state.label))
        if let user = command.username, !user.isEmpty { details.append(.init(label: "User", value: user)) }

        // Jamf overloads `status` with the error text on failure.
        let errorDetail = (state == .failed) ? command.status : nil

        return RowModel(
            id: "cmd-\(index)-\(state.label)-\(command.id)",
            color: color,
            title: title,
            badge: state.label,
            date: command.date,
            rawDate: command.completedUtc ?? command.issuedUtc ?? command.failedUtc,
            username: command.username,
            errorDetail: errorDetail,
            details: details
        )
    }
}
