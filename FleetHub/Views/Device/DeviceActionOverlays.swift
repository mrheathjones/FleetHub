//
//  DeviceActionOverlays.swift
//  FleetHub
//
//  Modal overlays for device actions: the command result, the two-stage
//  destructive confirmation (danger warning → typed ERASE), the Return to
//  Service / Erase progress card, the unlock-account prompt, and the LAPS /
//  FileVault secret readouts. Rendered as direct children of the device
//  view's root ZStack, in stacking order.
//

import SwiftUI

struct DeviceActionOverlays: View {
    let computer: Computer
    @Bindable var executor: DeviceCommandExecutor
    @Bindable var flow: DeviceActionFlow
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Command result overlay
        commandResultOverlay

        // Destructive-action danger warning (stage 1 for erase/RTS)
        destructiveWarningOverlay

        // Action confirmation overlay
        actionConfirmationOverlay

        // Processing progress overlay (Return to Service multi-stage flow)
        processingOverlay

        // Unlock account sheet overlay
        unlockAccountOverlay

        // Local admin password overlay

        // FileVault key overlay

        // SSH: progress, changed host key, failure
        sshOverlay

        // Screen Share approval: waiting on the person at the Mac, or refused
        screenShareApprovalOverlay
    }

    // MARK: - Screen Share Approval Overlay

    @ViewBuilder
    private var screenShareApprovalOverlay: some View {
        switch executor.screenShareApprovalPrompt {
        case .working(let step):
            ActionDialog(width: 400) {
                ActionDialogHeader(icon: "person.crop.circle.badge.questionmark", tone: .accent,
                                   title: "Asking for Approval", subtitle: computer.displayName)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(FleetHubTheme.accentFill)
                Text(step)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 34, alignment: .topLeading)
                ActionDialogFooter {
                    ActionDialogButton(title: "Cancel", style: .outline) { executor.cancelScreenShareApproval() }
                }
            }
        case .failed(let title, let message):
            ActionDialog(width: 400, onBackdropTap: { executor.cancelScreenShareApproval() }) {
                ActionDialogHeader(icon: "xmark.circle.fill", tone: .bad, title: title,
                                   subtitle: computer.displayName)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ActionDialogFooter {
                    ActionDialogButton(title: "Close", style: .primary) { executor.cancelScreenShareApproval() }
                }
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - SSH Overlay

    @ViewBuilder
    private var sshOverlay: some View {
        switch executor.sshPrompt {
        case .working(let step):
            ActionDialog(width: 400) {
                ActionDialogHeader(icon: "terminal", tone: .accent, title: "Opening SSH Session",
                                   subtitle: computer.displayName)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(FleetHubTheme.accentFill)
                Text(step)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 34, alignment: .topLeading)
                ActionDialogFooter {
                    ActionDialogButton(title: "Cancel", style: .outline) { executor.cancelSSH() }
                }
            }
        case .hostKeyChanged:
            ActionDialog(width: 440, onBackdropTap: { executor.cancelSSH() }) {
                ActionDialogHeader(icon: "exclamationmark.shield", tone: .warn, eyebrow: "Host Key Changed",
                                   title: "This Mac Is Not the One FleetHub Saved",
                                   subtitle: computer.displayName)
                Text("The identity this Mac presented does not match the one saved from an earlier SSH session. That is expected after the Mac has been erased or reinstalled. It can also mean a different computer is answering at this address.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If you know why it changed, delete the saved key. FleetHub will accept and save the new one and connect.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ActionDialogFooter {
                    ActionDialogButton(title: "Cancel", style: .outline) { executor.cancelSSH() }
                    ActionDialogButton(title: "Delete Saved Key and Connect", style: .primary) {
                        executor.startSSH(forgettingSavedHostKey: true)
                    }
                }
            }
        case .failed(let title, let message):
            ActionDialog(width: 400, onBackdropTap: { executor.cancelSSH() }) {
                ActionDialogHeader(icon: "xmark.circle.fill", tone: .bad, title: title,
                                   subtitle: computer.displayName)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ActionDialogFooter {
                    ActionDialogButton(title: "Close", style: .outline) { executor.cancelSSH() }
                    ActionDialogButton(title: "Try Again", style: .primary) { executor.startSSH() }
                }
            }
        case nil:
            EmptyView()
        }
    }

    // MARK: - Processing Progress Overlay

    @ViewBuilder
    private var processingOverlay: some View {
        if let message = executor.processingMessage {
            ActionDialog(width: 380) {
                ActionDialogHeader(
                    icon: "arrow.triangle.2.circlepath",
                    tone: .accent,
                    title: executor.processingTitle,
                    subtitle: nil
                )

                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(FleetHubTheme.accentFill)

                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 34, alignment: .topLeading)

                Text("Please keep this window open — do not close the app.")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Command Result Overlay

    private func dismissCommandResult() {
        withAnimation(.easeOut(duration: 0.2)) {
            executor.showingCommandAlert = false
            executor.commandResult = nil
        }
    }

    @ViewBuilder
    private var commandResultOverlay: some View {
        if executor.showingCommandAlert, let result = executor.commandResult {
            ActionDialog(width: 380, onBackdropTap: dismissCommandResult) {
                ActionDialogHeader(
                    icon: result.success ? "checkmark.circle.fill" : "xmark.circle.fill",
                    tone: result.success ? .good : .bad,
                    title: result.title,
                    subtitle: nil
                )

                Text(result.message)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                ActionDialogFooter {
                    ActionDialogButton(title: "OK", style: .primary, action: dismissCommandResult)
                }
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(FleetHubTheme.control)
    }

    // MARK: - Destructive Action Warning Overlay (stage 1 of 2)

    private func dismissConfirmation() {
        withAnimation(.easeOut(duration: 0.2)) {
            flow.dismissConfirmation()
        }
    }

    /// The Mac a destructive action will hit, in a red-bordered box.
    private var destructiveTargetCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(computer.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)

            if let serial = computer.serialNumber {
                Text(serial)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(FleetHubTheme.muted)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FleetHubTheme.badFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(FleetHubTheme.badText.opacity(0.3), lineWidth: 1)
        )
    }

    /// Stage 1 for Erase Device / Return to Service: states the damage in
    /// plain language and names the target, with no confirm control other
    /// than an explicit acknowledgement button. Clearing it opens the
    /// typed-ERASE dialog (stage 2), which carries the per-action specifics.
    @ViewBuilder
    private var destructiveWarningOverlay: some View {
        if flow.showingDestructiveWarning, let action = flow.pendingAction,
           let warning = action.dangerWarning {
            ActionDialog(width: 440, isDanger: true, onBackdropTap: dismissConfirmation) {
                ActionDialogHeader(
                    icon: "exclamationmark.octagon.fill",
                    tone: .bad,
                    eyebrow: "Destructive Action",
                    title: ActionBranding.confirmationTitle(for: action),
                    subtitle: nil
                )

                Text(warning)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                // Name the target explicitly — wrong-device is the most
                // likely way this action goes wrong.
                destructiveTargetCard

                ActionDialogFooter {
                    ActionDialogButton(title: "Cancel", style: .outline, action: dismissConfirmation)
                    ActionDialogButton(title: "I Understand — Continue", style: .dangerOutline) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            flow.showingDestructiveWarning = false
                            flow.showingActionConfirmation = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Action Confirmation Overlay

    @ViewBuilder
    private var actionConfirmationOverlay: some View {
        if flow.showingActionConfirmation, let action = flow.pendingAction {
            // Destructive actions require the operator to type ERASE to confirm.
            let canConfirm = !action.isDestructive
                || flow.confirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("ERASE") == .orderedSame

            // Destructive dialogs match stage 1's width and red border so
            // the two steps read as one flow rather than two dialogs.
            ActionDialog(
                width: action.isDestructive ? 440 : 400,
                isDanger: action.isDestructive,
                onBackdropTap: dismissConfirmation
            ) {
                // Warning header. Destructive actions carry the same red
                // treatment as the stage-1 danger warning — octagon, red
                // eyebrow, red card border — so the severity doesn't drop
                // off between the two steps of one flow.
                //
                // Titled with the ui-domain label override so a renamed
                // action reads the same here as in the menu. Only the
                // name follows the override — the body copy below and
                // the typed-ERASE gate stay built-in.
                ActionDialogHeader(
                    icon: destructiveConfirmIcon(for: action),
                    tone: action.isDestructive ? .bad : (action.isWarning ? .warn : .accent),
                    eyebrow: action.isDestructive ? "Destructive Action" : nil,
                    title: ActionBranding.confirmationTitle(for: action),
                    subtitle: action.isDestructive ? nil : computer.displayName
                )

                Text(confirmationMessage(for: action))
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if action.isDestructive {
                    // Same red target card as stage 1 — the operator sees
                    // exactly which Mac they are erasing at both steps.
                    destructiveTargetCard

                    // Typed confirmation for destructive actions.
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Type ERASE to confirm:")
                        TextField("", text: $flow.confirmationText, prompt: Text("ERASE").foregroundColor(FleetHubTheme.muted))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .overlay(
                                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                    .stroke(canConfirm ? FleetHubTheme.goodText.opacity(0.7) : FleetHubTheme.border, lineWidth: 1)
                            )
                            .accessibilityLabel("Type ERASE to confirm")
                    }
                }

                ActionDialogFooter {
                    ActionDialogButton(title: "Cancel", style: .outline, action: dismissConfirmation)
                    ActionDialogButton(
                        title: action.confirmButtonTitle,
                        style: action.isDestructive ? .danger : .primary,
                        enabled: canConfirm
                    ) {
                        let actionToExecute = action
                        withAnimation(.easeOut(duration: 0.2)) {
                            flow.dismissConfirmation()
                        }
                        flow.execute(actionToExecute, with: executor, openURL: openURL)
                    }
                }
            }
        }
    }

    /// Header symbol for the confirmation dialog: destructive actions get the
    /// stage-1 octagon, other warnings the triangle, everything else its own
    /// action icon.
    private func destructiveConfirmIcon(for action: DeviceAction) -> String {
        if action.isDestructive { return "exclamationmark.octagon.fill" }
        if action.isWarning { return "exclamationmark.triangle.fill" }
        return action.icon
    }

    /// Return to Service's confirmation copy is composed from the steps that
    /// will actually run — it never promises a disabled or unconfigured step.
    /// All other actions use their built-in copy. The typed-name confirmation
    /// for destructive actions is a permanent safeguard and is never relaxed.
    private func confirmationMessage(for action: DeviceAction) -> String {
        guard action == .returnToService else { return action.message }

        // Use the plan snapshotted when the dialog opened (DeviceActionFlow.trigger) so
        // the copy and the execution can never diverge mid-dialog.
        let options = flow.pendingRTSPlan?.options
            ?? DeviceActionPolicy.currentForComputers.returnToServiceOptions()
        let entraConfigured = flow.pendingRTSPlan?.entraConfigured
            ?? configManager.configuration.isEntraConfigured

        var cleanupSteps: [String] = []
        if options.effectiveDeleteJamfRecord {
            cleanupSteps.append("remove its record from Jamf Pro")
        }
        if options.effectiveDeleteEntraObject && entraConfigured {
            cleanupSteps.append("delete its device object from Microsoft Entra so the device can re-enroll cleanly")
        }

        // Disclose what the policy deliberately keeps, so an operator who
        // knows RTS as "full decommission" isn't surprised post-erase.
        var kept: [String] = []
        if !options.effectiveDeleteJamfRecord { kept.append("Jamf Pro record") }
        if !options.effectiveDeleteEntraObject { kept.append("Entra device object") }
        let keptSentence = kept.isEmpty
            ? ""
            : " The device's \(kept.joined(separator: " and ")) will be kept."

        if cleanupSteps.isEmpty {
            return "This will erase all data on the device and wait for the device to acknowledge the erase — no cleanup steps will run.\(keptSentence) This action cannot be undone."
        }

        let steps = ["erase all data on the device (the device must acknowledge the erase before any cleanup step runs)"] + cleanupSteps
        let numbered = steps.enumerated().map { "(\($0.offset + 1)) \($0.element)" }
        let joined = numbered.count == 2
            ? "\(numbered[0]) and \(numbered[1])"
            : numbered.dropLast().joined(separator: ", ") + ", and \(numbered[numbered.count - 1])"
        return "This will \(joined).\(keptSentence) This action cannot be undone."
    }

    // MARK: - Unlock Account Overlay

    private func dismissUnlockAccount() {
        withAnimation(.easeOut(duration: 0.2)) {
            flow.showingUnlockAccountSheet = false
            flow.unlockUsername = ""
        }
    }

    @ViewBuilder
    private var unlockAccountOverlay: some View {
        if flow.showingUnlockAccountSheet {
            ActionDialog(width: 400, onBackdropTap: dismissUnlockAccount) {
                ActionDialogHeader(
                    icon: "person.badge.key",
                    tone: .accent,
                    title: "Unlock User Account",
                    subtitle: "Enter the username of the account to unlock on \(computer.displayName)."
                )

                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Username")
                    TextField("", text: $flow.unlockUsername, prompt: Text("Username").foregroundColor(FleetHubTheme.muted))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .stroke(FleetHubTheme.border, lineWidth: 1)
                        )
                        .accessibilityLabel("Username")
                }

                ActionDialogFooter {
                    ActionDialogButton(title: "Cancel", style: .outline, action: dismissUnlockAccount)
                    ActionDialogButton(title: "Unlock", style: .primary, enabled: !flow.unlockUsername.isEmpty) {
                        let username = flow.unlockUsername
                        withAnimation(.easeOut(duration: 0.2)) {
                            flow.showingUnlockAccountSheet = false
                            flow.unlockUsername = ""
                        }
                        Task { await executor.sendUnlockAccountCommand(username: username) }
                    }
                }
            }
        }
    }
}

// MARK: - Dialog building blocks

/// Dimmed backdrop plus the dialog card. `isDanger` gives the card the red
/// border the destructive flow uses at both of its steps.
struct ActionDialog<Content: View>: View {
    let width: CGFloat
    var isDanger = false
    var onBackdropTap: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { onBackdropTap?() }

            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(24)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isDanger ? FleetHubTheme.badText.opacity(0.45) : FleetHubTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 16)
        }
    }
}

struct ActionDialogHeader: View {
    enum Tone { case accent, good, warn, bad }

    let icon: String
    let tone: Tone
    var eyebrow: String?
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(ink)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(fill))

            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(ink)
                }
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var ink: Color {
        switch tone {
        case .accent: FleetHubTheme.accent
        case .good: FleetHubTheme.goodText
        case .warn: FleetHubTheme.warnText
        case .bad: FleetHubTheme.badText
        }
    }

    private var fill: Color {
        switch tone {
        case .accent: FleetHubTheme.accent.opacity(0.12)
        case .good: FleetHubTheme.goodFill
        case .warn: FleetHubTheme.warnFill
        case .bad: FleetHubTheme.badFill
        }
    }
}

/// Right-aligned button row at the bottom of a dialog.
struct ActionDialogFooter<Buttons: View>: View {
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            buttons()
        }
        .padding(.top, 4)
    }
}

struct ActionDialogButton: View {
    enum Style { case primary, outline, danger, dangerOutline }

    let title: String
    let style: Style
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(ink)
                .padding(.horizontal, 16)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous).fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .stroke(border, lineWidth: 1)
                )
                .opacity(enabled ? 1 : 0.45)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var ink: Color {
        switch style {
        case .primary, .danger: .white
        case .outline: FleetHubTheme.ink
        case .dangerOutline: FleetHubTheme.badText
        }
    }

    private var fill: Color {
        switch style {
        case .primary: FleetHubTheme.accentFill
        case .danger: Color(light: 0xB3261E, dark: 0xC8362D)
        case .outline, .dangerOutline: FleetHubTheme.surface
        }
    }

    private var border: Color {
        switch style {
        case .primary, .danger: .clear
        case .outline: FleetHubTheme.border
        case .dangerOutline: FleetHubTheme.badText.opacity(0.35)
        }
    }
}
