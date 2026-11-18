//
//  PreStageAssignmentSheet.swift
//  FleetHub
//
//  The Assign-to-PreStage flow for the `assignPreStage` device action,
//  presented from the computer Device Details Actions menu. Registers the
//  device's serial to a Jamf Pro Computer PreStage Enrollment (and, when an
//  asset tag is entered, upserts an Inventory Preload record first). Nothing
//  touches a running Mac — both writes take effect at the device's next
//  Automated Device Enrollment.
//
//  Authorization model (identical to ABMAssignmentSheet): the host supplies
//  policyProvider, a closure that re-derives the LIVE DeviceActionPolicy. The
//  sheet consults it at open AND again at execution, so a role revocation or
//  config hot-reload while the sheet sits open still denies — nothing is
//  frozen at presentation. The PreStage picker is filtered by the grant's
//  allowedPrestages (with the reserved `all` literal), and the SAME check is
//  re-run at execute: the picker is UI, never the gate. A grant that permits
//  no PreStages that exist in Jamf replaces the form with a fail-closed
//  notice.
//
//  Audit model: onFinished fires for EVERY end state — success, the
//  informative not-yet-eligible outcome, thrown errors, and in-sheet
//  denials — so the host audit-logs executed and denied writes alike.
//
//  This is the COMPUTER-only flow: JamfPreStageService targets
//  /api/v3/computer-prestages and Inventory Preload deviceType "Computer".
//  Mobile-device PreStage support (a different Jamf API) is a follow-up.
//

import SwiftUI

struct PreStageAssignmentSheet: View {
    let serialNumber: String
    let deviceName: String
    /// Header title — the host passes the override-aware
    /// ActionBranding.label so a profile displayName rename carries through.
    let title: String
    /// Re-derives the LIVE policy. Consulted at open and again at execute.
    let policyProvider: () -> DeviceActionPolicy
    /// Fires for EVERY end state (success, not-yet-eligible, thrown error,
    /// in-sheet denial) so the host audit-logs all of them.
    let onFinished: (_ success: Bool, _ preStageName: String?, _ detail: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case ready
        case executing
        /// success drives the green icon; the informative not-yet-eligible
        /// outcome sets success == false but is not a hard failure.
        case finished(success: Bool, title: String, message: String)
        case unavailable(String)
    }

    @State private var phase: Phase = .loading
    @State private var permittedPreStages: [JamfPreStage] = []
    @State private var selectedPreStageId: String?
    /// The serial's current PreStage displayName, resolved best-effort at
    /// open (a lookup failure just hides the row — never blocks the form).
    @State private var currentPreStageName: String?
    @State private var assetTag = ""

    private var isExecuting: Bool {
        if case .executing = phase { return true }
        return false
    }

    private var normalizedSerial: String {
        serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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
        .frame(width: 500, height: 500)
        .background(FleetHubTheme.surface)
        .interactiveDismissDisabled(isExecuting)
        .task { await prepare() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox")
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
                Text("\(deviceName) · \(normalizedSerial)")
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
            .disabled(isExecuting)
            .accessibilityLabel("Close")
        }
        .padding(22)
    }

    // MARK: Phases

