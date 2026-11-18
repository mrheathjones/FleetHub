//
//  DeviceComplianceViews.swift
//  FleetHub
//
//  Two device-page sections:
//    • Compliance — the device's result under each Jamf Compliance
//      Benchmark (Platform API; shown only when it is configured).
//    • Declarative Management — whether DDM is enabled and the status items
//      the device has reported (Jamf Pro API).
//
//  Both load only when the section is opened: the compliance lookup costs
//  one request per benchmark rule, so it never runs on page load.
//
//  The Compliance section lists EVERY rule of every benchmark with its
//  state on this device — Failed, Passed, Unknown, Not Reported (Jamf has
//  no result for the device under that rule) or Not Checked (the request
//  for that rule failed, with the reason).
//

import SwiftUI

// MARK: - Compliance

struct DeviceComplianceSectionView: View {
    let serialNumber: String?

    @State private var results: [DeviceBenchmarkCompliance] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var progress: (done: Int, total: Int) = (0, 0)

    /// Rules Jamf returned a result for, across every benchmark.
    private var evaluatedTotal: Int { results.reduce(0) { $0 + $1.evaluated } }
    private var notCheckedTotal: Int { results.reduce(0) { $0 + $1.notChecked } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                statusCard {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.regular)
                        Text(progress.total > 0
                             ? "Checking Rule \(progress.done) of \(progress.total)…"
                             : "Looking Up This Device…")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(FleetHubTheme.muted)
                        if progress.total > 60 {
                            Text("Jamf reports results one rule at a time, so a large benchmark takes a little while.")
                                .font(.system(size: 12))
                                .foregroundStyle(FleetHubTheme.muted)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 44)
                }
            } else if let errorMessage {
                statusCard {
                    InventoryEmptyState(
                        icon: "exclamationmark.triangle",
                        title: "Unable to Load Compliance",
                        message: errorMessage,
                        buttonTitle: "Try Again",
                        action: { Task { await load(force: true) } }
                    )
                }
            } else if hasLoaded && results.isEmpty {
                statusCard {
                    InventoryEmptyState(
                        icon: "checklist",
                        title: "No Compliance Benchmarks",
                        message: "No benchmarks are set up in Jamf for this environment."
                    )
                }
            } else if hasLoaded {
                summaryCard
                ForEach(results) { result in
                    DeviceBenchmarkCard(result: result)
                }
            }
        }
        .task(id: serialNumber) { await load(force: false) }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        InventoryCardShell {
            InventoryToolbar(title: "Compliance")
            content()
        }
    }

    /// Totals across benchmarks, what could not be worked out and why, and
    /// a way to run the check again.
    private var summaryCard: some View {
        let failed = results.reduce(0) { $0 + $1.failed }
        let passed = results.reduce(0) { $0 + $1.passed }
        let unknown = results.reduce(0) { $0 + $1.unknown }
        return InventoryCardShell {
            InventoryToolbar(title: "Compliance") {
                HStack(spacing: 6) {
                    if evaluatedTotal > 0 {
                        if failed > 0 { InventoryTag(text: "\(failed) Failed", tone: .bad) }
                        InventoryTag(text: "\(passed) Passed", tone: .good)
                        if unknown > 0 { InventoryTag(text: "\(unknown) Unknown", tone: .warn) }
                    }
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                            Text("Check Again").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(FleetHubTheme.control)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FleetHubTheme.ground))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Ask Jamf for this device's results again")
                }
            }
            if evaluatedTotal == 0 && notCheckedTotal == 0 {
                InventoryEmptyState(
                    icon: "minus.circle",
                    title: "Not in the Scope of Any Benchmark",
                    message: "Jamf has this device on record but lists no result for it under any benchmark rule. It is either outside every benchmark's target, or it has not reported compliance results yet. The rules are listed below as Not Reported."
                )
            } else if notCheckedTotal > 0 {
                complianceNote(
                    "\(notCheckedTotal) rule\(notCheckedTotal == 1 ? "" : "s") could not be checked and \(notCheckedTotal == 1 ? "is" : "are") shown as Not Checked, with the reason on each. Check Again usually clears a temporary failure.",
                    tone: FleetHubTheme.warnText
                )
            } else {
                complianceNote(
                    "Every rule in each benchmark is listed below with its result on this device. Results are kept for ten minutes; Check Again asks Jamf afresh.",
                    tone: FleetHubTheme.muted
                )
            }
        }
    }

    private func complianceNote(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .textSelection(.enabled)
    }

    private func load(force: Bool) async {
        guard force || !hasLoaded, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        progress = (0, 0)
        defer { isLoading = false }
        do {
            results = try await ComplianceBenchmarkService.shared.deviceCompliance(
                serialNumber: serialNumber, force: force
            ) { done, total in
                progress = (done, total)
            }
            hasLoaded = true
        } catch is CancellationError {
            // Section closed mid-check; reopening starts again.
        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }
}

