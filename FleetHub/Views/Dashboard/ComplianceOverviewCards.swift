//
//  ComplianceOverviewCards.swift
//  FleetHub
//
//  Two Overview cards:
//    • Compliance Benchmarks — one row per Jamf Compliance Benchmark with
//      its fleet compliance percentage and how many rules are failing
//      somewhere. Each row opens to show every rule's own numbers: devices
//      passing, failing and unknown, and the rule's pass percentage.
//      Platform API only; the Overview omits the card entirely when no
//      Platform integration is configured.
//    • Declarative Management — how many Macs in inventory report DDM as
//      enabled, from the inventory already in the cache (no extra fetch).
//

import SwiftUI

// MARK: - Compliance Benchmarks

struct ComplianceBenchmarksCard: View {
    @ObservedObject private var service = ComplianceBenchmarkService.shared
    /// Observed so the card re-checks availability when the configuration
    /// or a delivered secret changes.
    @ObservedObject private var configManager = MDMConfigurationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compliance Benchmarks")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Text("How the fleet measures against each Jamf benchmark.")
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                Spacer(minLength: 8)
                if service.isLoading {
                    ProgressView().controlSize(.small)
                } else if ComplianceBenchmarkService.isAvailable {
                    Button {
                        Task { await service.loadSummary(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.muted)
                            .frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FleetHubTheme.ground))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reload compliance benchmarks")
                    .accessibilityLabel("Reload Compliance Benchmarks")
                }
            }

            if let reason = ComplianceBenchmarkService.unavailableReason {
                note(reason, tone: FleetHubTheme.warnText)
            } else if let error = service.errorMessage, service.summaries.isEmpty {
                note(error, tone: FleetHubTheme.badText)
            } else if service.summaries.isEmpty {
                note(service.isLoading || service.lastLoaded == nil
                     ? "Loading benchmarks…"
                     : "No benchmarks are set up in Jamf for this environment.",
                     tone: FleetHubTheme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(service.summaries.enumerated()), id: \.element.id) { index, benchmark in
                        if index > 0 {
                            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                        }
                        ComplianceBenchmarkRow(
                            benchmark: benchmark,
                            isExpanded: service.expandedBenchmarkIDs.contains(benchmark.id),
                            onToggle: { service.toggleExpanded(benchmark.id) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
        // Loads on first appearance, and again the moment the integration
        // becomes usable (the secret arrives, the profile is corrected).
        .task(id: ComplianceBenchmarkService.isAvailable) { await service.loadSummary() }
    }

    private func note(_ text: String, tone: Color) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(tone)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct ComplianceBenchmarkRow: View {
    let benchmark: ComplianceBenchmarkSummary
    /// Whether this benchmark's rule list is open. Owned by the service so
    /// it outlives the card.
    let isExpanded: Bool
    let onToggle: () -> Void

    private var tone: (text: Color, bar: Color) {
        guard let percentage = benchmark.compliancePercentage else {
            return (FleetHubTheme.muted, FleetHubTheme.muted)
        }
        switch percentage {
        case 90...: return (FleetHubTheme.goodText, Color(light: 0x0E7A4B, dark: 0x6FD8A5))
        case 70..<90: return (FleetHubTheme.warnText, Color(light: 0xC27A00, dark: 0xF2C26B))
        default: return (FleetHubTheme.badText, Color(light: 0xB3261E, dark: 0xFF9C94))
        }
    }

    private var detail: String {
        var parts: [String] = []
        let failing = benchmark.failingRuleCount
        parts.append(failing == 0 ? "No Rules Failing" : "\(failing) Rule\(failing == 1 ? "" : "s") Failing")
        parts.append("\(benchmark.rules.count) Rule\(benchmark.rules.count == 1 ? "" : "s")")
        if benchmark.deviceCount > 0 {
            parts.append("\(benchmark.deviceCount.formatted()) Device\(benchmark.deviceCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The whole summary is the control that opens the rule list.
            Button(action: onToggle) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(FleetHubTheme.muted)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Text(benchmark.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.ink)
                            .lineLimit(1)
                        if !benchmark.syncState.isEmpty, benchmark.syncState.uppercased() != "SYNCED" {
                            Text(benchmark.syncState.capitalized.replacingOccurrences(of: "_", with: " "))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(FleetHubTheme.warnText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(FleetHubTheme.warnFill))
                                .fixedSize()
                        }
                        Spacer(minLength: 8)
                        Text(benchmark.compliancePercentage.map { "\(Int($0.rounded()))%" } ?? "No Data")
                            .font(.system(size: 14, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(tone.text)
                            .fixedSize()
                    }

                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(FleetHubTheme.trough)
                            if let percentage = benchmark.compliancePercentage {
                                Capsule()
                                    .fill(tone.bar)
                                    .frame(width: max(8, geometry.size.width * CGFloat(min(max(percentage, 0), 100) / 100)))
                            }
                        }
                    }
                    .frame(height: 8)

                    HStack(spacing: 8) {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(FleetHubTheme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !benchmark.rules.isEmpty {
                            Text(isExpanded ? "Hide Rules" : "Show Rules")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(FleetHubTheme.accent)
                                .fixedSize()
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(benchmark.rules.isEmpty)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(benchmark.title), \(benchmark.compliancePercentage.map { "\(Int($0.rounded())) percent compliant" } ?? "no data"), \(detail)")
            .accessibilityValue(isExpanded ? "Rules shown" : "Rules hidden")
            .accessibilityHint(benchmark.rules.isEmpty ? "" : "Shows or hides this benchmark's rules")

            if isExpanded, !benchmark.rules.isEmpty {
                ComplianceRuleTable(rules: benchmark.rules)
            }
        }
        .padding(.vertical, 10)
    }
}

/// One benchmark's rules on the Overview: per rule, how many devices pass,
/// fail and are unknown, and its pass percentage. The rules failing on the
/// most devices come first; every column sorts.
private struct ComplianceRuleTable: View {
    let rules: [ComplianceRuleStat]

    @State private var sort = TableSort<String>()
    @State private var showsAll = false

    private static let initialRowLimit = 10

    /// Most failing devices first, then most unknown, then the benchmark's
    /// own order — unless a header was clicked.
    private var ordered: [ComplianceRuleStat] {
        guard sort.key != nil else {
            return rules.enumerated()
                .sorted { left, right in
                    if left.element.failed != right.element.failed { return left.element.failed > right.element.failed }
                    if left.element.unknown != right.element.unknown { return left.element.unknown > right.element.unknown }
                    return left.offset < right.offset
                }
                .map(\.element)
        }
        return rules.sorted(by: sort) { rule, column in
            switch column {
            case "Passed": .int(rule.passed)
            case "Failed": .int(rule.failed)
            case "Unknown": .int(rule.unknown)
            case "Pass %": .number(rule.effectivePassPercentage)
            default: .text(rule.ruleTitle)
            }
        }
    }

    var body: some View {
        let all = ordered
        let shown = showsAll ? all : Array(all.prefix(Self.initialRowLimit))
        VStack(alignment: .leading, spacing: 0) {
            columns(
                rule: SortableHeaderText("Rule", key: "Rule", sort: $sort),
                passed: SortableHeaderText("Passed", key: "Passed", sort: $sort),
                failed: SortableHeaderText("Failed", key: "Failed", sort: $sort),
                unknown: SortableHeaderText("Unknown", key: "Unknown", sort: $sort),
                percentage: SortableHeaderText("Pass %", key: "Pass %", sort: $sort)
            )
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FleetHubTheme.trough))

            ForEach(Array(shown.enumerated()), id: \.element.id) { index, rule in
                if index > 0 {
                    Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                }
                columns(
                    rule: VStack(alignment: .leading, spacing: 1) {
                        Text(rule.ruleTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FleetHubTheme.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: [rule.ruleNumber, rule.ruleId].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .foregroundStyle(FleetHubTheme.muted)
                            .lineLimit(1)
                    }
                    .help(rule.discussion ?? rule.ruleTitle),
                    passed: number(rule.passed, FleetHubTheme.ink),
                    failed: number(rule.failed, rule.failed > 0 ? FleetHubTheme.badText : FleetHubTheme.muted),
                    unknown: number(rule.unknown, rule.unknown > 0 ? FleetHubTheme.warnText : FleetHubTheme.muted),
                    percentage: Text(rule.effectivePassPercentage.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(percentageTone(rule.effectivePassPercentage))
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }

            if all.count > Self.initialRowLimit {
                Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                Button {
                    showsAll.toggle()
                } label: {
                    Text(showsAll ? "Show Fewer Rules" : "Show All \(all.count.formatted()) Rules")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FleetHubTheme.ground))
        .textSelection(.enabled)
    }

    private func number(_ value: Int, _ color: Color) -> some View {
        Text(value.formatted())
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private func percentageTone(_ percentage: Double?) -> Color {
        guard let percentage else { return FleetHubTheme.muted }
        switch percentage {
        case 90...: return FleetHubTheme.goodText
        case 70..<90: return FleetHubTheme.warnText
        default: return FleetHubTheme.badText
        }
    }

    private func columns<Rule: View, Passed: View, Failed: View, Unknown: View, Percentage: View>(
        rule: Rule, passed: Passed, failed: Failed, unknown: Unknown, percentage: Percentage
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            rule.frame(maxWidth: .infinity, alignment: .leading)
            passed.frame(width: 62, alignment: .trailing)
            failed.frame(width: 56, alignment: .trailing)
            unknown.frame(width: 72, alignment: .trailing)
            percentage.frame(width: 58, alignment: .trailing)
        }
    }
}

// MARK: - Declarative Management

struct DeclarativeManagementCard: View {
    /// Macs in inventory reporting DDM enabled, and the Macs that reported
    /// the flag at all (records without it are left out of the total).
    let enabled: Int
    let reporting: Int

    var body: some View {
        let fraction = reporting > 0 ? CGFloat(enabled) / CGFloat(reporting) : 0
        VStack(alignment: .leading, spacing: 12) {
            Text("Declarative Management")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)

            if reporting == 0 {
                Text("No Macs in inventory report a DDM state yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("DDM Enabled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Spacer(minLength: 8)
                    Text("\(enabled.formatted()) of \(reporting.formatted()) Macs")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(FleetHubTheme.ink)
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(FleetHubTheme.trough)
                        Capsule()
                            .fill(FleetHubTheme.accentFill)
                            .frame(width: max(8, geometry.size.width * fraction))
                    }
                }
                .frame(height: 8)
                if enabled < reporting {
                    Text("\((reporting - enabled).formatted()) Not Enabled")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
        .textSelection(.enabled)
    }
}
