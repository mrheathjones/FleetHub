//
//  LogsView.swift
//  FleetHub
//
//  The audit trail of every MDM action performed from the app: one table
//  card with search, category chips, source and result filters, expandable
//  rows and paging.
//

import SwiftUI

struct LogsView: View {
    @ObservedObject private var logService = ActionLogService.shared
    /// Observed so the export gate re-evaluates when capabilities land
    /// after sign-in.
    @ObservedObject private var session = UserSession.shared

    @State private var searchText = ""
    @State private var selectedSource: ActionLogEntry.LogSource?
    @State private var selectedCategory: String?
    @State private var showSuccessOnly: Bool?
    @State private var expandedLogId: UUID?
    @State private var page = 0
    @State private var sort = TableSort<String>()
    @State private var showingClearConfirmation = false
    @State private var showingExportConfirmation = false
    @State private var cardWidth: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    private let pageSize = 25

    // MARK: - Data

    /// The DEBUG demo shows sample entries; the real store on this Mac is
    /// neither shown nor touched while it runs.
    private var isDemo: Bool {
        #if DEBUG
        return DemoMode.isEnabled
        #else
        return false
        #endif
    }

    private var allLogs: [ActionLogEntry] {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.actionLogs }
        #endif
        return logService.logs
    }

    private func filtered(_ logs: [ActionLogEntry]) -> [ActionLogEntry] {
        let query = searchText.lowercased()
        return logs.filter { entry in
            if !query.isEmpty,
               !entry.deviceName.lowercased().contains(query),
               !entry.deviceSerialNumber.lowercased().contains(query),
               !entry.actionName.lowercased().contains(query),
               !entry.performedBy.lowercased().contains(query) {
                return false
            }
            if let selectedSource, entry.source != selectedSource { return false }
            if let selectedCategory, entry.actionCategory != selectedCategory { return false }
            if let showSuccessOnly, entry.success != showSuccessOnly { return false }
            return true
        }
    }

    private func categories(in logs: [ActionLogEntry]) -> [String] {
        Array(Set(logs.map(\.actionCategory))).sorted()
    }

    // MARK: - Body

    var body: some View {
        let logs = allLogs
        let matches = filtered(logs).sorted(by: sort) { entry, column in
            switch column {
            case "Action": .text(entry.actionName)
            case "Category": .text(entry.actionCategory)
            case "Device": .text(entry.deviceName)
            case "Performed By": .text(entry.performedBy)
            case "Result": .flag(entry.success)
            default: .date(entry.timestamp)
            }
        }
        let pageCount = max(1, Int((Double(matches.count) / Double(pageSize)).rounded(.up)))
        let currentPage = min(page, pageCount - 1)
        let start = currentPage * pageSize
        let pageEntries = Array(matches[min(start, matches.count)..<min(start + pageSize, matches.count)])

        VStack(alignment: .leading, spacing: 20) {
            header(hasLogs: !logs.isEmpty)

            VStack(spacing: 0) {
                toolbar(logs: logs, matchCount: matches.count)
                columnHeader

                if logs.isEmpty {
                    emptyState
                } else if matches.isEmpty {
                    noResultsState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(pageEntries) { entry in
                                logRow(entry)
                                Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }

                footer(currentPage: currentPage, pageCount: pageCount)
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
        .onChange(of: searchText) { page = 0 }
        .onChange(of: sort) { page = 0 }
        .onChange(of: selectedSource) { page = 0 }
        .onChange(of: selectedCategory) { page = 0 }
        .onChange(of: showSuccessOnly) { page = 0 }
        .alert("Clear All Logs?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Clear All", role: .destructive) {
                logService.clearLogs()
            }
        } message: {
            Text("This will permanently delete all action logs. This cannot be undone.")
        }
    }

    // MARK: - Export

    private func exportCSVToPasteboard() {
        // Defense in depth: the button is not rendered without the grant,
        // but never let enforcement live only in the UI.
        guard session.capabilities.allowExport, !isDemo else { return }
        let csv = logService.exportAsCSV()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
        showingExportConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showingExportConfirmation = false
        }
    }

    // MARK: - Header

    private func header(hasLogs: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Action Logs")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text("Audit trail of every MDM action performed from \(Branding.productName).")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                // The audit trail leaves the app here (via the pasteboard),
                // so it answers to allowExport exactly like the Reports and
                // Cleanup exporters: no grant, no control.
                if session.capabilities.allowExport {
                    Button {
                        exportCSVToPasteboard()
                    } label: {
                        outlineLabel(
                            showingExportConfirmation ? "Copied" : "Export CSV",
                            icon: showingExportConfirmation ? "checkmark" : "square.and.arrow.down",
                            text: showingExportConfirmation ? FleetHubTheme.goodText : FleetHubTheme.ink,
                            border: FleetHubTheme.border
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasLogs || isDemo)
                    .help("Copy every log entry to the clipboard as CSV")
                }

                Button {
                    showingClearConfirmation = true
                } label: {
                    outlineLabel(
                        "Clear All",
                        icon: nil,
                        text: FleetHubTheme.badText,
                        border: FleetHubTheme.badText.opacity(0.35)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasLogs || isDemo)
                .opacity(hasLogs && !isDemo ? 1 : 0.5)
                .help(isDemo ? "Not available with sample data" : "Delete every log entry on this Mac")
            }
            .fixedSize()
        }
    }

    private func outlineLabel(_ title: String, icon: String?, text: Color, border: Color) -> some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(text)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Toolbar

    private func toolbar(logs: [ActionLogEntry], matchCount: Int) -> some View {
        let categories = categories(in: logs)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                searchField
                sourceMenu
                resultMenu
                Spacer(minLength: 8)
                Text("\(matchCount) of \(logs.count) Shown")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize()
            }

            if !categories.isEmpty {
                FlowLayout(spacing: 6) {
                    categoryChip("All Categories", isSelected: selectedCategory == nil) {
                        selectedCategory = nil
                    }
                    ForEach(categories, id: \.self) { category in
                        categoryChip(category, isSelected: selectedCategory == category) {
                            selectedCategory = selectedCategory == category ? nil : category
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
            TextField("", text: $searchText, prompt: Text("Search by device, serial, action, or user")
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
        .frame(minWidth: 180, maxWidth: 380)
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
        )
    }

    /// The stored raw value keeps the old product name for compatibility;
    /// people see the current one.
    private func sourceTitle(_ source: ActionLogEntry.LogSource) -> String {
        source == .fleetHub ? Branding.productName : source.rawValue
    }

    private var sourceMenu: some View {
        Menu {
            Picker("Source", selection: $selectedSource) {
                Text("All Sources").tag(ActionLogEntry.LogSource?.none)
                ForEach(ActionLogEntry.LogSource.allCases, id: \.self) { source in
                    Text(sourceTitle(source)).tag(ActionLogEntry.LogSource?.some(source))
                }
            }
            .pickerStyle(.inline)
        } label: {
            CleanupMenuLabel(text: selectedSource.map(sourceTitle) ?? "All Sources")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var resultMenu: some View {
        Menu {
            Picker("Result", selection: $showSuccessOnly) {
                Text("All Results").tag(Bool?.none)
                Text("Success").tag(Bool?.some(true))
                Text("Failed").tag(Bool?.some(false))
            }
            .pickerStyle(.inline)
        } label: {
            CleanupMenuLabel(text: showSuccessOnly.map { $0 ? "Success" : "Failed" } ?? "All Results")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func categoryChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : FleetHubTheme.control)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Capsule().fill(isSelected ? FleetHubTheme.accentFill : FleetHubTheme.surface))
                .overlay(Capsule().stroke(isSelected ? Color.clear : FleetHubTheme.border, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Table

    private var showsCategory: Bool { cardWidth >= 900 }
    private var showsPerformedBy: Bool { cardWidth >= 740 }

    private func columns<Time: View, Action: View, Category: View, Device: View, Who: View, Result: View>(
        @ViewBuilder time: () -> Time,
        @ViewBuilder action: () -> Action,
        @ViewBuilder category: () -> Category,
        @ViewBuilder device: () -> Device,
        @ViewBuilder who: () -> Who,
        @ViewBuilder result: () -> Result
    ) -> some View {
        HStack(spacing: 14) {
            time().frame(width: 150, alignment: .leading)
            action().frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            if showsCategory {
                category().frame(width: 130, alignment: .leading)
            }
            device().frame(width: 180, alignment: .leading)
            if showsPerformedBy {
                who().frame(width: 130, alignment: .leading)
            }
            result().frame(width: 84, alignment: .trailing)
            Color.clear.frame(width: 12, height: 1)
        }
    }

    private func headerText(_ title: String) -> some View {
        SortableHeaderText(title, key: title, sort: $sort)
    }

    private var columnHeader: some View {
        columns(
            time: { headerText("Time") },
            action: { headerText("Action") },
            category: { headerText("Category") },
            device: { headerText("Device") },
            who: { headerText("Performed By") },
            result: { headerText("Result") }
        )
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(FleetHubTheme.ground)
    }

    private func tag(_ text: String, fill: Color, ink: Color, weight: Font.Weight = .semibold) -> some View {
        Text(text)
            .font(.system(size: 12, weight: weight))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
    }

    private func logRow(_ entry: ActionLogEntry) -> some View {
        let isExpanded = expandedLogId == entry.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                columns(
                    time: {
                        Text(Self.timeString(entry.timestamp))
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.control)
                            .lineLimit(1)
                    },
                    action: {
                        Text(entry.actionName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.ink)
                            .lineLimit(1)
                    },
                    category: {
                        tag(entry.actionCategory, fill: FleetHubTheme.trough, ink: FleetHubTheme.control)
                    },
                    device: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.deviceName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FleetHubTheme.ink)
                                .lineLimit(1)
                            Text(entry.deviceSerialNumber)
                                .font(.system(size: 11))
                                .foregroundStyle(FleetHubTheme.muted)
                                .lineLimit(1)
                        }
                    },
                    who: {
                        Text(entry.performedBy)
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.ink)
                            .lineLimit(1)
                    },
                    result: {
                        tag(
                            entry.success ? "Success" : "Failed",
                            fill: entry.success ? FleetHubTheme.goodFill : FleetHubTheme.badFill,
                            ink: entry.success ? FleetHubTheme.goodText : FleetHubTheme.badText,
                            weight: .bold
                        )
                        .fixedSize()
                    }
                )
                .overlay(alignment: .trailing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.muted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expandedLogId = isExpanded ? nil : entry.id
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Hides details" : "Shows details")

            if isExpanded {
                expandedDetail(entry)
                    .transition(.opacity)
            }
        }
        .background(isExpanded ? FleetHubTheme.ground.opacity(0.6) : Color.clear)
    }

    private func expandedDetail(_ entry: ActionLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowLayout(spacing: 28) {
                detailField("Category", entry.actionCategory)
                detailField("Platform", entry.devicePlatform)
                detailField("Device ID", entry.deviceId)
                detailField("Serial Number", entry.deviceSerialNumber)
                detailField("Performed By", entry.performedBy)
                detailField("Source", sourceTitle(entry.source))
                if let ip = entry.ipAddressUsed {
                    detailField("IP Address", ip)
                }
                detailField("Time", entry.timestamp.formatted(date: .abbreviated, time: .standard))
            }

            if let error = entry.errorMessage, !entry.success {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
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
        .padding(.bottom, 16)
        .textSelection(.enabled)
    }

    private func detailField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(FleetHubTheme.muted)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.ink)
        }
        .fixedSize()
    }

    private static func timeString(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    // MARK: - Footer

    private func footer(currentPage: Int, pageCount: Int) -> some View {
        HStack(spacing: 6) {
            Text("Page \(currentPage + 1) of \(pageCount)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)
            Spacer()
            pageButton("chevron.left", label: "Previous Page", enabled: currentPage > 0) {
                page = currentPage - 1
                expandedLogId = nil
            }
            pageButton("chevron.right", label: "Next Page", enabled: currentPage < pageCount - 1) {
                page = currentPage + 1
                expandedLogId = nil
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
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.control)
                .frame(width: 40, height: 32)
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

    // MARK: - Empty States

    private var emptyState: some View {
        stateMessage(
            icon: "doc.text.magnifyingglass",
            title: "No Action Logs Yet",
            message: "Actions performed on devices are logged here for auditing."
        )
    }

    private var noResultsState: some View {
        stateMessage(
            icon: "magnifyingglass",
            title: "No Matching Logs",
            message: "Try adjusting your search or filters."
        )
    }

    private func stateMessage(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Logs View") {
    LogsView()
        .frame(width: 1000, height: 600)
}
#endif
