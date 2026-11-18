//
//  SetupConfigureStep.swift
//  FleetHubSetup
//
//  Step 4: the settings themselves, one tab per domain, with a live preview
//  of exactly what the Mac will receive.
//

import SwiftUI

struct SetupConfigureStep: View {
    @EnvironmentObject private var model: SetupModel
    @State private var domain: SetupDomain = .core

    var body: some View {
        SetupSegmented(options: SetupDomain.allCases.map { ($0, $0.title) }, selection: $domain, onGround: true)

        HStack(alignment: .top, spacing: 20) {
            VStack(spacing: 16) {
                switch domain {
                case .core: SetupCoreForm()
                case .access: SetupAccessForm()
                case .features: SetupFeaturesForm()
                case .ui: SetupBrandingForm()
                }
            }
            .frame(maxWidth: .infinity)

            SetupPreviewCard(domain: domain)
                .frame(width: 330)
        }
    }
}

/// The dark panel showing exactly what the Mac will receive.
struct SetupPreviewCard: View {
    @EnvironmentObject private var model: SetupModel
    let domain: SetupDomain

    var body: some View {
        let text = SetupOutput.previewText(for: domain, model: model)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("\(domain.title) Settings Preview")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("Updates as You Type")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(Color(light: 0xAFC1FF, dark: 0xAFC1FF))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Color(light: 0x1F2A40, dark: 0x1F2A40), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            ScrollView(.horizontal) {
                Text(verbatim: text)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(5)
                    .foregroundStyle(SetupTheme.previewText)
                    .textSelection(.enabled)
                    .padding(14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SetupTheme.previewWell, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("No secrets appear here or in any exported file.")
                .font(.system(size: 12)).foregroundStyle(Color(light: 0xC5CCDA, dark: 0xC5CCDA))
        }
        .padding(20)
        .background(SetupTheme.previewPanel, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A hairline between rows inside a card.
struct SetupRowLine: View {
    var body: some View { Rectangle().fill(SetupTheme.rowLine).frame(height: 1) }
}

// MARK: - Core

struct SetupCoreForm: View {
    @EnvironmentObject private var model: SetupModel

    private var backendHint: String {
        switch model.api {
        case .jamfPro: "Written to Core as apiBackend = jamfPro. If you add a Platform integration in Jamf Environment Setup, platformAPI is included too and enables Compliance Benchmarks only."
        case .hybrid: "Written to Core as apiBackend = hybrid, with the platformAPI identity from Jamf Environment Setup. Reads use that integration; the provisioning client and per-user roles below are still used for actions."
        case .platform: "Written to Core as apiBackend = platform, with the platformAPI identity from Jamf Environment Setup. Everyone acts as that one integration, so the provisioning client and per-user role are not used."
        }
    }

    var body: some View {
        SetupCard("Jamf API") {
            SetupSegmented(options: SetupAPIChoice.allCases.map { ($0, $0.title) }, selection: $model.api, fill: true)
            Text(backendHint).font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }

        SetupCard("Jamf Pro Connection") {
            SetupField(label: "Jamf Pro Server URL", text: $model.jamfURL, placeholder: "https://yourtenant.jamfcloud.com",
                       help: model.jamfURLHint)
            if !model.jamfURLIsDetected, let detected = SetupModel.detectedJamfURL {
                SetupButton(title: "Use Detected URL", kind: .quiet) { model.jamfURL = detected }
            }
            if model.api.usesPerUserClients {
                SetupToggleRow(
                    title: "Create Each Person's Jamf API Client Automatically",
                    detail: "Off (the default): you create each person's client in Jamf Pro and they enter it in FleetHub once. No provisioning secret is deployed, which is the more secure choice. On: FleetHub creates a personal API client at first sign-in, using a provisioning client whose secret is kept on every Mac. On needs Microsoft Entra ID sign-in.",
                    isOn: $model.autoCreateUserClients)
            }
            if model.api.usesPerUserClients, !model.autoCreateUserClients {
                SetupNotice(
                    text: "No provisioning client is used. For each person, create an API client in Jamf Pro with the API role their FleetHub role needs (listed on the Jamf Environment Setup step), then give them its client ID and secret. FleetHub asks for it once and keeps it in their Keychain.",
                    tone: .accent
                )
            }
            if model.provisionsClients {
                HStack(alignment: .top, spacing: 12) {
                    SetupField(label: "Provisioning (Master) Client ID", text: $model.masterClientID,
                               placeholder: "Client ID")
                    SetupField(label: "Fallback Jamf API Role", text: $model.defaultJamfRoleName,
                               placeholder: "Optional",
                               help: "Used only for a FleetHub role that names no Jamf API role of its own. Leave empty when every role names one.")
                }
                Text("Only the client ID goes into the settings. Each admin enters the client secret in FleetHub on first launch, where it is kept in the Keychain.")
                    .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                SetupNotice(text: "On the Platform API there is no provisioning client: everyone uses the one integration from Jamf Environment Setup.", tone: .neutral)
            }
        }

        SetupCard("Sign-In") {
            SetupSegmented(options: [("entra", "Microsoft Entra ID"), ("email", "Email Address")], selection: $model.signInMethod, fill: true)
            if model.signInMethod == "entra" {
                HStack(alignment: .top, spacing: 12) {
                    SetupField(label: "Entra Tenant ID", text: $model.entraTenantID, placeholder: "Tenant ID")
                    SetupField(label: "Client ID (Public Client)", text: $model.entraClientID, placeholder: "Client ID")
                }
                SetupField(label: "Redirect URI", text: $model.entraRedirectURI,
                           placeholder: "Optional. Default: \(SetupModel.defaultEntraRedirectURI)",
                           help: "Leave blank for a new app registration. If your registration already uses a different redirect URI, enter it here exactly as registered.")
                SetupNotice(
                    text: "Register the redirect URI \(model.effectiveEntraRedirectURI) on the Entra app (Mobile and desktop applications). FleetHub roles come from the app roles in the person's sign-in; name them exactly as on the Access and Roles tab.",
                    tone: .accent
                )
            } else {
                SetupNotice(
                    text: model.provisionsClients
                        ? "With email sign-in there is no identity provider, so every user of a Mac holds the single role you pick on the Access and Roles tab. FleetHub accepts whatever address is typed, so use this only where one trusted person uses the Mac, or turn off automatic API client creation so each person must hold their own client."
                        : "With email sign-in there is no identity provider, so every user of a Mac holds the single role you pick on the Access and Roles tab. Because each person must enter their own Jamf API client, Jamf's audit log still names who acted.",
                    tone: .warn
                )
            }
            SetupRowLine()
            SetupToggleRow(title: "Require Touch ID or Password to Unlock",
                           detail: "Asked each time FleetHub opens.", isOn: $model.requireBiometric)
            SetupStepperRow(title: "Sign Out After Inactivity",
                            detail: "0 keeps the session until the person signs out.",
                            value: $model.sessionTimeoutMinutes, range: 0...480, unit: "min")
        }

        SetupCard("Optional Integrations",
                  subtitle: "Only identifiers go here. Each integration's key or secret is typed into FleetHub on the Mac.") {
            SetupToggleRow(title: "Apple Business Manager",
                           detail: "ABM lookup and MDM server assignment.", isOn: $model.abmEnabled)
            if model.abmEnabled {
                HStack(spacing: 12) {
                    SetupField(label: "ABM Client ID", text: $model.abmClientID, placeholder: "BUSINESSAPI.…", monospaced: true)
                    SetupField(label: "ABM Key ID", text: $model.abmKeyID, placeholder: "Key ID", monospaced: true)
                }
            }
            SetupRowLine()
            SetupToggleRow(title: "Jamf Protect",
                           detail: "Remove stale Protect records from Cleanup.", isOn: $model.protectEnabled)
            if model.protectEnabled, model.protectUsesPlatform {
                SetupNotice(text: "Jamf Protect runs through your Jamf Platform API integration, so it needs no address, client ID or password of its own. The integration needs devices:read, and devices:delete for roles that can delete Protect records.",
                            tone: .accent)
            } else if model.protectEnabled {
                SetupNotice(text: "Add a Platform integration with your Jamf Protect tenant ID in Jamf Environment Setup and Jamf Protect will use it. Without one, enter the Protect tenant's own API client here; its password is typed into FleetHub on each Mac.",
                            tone: .neutral)
                HStack(spacing: 12) {
                    SetupField(label: "Protect URL", text: $model.protectURL, placeholder: "https://yourorg.protect.jamfcloud.com")
                    SetupField(label: "Protect Client ID", text: $model.protectClientID, placeholder: "Client ID", monospaced: true)
                }
            }
            SetupRowLine()
            SetupToggleRow(title: "Entra Device Cleanup",
                           detail: "Delete the Entra device object after Return to Service.", isOn: $model.entraCleanupEnabled)
            if model.entraCleanupEnabled {
                HStack(spacing: 12) {
                    SetupField(label: "Tenant ID", text: $model.entraCleanupTenantID, placeholder: "Tenant ID", monospaced: true)
                    SetupField(label: "Client ID", text: $model.entraCleanupClientID, placeholder: "Client ID", monospaced: true)
                }
            }
        }
    }
}

// MARK: - Access

struct SetupAccessForm: View {
    @EnvironmentObject private var model: SetupModel
    @State private var selectedRoleID: UUID?
    @State private var roleToRemove: SetupRole?

    private var selectedIndex: Int? {
        model.roles.firstIndex { $0.id == selectedRoleID } ?? (model.roles.isEmpty ? nil : 0)
    }

    var body: some View {
        SetupCard("Roles",
                  subtitle: "A role decides what a person sees and can do in FleetHub. Nothing is built in: a capability not granted here does not exist for that person.") {
            SetupFlow(spacing: 8) {
                ForEach(Array(model.roles.enumerated()), id: \.element.id) { index, role in
                    let selected = index == selectedIndex
                    HStack(spacing: 0) {
                        Button { selectedRoleID = role.id } label: {
                            Text(role.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selected ? .white : SetupTheme.control)
                                .padding(.leading, 14).padding(.trailing, 6)
                                .frame(height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button { roleToRemove = role } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(selected ? .white.opacity(0.85) : SetupTheme.muted)
                                .frame(width: 30, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(role.displayName)")
                        .accessibilityLabel("Remove \(role.displayName)")
                    }
                    .background(selected ? SetupTheme.accentFill : SetupTheme.ground,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? .clear : SetupTheme.fieldBorder))
                }
                SetupButton(title: "Add Role", icon: "plus") {
                    let role = SetupRole.blank()
                    model.roles.append(role)
                    selectedRoleID = role.id
                }
                .frame(height: 38)
            }
            if model.signInMethod == "email", !model.usableRoles.isEmpty {
                SetupRowLine()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Role Every User Holds (Email Sign-In)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                    SetupSegmented(options: model.usableRoles.map { ($0.name, $0.displayName) },
                                   selection: $model.emailModeRoleName)
                }
            }
        }
        .confirmationDialog(
            "Remove \(roleToRemove?.displayName ?? "this role")?",
            isPresented: Binding(get: { roleToRemove != nil }, set: { if !$0 { roleToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Role", role: .destructive) {
                if let role = roleToRemove { model.roles.removeAll { $0.id == role.id } }
                selectedRoleID = nil
                roleToRemove = nil
            }
            Button("Cancel", role: .cancel) { roleToRemove = nil }
        } message: {
            Text("The role and everything granted to it here is removed from the Access settings.")
        }

        if let index = selectedIndex {
            SetupRoleEditor(role: $model.roles[index], showsJamfRole: model.provisionsClients) {
                roleToRemove = model.roles[index]
            }
        }
    }
}

struct SetupRoleEditor: View {
    @Binding var role: SetupRole
    let showsJamfRole: Bool
    let remove: () -> Void
    @State private var scopeKind: SetupScopeKind = .site

    var body: some View {
        SetupCard {
            HStack(alignment: .center) {
                Text(role.displayName).font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                Spacer()
                SetupButton(title: "Remove Role", icon: "trash", action: remove)
            }
            HStack(alignment: .top, spacing: 12) {
                SetupField(label: "Role Name", text: $role.name, placeholder: "FleetHub.Admin",
                           help: "Must match the Entra app role value exactly.")
                if showsJamfRole {
                    SetupField(label: "Jamf API Role", text: $role.jamfApiRoleName, placeholder: "FleetHub Admin",
                               help: "The Jamf Pro API role given to this person's own API client.")
                }
            }
            section("Modules") {
                SetupChipPicker(options: SetupRole.allModules, titles: SetupRole.moduleTitles, selection: $role.modules)
            }
            section("Device Tabs") {
                SetupChipPicker(options: SetupRole.allDeviceTabs, titles: SetupRole.deviceTabTitles, selection: $role.deviceTabs)
            }
            section("Computer Actions") {
                SetupChipPicker(options: SetupRole.allComputerActions, titles: SetupRole.computerActionTitles,
                                selection: $role.computerActions)
            }
            section("Mobile Device Actions") {
                SetupChipPicker(options: SetupRole.allMobileActions, titles: SetupRole.mobileActionTitles,
                                selection: $role.mobileDeviceActions)
            }
            section("Cleanup Actions") {
                SetupChipPicker(options: SetupRole.allCleanupActions, titles: SetupRole.cleanupActionTitles,
                                selection: $role.cleanupActions)
            }
            SetupRowLine()
            scopeEditor
            SetupRowLine()
            SetupToggleRow(title: "Allow Export", detail: "CSV and report exports.", isOn: $role.allowExport)
            SetupToggleRow(title: "Allow Scorecard Diagnostics",
                           detail: "Shows why a device fails a health card.", isOn: $role.allowScorecardDiagnostics)
        }
    }

    private var scopeBinding: Binding<SetupScope> {
        Binding(get: { role.scope(scopeKind) }, set: { role.setScope($0, for: scopeKind) })
    }

    private func scopeLabel(_ kind: SetupScopeKind) -> String {
        let scope = role.scope(kind)
        return scope.all ? "\(kind.title) · All" : scope.values.isEmpty ? kind.title : "\(kind.title) · \(scope.values.count)"
    }

    private var scopeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scope").font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
            SetupSegmented(options: SetupScopeKind.allCases.map { ($0, scopeLabel($0)) }, selection: $scopeKind)
            Text(scopeKind.explanation + " With nothing added, the matching actions stay unavailable.")
                .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            SetupToggleRow(title: scopeKind.allTitle, isOn: scopeBinding.all)
            if !role.scope(scopeKind).all {
                SetupListEditor(values: scopeBinding.values, placeholder: scopeKind.placeholder,
                                addLabel: "Add \(scopeKind.title)")
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
            content()
        }
    }
}

/// A list of text values: removable chips, and a field with a plus button
/// that adds what was typed (Return adds too; a pasted comma-separated
/// list adds each value). Setup writes the list in the profile's format.
struct SetupListEditor: View {
    @Binding var values: [String]
    /// False when the caller draws the values itself and only wants the entry field.
    var showsValues = true
    let placeholder: String
    var addLabel = "Add"
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsValues, !values.isEmpty {
                SetupFlow(spacing: 6) {
                    ForEach(values, id: \.self) { value in
                        HStack(spacing: 6) {
                            Text(verbatim: value).font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SetupTheme.accentInk)
                            Button { values.removeAll { $0 == value } } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(SetupTheme.accentInk)
                                    .frame(width: 18, height: 18)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(value)")
                        }
                        .padding(.leading, 10).padding(.trailing, 4)
                        .frame(height: 28)
                        .background(SetupTheme.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
            HStack(spacing: 8) {
                TextField("", text: $draft, prompt: Text(verbatim: placeholder))
                    .textFieldStyle(.plain)
                    .font(.system(size: 14)).foregroundStyle(SetupTheme.ink)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(SetupTheme.surface, in: RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous).stroke(SetupTheme.fieldBorder))
                    .onSubmit(add)
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(SetupTheme.accentFill, in: RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1)
                .help(addLabel)
                .accessibilityLabel(addLabel)
            }
        }
    }

    private func add() {
        for piece in draft.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let value = piece.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty, !values.contains(value) { values.append(value) }
        }
        draft = ""
    }
}

// MARK: - Features

struct SetupFeaturesForm: View {
    @EnvironmentObject private var model: SetupModel
    @State private var exclusionCard: SetupHealthCard = .encrypted
    @State private var exclusionKind = "site"
    @State private var exclusionMode = "exclude"

    /// Cards the settings will actually produce (Protected needs an app).
    private var availableCards: [SetupHealthCard] {
        SetupHealthCard.allCases.filter { $0 != .protected || !model.scorecardRequiredApps.isEmpty }
    }

    private func cardLabel(_ card: SetupHealthCard) -> String {
        let count = model.scorecardExclusions[card.rawValue]?.count ?? 0
        return count == 0 ? card.title : "\(card.title) · \(count)"
    }

    private func exclusionBinding(_ keyPath: WritableKeyPath<SetupCardExclusion, [String]>) -> Binding<[String]> {
        let card = (availableCards.contains(exclusionCard) ? exclusionCard : .encrypted).rawValue
        return Binding(
            get: { model.scorecardExclusions[card]?[keyPath: keyPath] ?? [] },
            set: { values in
                var exclusion = model.scorecardExclusions[card] ?? SetupCardExclusion()
                exclusion[keyPath: keyPath] = values
                model.scorecardExclusions[card] = exclusion.isEmpty ? nil : exclusion
            }
        )
    }

    /// Per-card scope: pick a card, choose to leave out or to include
    /// only, pick what kind of thing, add IDs.
    private var exclusionsEditor: some View {
        let card = availableCards.contains(exclusionCard) ? exclusionCard : .encrypted
        let scope = model.scorecardExclusions[card.rawValue] ?? SetupCardExclusion()
        let only = exclusionMode == "only"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Limit Which Devices a Card Measures")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
            Text("Each card measures the whole fleet unless you change it here. Leave Out removes sites or groups from a card. Only Include makes the card measure just the sites or groups you list, which is quicker when most of the fleet should be left out. A device in both lists is left out.")
                .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            SetupSegmented(options: availableCards.map { ($0, cardLabel($0)) },
                           selection: Binding(get: { card }, set: { exclusionCard = $0 }))
            SetupSegmented(
                options: [("exclude", scope.excludeCount == 0 ? "Leave Out" : "Leave Out · \(scope.excludeCount)"),
                          ("only", scope.onlyCount == 0 ? "Only Include" : "Only Include · \(scope.onlyCount)")],
                selection: $exclusionMode
            )
            SetupSegmented(options: [("site", "Site"), ("computerGroup", "Computer Group"), ("mobileGroup", "Mobile Device Group")],
                           selection: $exclusionKind)
            switch exclusionKind {
            case "computerGroup":
                SetupListEditor(values: exclusionBinding(only ? \.onlyComputerGroupIDs : \.computerGroupIDs),
                                placeholder: "Jamf Pro computer group ID, for example 42",
                                addLabel: only ? "Include Computer Group" : "Leave Out Computer Group")
            case "mobileGroup":
                SetupListEditor(values: exclusionBinding(only ? \.onlyMobileGroupIDs : \.mobileGroupIDs),
                                placeholder: "Jamf Pro mobile device group ID, for example 17",
                                addLabel: only ? "Include Mobile Device Group" : "Leave Out Mobile Device Group")
            default:
                SetupListEditor(values: exclusionBinding(only ? \.onlySiteIDs : \.siteIDs),
                                placeholder: "Jamf Pro site ID, for example 3",
                                addLabel: only ? "Include Site" : "Leave Out Site")
            }
            Text(scopeSummary(card, scope)).font(.system(size: 12, weight: .medium)).foregroundStyle(SetupTheme.control)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One sentence on what the selected card will measure.
    private func scopeSummary(_ card: SetupHealthCard, _ scope: SetupCardExclusion) -> String {
        func parts(_ sites: [String], _ computers: [String], _ mobiles: [String]) -> String {
            var list: [String] = []
            if !sites.isEmpty { list.append("site\(sites.count == 1 ? "" : "s") \(sites.joined(separator: ", "))") }
            if !computers.isEmpty { list.append("computer group\(computers.count == 1 ? "" : "s") \(computers.joined(separator: ", "))") }
            if !mobiles.isEmpty { list.append("mobile device group\(mobiles.count == 1 ? "" : "s") \(mobiles.joined(separator: ", "))") }
            return list.joined(separator: "; ")
        }
        let included = scope.onlyCount == 0
            ? "every device"
            : "only devices in " + parts(scope.onlySiteIDs, scope.onlyComputerGroupIDs, scope.onlyMobileGroupIDs)
        let excluded = scope.excludeCount == 0
            ? ""
            : ", leaving out " + parts(scope.siteIDs, scope.computerGroupIDs, scope.mobileGroupIDs)
        return "\(card.title) measures \(included)\(excluded)."
    }

    /// One row per required app: its name, a Contains switch and Remove.
    @ViewBuilder private var requiredAppRows: some View {
        ForEach(model.scorecardRequiredApps, id: \.self) { app in
            HStack(spacing: 10) {
                Text(verbatim: app).font(.system(size: 14, weight: .medium)).foregroundStyle(SetupTheme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text("Contains").font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                Toggle("", isOn: Binding(
                    get: { model.scorecardContainsApps.contains(app) },
                    set: { on in
                        if on { model.scorecardContainsApps.insert(app) } else { model.scorecardContainsApps.remove(app) }
                    }
                ))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).tint(SetupTheme.accentFill)
                .accessibilityLabel("Match \(app) by Contains")
                Button {
                    model.scorecardRequiredApps.removeAll { $0 == app }
                    model.scorecardContainsApps.remove(app)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SetupTheme.muted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(app)")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(SetupTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    var body: some View {
        SetupCard("Devices") {
            SetupToggleRow(title: "Show Device History",
                           detail: "Policy logs and MDM command history on a computer's page.", isOn: $model.showDeviceHistory)
            SetupToggleRow(title: "Screen Share Signs In Automatically",
                           detail: "Fetches the Jamf management account and its rotating password, so a technician only clicks Screen Share. Needs the Screen Share and Local Admin Password actions on the role.",
                           isOn: $model.screenShareAutoSignIn)
            SetupField(label: "VPN IP Extension Attribute ID", text: $model.vpnIPExtensionAttributeID, placeholder: "Optional, for example 42",
                       help: "If you collect each Mac's VPN IP address in a Jamf extension attribute, enter that attribute's numeric ID. Find it in the address bar when you open the attribute in Jamf Pro (…id=42). FleetHub then shows the VPN address with a VPN badge on the device page, and Screen Share and SSH connect to it. Leave blank if you do not collect it.")
            SetupStepperRow(title: "SSH Password Rotation",
                            detail: "How long after a management account password is used Jamf rotates it. Match the Password Rotation Time in Jamf Pro's Local Admin Password settings. The SSH window counts down to it. SSH itself is granted per role, under Computer Actions.",
                            value: $model.sshPasswordRotationMinutes, range: 5...1440, unit: "minutes")
            SetupToggleRow(title: "My Devices",
                           detail: "A read-only page of the signed-in person's own devices.", isOn: $model.myDevicesEnabled)
            SetupField(label: "Local Administrator Account", text: $model.localAdminUsername, placeholder: "Optional",
                       help: "The LAPS-managed local admin account name, if you use one.")
        }

        SetupCard("Cleanup") {
            SetupStepperRow(title: "Stale After",
                            detail: "A device that has not checked in for this long appears in Cleanup.",
                            value: $model.staleDays, range: 7...730, unit: "days")
        }

        SetupCard("Health Scorecard",
                  subtitle: "Each card measures the whole fleet to start with. Narrow a card to sites or groups later in Jamf Pro's settings form.") {
            SetupToggleRow(title: "Show the Health Scorecard", isOn: $model.scorecardEnabled)
            if model.scorecardEnabled {
                SetupStepperRow(title: "Checked In Within", value: $model.scorecardCheckedInDays, range: 1...180, unit: "days")
                SetupStepperRow(title: "Minimum macOS Version",
                                detail: "A Mac on this major version or later counts as Up to Date. Set it to the oldest version you still support.",
                                value: $model.scorecardMinimumMacOS, range: 11...40)
                SetupStepperRow(title: "Minimum iOS and iPadOS Version", value: $model.scorecardMinimumIOS, range: 15...40)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Required Security Apps").font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                    requiredAppRows
                    SetupListEditor(values: $model.scorecardRequiredApps, showsValues: false,
                                    placeholder: "App name, for example Jamf Protect", addLabel: "Add Security App")
                    Text("Optional. Adds the Protected card: a Mac counts as protected when every app listed here is installed. An app matches by its whole name as Jamf reports it, with or without .app. Turn on Contains to match any installed app whose name includes the text.")
                        .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupRowLine()
                exclusionsEditor
            }
        }
    }
}

// MARK: - Branding

struct SetupBrandingForm: View {
    @EnvironmentObject private var model: SetupModel
    @State private var showingPreview = false

    var body: some View {
        SetupCard {
            HStack {
                Text("Branding").font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                Spacer()
                SetupButton(title: "Preview Sign-In", icon: "eye") { showingPreview = true }
            }
            SetupField(label: "App Title", text: $model.appTitle, placeholder: "FleetHub")
            SetupField(label: "Organization Name", text: $model.companyName, placeholder: "Your Organization",
                       help: "Also used as the organization on the exported profiles.")
            SetupField(label: "Support URL", text: $model.supportURL, placeholder: "https://support.example.com")
            SetupField(label: "Accent Color", text: $model.accentColorHex, placeholder: "#2952E3",
                       help: "A hex color. Leave empty for FleetHub blue.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                SetupSegmented(options: [("system", "Match System"), ("light", "Light"), ("dark", "Dark")],
                               selection: $model.defaultColorScheme)
            }
        }
        .sheet(isPresented: $showingPreview) {
            SetupBrandingPreview().environmentObject(model)
        }
    }
}
