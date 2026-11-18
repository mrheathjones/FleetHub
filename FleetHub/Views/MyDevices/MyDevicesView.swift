//
//  MyDevicesView.swift
//  FleetHub
//
//  The `myDevices` module: the signed-in person's own Macs, iPhones, iPads and
//  Vision Pros, with the facts they would otherwise open a ticket to ask for —
//  serial, OS version, last check-in, free space, encryption state, battery.
//
//  READ-ONLY. This view issues no action and renders no action control of its
//  own. Opening a device pushes the SAME detail views the Devices module uses,
//  which gate every action on the role's `computerActions` /
//  `mobileDeviceActions` grants — so an end-user role sees information and
//  nothing else, while an admin looking at their own Mac keeps whatever their
//  role already allows. One code path, one set of gates.
//
//  When the identity lookup finds nothing, the view falls back (config
//  permitting) to the Mac FleetHub is running on and SAYS SO — an unlabelled
//  fallback would read as "this is assigned to you", which it is not.
//

import SwiftUI

struct MyDevicesView: View {
    @Binding var isInNestedView: Bool

    @ObservedObject private var session = UserSession.shared
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @StateObject private var service = MyDevicesService()

    @State private var navigationPath = NavigationPath()
    @State private var loadingDeviceID: String?
    @State private var detailError: String?
    @State private var gridWidth: CGFloat = 0

    private var settings: FeaturesConfiguration.MyDevicesSettings {
        configManager.configuration.features?.effectiveMyDevices ?? .empty
    }

