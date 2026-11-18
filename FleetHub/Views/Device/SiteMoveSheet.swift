//
//  SiteMoveSheet.swift
//  FleetHub
//
//  The Move-to-Site flow for the `moveToSite` device action, presented from
//  the computer Device Details Actions menu. Changes which Jamf Pro site the
//  computer's record belongs to (PATCH computers-inventory-detail). Nothing
//  touches the running Mac — but site membership drives scoping, so
//  site-targeted policies, profiles and groups start or stop applying at the
//  device's next check-in.
//
//  Authorization model (identical to PreStageAssignmentSheet / ABMAssignmentSheet):
//  the host supplies policyProvider, a closure re-deriving the LIVE
//  DeviceActionPolicy. The sheet consults it at open AND again at execution,
//  so a role revocation or config hot-reload while the sheet sits open still
//  denies — nothing is frozen at presentation. The site picker is filtered by
//  the grant's allowedSites (with the reserved `all` literal), and the SAME
//  check is re-run at execute: the picker is UI, never the gate.
//
//  Sites are matched by ID, not name — a renamed site keeps its scope. The
//  picker always DISPLAYS the resolved site NAME; the id is only ever the
//  wire value. A grant whose allowedSites match no site that exists in Jamf
//  replaces the form with a fail-closed notice (the empty-scope case is
//  already hidden upstream by DeviceActionPolicy, so this covers the
//  narrower "every listed id was deleted in Jamf" race).
//
//  Audit model: onFinished fires for EVERY end state — success, thrown
//  errors, and in-sheet denials — so the host audit-logs executed and denied
//  writes alike.
//

import SwiftUI

struct SiteMoveSheet: View {
    /// Jamf INVENTORY id of the device being moved — Computer.id for a
    /// computer, MobileDevice.id for a mobile device (NOT the managementId
    /// either platform uses for MDM commands). Used only for the empty-guard
    /// and audit copy; the actual write goes through `performMove`, which the
    /// host binds to the right platform endpoint.
    let deviceID: String
    let deviceName: String
    let serialNumber: String
    /// The device's current site, read from the inventory record. Optional:
    /// a device may have no site ("None"/"Full Jamf Pro"), in which case the
    /// current-site row is hidden and any permitted site is a valid target.
    let currentSiteID: String?
    let currentSiteName: String?
    /// Header title — the host passes the override-aware ActionBranding.label
    /// so a profile displayName rename carries through.
    let title: String
    /// Re-derives the LIVE policy. Consulted at open and again at execute.
    /// The host binds this to the computer OR mobile-device policy, so the
    /// same sheet gates correctly on either platform's capability set.
    let policyProvider: () -> DeviceActionPolicy
    /// Performs the actual site move for the target site id. The host binds
    /// this to JamfSiteService.moveComputer or .moveMobileDevice — the sheet
    /// stays platform-agnostic and never names an endpoint itself.
    let performMove: (_ siteID: String) async throws -> Void
    /// Fires for EVERY end state (success, thrown error, in-sheet denial) so
    /// the host audit-logs all of them.
    let onFinished: (_ success: Bool, _ siteName: String?, _ detail: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case loading
        case ready
        case executing
        case finished(success: Bool, title: String, message: String)
        case unavailable(String)
    }

    @State private var phase: Phase = .loading
    @State private var permittedSites: [JamfSiteRecord] = []
    @State private var selectedSiteID: String?

    private var isExecuting: Bool {
        if case .executing = phase { return true }
        return false
    }

