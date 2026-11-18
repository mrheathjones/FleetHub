//
//  ScopeIDInspector.swift
//  FleetHub
//
//  Lists every Jamf site and group present in the fleet alongside its id.
//
//  The Health Scorecard is targeted entirely by id — a site or group can be
//  renamed in Jamf, and a rename must never silently change what is counted.
//  But FleetHub displays no Jamf ids anywhere else, so without this an admin has
//  to dig them out of Jamf by hand to author a targeting profile. That is a hard
//  blocker on the model being usable, not a convenience.
//
//  Built from cached inventory rather than a directory API, so it costs no
//  request and can only ever show ids that real devices actually carry — an id
//  listed here is guaranteed to match something.
//

import SwiftUI

struct ScopeIDInspector: View {
    @ObservedObject private var calculator = HealthMetricsCalculator.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText: String = ""
    @State private var copiedID: String? = nil

    private var entries: [HealthMetricsCalculator.ScopeDirectoryEntry] {
        let all = calculator.scopeDirectory
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.id.contains(query)
        }
    }

    private var grouped: [(kind: HealthMetricsCalculator.ScopeDirectoryEntry.Kind,
                           items: [HealthMetricsCalculator.ScopeDirectoryEntry])] {
        let kinds: [HealthMetricsCalculator.ScopeDirectoryEntry.Kind] =
            [.site, .computerGroup, .mobileGroup]
        return kinds.compactMap { kind in
            let items = entries.filter { $0.kind == kind }
            return items.isEmpty ? nil : (kind: kind, items: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if calculator.scopeDirectory.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(grouped, id: \.kind) { section in
                            sectionView(section.kind, section.items)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
            }
        }
        .frame(width: 560, height: 620)
        .background(FleetHubTheme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scope IDs")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Spacer()
                Button { dismiss() } label: {
                    SettingsButtonLabel(text: "Done", kind: .primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }

            Text("Health Scorecard targets are written with these ids, not names — a site renamed in Jamf keeps its id, so what you measure doesn't change underneath you. Click an id to copy it.")
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            SearchBar(text: $searchText, placeholder: "Filter by name or id")
        }
        .padding(22)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "questionmark.folder")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)
            Text("No Sites or Groups Found in the Current Inventory")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)
            Text("Sites come from the GENERAL inventory section and groups from GROUP_MEMBERSHIPS (computers) or GROUPS (mobile). If those aren't in features → inventorySections, there is nothing to list.")
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionView(
        _ kind: HealthMetricsCalculator.ScopeDirectoryEntry.Kind,
        _ items: [HealthMetricsCalculator.ScopeDirectoryEntry]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(kind.rawValue)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text(items.first?.configKeyHint ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FleetHubTheme.muted)
                    .textSelection(.enabled)
                Spacer()
            }
            .padding(.bottom, 8)

            ForEach(items, id: \.identity) { entry in
                Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
                row(entry)
            }
        }
    }

    private func row(_ entry: HealthMetricsCalculator.ScopeDirectoryEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FleetHubTheme.ink)
                        .textSelection(.enabled)
                    if let isSmart = entry.isSmart {
                        Text(isSmart ? "Smart" : "Static")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.control)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(FleetHubTheme.trough))
                    }
                }
                Text("\(entry.deviceCount) device\(entry.deviceCount == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
            }

            Spacer()

            let copied = copiedID == entry.identity
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.id, forType: .string)
                copiedID = entry.identity
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if copiedID == entry.identity { copiedID = nil }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(entry.id)
                        .font(.system(size: 12, design: .monospaced))
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(copied ? FleetHubTheme.goodText : FleetHubTheme.accent)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(copied ? FleetHubTheme.goodFill : FleetHubTheme.accent.opacity(0.12))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy id for use in healthScorecard targets")
        }
        .padding(.vertical, 9)
    }
}