    private var loadingBody: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading PreStages From Jamf Pro…")
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
            if let currentPreStageName {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("Current PreStage")
                    HStack(spacing: 8) {
                        Circle().fill(FleetHubTheme.goodText).frame(width: 8, height: 8)
                        Text(currentPreStageName)
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
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Assign to PreStage")
                // Native pop-up button on purpose: a custom-styled Menu read
                // as static text here (see PreStageView.preStageMenu).
                Picker("", selection: $selectedPreStageId) {
                    Text("Select a PreStage…").tag(String?.none)
                    ForEach(permittedPreStages) { prestage in
                        Text(prestage.displayName).tag(String?.some(prestage.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .disabled(isExecuting)
            }

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Asset Tag (Optional)")
                TextField(
                    "",
                    text: $assetTag,
                    prompt: Text("Leave blank to assign the PreStage only").foregroundColor(FleetHubTheme.muted)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(FleetHubTheme.ink)
                .disabled(isExecuting)
                .settingsFieldBox()
                Text("When set, an Inventory Preload record is saved with this asset tag before the PreStage is assigned.")
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let selectedPreStageId,
               let current = currentPreStageName,
               let selected = permittedPreStages.first(where: { $0.id == selectedPreStageId }),
               selected.displayName != current {
                Label("The device is currently in \(current) — assigning will move it.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Single source of truth for the safety copy — never restated
            // here where it could drift from the action's message.
            Text(DeviceAction.assignPreStage.message)
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

                let isBlocked = selectedPreStageId == nil || isExecuting
                Button {
                    Task { await executeAssign() }
                } label: {
                    HStack(spacing: 8) {
                        if isExecuting {
                            ProgressView().controlSize(.small)
                        }
                        SettingsButtonLabel(text: "Assign", kind: .primary)
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
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundColor(success ? FleetHubTheme.goodText : FleetHubTheme.warnText)
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
            .frame(maxHeight: 150)

            Button { dismiss() } label: {
                SettingsButtonLabel(text: "Done", kind: .primary)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }

    // MARK: Actions

    @MainActor
    private func prepare() async {
        let policy = policyProvider()
        guard policy.isAllowed(.assignPreStage) else {
            phase = .unavailable("Your current role does not permit assigning devices to a PreStage.")
            onFinished(false, nil, "Denied by policy at sheet open")
            return
        }
        guard !normalizedSerial.isEmpty else {
            phase = .unavailable("This device has no serial number to register in a PreStage.")
            onFinished(false, nil, "No serial number")
            return
        }

        do {
            let all = try await JamfPreStageService.shared.fetchPreStages()
            // canUsePrestage folds the `all` sentinel — never branch around it.
            let permitted = all.filter { policy.canUsePrestage(named: $0.displayName) }
            guard !permitted.isEmpty else {
                phase = .unavailable(all.isEmpty
                    ? "No computer PreStage enrollments exist in Jamf Pro yet — there is nothing to assign."
                    : "Your role permits no PreStages that exist in Jamf Pro. Ask an administrator to add allowedPrestages to your role in the access profile.")
                return
            }
            permittedPreStages = permitted

            // Best-effort current-PreStage lookup — a failure just hides the
            // row, it must never block the form or fail the sheet.
            if let currentId = try? await JamfPreStageService.shared.currentPreStageId(forSerial: normalizedSerial) {
                currentPreStageName = all.first(where: { $0.id == currentId })?.displayName
            }

            if permitted.count == 1 { selectedPreStageId = permitted[0].id }
            phase = .ready
        } catch {
            phase = .unavailable("Could not load PreStages from Jamf Pro: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func executeAssign() async {
        guard let prestageId = selectedPreStageId,
              let prestage = permittedPreStages.first(where: { $0.id == prestageId }) else { return }

        // Re-derive the LIVE policy — a revocation or config change while the
        // sheet sat open must deny here, whatever the picker shows.
        let policy = policyProvider()
        guard policy.isAllowed(.assignPreStage) else {
            phase = .finished(success: false, title: "Not Permitted",
                              message: "Your current role no longer permits assigning devices to a PreStage.")
            onFinished(false, prestage.displayName, "Denied by policy at execution")
            return
        }
        guard policy.canUsePrestage(named: prestage.displayName) else {
            phase = .finished(success: false, title: "Not Permitted",
                              message: "Your role's grant does not permit PreStage \"\(prestage.displayName)\".")
            onFinished(false, prestage.displayName, "Denied by allowedPrestages for PreStage \"\(prestage.displayName)\"")
            return
        }

        let serial = normalizedSerial
        let tag = assetTag.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reflect the trimmed value so what the operator sees is what was
        // sent (and a post-failure retry re-uses the clean value).
        assetTag = tag

        phase = .executing

        // A failure AFTER the preload upsert must disclose the write that
        // already happened — a durable record misreported as a no-op is an
        // audit violation.
        var preloadSaved = false
        func preloadNote() -> String {
            preloadSaved ? " Note: the Inventory Preload record (asset tag \(tag)) WAS saved." : ""
        }

        do {
            if !tag.isEmpty {
                try await JamfPreStageService.shared.upsertInventoryPreload(serial: serial, assetTag: tag)
                preloadSaved = true
            }
            try await JamfPreStageService.shared.assign(serial: serial, toPreStage: prestage.id)
            phase = .finished(
                success: true,
                title: "Assigned to \(prestage.displayName)",
                message: "The PreStage\(tag.isEmpty ? "" : " and asset tag \(tag)") take\(tag.isEmpty ? "s" : "") effect at the device's next Automated Device Enrollment.")
            onFinished(true, prestage.displayName,
                       "Assigned PreStage \"\(prestage.displayName)\"\(tag.isEmpty ? "" : " • asset tag \(tag)")")
        } catch let error as PreStageError {
            if case .serialNotEligible = error {
                // Informative, not a hard failure: Jamf does not consider the
                // serial a valid ADE device (e.g. manually enrolled, or an
                // ABM assignment Jamf's ~2-minute sync hasn't picked up).
                phase = .finished(
                    success: false,
                    title: "PreStage Not Assigned",
                    message: (error.errorDescription ?? "Jamf Pro does not recognize this serial as an Automated Device Enrollment device.") + preloadNote())
                onFinished(false, prestage.displayName, (error.errorDescription ?? "serialNotEligible") + preloadNote())
            } else {
                phase = .finished(success: false, title: "Assignment Failed",
                                  message: (error.errorDescription ?? "PreStage assignment failed.") + preloadNote())
                onFinished(false, prestage.displayName, (error.errorDescription ?? "PreStage assignment failed.") + preloadNote())
            }
        } catch {
            phase = .finished(success: false, title: "Assignment Failed",
                              message: error.localizedDescription + preloadNote())
            onFinished(false, prestage.displayName, error.localizedDescription + preloadNote())
        }
    }
}
