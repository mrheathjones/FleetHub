//
//  DeviceActionsMenu.swift
//  FleetHub
//
//  The device Actions menu and the presentation flow behind it: which
//  confirmation stage or sheet is showing, the typed-ERASE text, and the
//  Return to Service plan snapshot. Execution itself lives in
//  DeviceCommandExecutor.
//

import SwiftUI
import Observation

// MARK: - Action Flow

@Observable
@MainActor
final class DeviceActionFlow {
    var pendingAction: DeviceAction?
    /// First stage for destructive actions (Erase Device / Return to Service):
    /// a plain-language danger warning shown BEFORE the typed-ERASE
    /// acknowledgement, so the stakes and the specifics are two deliberate
    /// steps rather than one dialog the operator can click through.
    var showingDestructiveWarning: Bool = false
    var showingActionConfirmation: Bool = false
    /// Typed confirmation for destructive actions (operator must type ERASE).
    var confirmationText: String = ""
    /// Snapshot of the Return to Service plan taken when the confirmation
    /// dialog opens: the executed steps must be exactly the steps the
    /// operator confirmed, even if a profile re-push lands mid-dialog.
    var pendingRTSPlan: DeviceCommandExecutor.ReturnToServicePlan? = nil
    var showingUnlockAccountSheet: Bool = false
    var unlockUsername: String = ""
    var showingABMAssignSheet: Bool = false
    var showingPreStageAssignSheet: Bool = false
    var showingSiteMoveSheet: Bool = false

    /// Routes a granted menu action: Unlock User Account opens its own
    /// sheet; everything else goes through the confirmation overlay.
    func trigger(_ action: DeviceAction, executor: DeviceCommandExecutor) {
        let actionPolicy = DeviceActionPolicy.currentForComputers
        if action == .unlockUserAccount {
            showingUnlockAccountSheet = true
            return
        }
        if action == .abmAssign {
            // Server selection happens inside the sheet, so it owns the
            // whole flow (like the unlock-account sheet). Same defense in
            // depth as DeviceCommandExecutor.execute: never trust the menu
            // filter alone.
            if let denial = actionPolicy.denialReason(for: .abmAssign) {
                Task { await executor.reportActionDenial(denial, for: .abmAssign) }
            } else {
                showingABMAssignSheet = true
            }
            return
        }
        if action == .assignPreStage {
            // PreStage selection + optional asset tag happen inside the
            // sheet, so it owns the whole flow (like abmAssign). Same
            // defense in depth: never trust the menu filter alone.
            if let denial = actionPolicy.denialReason(for: .assignPreStage) {
                Task { await executor.reportActionDenial(denial, for: .assignPreStage) }
            } else {
                showingPreStageAssignSheet = true
            }
            return
        }
        if action == .moveToSite {
            // Site selection happens inside the sheet, so it owns the whole
            // flow (like abmAssign / assignPreStage). Same defense in depth:
            // never trust the menu filter alone. Note denialReason also
            // catches the empty-allowedSites case, so a role granted the
            // action with no sites reaches the audit log rather than an
            // empty picker.
            if let denial = actionPolicy.denialReason(for: .moveToSite) {
                Task { await executor.reportActionDenial(denial, for: .moveToSite) }
            } else {
                showingSiteMoveSheet = true
            }
            return
        }
        if action == .returnToService {
            // Freeze the plan the confirmation dialog will describe.
            pendingRTSPlan = DeviceCommandExecutor.ReturnToServicePlan(
                options: actionPolicy.returnToServiceOptions(),
                entraConfigured: MDMConfigurationManager.shared.configuration.isEntraConfigured
            )
        }
        pendingAction = action
        // Destructive actions get the danger warning first; the typed-ERASE
        // acknowledgement only opens once the operator clears that stage.
        if action.isDestructive && action.dangerWarning != nil {
            showingDestructiveWarning = true
        } else {
            showingActionConfirmation = true
        }
    }

    /// Clears every stage of the destructive-action flow. Used by Cancel and
    /// by the scrim tap so no stage can be left armed behind another.
    func dismissConfirmation() {
        showingDestructiveWarning = false
        showingActionConfirmation = false
        pendingAction = nil
        confirmationText = ""
    }

    /// Runs the confirmed action with the plan snapshotted for it.
    func execute(_ action: DeviceAction, with executor: DeviceCommandExecutor, openURL: OpenURLAction) {
        let plan = pendingRTSPlan
        Task {
            await executor.execute(action, returnToServicePlan: plan, openURL: openURL) { sheetAction in
                self.presentSheet(for: sheetAction)
            }
        }
    }

    /// Opens the sheet that owns a sheet-driven action's flow.
    func presentSheet(for action: DeviceAction) {
        switch action {
        case .unlockUserAccount: showingUnlockAccountSheet = true
        case .abmAssign: showingABMAssignSheet = true
        case .assignPreStage: showingPreStageAssignSheet = true
        case .moveToSite: showingSiteMoveSheet = true
        default: break
        }
    }
}

// MARK: - Actions Menu