/// One benchmark on a device's page: every rule with its state, filterable
/// by state and sortable by rule or state. Failed rules come first.
private struct DeviceBenchmarkCard: View {
    let result: DeviceBenchmarkCompliance

    enum StateFilter: String, CaseIterable, Identifiable {
        case all, failed, passed, unknown
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .failed: "Failed"
            case .passed: "Passed"
            case .unknown: "Unknown"
            }
        }

        /// "Unknown" gathers everything without a pass or fail: Jamf's own
        /// Unknown, rules it reports nothing for, and rules that could not
        /// be checked. Each row still says which.
        func includes(_ state: DeviceRuleState) -> Bool {
            switch self {
            case .all: true
            case .failed: state == .failed
            case .passed: state == .passed
            case .unknown: state != .failed && state != .passed
            }
        }
    }

    @State private var filter: StateFilter = .all
    @State private var sort = TableSort<String>()
    @State private var searchText = ""
    @State private var showsAll = false

    private static let initialRowLimit = 50

    private func count(_ filter: StateFilter) -> Int {
        result.rules.count(where: { filter.includes($0.state) })
    }

    /// Filtered, then failed-first (the benchmark's own order within each
    /// state) unless a header was clicked.
    private var visibleRules: [DeviceBenchmarkCompliance.RuleResult] {
        let matching = result.rules.filter { rule in
            guard filter.includes(rule.state) else { return false }
            guard !searchText.isEmpty else { return true }
            return rule.ruleTitle.localizedCaseInsensitiveContains(searchText)
                || rule.ruleId.localizedCaseInsensitiveContains(searchText)
                || (rule.ruleNumber ?? "").localizedCaseInsensitiveContains(searchText)
        }
        guard sort.key != nil else {
            return matching.enumerated()
                .sorted { ($0.element.state.sortRank, $0.offset) < ($1.element.state.sortRank, $1.offset) }
                .map(\.element)
        }
        return matching.sorted(by: sort) { rule, column in
            switch column {
            case "State": .int(rule.state.sortRank)
            case "Number": .text(rule.ruleNumber)
            default: .text(rule.ruleTitle)
            }
        }
    }

    var body: some View {
        let rules = visibleRules
        let shown = showsAll ? rules : Array(rules.prefix(Self.initialRowLimit))
        InventoryCardShell {
            InventoryToolbar(
                title: result.title,
                countText: inventoryCountText(shown: rules.count, total: result.rules.count),
                search: $searchText,
                searchPrompt: "Rule name or number"
            ) {
                HStack(spacing: 6) {
                    if result.evaluated == 0 && result.notChecked == 0 {
                        InventoryTag(text: "Not Evaluated")
                    } else {
                        if result.failed > 0 { InventoryTag(text: "\(result.failed) Failed", tone: .bad) }
                        InventoryTag(text: "\(result.passed) Passed", tone: .good)
                        if result.unknown > 0 { InventoryTag(text: "\(result.unknown) Unknown", tone: .warn) }
                        if result.notChecked > 0 { InventoryTag(text: "\(result.notChecked) Not Checked", tone: .warn) }
                    }
                }
            }

            filterBar

            if result.rules.isEmpty {
                InventoryEmptyState(
                    icon: "checklist",
                    title: "No Rules",
                    message: "Jamf lists no rules for this benchmark yet. A benchmark that is still syncing has none to report."
                )
            } else if rules.isEmpty {
                InventoryEmptyState(
                    icon: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    title: searchText.isEmpty ? "No \(filter.title) Rules" : "No Matches",
                    message: searchText.isEmpty
                        ? "No rule in this benchmark is \(filter.title.lowercased()) on this device."
                        : "Try a different rule name or number."
                )
            } else {
                InventoryHeaderRow {
                    HStack(spacing: 14) {
                        SortableHeaderText("Rule", key: "Rule", sort: $sort)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SortableHeaderText("Number", key: "Number", sort: $sort)
                            .frame(width: 90, alignment: .leading)
                        SortableHeaderText("State", key: "State", sort: $sort)
                            .frame(width: 110, alignment: .trailing)
                    }
                }
                ForEach(shown) { rule in
                    InventoryRow {
                        HStack(alignment: .top, spacing: 14) {
                            InventoryPrimaryCell(title: rule.ruleTitle, subtitle: detail(for: rule))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(rule.discussion ?? rule.ruleTitle)
                            InventoryCellText(rule.ruleNumber)
                                .frame(width: 90, alignment: .leading)
                            InventoryTag(text: rule.state.title, tone: tone(for: rule.state))
                                .frame(width: 110, alignment: .trailing)
                        }
                    }
                }
                if rules.count > shown.count {
                    Button {
                        showsAll = true
                    } label: {
                        Text("Show All \(rules.count.formatted()) Rules")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// All / Failed / Passed / Unknown, each with its count.
    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(StateFilter.allCases) { option in
                let isSelected = option == filter
                Button {
                    filter = option
                    showsAll = false
                } label: {
                    Text("\(option.title) · \(count(option).formatted())")
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                                .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(FleetHubTheme.trough))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The rule's ID, plus why it has no pass or fail when it has none.
    private func detail(for rule: DeviceBenchmarkCompliance.RuleResult) -> String {
        switch rule.state {
        case .notReported:
            return "\(rule.ruleId) · Jamf lists no result for this device"
        case .notChecked(let reason):
            return "\(rule.ruleId) · \(reason)"
        case .unknown:
            return "\(rule.ruleId) · Jamf reports this result as unknown"
        case .failed, .passed:
            return rule.ruleId
        }
    }

    private func tone(for state: DeviceRuleState) -> InventoryTag.Tone {
        switch state {
        case .failed: .bad
        case .passed: .good
        case .unknown, .notChecked: .warn
        case .notReported: .neutral
        }
    }
}

// MARK: - Declarative Management

struct DeviceDDMSectionView: View {
    let managementId: String?
    /// From the inventory record; nil when Jamf did not report it.
    let ddmEnabled: Bool?

    @State private var items: [DDMStatusItem] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var sort = TableSort<String>()

    private var filtered: [DDMStatusItem] {
        let matching = searchText.isEmpty ? items : items.filter {
            $0.key.localizedCaseInsensitiveContains(searchText)
                || $0.value.localizedCaseInsensitiveContains(searchText)
        }
        return matching.sorted(by: sort) { item, column in
            switch column {
            case "Value": .text(item.value)
            case "Updated": .isoDate(item.lastUpdateTime)
            default: .text(item.key)
            }
        }
    }

    var body: some View {
        let shown = filtered
        InventoryCardShell {
            InventoryToolbar(
                title: "Declarative Management",
                countText: hasLoaded && errorMessage == nil ? inventoryCountText(shown: shown.count, total: items.count) : nil,
                search: $searchText,
                searchPrompt: "Key or value"
            ) {
                switch ddmEnabled {
                case .some(true): InventoryTag(text: "DDM Enabled", tone: .good)
                case .some(false): InventoryTag(text: "DDM Not Enabled", tone: .warn)
                case .none: InventoryTag(text: "DDM Unknown")
                }
            }

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Loading Status Items…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            } else if let errorMessage {
                InventoryEmptyState(
                    icon: "exclamationmark.triangle",
                    title: "Unable to Load DDM Status",
                    message: errorMessage,
                    buttonTitle: "Try Again",
                    action: { Task { await load(force: true) } }
                )
            } else if items.isEmpty {
                InventoryEmptyState(
                    icon: "tray",
                    title: "No Status Items",
                    message: ddmEnabled == false
                        ? "Declarative Device Management is not enabled on this device."
                        : "This device has not reported any DDM status to Jamf."
                )
            } else if shown.isEmpty {
                InventoryEmptyState(icon: "magnifyingglass", title: "No Matches", message: "Try a different key or value.")
            } else {
                InventoryHeaderRow {
                    columns(
                        key: SortableHeaderText("Key", key: "Key", sort: $sort),
                        value: SortableHeaderText("Value", key: "Value", sort: $sort),
                        updated: SortableHeaderText("Updated", key: "Updated", sort: $sort)
                    )
                }
                ForEach(shown) { item in
                    InventoryRow {
                        columns(
                            key: Text(item.key)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FleetHubTheme.ink)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true),
                            value: Text(item.value.isEmpty ? "—" : item.value)
                                .font(.system(size: 13))
                                .foregroundStyle(item.value.isEmpty ? FleetHubTheme.muted : FleetHubTheme.ink)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true),
                            updated: InventoryCellText(item.formattedUpdateTime)
                        )
                    }
                }
            }
        }
        .task(id: managementId) { await load(force: false) }
    }

    private func columns<Key: View, Value: View, Updated: View>(key: Key, value: Value, updated: Updated) -> some View {
        HStack(alignment: .top, spacing: 14) {
            key.frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            value.frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
            updated.frame(width: 150, alignment: .trailing)
        }
    }

    private func load(force: Bool) async {
        guard force || !hasLoaded, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await DDMStatusService.statusItems(managementId: managementId)
            hasLoaded = true
        } catch is CancellationError {
            // Section closed mid-load; reopening starts again.
        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }
}
