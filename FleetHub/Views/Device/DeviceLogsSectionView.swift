//
//  DeviceLogsSectionView.swift
//  FleetHub
//
//  Per-device audit log section of the computer detail view.
//

import SwiftUI

struct DeviceLogsSectionView: View {
    let computer: Computer
    @ObservedObject private var actionLogService = ActionLogService.shared
    @State private var sort = TableSort<String>()

    var body: some View {
        let deviceLogs = actionLogService.logs(forDeviceId: computer.id).sorted(by: sort) { entry, column in
            switch column {
            case "Action": .text(entry.actionName)
            case "Performed By": .text(entry.performedBy)
            case "Result": .flag(entry.success)
            default: .date(entry.timestamp)
            }
        }

        return InventoryCardShell {
            InventoryToolbar(title: "Action Logs", countText: "\(deviceLogs.count)")

            if deviceLogs.isEmpty {
                InventoryEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: "No Actions Logged Yet",
                    message: "Actions performed on this device will appear here for auditing."
                )
            } else {
                InventoryHeaderRow {
                    columns {
                        SortableHeaderText("Time", key: "Time", sort: $sort)
                    } action: {
                        SortableHeaderText("Action", key: "Action", sort: $sort)
                    } who: {
                        SortableHeaderText("Performed By", key: "Performed By", sort: $sort)
                    } result: {
                        SortableHeaderText("Result", key: "Result", sort: $sort)
                    }
                }

                LazyVStack(spacing: 0) {
                    ForEach(deviceLogs) { entry in
                        InventoryRow { row(entry) }
                    }
                }
            }
        }
    }

    private func columns<A: View, B: View, C: View, D: View>(
        @ViewBuilder time: () -> A,
        @ViewBuilder action: () -> B,
        @ViewBuilder who: () -> C,
        @ViewBuilder result: () -> D
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            time().frame(width: 170, alignment: .leading)
            action().frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            who().frame(width: 140, alignment: .leading)
            result().frame(width: 80, alignment: .trailing)
        }
    }

    /// The stored raw value keeps the old product name for compatibility;
    /// people see the current one.
    private func sourceTitle(_ source: ActionLogEntry.LogSource) -> String {
        source == .fleetHub ? Branding.productName : source.rawValue
    }

    private func row(_ entry: ActionLogEntry) -> some View {
        columns {
            InventoryCellText(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
        } action: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.actionName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                        .lineLimit(1)
                    InventoryTag(text: sourceTitle(entry.source))
                }
                if let ip = entry.ipAddressUsed {
                    Text(ip)
                        .font(.system(size: 11))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                if let error = entry.errorMessage, !entry.success {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.badText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } who: {
            InventoryCellText(entry.performedBy)
        } result: {
            InventoryTag(text: entry.success ? "Success" : "Failed", tone: entry.success ? .good : .bad)
        }
    }
}