    /// The page title tracks the sidebar row's managed label, so an org that
    /// renames the row to "My Equipment" gets the same word in both places.
    private var title: String {
        let override = configManager.configuration.sidebarItems
            .first { $0.id == NavigationDestination.myDevices.rawValue }?
            .title
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? NavigationDestination.myDevices.title : trimmed
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            content
                .navigationDestination(for: Computer.self) { computer in
                    DeviceView(computer: computer)
                }
                .navigationDestination(for: MobileDevice.self) { device in
                    MobileDeviceView(device: device)
                }
        }
        .onChange(of: navigationPath.count) { _, newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                isInNestedView = newValue > 0
            }
        }
        .onShowTabRoot(.myDevices) {
            if !navigationPath.isEmpty { navigationPath = NavigationPath() }
        }
        .onAppear {
            // The route can be re-entered with a stale nested flag (the sidebar
            // owns it, not this view) — same reset DevicesView performs.
            isInNestedView = navigationPath.count > 0
        }
        .task {
            // The machine layer can disable the module outright; don't spend a
            // Jamf round trip discovering that.
            guard settings.effectiveEnabled else { return }
            if service.origin == .idle {
                await service.load()
            }
        }
        // A different person signing in must never inherit the previous
        // operator's devices, even for one frame.
        .onChange(of: session.email) { _, _ in
            service.reset()
            navigationPath = NavigationPath()
            Task { await service.load() }
        }
    }

    private var content: some View {
        ZStack {
            FleetHubTheme.ground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    if !settings.effectiveEnabled {
                        messageState(
                            icon: "square.dashed",
                            title: "Not Available",
                            message: "\(title) is turned off on this Mac."
                        )
                    } else if service.isLoading && service.devices.isEmpty {
                        loadingState
                    } else if service.devices.isEmpty {
                        emptyState
                    } else {
                        deviceGrid
                        footnote
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 16) {
                titleBlock
                Spacer(minLength: 16)
                headerControls
            }
            VStack(alignment: .leading, spacing: 14) {
                titleBlock
                headerControls
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerControls: some View {
        HStack(spacing: 8) {
            identityChip
            RefreshButton(isLoading: service.isLoading) {
                Task { await service.load() }
            }
        }
        .fixedSize()
    }

    private var subtitle: String {
        switch service.origin {
        case .idle:
            return "Looking up the devices assigned to you…"
        case .assigned:
            return "Devices assigned to you in Jamf Pro. This view is read-only."
        case .localDevice:
            return "No assigned devices found — showing this Mac."
        case .empty:
            return "No devices found for your account."
        }
    }

    /// Who the lookup ran as. Present on every state because it is the first
    /// thing that explains an empty list: a person seeing their identity here
    /// and no devices below knows to check the assignment in Jamf, not their
    /// sign-in.
    @ViewBuilder
    private var identityChip: some View {
        let text: String? = {
            if !service.matchedUsernames.isEmpty {
                return "Jamf User: \(service.matchedUsernames.joined(separator: ", "))"
            }
            return session.email.isEmpty ? nil : session.email
        }()

        if let text {
            HStack(spacing: 8) {
                Image(systemName: "person")
                    .font(.system(size: 12, weight: .medium))
                Text(text)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .foregroundStyle(FleetHubTheme.control)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Grid

    /// One to three equal columns. Explicit rows rather than an adaptive
    /// grid: the count is small, and every card in a row shares one height.
    private var columnCount: Int {
        let fitting = Int((gridWidth + 20) / 380)
        return max(1, min(3, min(fitting, service.devices.count)))
    }

    private var deviceRows: [[MyDevice]] {
        let columns = columnCount
        return stride(from: 0, to: service.devices.count, by: columns).map {
            Array(service.devices[$0..<min($0 + columns, service.devices.count)])
        }
    }

    private var deviceGrid: some View {
        VStack(alignment: .leading, spacing: 20) {
            notices

            ForEach(Array(deviceRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 20) {
                    ForEach(row) { device in
                        MyDeviceCard(
                            device: device,
                            isLoading: loadingDeviceID == device.id,
                            onOpen: { open(device) }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                    // Keep a short last row on the same column widths.
                    ForEach(0..<(columnCount - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .readWidth(into: $gridWidth)
    }

    @ViewBuilder
    private var notices: some View {
        if service.origin == .localDevice {
            noticeBanner(
                icon: "desktopcomputer",
                tone: .warn,
                text: "Nothing in Jamf Pro is assigned to your account, so this is the Mac you are using right now. It may be assigned to someone else."
            )
        }
        if let note = service.directoryLookupNote {
            noticeBanner(icon: "info.circle", tone: .info, text: note)
        }
        if let error = service.errorMessage {
            noticeBanner(icon: "exclamationmark.triangle", tone: .bad, text: error)
        }
        if let detailError {
            noticeBanner(icon: "exclamationmark.triangle", tone: .bad, text: detailError)
        }
    }

    private var footnote: some View {
        noticeBanner(
            icon: "questionmark.circle",
            tone: .info,
            text: "Something missing or out of date? Your devices are matched to your sign-in email. Contact your administrator to correct an assignment."
        )
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Finding Your Devices…")
                .font(.system(size: 14))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error = service.errorMessage {
                messageState(
                    icon: "exclamationmark.triangle",
                    title: "Couldn't Load Your Devices",
                    message: error
                )
            } else {
                messageState(
                    icon: "laptopcomputer.slash",
                    title: "No Devices Found",
                    message: noDevicesMessage
                )
            }

            if let note = service.directoryLookupNote {
                noticeBanner(icon: "info.circle", tone: .info, text: note)
            }
        }
    }

    private var noDevicesMessage: String {
        var message = "Nothing in Jamf Pro is assigned to "
        message += session.email.isEmpty ? "your account" : session.email
        message += "."
        if settings.effectiveShowLocalDeviceFallback, LocalDeviceIdentity.serialNumber != nil {
            message += "\nThis Mac isn't enrolled under a record we can read either."
        }
        message += "\nContact your IT team if you believe this is wrong."
        return message
    }

    private func messageState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .fleetHubCard()
    }

    private enum NoticeTone {
        case info, warn, bad

        var fill: Color {
            switch self {
            case .info: FleetHubTheme.accent.opacity(0.12)
            case .warn: FleetHubTheme.warnFill
            case .bad: FleetHubTheme.badFill
            }
        }

        var text: Color {
            switch self {
            case .info: FleetHubTheme.accent
            case .warn: FleetHubTheme.warnText
            case .bad: FleetHubTheme.badText
            }
        }
    }

    private func noticeBanner(icon: String, tone: NoticeTone, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tone.text)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.fill)
        )
    }

    // MARK: - Navigation

    /// Macs push straight through (the list already carries the full
    /// inventory record). Mobile devices need one extra GET because the
    /// detail view takes the by-id shape, not the collection shape — the same
    /// two-step the Devices list performs.
    private func open(_ device: MyDevice) {
        detailError = nil

        switch device {
        case .computer(let computer):
            navigationPath.append(computer)
        case .mobileDevice(let item):
            loadingDeviceID = device.id
            Task {
                do {
                    let detail = try await service.mobileDeviceDetail(id: item.id)
                    loadingDeviceID = nil
                    navigationPath.append(detail)
                } catch {
                    loadingDeviceID = nil
                    detailError = "Couldn't open \(device.name): \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Device Card

/// One device, summarized. Deliberately richer than a list row: this is the
/// only place a non-admin sees their device, so the card carries the facts a
/// support call would otherwise ask for instead of making them open a detail
/// page to find a serial number.
struct MyDeviceCard: View {
    let device: MyDevice
    var isLoading: Bool = false
    let onOpen: () -> Void

    @State private var isHovered = false

    private struct Check: Identifiable {
        let label: String
        let passes: Bool
        var id: String { label }
    }

    /// Macs use the org's own scorecard rules (the same evaluator as the
    /// device page). Where no rule applies — and for mobile devices — the
    /// chips fall back to plain inventory facts.
    private var checks: [Check] {
        if case .computer(let computer) = device {
            let scored: [Check] = DeviceHealthEvaluator.evaluateComputer(computer).compactMap { result in
                switch result.status {
                case .compliant: Check(label: result.type.rawValue, passes: true)
                case .nonCompliant: Check(label: "Not \(result.type.rawValue)", passes: false)
                case .unknown, .excluded: nil
                }
            }
            if !scored.isEmpty { return scored }
        }

        var facts = [Check(label: device.isManaged ? "Managed" : "Unmanaged", passes: device.isManaged)]
        if device.isSupervised {
            facts.append(Check(label: "Supervised", passes: true))
        }
        if let encrypted = device.isEncrypted {
            facts.append(Check(label: encrypted ? "Encrypted" : "Not Encrypted", passes: encrypted))
        }
        return facts
    }

    var body: some View {
        let checks = checks
        let needsAttention = checks.contains { !$0.passes }

        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 16) {
                headerRow(needsAttention: needsAttention)
                FlowLayout(spacing: 6) {
                    ForEach(checks) { check in
                        chip(check)
                    }
                }
                if let storage = device.storage {
                    storageBar(storage)
                }
                facts
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                    .stroke(isHovered ? FleetHubTheme.accent.opacity(0.6) : FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovered = $0 }
        .help("Open \(device.name)")
    }

    private func headerRow(needsAttention: Bool) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(FleetHubTheme.accent.opacity(0.12))
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    DeviceIconView(
                        modelIdentifier: device.modelIdentifier,
                        modelName: device.modelName,
                        platform: device.platform,
                        size: 36
                    )
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                Text("\(device.modelName) · \(device.platform.rawValue) \(device.osVersion ?? "Unknown")")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(needsAttention ? "Needs Attention" : "Healthy")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(needsAttention ? FleetHubTheme.warnText : FleetHubTheme.goodText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(needsAttention ? FleetHubTheme.warnFill : FleetHubTheme.goodFill)
                )
                .fixedSize()
        }
    }

    private func chip(_ check: Check) -> some View {
        HStack(spacing: 5) {
            Image(systemName: check.passes ? "checkmark" : "xmark")
                .font(.system(size: 9, weight: .heavy))
            Text(check.label)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(check.passes ? FleetHubTheme.goodText : FleetHubTheme.badText)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(check.passes ? FleetHubTheme.goodFill : FleetHubTheme.badFill)
        )
        .fixedSize()
    }

    private func storageBar(_ storage: (fraction: Double, summary: String)) -> some View {
        let fraction = min(max(storage.fraction, 0), 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Storage")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                Spacer()
                Text(storage.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .lineLimit(1)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(FleetHubTheme.trough)
                    Capsule()
                        .fill(fraction > 0.9 ? Color(light: 0xC27A00, dark: 0xF2C26B) : FleetHubTheme.accentFill)
                        .frame(width: max(8, geometry.size.width * fraction))
                }
            }
            .frame(height: 8)
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            factRow("Serial Number", device.serialNumber ?? "Unknown")
            factRow("Last Check-In", lastCheckInText)
            factRow("Assigned To", device.assignedUser ?? "Unassigned")
            if let battery = device.batteryLevel {
                factRow("Battery", "\(battery)%")
            }
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
            HStack(spacing: 16) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 10)
        }
    }

    private var lastCheckInText: String {
        guard let date = device.lastCheckIn else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
