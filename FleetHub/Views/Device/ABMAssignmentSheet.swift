//
//  ABMAssignmentSheet.swift
//  FleetHub
//
//  The shared Apple Business Manager assign flow, presented from Device
//  Details (abmAssign device action) and the ABM Lookup tab.
//
//  Authorization model: the host supplies policyProvider, a closure that
//  re-derives the LIVE DeviceActionPolicy — the sheet consults it at open
//  AND again at execution, so a role revocation or config hot-reload while
//  the sheet sits open still denies (nothing is frozen at presentation).
//  Server-level scoping (options.allowedMdmServers, with the reserved
//  `all` literal) is likewise re-read from the live policy at execution.
//
//  Audit model: onFinished fires for EVERY end state — success, Apple-side
//  errors, timeouts, thrown errors, and in-sheet denials — so the host can
//  audit-log executed and denied mutations alike.
//
//  Unassign has no picker, so it stays a confirm-dialog flow in the host
//  views — the shared resolve/execute pieces live in ABMAssignmentExecutor
//  so the two hosts can't drift apart.
//

import SwiftUI

// MARK: - Shared resolve/execute helpers

enum ABMAssignmentExecutor {

    enum ExecutorError: LocalizedError {
        case missingSerial
        case deviceNotInABM(String)
        case notAssigned
        case serverListUnavailable

        var errorDescription: String? {
            switch self {
            case .missingSerial:
                return "This device has no serial number to look up in Apple Business Manager."
            case .deviceNotInABM(let serial):
                return "Serial \(serial) was not found in Apple Business Manager."
            case .notAssigned:
                return "The device is not assigned to any MDM server in Apple Business Manager."
            case .serverListUnavailable:
                return "The MDM server list could not be loaded from Apple Business Manager."
            }
        }
    }

    /// Cache-first ABM device resolution — safe for identity (id/serial
    /// never change between sweeps); assignment state is NOT taken from
    /// this, see currentServer.
    @MainActor
    static func resolveDevice(serial: String) async throws -> ABMOrgDevice {
        let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExecutorError.missingSerial }

        if let cached = ABMDeviceCache.shared.device(forSerial: trimmed) {
            return cached
        }
        guard let device = try await ABMAPIService.shared.findOrgDevice(serialNumber: trimmed) else {
            throw ExecutorError.deviceNotInABM(trimmed.uppercased())
        }
        return device
    }

    /// The device's CURRENT MDM server — always resolved live from the
    /// relationships endpoint, never from the last sweep's snapshot: this
    /// value authorizes unassignment (allowedMdmServers is checked against
    /// it) and is the id the mutation submits, so staleness is not an
    /// option. The server LIST is cache-first but refreshed live once if
    /// the assigned id isn't in it (server created after the sweep).
    @MainActor
    static func currentServer(
        for device: ABMOrgDevice,
        servers: [ABMMdmServer]
    ) async throws -> ABMMdmServer? {
        guard let serverId = try await ABMAPIService.shared.fetchAssignedServerId(deviceId: device.id) else {
            return nil
        }
        if let match = servers.first(where: { $0.id == serverId }) {
            return match
        }
        let fresh = try await ABMAPIService.shared.fetchMdmServers()
        if let match = fresh.first(where: { $0.id == serverId }) {
            return match
        }
        // Unknown server: name-based grants can never match it (deny,
        // fail-closed); only an `all` grant may act on it.
        return ABMMdmServer(id: serverId, serverName: serverId, serverType: nil,
                            createdDateTime: nil, updatedDateTime: nil)
    }

    /// Cache-first MDM server list.
    @MainActor
    static func loadServers() async throws -> [ABMMdmServer] {
        let cached = ABMDeviceCache.shared.mdmServers
        if !cached.isEmpty { return cached }
        return try await ABMAPIService.shared.fetchMdmServers()
    }
}

// MARK: - Assign Sheet

struct ABMAssignmentSheet: View {
    let serialNumber: String
    let deviceName: String
    /// Header title — hosts pass the override-aware policy.menuLabel so a
    /// profile displayName rename carries through.
    let title: String
    /// Re-derives the LIVE policy. Consulted at open and again at execute.
    let policyProvider: () -> DeviceActionPolicy
    /// Fires for EVERY end state (success, Apple errors, timeout, thrown
    /// error, in-sheet denial) so the host audit-logs all of them.
    let onFinished: (_ success: Bool, _ server: ABMMdmServer?, _ error: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case ready
        case executing
        case finished(success: Bool, title: String, message: String)
        case unavailable(String)
    }

