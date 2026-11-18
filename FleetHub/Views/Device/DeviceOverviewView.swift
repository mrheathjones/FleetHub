//
//  DeviceOverviewView.swift
//  FleetHub
//
//  Overview section of the computer detail view: quick-stat cards,
//  device health, and general/hardware/security summaries.
//

import SwiftUI

struct DeviceOverviewView: View {
    let computer: Computer
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @State private var showingUpdatesPopover: Bool = false
    /// Width this view was last offered; drives its wide/narrow layout.
    @State private var summaryWidth: CGFloat = 1100

    // MARK: - Overview Section
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // At-a-glance tiles. Widest arrangement that fits wins; a tile
            // is never squeezed below a legible width.
            ViewThatFits(in: .horizontal) {
                statRow(0..<5)
                VStack(spacing: 14) {
                    statRow(0..<3)
                    statRow(3..<5)
                }
                VStack(spacing: 14) {
                    statRow(0..<2)
                    statRow(2..<4)
                    statRow(4..<5)
                }
            }

            // Three summaries side by side when the pane has room for them;
            // stacked, full width, when it does not.
            Group {
                if summaryWidth >= 690 {
                    HStack(alignment: .top, spacing: 14) {
                        generalCard
                        hardwareCard
                        securityCard
                    }
                    .detailRowsStacked()
                    // All three as tall as the tallest.
                    .detailCardsFillHeight()
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 14) {
                        generalCard
                        hardwareCard
                        securityCard
                    }
                }
            }
            .readWidth(into: $summaryWidth)
        }
    }

    // MARK: - Summary Cards

    private var generalCard: some View {
        DetailCard(title: "General") {
            DetailRow("Device Name", computer.general?.name)
            DetailRow("Serial Number", computer.serialNumber)
            DetailRow("Asset Tag", computer.general?.assetTag)
            // Site is a tag in the device header.
            DetailRow("Jamf Binary", computer.general?.jamfBinaryVersion)
            DetailRow("UDID", computer.udid, monospaced: true)
            DetailRow("Management ID", computer.general?.managementId, monospaced: true)
        }
    }

    private var hardwareCard: some View {
        DetailCard(title: "Hardware Summary") {
            DetailRow("Model", computer.modelName)
            DetailRow("Model Identifier", computer.hardware?.modelIdentifier)
            DetailRow("Processor", computer.processorDescription)
            DetailRow("Architecture", computer.hardware?.processorArchitecture)
            DetailRow("Apple Silicon", computer.isAppleSilicon ? "Yes" : "No")
            DetailRow("Memory", computer.totalRAMGB.map { "\(Int($0)) GB" })
        }
    }

    private var securityCard: some View {
        DetailCard(title: "Security Summary") {
            DetailRow("FileVault", computer.fileVaultStatusText)
            DetailRow("SIP Status", computer.security?.sipStatus)
            DetailRow("Gatekeeper", DeviceFormatting.gatekeeperStatus(computer.security?.gatekeeperStatus))
            DetailRow("Firewall", computer.security?.firewallEnabled == true ? "Enabled" : "Disabled")
            DetailRow("Secure Boot", computer.security?.secureBootLevel)
        }
    }

    // MARK: - Stat Tiles

    /// One row of tiles. The 150pt minimum is what ViewThatFits measures to
    /// pick an arrangement; maxWidth lets the tiles share the row.
    private func statRow(_ range: Range<Int>) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(range), id: \.self) { index in
                statTile(index)
                    .frame(minWidth: 150, maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func statTile(_ index: Int) -> some View {
        switch index {
        case 0: lastCheckInTile
        case 1: batteryTile
        case 2: storageTile
        case 3: ipAddressTile
        default: updatesTile
        }
    }

    private var lastCheckInTile: some View {
        // "Nov 16, 2026 at 9:15 AM" → the date as the value, the time beneath.
        let parts = (DeviceFormatting.date(computer.general?.reportDate) ?? "").components(separatedBy: " at ")
        return DeviceStatTile(
            icon: "clock",
            tint: FleetHubTheme.accent,
            value: parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "N/A",
            title: "Last Check-In",
            caption: parts.count > 1 ? parts[1] : nil
        )
    }

    private var batteryTile: some View {
        let health = computer.hardware?.batteryHealth
        let capacity = computer.hardware?.batteryCapacityPercent
        let hasBattery = health != nil && health?.uppercased() != "UNSUPPORTED"
            && capacity != nil && capacity != -1

        let tint: Color
        switch (health ?? "").uppercased() {
        case "NORMAL", "GOOD":
            tint = FleetHubTheme.goodText
        case "SERVICE_RECOMMENDED", "SERVICE RECOMMENDED", "REPLACE_SOON", "REPLACE SOON":
            tint = FleetHubTheme.warnText
        case "REPLACE_NOW", "REPLACE NOW", "SERVICE_BATTERY", "SERVICE BATTERY":
            tint = FleetHubTheme.badText
        default:
            tint = FleetHubTheme.control
        }

        return DeviceStatTile(
            icon: hasBattery ? "battery.100" : "battery.0",
            tint: hasBattery ? tint : FleetHubTheme.control,
            value: hasBattery ? "\(capacity ?? 0)%" : "N/A",
            title: "Battery Health",
            caption: hasBattery ? formatBatteryHealth(health ?? "") : "No battery",
            progress: hasBattery ? Double(capacity ?? 0) / 100 : nil
        )
    }

    private var storageTile: some View {
        let availableMB = computer.storage?.bootDriveAvailableSpaceMegabytes
        let totalMB = getBootDriveTotalSize()
        let used: Double? = {
            guard let available = availableMB, let total = totalMB, total > 0 else { return nil }
            return Double(total - available) / Double(total)
        }()
        let tint: Color = {
            guard let used else { return FleetHubTheme.control }
            if used > 0.9 { return FleetHubTheme.badText }
            if used > 0.75 { return FleetHubTheme.warnText }
            return FleetHubTheme.accent
        }()
        let caption: String? = {
            guard let total = totalMB, let used else { return nil }
            return String(format: "free of %.0f GB · %d%% used", Double(total) / 1024, Int(used * 100))
        }()

        return DeviceStatTile(
            icon: "internaldrive",
            tint: tint,
            value: availableMB.map { String(format: "%.0f GB", Double($0) / 1024) } ?? "N/A",
            title: "Storage",
            caption: caption,
            progress: used
        )
    }

    private var ipAddressTile: some View {
        // The configured VPN IP extension attribute wins when it has a value
        // (features computers.vpnIPExtensionAttributeID; off = LAN IP only).
        let vpnIP = configManager.configuration.effectiveVPNIPExtensionAttribute
            .flatMap { computer.extensionAttributeValue($0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasVPN = vpnIP.map { !$0.isEmpty && $0.uppercased() != "N/A" } ?? false

        return DeviceStatTile(
            icon: hasVPN ? "lock.shield" : "network",
            tint: hasVPN ? FleetHubTheme.goodText : FleetHubTheme.accent,
            value: (hasVPN ? vpnIP : computer.ipAddress) ?? "N/A",
            title: "IP Address",
            caption: hasVPN ? "VPN connected" : "Last reported",
            badge: hasVPN ? "VPN" : nil
        )
    }

    private var updatesTile: some View {
        let updates = computer.softwareUpdates ?? []
        let hasUpdates = !updates.isEmpty

        return Button {
            if hasUpdates { showingUpdatesPopover.toggle() }
        } label: {
            DeviceStatTile(
                icon: hasUpdates ? "arrow.down.circle" : "checkmark.circle",
                tint: hasUpdates ? FleetHubTheme.warnText : FleetHubTheme.goodText,
                value: hasUpdates ? "\(updates.count)" : "None",
                title: "Updates",
                caption: hasUpdates ? "Available · show list" : "Up to date"
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasUpdates)
        // A button's label must not swallow the click as a text selection.
        .textSelection(.disabled)
        .popover(isPresented: $showingUpdatesPopover, arrowEdge: .bottom) {
            updatesPopoverContent(updates: updates)
        }
    }

    private func formatBatteryHealth(_ health: String) -> String {
        switch health.uppercased() {
        case "NORMAL", "GOOD": return "Normal"
        case "SERVICE_RECOMMENDED", "SERVICE RECOMMENDED": return "Service Recommended"
        case "REPLACE_SOON", "REPLACE SOON": return "Replace Soon"
        case "REPLACE_NOW", "REPLACE NOW": return "Replace Now"
        case "SERVICE_BATTERY", "SERVICE BATTERY": return "Service Battery"
        case "UNSUPPORTED": return "No Battery"
        default: return health
        }
    }
    
    private func getBootDriveTotalSize() -> Int? {
        // Try to get total size from the boot partition or first disk
        if let disks = computer.storage?.disks {
            // Look for the boot partition in any disk
            for disk in disks {
                if let partitions = disk.partitions {
                    // Find partition named "Macintosh HD" or similar boot partition
                    if let bootPartition = partitions.first(where: {
                        $0.name?.lowercased().contains("macintosh") == true ||
                        $0.partitionType?.uppercased() == "BOOT"
                    }) {
                        return bootPartition.sizeMegabytes
                    }
                }
                // Fallback to disk size
                if let diskSize = disk.sizeMegabytes {
                    return diskSize
                }
            }
        }
        return nil
    }
    
    private func updatesPopoverContent(updates: [SoftwareUpdate]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.cyan)
                Text("Available Updates")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.bottom, 4)
            
            Divider()
            
            ForEach(updates) { update in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(update.name ?? "Unknown Update")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.primary)
                        Spacer()
                        if let version = update.version {
                            Text(version)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let packageName = update.packageName {
                        Text(packageName)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 4)
                
                if update.id != updates.last?.id {
                    Divider()
                }
            }
        }
        .padding(16)
        .frame(width: 350)
    }
}

// MARK: - Stat Tile

/// One at-a-glance fact about a device, in the same shape as the Overview
/// page's summary tiles: tinted icon, value, title, optional caption and bar.
struct DeviceStatTile: View {
    let icon: String
    let tint: Color
    let value: String
    let title: String
    var caption: String? = nil
    /// 0…1; draws a bar under the value when set.
    var progress: Double? = nil
    /// Short label drawn as a pill beside the value, e.g. "VPN".
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(tint)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.14))
                )

            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(FleetHubTheme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FleetHubTheme.goodText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(FleetHubTheme.goodFill))
                        .fixedSize()
                        .accessibilityLabel("Connected over \(badge)")
                }
            }

            // The bar's row is always reserved so tiles line up.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    if let progress {
                        Capsule().fill(FleetHubTheme.trough)
                        Capsule()
                            .fill(tint)
                            .frame(width: max(0, geometry.size.width * min(1, max(0, progress))))
                    }
                }
            }
            .frame(height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FleetHubTheme.ink)
                    .lineLimit(1)
                Text(caption ?? " ")
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
