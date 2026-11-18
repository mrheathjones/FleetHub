//
//  CleanupActionsSheet.swift
//  FleetHub
//
//  Pick the actions to run against the selected stale devices, confirm,
//  watch progress, review per-device results. A FleetHub sheet: title and
//  subtitle, bordered blocks of toggles, and a footer with Cancel and the
//  run button.
//

import SwiftUI

struct CleanupActionsSheet: View {
    @Environment(CleanupViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var unmanage = false
    @State private var addToGroup = false
    @State private var selectedGroupID: Int = 0
    @State private var moveToSite = false
    @State private var selectedSiteID: Int = -1
    @State private var deleteFromProtect = false
    @State private var deleteRecord = false
    @State private var confirming = false
    @State private var phase: Phase = .configure
    /// Observed so the action gates re-evaluate when capabilities land
    /// after sign-in.
    @ObservedObject private var session = UserSession.shared

    private enum Phase { case configure, running, done }

    /// Whether the signed-in user's roles grant a Cleanup action. Every
    /// toggle below is gated on this, and `deniedPlanActions` re-checks it
    /// before anything runs.
    private func can(_ action: CleanupAction) -> Bool {
        session.capabilities.canRunCleanupAction(action)
    }

    private var hasAnyPermittedAction: Bool {
        CleanupAction.allCases.contains(where: can)
    }

    /// When on, deleting a Jamf Pro record always deletes the matching
    /// Jamf Protect record too. Requires the Protect delete grant — the
    /// convenience must never widen what the user's roles allow.
    private var autoProtectCleanup: Bool {
        model.settings.isProtectConfigured
            && model.settings.protectAutoCleanup
            && can(.deleteFromProtect)
    }

    private var plan: ActionPlan {
        var plan = ActionPlan()
        plan.unmanage = unmanage
        if addToGroup, selectedGroupID != 0 {
            plan.addToGroupID = selectedGroupID
            plan.addToGroupName = model.staticGroups.first { $0.id == selectedGroupID }?.name
        }
        if moveToSite, selectedSiteID != -1 || model.sites.contains(where: { $0.intID == selectedSiteID }) {
            plan.moveToSiteID = selectedSiteID
            plan.moveToSiteName = model.sites.first { $0.intID == selectedSiteID }?.name ?? "None"
        }
        plan.deleteFromProtect = deleteFromProtect
        plan.deleteRecord = deleteRecord
        return plan
    }

    /// Defense in depth: rows for actions the user's roles don't grant are
    /// never rendered, so their toggles cannot be on — but enforcement must
    /// never live only in the UI. Any ungranted action found in the plan
    /// blocks the whole run rather than silently executing a subset.
    private var deniedPlanActions: [CleanupAction] {
        let plan = self.plan
        var denied: [CleanupAction] = []
        if plan.unmanage, !can(.unmanage) { denied.append(.unmanage) }
        if plan.addToGroupID != nil, !can(.addToGroup) { denied.append(.addToGroup) }
        if plan.moveToSiteID != nil, !can(.moveToSite) { denied.append(.moveToSite) }
        if plan.deleteFromProtect, !can(.deleteFromProtect) { denied.append(.deleteFromProtect) }
        if plan.deleteRecord, !can(.deleteRecord) { denied.append(.deleteRecord) }
        return denied
    }

    private var canRun: Bool {
        !plan.isEmpty
            && !model.selectedDevices.isEmpty
            && !(addToGroup && selectedGroupID == 0)
            && deniedPlanActions.isEmpty
    }

    private var deviceCountText: String {
        let count = model.selectedDevices.count
        return count == 1 ? "1 Device" : "\(count) Devices"
    }

    var body: some View {
        ZStack {
            FleetHubTheme.surface.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                switch phase {
                case .configure:
                    // Roles that grant the cleanup module but no cleanup
                    // action get a read-only explanation, not dead toggles.
                    if hasAnyPermittedAction {
                        configureView
                    } else {
                        noActionsView
                    }
                case .running:   runningView
                case .done:      resultsView
                }
                footer
            }

            if confirming { confirmationOverlay }
        }
        .frame(width: 580, height: 640)
        .task { await model.loadLookups() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phase == .done ? "Results" : "Review Actions")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            Text(headerSubtitle)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var headerSubtitle: String {
        switch phase {
        case .configure: "Choose what to do with the \(deviceCountText.lowercased()) you selected."
        case .running: "Running on \(deviceCountText.lowercased())…"
        case .done: "\(model.actionResults.count) operations on \(deviceCountText.lowercased())."
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button { dismiss() } label: {
                SettingsButtonLabel(text: phase == .done ? "Close" : "Cancel",
                                    kind: phase == .done ? .primary : .outline)
                    .opacity(phase == .running ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(phase == .running)

            if phase == .configure, hasAnyPermittedAction {
                Button { confirming = true } label: {
                    SettingsButtonLabel(
                        text: "Run \(plan.summary.count) Action\(plan.summary.count == 1 ? "" : "s") on \(deviceCountText)",
                        kind: .primary,
                        icon: "bolt.fill"
                    )
                    .opacity(canRun ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .disabled(!canRun)
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .background(FleetHubTheme.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
        }
    }

    // MARK: - Configure

    private var configureView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Each row is gated on the user's role capabilities; a
                // section whose every action is ungranted disappears.
                if can(.unmanage) || can(.addToGroup) || can(.moveToSite) {
                    section("Jamf Pro") {
                        if can(.unmanage) {
                            toggleRow("Send Unmanage Command",
                                      "Stops management without deleting the record.",
                                      isOn: $unmanage)
                        }

                        if can(.addToGroup) {
                            toggleRow("Add to Static Group",
                                      "Collects the devices in a group for follow-up.",
                                      isOn: $addToGroup)
                            if addToGroup { groupPicker }
                        }

                        if can(.moveToSite) {
                            toggleRow("Move to Site",
                                      "Reassigns the devices to another Jamf Pro site.",
                                      isOn: $moveToSite)
                            if moveToSite { sitePicker }
                        }
                    }
                }

                if can(.deleteFromProtect) || can(.deleteRecord) {
                    section("Delete Records") {
                        if model.settings.isProtectConfigured, can(.deleteFromProtect) {
                            toggleRow("Delete from Jamf Protect",
                                      "Removes the matching Protect record. Jamf Pro is untouched.",
                                      isOn: $deleteFromProtect,
                                      disabled: autoProtectCleanup && deleteRecord)
                        }
                        if can(.deleteRecord) {
                            toggleRow("Delete Jamf Pro Record",
                                      "Permanently removes the computer record from Jamf Pro.",
                                      isOn: $deleteRecord, destructive: true)
                                .onChange(of: deleteRecord) { _, isOn in
                                    if autoProtectCleanup && isOn { deleteFromProtect = true }
                                }

                            if autoProtectCleanup && deleteRecord {
                                footnote("Jamf Protect cleanup is automatic when deleting records (enabled in Settings).")
                            }
                            if deleteRecord {
                                footnote("Deleting a record does not unenroll the device. If it ever checks in again it will re-enroll as a new record.")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
    }

    private var noActionsView: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)
            Text("No Actions Available")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            Text("Your role does not allow any cleanup actions on these devices.\nContact your administrator to request access.")
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var groupPicker: some View {
        pickerRow("Static Group") {
            Menu {
                Picker("Static Group", selection: $selectedGroupID) {
                    Text("Choose…").tag(0)
                    ForEach(model.staticGroups) { group in Text(group.name).tag(group.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                CleanupMenuLabel(text: model.staticGroups.first { $0.id == selectedGroupID }?.name ?? "Choose…")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var sitePicker: some View {
        pickerRow("Site") {
            Menu {
                Picker("Site", selection: $selectedSiteID) {
                    Text("None").tag(-1)
                    ForEach(model.sites) { site in Text(site.name).tag(site.intID) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                CleanupMenuLabel(text: model.sites.first { $0.intID == selectedSiteID }?.name ?? "None")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func pickerRow<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.control)
            Spacer(minLength: 8)
            control()
        }
        .padding(.bottom, 12)
    }

    // MARK: - Running

    private var runningView: some View {
        VStack(spacing: 16) {
            ProgressView(value: model.actionProgress)
                .progressViewStyle(.linear)
                .tint(FleetHubTheme.accentFill)
                .frame(maxWidth: 360)
            Text("Working… \(model.actionResults.count) Operations Finished")
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Results

    private var resultsView: some View {
        let failures = model.actionResults.filter { !$0.success }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(failures.isEmpty
                             ? "All Actions Completed"
                             : (failures.count == 1 ? "1 Operation Failed" : "\(failures.count) Operations Failed"))
                            .font(.system(size: 14, weight: .semibold))
                        Text("\(model.actionResults.count) total operations")
                            .font(.system(size: 12))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(failures.isEmpty ? FleetHubTheme.goodText : FleetHubTheme.warnText)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(failures.isEmpty ? FleetHubTheme.goodFill : FleetHubTheme.warnFill)
                )

                if !failures.isEmpty {
                    resultGroup("Failures", results: failures)
                }
                resultGroup("All Results", results: model.actionResults)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity)
    }

    private func resultGroup(_ title: String, results: [ActionResult]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
                .padding(.bottom, 8)
            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                if index > 0 {
                    Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(result.success ? FleetHubTheme.goodText : FleetHubTheme.badText)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.deviceName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(FleetHubTheme.ink)
                        Text(result.action.rawValue)
                            .font(.system(size: 12))
                            .foregroundStyle(FleetHubTheme.muted)
                        if !result.success {
                            Text(result.message)
                                .font(.system(size: 12))
                                .foregroundStyle(FleetHubTheme.badText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
            }
        }
        .textSelection(.enabled)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    // MARK: - Confirmation overlay

    private var confirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { confirming = false }

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: plan.isDestructive ? "exclamationmark.triangle.fill" : "bolt.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(plan.isDestructive ? FleetHubTheme.badText : FleetHubTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(plan.isDestructive ? FleetHubTheme.badFill : FleetHubTheme.accent.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Run on \(deviceCountText)?")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(FleetHubTheme.ink)
                        Text(plan.isDestructive
                             ? "Some of these actions cannot be undone."
                             : "These actions will run now.")
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.muted)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.summary, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 4))
                                    .foregroundStyle(FleetHubTheme.muted)
                                    .padding(.top, 6)
                                Text(line)
                                    .font(.system(size: 13))
                                    .foregroundStyle(FleetHubTheme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(24)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button { confirming = false } label: {
                        SettingsButtonLabel(text: "Cancel")
                    }
                    .buttonStyle(.plain)

                    Button {
                        confirming = false
                        // Defense in depth: re-check the plan against the
                        // user's role capabilities immediately before it
                        // runs — never rely on the toggles being hidden.
                        guard deniedPlanActions.isEmpty else { return }
                        phase = .running
                        Task {
                            await model.runActions(plan)
                            phase = .done
                        }
                    } label: {
                        if plan.isDestructive {
                            Text("Run Actions")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                        .fill(Color(light: 0xB3261E, dark: 0xC8362D))
                                )
                                .contentShape(Rectangle())
                        } else {
                            SettingsButtonLabel(text: "Run", kind: .primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background(FleetHubTheme.ground)
                .overlay(alignment: .top) {
                    Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                }
            }
            .frame(width: 400)
            .background(FleetHubTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
                .padding(.top, 16)
                .padding(.bottom, 4)
            content()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    private func toggleRow(
        _ title: String, _ subtitle: String,
        isOn: Binding<Bool>, destructive: Bool = false, disabled: Bool = false
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(destructive ? FleetHubTheme.badText : FleetHubTheme.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(destructive ? Color(light: 0xB3261E, dark: 0xC8362D) : FleetHubTheme.accentFill)
                .disabled(disabled)
                .accessibilityLabel(title)
        }
        .padding(.vertical, 12)
        .opacity(disabled ? 0.5 : 1)
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(FleetHubTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)
    }
}