    @State private var phase: Phase = .loading
    @State private var device: ABMOrgDevice?
    @State private var currentServer: ABMMdmServer?
    @State private var permittedServers: [ABMMdmServer] = []
    @State private var selectedServerId: String?

    // Optional post-assign PreStage step (gated by the grant's
    // allowPrestageOnAssign + allowedPrestages options).
    private enum PrestagePhase {
        case idle
        case loadingList
        case ready
        case running(String)
        case done(success: Bool, message: String)
        case unavailable(String)
    }

    @State private var prestageOfferAvailable = false
    @State private var prestagePhase: PrestagePhase = .idle
    @State private var offeredPrestages: [JamfPreStage] = []
    @State private var selectedPrestageId: String?
    @State private var prestageAssetTag = ""
    @State private var prestageTask: Task<Void, Never>?

    private var isPrestageRunning: Bool {
        if case .running = prestagePhase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            Group {
                switch phase {
                case .loading:
                    loadingBody
                case .unavailable(let message):
                    unavailableBody(message)
                case .ready, .executing:
                    formBody
                case .finished(let success, let title, let message):
                    finishedBody(success: success, title: title, message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 500, height: prestageOfferExpanded ? 640 : 450)
        .animation(.easeInOut(duration: 0.2), value: prestageOfferExpanded)
        .background(FleetHubTheme.surface)
        .interactiveDismissDisabled(isExecuting || isPrestageRunning)
        .task { await prepare() }
        .onDisappear {
            // Fail-safe: a dismissed sheet must never leave the eligibility
            // retry loop mutating Jamf with no UI attached.
            prestageTask?.cancel()
        }
    }

    /// Whether the finished view is currently showing the expanded
    /// PreStage step (drives the taller sheet frame).
    private var prestageOfferExpanded: Bool {
        guard case .finished(true, _, _) = phase, prestageOfferAvailable else { return false }
        if case .idle = prestagePhase { return false }
        return true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(FleetHubTheme.accent)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(FleetHubTheme.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(FleetHubTheme.ink)
                Text("\(deviceName) · \(serialNumber.uppercased())")
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(FleetHubTheme.control)
                    .frame(width: 30, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(FleetHubTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isExecuting || isPrestageRunning)
            .accessibilityLabel("Close")
        }
        .padding(22)
    }

    // MARK: Phases

    private var loadingBody: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Looking Up the Device in Apple Business Manager…")
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
        }
    }

    private func unavailableBody(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundColor(FleetHubTheme.warnText)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button { dismiss() } label: {
                SettingsButtonLabel(text: "Close")
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FleetHubTheme.control)
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Current Assignment")
                HStack(spacing: 8) {
                    Circle()
                        .fill(currentServer == nil ? FleetHubTheme.warnText : FleetHubTheme.goodText)
                        .frame(width: 8, height: 8)
                    Text(currentServer?.serverName ?? "Not Assigned to Any MDM Server")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FleetHubTheme.ink)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .fill(FleetHubTheme.ground)
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Assign To")
                // Native pop-up button: a custom-styled Menu read as static
                // text here, so this keeps the real AppKit control (same
                // pattern as PreStageView / PreStageAssignmentSheet).
                Picker("", selection: $selectedServerId) {
                    Text("Select an MDM Server…").tag(String?.none)
                    ForEach(permittedServers) { server in
                        Text(server.serverName).tag(String?.some(server.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .disabled(isExecuting)
            }

            if let selectedServerId,
               let current = currentServer,
               selectedServerId != current.id {
                Label("The device is currently assigned to \(current.serverName) — assigning will move it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Single source of truth for the safety copy — never restated
            // here where it could drift from the confirmation-dialog text.
            Text(DeviceAction.abmAssign.message)
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer()
                Button { dismiss() } label: {
                    SettingsButtonLabel(text: "Cancel")
                }
                .buttonStyle(.plain)
                .disabled(isExecuting)
                .keyboardShortcut(.cancelAction)

                let isBlocked = selectedServerId == nil || isExecuting || selectedServerId == currentServer?.id
                Button {
                    Task { await executeAssign() }
                } label: {
                    HStack(spacing: 8) {
                        if isExecuting {
                            ProgressView().controlSize(.small)
                        }
                        SettingsButtonLabel(text: assignButtonTitle, kind: .primary)
                    }
                    .opacity(isBlocked && !isExecuting ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isBlocked)
            }
        }
        .padding(22)
    }

    private func finishedBody(success: Bool, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 32))
                .foregroundColor(success ? FleetHubTheme.goodText : FleetHubTheme.badText)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(FleetHubTheme.ink)
                .multilineTextAlignment(.center)
            ScrollView {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.muted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: prestageOfferExpanded ? 60 : 130)

            if success && prestageOfferAvailable {
                prestageOfferSection
            }

            Button { dismiss() } label: {
                SettingsButtonLabel(text: "Done", kind: .primary)
                    .opacity(isPrestageRunning ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isPrestageRunning)
        }
        .padding(24)
    }

    // MARK: - Optional PreStage step (post-assign)

    /// Offered only after a SUCCESSFUL assign when the grant's options
    /// enable it. Always operator-optional — Done skips it. The eligibility
    /// retry exists because Jamf can't scope a serial its ~2-minute ABM
    /// sync hasn't delivered yet.
    @ViewBuilder
    private var prestageOfferSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)

            switch prestagePhase {
            case .idle:
                Button {
                    Task { await loadPrestageOffer() }
                } label: {
                    SettingsButtonLabel(text: "Register PreStage (Optional)", icon: "shippingbox")
                }
                .buttonStyle(.plain)

            case .loadingList:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading PreStages…")
                        .font(.system(size: 12))
                        .foregroundColor(FleetHubTheme.muted)
                }

            case .unavailable(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.warnText)
                    .fixedSize(horizontal: false, vertical: true)

            case .ready:
                VStack(alignment: .leading, spacing: 8) {
                    fieldLabel("Register PreStage (Optional)")
                    Picker("", selection: $selectedPrestageId) {
                        Text("Select a PreStage…").tag(String?.none)
                        ForEach(offeredPrestages) { prestage in
                            Text(prestage.displayName).tag(String?.some(prestage.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.large)

                    TextField(
                        "",
                        text: $prestageAssetTag,
                        prompt: Text("Asset tag (optional — saves an Inventory Preload record)")
                            .foregroundColor(FleetHubTheme.muted)
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .settingsFieldBox()

                    HStack(alignment: .center, spacing: 10) {
                        Button {
                            startPrestageRegistration()
                        } label: {
                            SettingsButtonLabel(text: "Register", kind: .primary)
                                .opacity(selectedPrestageId == nil ? 0.45 : 1)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedPrestageId == nil)
                        Text("Jamf may need a couple of minutes to sync the new assignment first — registration waits for it.")
                            .font(.system(size: 11))
                            .foregroundColor(FleetHubTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

            case .running(let status):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundColor(FleetHubTheme.muted)
                    }
                    Button {
                        prestageTask?.cancel()
                    } label: {
                        SettingsButtonLabel(text: "Cancel PreStage Registration")
                    }
                    .buttonStyle(.plain)
                }

            case .done(let stepSuccess, let stepMessage):
                Label(stepMessage, systemImage: stepSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(stepSuccess ? FleetHubTheme.goodText : FleetHubTheme.warnText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func loadPrestageOffer() async {
        prestagePhase = .loadingList
        let policy = policyProvider()

        // Live toggle check FIRST, distinctly — the offer flag was set at
        // assign-success and the grant may have been revoked since.
        guard policy.allowsPrestageOnAssign else {
            prestagePhase = .unavailable("The PreStage step is no longer enabled by your grant.")
            logPrestageStep(success: false, error: "Offer revoked by live policy at load (allowPrestageOnAssign off)")
            return
        }

        do {
            let all = try await JamfPreStageService.shared.fetchPreStages()
            // permitsPrestage folds BOTH the toggle and the `all` sentinel —
            // never branch around it (an allowsAllPrestages shortcut would
            // bypass the toggle fold).
            let permitted = all.filter { policy.canUsePrestage(named: $0.displayName) }
            guard !permitted.isEmpty else {
                prestagePhase = .unavailable("Your grant permits no PreStages that exist in Jamf Pro — the step is unavailable.")
                return
            }
            offeredPrestages = permitted
            if permitted.count == 1 { selectedPrestageId = permitted[0].id }
            prestagePhase = .ready
        } catch {
            prestagePhase = .unavailable("Could not load PreStages: \(error.localizedDescription)")
        }
    }

    private func startPrestageRegistration() {
        // Synchronous re-entrancy guard: flip out of .ready BEFORE spawning
        // the task so a double-click can't start two registrations.
        guard case .ready = prestagePhase,
              let prestageId = selectedPrestageId,
              let prestage = offeredPrestages.first(where: { $0.id == prestageId }) else { return }
        prestagePhase = .running("Starting…")
        prestageTask = Task { await runPrestageRegistration(prestage) }
    }

    @MainActor
    private func runPrestageRegistration(_ prestage: JamfPreStage) async {
        // Re-derive the LIVE options — the offer may have been revoked
        // while the sheet sat open.
        let policy = policyProvider()
        guard policy.allowsPrestageOnAssign,
              policy.canUsePrestage(named: prestage.displayName) else {
            prestagePhase = .done(success: false,
                                  message: "Your grant no longer permits PreStage \"\(prestage.displayName)\".")
            logPrestageStep(success: false, error: "Denied by live options for PreStage \"\(prestage.displayName)\"")
            return
        }

        let serial = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let tag = prestageAssetTag.trimmingCharacters(in: .whitespacesAndNewlines)

        // A cancel/failure AFTER the preload upsert must disclose the write
        // that already happened — a durable record misreported as a no-op
        // is an audit violation.
        var preloadSaved = false
        func preloadNote() -> String {
            preloadSaved ? " Note: the Inventory Preload record (asset tag \(tag)) WAS saved." : ""
        }

        do {
            if !tag.isEmpty {
                prestagePhase = .running("Saving Inventory Preload record…")
                try await JamfPreStageService.shared.upsertInventoryPreload(serial: serial, assetTag: tag)
                preloadSaved = true
            }
            prestagePhase = .running("Assigning PreStage \(prestage.displayName)…")
            try await JamfPreStageService.shared.assignWhenEligible(
                serial: serial,
                toPreStage: prestage.id,
                stillAuthorized: {
                    let live = self.policyProvider()
                    return live.allowsPrestageOnAssign
                        && live.canUsePrestage(named: prestage.displayName)
                },
                progress: { status in self.prestagePhase = .running(status) }
            )
            prestagePhase = .done(success: true,
                                  message: "PreStage \"\(prestage.displayName)\" registered\(tag.isEmpty ? "" : " with asset tag \(tag)").")
            logPrestageStep(success: true,
                            error: "Assigned PreStage \"\(prestage.displayName)\"\(tag.isEmpty ? "" : " • asset tag \(tag)")")
        } catch {
            // Cancellation can surface two ways: CancellationError from the
            // retry loop's sleep/checkpoint, or URLError(.cancelled) when
            // the click lands mid-HTTP-request. Both are operator cancels.
            let isCancel = error is CancellationError
                || (error as? URLError)?.code == .cancelled
                || Task.isCancelled
            if isCancel {
                prestagePhase = .done(success: false,
                                      message: "PreStage registration cancelled. Use the Pre-Stage tab to register the device later.\(preloadNote())")
                logPrestageStep(success: false, error: "Cancelled by operator.\(preloadNote())")
            } else {
                prestagePhase = .done(success: false,
                                      message: "\(error.localizedDescription) You can register the device from the Pre-Stage tab later.\(preloadNote())")
                logPrestageStep(success: false, error: "\(error.localizedDescription)\(preloadNote())")
            }
        }
    }

    private func logPrestageStep(success: Bool, error: String?) {
        ActionLogService.shared.logAction(
            actionName: "PreStage Registration (on assign)",
            actionCategory: "Apple Business Manager",
            deviceName: deviceName,
            deviceSerialNumber: serialNumber.uppercased(),
            deviceId: device?.id ?? serialNumber.uppercased(),
            success: success,
            errorMessage: error
        )
    }

    private var isExecuting: Bool {
        if case .executing = phase { return true }
        return false
    }

    private var assignButtonTitle: String {
        if let current = currentServer, selectedServerId != nil, selectedServerId != current.id {
            return "Reassign"
        }
        return "Assign"
    }

    // MARK: Actions

    @MainActor
    private func prepare() async {
        let policy = policyProvider()
        guard policy.isAllowed(.abmAssign) else {
            phase = .unavailable("Your current role does not permit assigning devices to an MDM server.")
            onFinished(false, nil, "Denied by policy at sheet open")
            return
        }
        do {
            let resolved = try await ABMAssignmentExecutor.resolveDevice(serial: serialNumber)
            let servers = try await ABMAssignmentExecutor.loadServers()
            let current = try await ABMAssignmentExecutor.currentServer(for: resolved, servers: servers)

            let permitted = policy.allowsAllMdmServers
                ? servers
                : servers.filter { policy.canAssignToMdmServer(named: $0.serverName) }

            guard !permitted.isEmpty else {
                phase = .unavailable("Your role's abmAssign grant lists no MDM servers that exist in this ABM tenant — there is nothing to assign to. Ask an administrator to update the profile's allowedMdmServers.")
                return
            }

            if permitted.count == 1, let current, permitted[0].id == current.id {
                phase = .unavailable("The device is already assigned to \(current.serverName) — there is nothing to change.")
                return
            }

            device = resolved
            currentServer = current
            permittedServers = permitted
            if permitted.count == 1, permitted[0].id != current?.id {
                selectedServerId = permitted[0].id
            }
            phase = .ready
        } catch {
            phase = .unavailable(error.localizedDescription)
        }
    }

    @MainActor
    private func executeAssign() async {
        guard let device,
              let serverId = selectedServerId,
              let server = permittedServers.first(where: { $0.id == serverId }) else { return }

        // Re-derive the LIVE policy — a revocation or config change while
        // the sheet sat open must deny here, whatever the picker shows.
        let policy = policyProvider()
        guard policy.isAllowed(.abmAssign) else {
            phase = .finished(success: false, title: "Not Permitted",
                              message: "Your current role no longer permits assigning devices to an MDM server.")
            onFinished(false, server, "Denied by policy at execution")
            return
        }
        guard policy.canAssignToMdmServer(named: server.serverName) else {
            phase = .finished(success: false, title: "Not Permitted",
                              message: "Your role's grant does not permit assigning to \(server.serverName).")
            onFinished(false, server, "Denied by allowedMdmServers for server \(server.serverName)")
            return
        }

        phase = .executing
        do {
            let outcome = try await ABMAPIService.shared.performAssignment(
                .assignDevices, deviceId: device.id, mdmServerId: server.id
            )
            switch outcome {
            case .succeeded:
                ABMDeviceCache.shared.applyAssignment(deviceId: device.id, serverId: server.id)
                // The optional PreStage step is offered only on success and
                // only when the LIVE grant enables it.
                prestageOfferAvailable = policy.allowsPrestageOnAssign
                phase = .finished(success: true, title: "Assigned to \(server.serverName)",
                                  message: "The assignment takes effect at the device's next Automated Device Enrollment.")
                onFinished(true, server, nil)
            case .completedWithErrors(let detail):
                phase = .finished(success: false, title: "Completed With Errors",
                                  message: "Apple accepted the request but reported errors:\n\n\(detail)")
                onFinished(false, server, "COMPLETED_WITH_ERROR")
            case .failed(let status):
                phase = .finished(success: false, title: "Assignment Failed",
                                  message: "Apple Business Manager reported the activity as \(status).")
                onFinished(false, server, status)
            case .stillRunning(let activityId):
                phase = .finished(success: false, title: "Still Processing",
                                  message: "Apple accepted the request but it had not completed when polling stopped (activity \(activityId)). Refresh the ABM Lookup tab shortly to confirm the result — the assignment may still apply.")
                onFinished(false, server, "Timed out polling activity \(activityId)")
            }
        } catch {
            phase = .finished(success: false, title: "Assignment Failed", message: error.localizedDescription)
            onFinished(false, server, error.localizedDescription)
        }
    }
}
