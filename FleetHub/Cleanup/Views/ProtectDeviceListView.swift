//
//  ProtectDeviceListView.swift
//  FleetHub
//
//  Jamf Protect computer records, independent of Jamf Pro. The only
//  action here is deleting the Protect record — Jamf Pro is never touched
//  from this view.
//

import SwiftUI

struct ProtectDeviceListView: View {
    @Environment(CleanupViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let filter: ProtectFilter

    @State private var selection: Set<String> = []
    @State private var searchText = ""
    /// Column sort. Starts with the most stale records first, as before.
    @State private var sort = TableSort<String>(key: "Days Stale", ascending: false)
    @State private var confirmingDelete = false
    @State private var isDeleting = false
    @State private var results: [ActionResult]?
    /// Observed so the delete gate re-evaluates when capabilities land
    /// after sign-in.
    @ObservedObject private var session = UserSession.shared

    /// The only action in this view is deleting the Jamf Protect record.
    private var canDeleteFromProtect: Bool {
        session.capabilities.canRunCleanupAction(.deleteFromProtect)
    }

    private var filterMatches: [ProtectDevice] {
        model.protectDevices(for: filter)
    }

    private var visibleDevices: [ProtectDevice] {
        let base = searchText.isEmpty ? filterMatches : filterMatches.filter {
            $0.hostName.localizedCaseInsensitiveContains(searchText)
                || $0.serial.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted(by: sort) { device, column in
            switch column {
            case "Computer": .text(device.hostName)
            case "Last Check-In": .date(device.checkin)
            // Never checked in is the most stale, not a blank.
            default: .number(device.daysSinceCheckin.map(Double.init) ?? .infinity)
            }
        }
    }

    private var selectedDevices: [ProtectDevice] {
        filterMatches.filter { selection.contains($0.uuid) }
    }

    private var visibleSelectedCount: Int {
        visibleDevices.count(where: { selection.contains($0.uuid) })
    }

    private var exportFilename: String {
        ExportNaming.filename(Branding.title, filter.title, date: Date())
    }

    private func buildTable() -> ReportTable {
        var subtitle = "Jamf Protect • \(filter.title)"
        if !searchText.isEmpty {
            subtitle += " • search “\(searchText)”"
        }
        return ReportBuilders.protectTable(
            title: "\(Branding.title) Cleanup — \(filter.title)",
            subtitle: subtitle,
            devices: visibleDevices,
            staleDays: model.settings.staleDays,
            includeSummary: true,
            generatedAt: Date()
        )
    }

    private var pageTitle: String {
        switch filter {
        case .all: "Jamf Protect Records"
        case .stale: "Stale Jamf Protect Records"
        }
    }

    private var pageSubtitle: String {
        let lead = "Deleting here removes only the Jamf Protect record. Jamf Pro is untouched."
        guard filter == .stale else { return lead }
        return "No Protect check-in for \(model.settings.staleDays)+ days. \(lead)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            tableCard
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FleetHubTheme.ground)
        .navigationBarBackButtonHidden(true)
        .sheet(item: resultsBox) { box in
            ProtectResultsSheet(results: box.results)
        }
        .confirmationDialog(
            "Delete \(selectedDevices.count) records from Jamf Protect?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete from Jamf Protect", role: .destructive) {
                runDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Jamf Pro is not affected — only the Jamf Protect records are removed.")
        }
    }

    // MARK: - Delete flow

    private func runDelete() {
        // Defense in depth: the delete bar is not rendered without the
        // grant, but enforcement must never live only in the UI.
        guard canDeleteFromProtect else { return }
        let targets = selectedDevices
        isDeleting = true
        Task {
            let outcome = await model.deleteProtectDevices(targets)
            selection.subtract(outcome.filter(\.success).compactMap { result in
                targets.first { $0.hostName == result.deviceName }?.uuid
            })
            results = outcome
            isDeleting = false
        }
    }

    /// Identifiable wrapper so the results sheet can be item-driven.
    private struct ResultsBox: Identifiable {
        let id = UUID()
        let results: [ActionResult]
    }

    private var resultsBox: Binding<ResultsBox?> {
        Binding(
            get: { results.map(ResultsBox.init) },
            set: { if $0 == nil { results = nil } }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            CleanupBackButton { dismiss() }

            VStack(alignment: .leading, spacing: 4) {
                Text(pageTitle)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(pageSubtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            HStack(spacing: 8) {
                CleanupExportMenu(filename: exportFilename, makeTable: buildTable)
                    .disabled(visibleDevices.isEmpty)
                RefreshButton(isLoading: model.isLoading || isDeleting) {
                    Task { await model.refresh() }
                }
            }
            .fixedSize()
        }
    }

    // MARK: - Table card

    private var tableCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Records")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)
                    Text(searchText.isEmpty
                         ? "\(filterMatches.count)"
                         : "\(visibleDevices.count) of \(filterMatches.count)")
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(FleetHubTheme.muted)
                }
                .fixedSize()
                Spacer(minLength: 8)
                searchField.frame(maxWidth: 260)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            HStack(spacing: 12) {
                CleanupCheckBox(state: checkAllState) {
                    let ids = Set(visibleDevices.map(\.uuid))
                    if ids.isSubset(of: selection) {
                        selection.subtract(ids)
                    } else {
                        selection.formUnion(ids)
                    }
                }
                .help("Select every record shown")
                .disabled(visibleDevices.isEmpty)

                ProtectColumns(
                    computer: columnTitle("Computer"),
                    checkIn: columnTitle("Last Check-In"),
                    days: columnTitle("Days Stale")
                )
            }
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(FleetHubTheme.ground)

            if visibleDevices.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleDevices) { device in
                            ProtectRow(
                                device: device,
                                isSelected: selection.contains(device.uuid)
                            ) {
                                toggle(device.uuid)
                            }
                            Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            actionBar
        }
        .background(FleetHubTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    private func columnTitle(_ title: String) -> some View {
        SortableHeaderText(title, key: title, sort: $sort)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
            TextField("", text: $searchText, prompt: Text("Host name or serial")
                .foregroundColor(FleetHubTheme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.ink)
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
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    private var checkAllState: CleanupCheckBox.State {
        if visibleDevices.isEmpty || visibleSelectedCount == 0 { return .off }
        return visibleSelectedCount == visibleDevices.count ? .on : .mixed
    }

    private var actionBar: some View {
        let count = selection.count
        return HStack(spacing: 10) {
            Text(count == 0 ? "None Selected" : "\(count) Selected")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(count == 0 ? FleetHubTheme.muted : FleetHubTheme.ink)

            Spacer(minLength: 8)

            if count > 0 {
                Button {
                    selection.removeAll()
                } label: {
                    CleanupOutlineLabel(text: "Clear")
                }
                .buttonStyle(.plain)
            }

            // No Protect delete grant → no delete button; the list stays
            // browsable and exportable, but read-only.
            if canDeleteFromProtect {
                Button {
                    confirmingDelete = true
                } label: {
                    HStack(spacing: 7) {
                        if isDeleting {
                            ProgressView().controlSize(.small)
                        }
                        Text("Delete from Protect")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                            .fill(Color(light: 0xB3261E, dark: 0xC8362D))
                    )
                    .opacity(count == 0 ? 0.45 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(count == 0 || isDeleting)
                .help(count == 0 ? "Select records to delete them from Jamf Protect" : "Delete the selected records from Jamf Protect")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
        .background(FleetHubTheme.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoading {
                ProgressView().controlSize(.regular)
                Text("Loading…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.muted)
            } else {
                Image(systemName: searchText.isEmpty ? "shield.checkered" : "magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(FleetHubTheme.muted)
                Text(searchText.isEmpty ? "No Records Here" : "No Matches")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
            }
        }
        .padding(24)
    }

    private func toggle(_ uuid: String) {
        if selection.contains(uuid) {
            selection.remove(uuid)
        } else {
            selection.insert(uuid)
        }
    }
}

// MARK: - Columns and row

private struct ProtectColumns<Computer: View, CheckIn: View, Days: View>: View {
    let computer: Computer
    let checkIn: CheckIn
    let days: Days

    var body: some View {
        HStack(spacing: 14) {
            computer.frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            checkIn.frame(width: 190, alignment: .leading)
            days.frame(width: 88, alignment: .trailing)
        }
    }
}

private struct ProtectRow: View {
    let device: ProtectDevice
    let isSelected: Bool
    let toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            CleanupCheckBox(state: isSelected ? .on : .off, action: toggle)

            ProtectColumns(
                computer: VStack(alignment: .leading, spacing: 1) {
                    Text(device.hostName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                        .lineLimit(1)
                    Text(device.serial)
                        .font(.system(size: 11))
                        .foregroundStyle(FleetHubTheme.muted)
                        .lineLimit(1)
                }
                .textSelection(.enabled),
                checkIn: Text(CleanupFormatters.lastContactString(device.checkin))
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                    .textSelection(.enabled),
                days: StaleBadge(days: device.daysSinceCheckin)
            )
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

// MARK: - Results sheet

private struct ProtectResultsSheet: View {
    let results: [ActionResult]
    @Environment(\.dismiss) private var dismiss

    private var failures: [ActionResult] { results.filter { !$0.success } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: failures.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(failures.isEmpty ? Color.green : .orange)
                        VStack(alignment: .leading) {
                            Text(failures.isEmpty ? "Protect records deleted" : "\(failures.count) deletions failed")
                                .font(.headline)
                            Text("\(results.count) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(results) { result in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(result.success ? Color.green : Color.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.deviceName)
                                .font(.callout)
                            if !result.success {
                                Text(result.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Results")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 380)
    }
}