/// Menu contents are driven entirely by the policy — the access
/// profile's deviceActions allow-list intersected with the user's role
/// capabilities: only granted actions render, sections with no granted
/// action disappear, and the profile's displayName override (menu label
/// only) is honored. Grouping/order stay app-defined. Takes the policy
/// bound by the caller so one render evaluates it once (execution paths
/// still read it fresh).
struct DeviceActionsMenu: View {
    let policy: DeviceActionPolicy
    let isExecuting: Bool
    let onSelect: (DeviceAction) -> Void

    var body: some View {
        Menu {
            ForEach(DeviceAction.MenuSection.allCases, id: \.self) { section in
                // Destructive actions are pulled out of their home section
                // and listed last, on their own, so Erase never sits one row
                // away from Restart.
                let visibleActions = DeviceAction.allCases.filter {
                    $0.menuSection == section && !$0.isDestructive && policy.isAllowed($0)
                }
                if !visibleActions.isEmpty {
                    Section(section.title) {
                        ForEach(visibleActions) { action in
                            Button {
                                onSelect(action)
                            } label: {
                                Label(ActionBranding.label(for: action), systemImage: ActionBranding.icon(for: action))
                            }
                        }
                    }
                }
            }

            let destructiveActions = DeviceAction.allCases.filter {
                $0.isDestructive && policy.isAllowed($0)
            }
            if !destructiveActions.isEmpty {
                Section("Destructive") {
                    ForEach(destructiveActions) { action in
                        Button(role: .destructive) {
                            onSelect(action)
                        } label: {
                            Label(ActionBranding.label(for: action), systemImage: ActionBranding.icon(for: action))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                Text("Actions")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(FleetHubTheme.accentFill)
            )
        }
        // .button + plain style keeps the custom label (fill, icon, chevron);
        // .borderlessButton draws its own text-only label on macOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isExecuting)
    }
}

// MARK: - Actions Panel

/// The same policy-gated actions as `DeviceActionsMenu`, laid out as buttons
/// grouped by how much damage a mis-click can do. Destructive actions sit in
/// their own fenced block at the bottom. Selecting one runs exactly the flow
/// the menu runs — nothing here executes on its own.
struct DeviceActionsPanel: View {
    let policy: DeviceActionPolicy
    let isExecuting: Bool
    /// Buttons per row. 1 for the narrow column beside a device's sections.
    var columns: Int = 3
    /// True when the caller gives the card a fixed height: the title stays
    /// put and the groups scroll underneath it.
    var scrollsInside: Bool = false
    /// Actions the caller shows somewhere else (e.g. in the device header).
    var excluded: Set<DeviceAction> = []
    let onSelect: (DeviceAction) -> Void

    enum RiskGroup: String, CaseIterable, Identifiable {
        case everyday = "Everyday"
        case access = "Secrets and Access"
        case enrollment = "Enrollment and Site"
        case power = "Power"
        case destructive = "Destructive"

        var id: String { rawValue }

        var tint: Color {
            switch self {
            case .everyday: return FleetHubTheme.accent
            case .access: return Color(light: 0x5A31BC, dark: 0xC0A6FF)
            case .enrollment: return FleetHubTheme.control
            case .power: return FleetHubTheme.warnText
            case .destructive: return FleetHubTheme.badText
            }
        }
    }

    static func group(for action: DeviceAction) -> RiskGroup {
        if action.isDestructive { return .destructive }
        switch action {
        case .viewLocalAdminPassword, .viewFileVaultKey, .unlockUserAccount, .ssh:
            return .access
        case .moveToSite, .abmAssign, .abmUnassign, .assignPreStage:
            return .enrollment
        case .restart, .restartSilent, .shutdown:
            return .power
        default:
            return .everyday
        }
    }

    private func actions(in group: RiskGroup) -> [DeviceAction] {
        DeviceAction.allCases.filter {
            Self.group(for: $0) == group && !excluded.contains($0) && policy.isAllowed($0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Actions")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(FleetHubTheme.ink)
                if isExecuting {
                    ProgressView().controlSize(.small)
                }
            }

            if scrollsInside {
                ScrollView {
                    groups
                }
            } else {
                groups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: scrollsInside ? .infinity : nil, alignment: .topLeading)
        .fleetHubCard()
        .disabled(isExecuting)
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(RiskGroup.allCases.filter { $0 != .destructive }) { group in
                let visible = actions(in: group)
                if !visible.isEmpty {
                    section(group, actions: visible, columns: columns)
                }
            }

            let destructive = actions(in: .destructive)
            if !destructive.isEmpty {
                section(.destructive, actions: destructive, columns: min(columns, 2))
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(FleetHubTheme.badFill.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(FleetHubTheme.badText.opacity(0.3), lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ group: RiskGroup, actions: [DeviceAction], columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.rawValue)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundColor(group == .destructive ? FleetHubTheme.badText : FleetHubTheme.muted)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(actions) { action in
                    ActionPanelButton(
                        title: ActionBranding.label(for: action),
                        icon: ActionBranding.icon(for: action),
                        tint: group.tint,
                        isOutlined: group == .destructive
                    ) {
                        onSelect(action)
                    }
                }
            }
        }
    }
}

private struct ActionPanelButton: View {
    let title: String
    let icon: String
    let tint: Color
    let isOutlined: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(isOutlined ? FleetHubTheme.surface : tint.opacity(isHovered ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(tint.opacity(isHovered ? 0.6 : 0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