    private var normalizedSerial: String {
        serialNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Move is a no-op (or disallowed) when nothing is chosen or the chosen
    /// site is the one the device is already in.
    private var canMove: Bool {
        guard let selectedSiteID, !isExecuting else { return false }
        return selectedSiteID != currentSiteID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

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
        .frame(width: 480, height: 430)
        .background(FleetHubTheme.surface)
        .interactiveDismissDisabled(isExecuting)
        .task { await prepare() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "building.2")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(FleetHubTheme.accent)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(FleetHubTheme.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text("\(deviceName) • \(normalizedSerial)")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.control)
                    .frame(width: 30, height: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(FleetHubTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isExecuting)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    // MARK: Phases

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FleetHubTheme.control)
    }

    private var loadingBody: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading Sites from Jamf Pro…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FleetHubTheme.muted)
        }
    }

    private func unavailableBody(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(FleetHubTheme.warnText)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
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

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Current Site")
                Text(currentSiteName ?? "None")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.ink)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                            .fill(FleetHubTheme.ground)
                    )
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Move to Site")
                Menu {
                    Picker("", selection: $selectedSiteID) {
                        Text("Select a Site…").tag(String?.none)
                        ForEach(permittedSites) { site in
                            // The current site is shown but reads as such, so the
                            // operator can see there is nowhere new to move to
                            // rather than the row simply being absent.
                            Text(pickerLabel(for: site))
                                .tag(String?.some(site.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedSiteLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(selectedSiteID == nil ? FleetHubTheme.muted : FleetHubTheme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.muted)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                            .stroke(FleetHubTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .disabled(isExecuting)
                .accessibilityLabel("Move to Site")
            }

            // Single source of truth for the safety copy — never restated
            // here where it could drift from the action's message.
            Text(DeviceAction.moveToSite.message)
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { dismiss() } label: {
                    SettingsButtonLabel(text: "Cancel")
                        .opacity(isExecuting ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isExecuting)

                Button {
                    Task { await executeMove() }
                } label: {
                    HStack(spacing: 8) {
                        if isExecuting {
                            ProgressView().controlSize(.small)
                        }
                        SettingsButtonLabel(text: "Move", kind: .primary)
                    }
                    .opacity(canMove || isExecuting ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!canMove)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var selectedSiteLabel: String {
        guard let selectedSiteID,
              let site = permittedSites.first(where: { $0.id == selectedSiteID }) else {
            return "Select a Site…"
        }
        return pickerLabel(for: site)
    }

    private func finishedBody(success: Bool, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(success ? FleetHubTheme.goodText : FleetHubTheme.warnText)
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            ScrollView {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 130)

            Button { dismiss() } label: {
                SettingsButtonLabel(text: "Done", kind: .primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(24)
    }

    private func pickerLabel(for site: JamfSiteRecord) -> String {
        site.id == currentSiteID ? "\(site.name) (current)" : site.name
    }

    // MARK: Actions

    @MainActor
    private func prepare() async {
        let policy = policyProvider()
        guard policy.isAllowed(.moveToSite) else {
            phase = .unavailable("Your current role does not permit moving devices between sites.")
            onFinished(false, nil, "Denied by policy at sheet open")
            return
        }
        guard !deviceID.isEmpty else {
            phase = .unavailable("This device has no Jamf Pro record id — it cannot be moved.")
            onFinished(false, nil, "No device id")
            return
        }

        do {
            let all = try await JamfSiteService.shared.fetchSites()
            // canMoveDevice folds the `all` sentinel — never branch around it.
            let permitted = all.filter { policy.canMoveDevice(toSiteID: $0.id) }
            guard !permitted.isEmpty else {
                phase = .unavailable(all.isEmpty
                    ? "No sites exist in Jamf Pro yet — there is nowhere to move this device."
                    : "Your role permits no sites that exist in Jamf Pro. Ask an administrator to check allowedSites on your role in the access profile.")
                onFinished(false, nil, "No permitted site exists in Jamf")
                return
            }
            permittedSites = permitted

            // Preselect the sole target only when it is an actual MOVE — if the
            // one permitted site IS the current site there is nothing to do, so
            // leave the picker unselected (Move stays disabled).
            if permitted.count == 1, permitted[0].id != currentSiteID {
                selectedSiteID = permitted[0].id
            }
            phase = .ready
        } catch {
            phase = .unavailable("Could not load sites from Jamf Pro: \(error.localizedDescription)")
            onFinished(false, nil, "Site load failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func executeMove() async {
        guard let siteID = selectedSiteID,
              let site = permittedSites.first(where: { $0.id == siteID }) else { return }

        // Re-derive the LIVE policy — a revocation or config change while the
        // sheet sat open must deny here, whatever the picker shows.
        let policy = policyProvider()
        guard policy.isAllowed(.moveToSite) else {
            phase = .finished(success: false, title: "Not Permitted",
                              message: "Your current role no longer permits moving devices between sites.")
            onFinished(false, site.name, "Denied by policy at execution")
            return
        }
        guard policy.canMoveDevice(toSiteID: site.id) else {
            phase = .finished(success: false, title: "Not Permitted",
                              message: "Your role's grant does not permit the site \"\(site.name)\".")
            onFinished(false, site.name, "Denied by allowedSites for site id \(site.id) (\"\(site.name)\")")
            return
        }

        phase = .executing

        do {
            try await performMove(site.id)
            let fromClause = currentSiteName.map { "from \($0) " } ?? ""
            phase = .finished(
                success: true,
                title: "Moved to \(site.name)",
                message: "The device's record was moved \(fromClause)to \(site.name). Site-scoped policies, profiles and group memberships take effect at the device's next check-in.")
            onFinished(true, site.name,
                       "Moved to site \"\(site.name)\" (id \(site.id))\(currentSiteName.map { " from \"\($0)\"" } ?? "")")
        } catch {
            phase = .finished(success: false, title: "Move Failed",
                              message: error.localizedDescription)
            onFinished(false, site.name, error.localizedDescription)
        }
    }
}
