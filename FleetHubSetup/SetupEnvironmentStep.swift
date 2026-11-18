//
//  SetupEnvironmentStep.swift
//  FleetHubSetup
//
//  Step 3 — Jamf Environment Setup. Everything the admin creates in Jamf,
//  in one place, with the permissions each credential needs beside it:
//
//    Jamf Pro API tab
//      · For Setup — the temporary client that uploads the profiles
//      · For the App — the provisioning client, and one Jamf API role per
//        FleetHub role
//    Jamf Platform API tab
//      · the one integration from Jamf Account, and its permissions
//    Credential Delivery tab
//      · the Jamf policy script that puts those two secrets into each
//        Mac's Keychain, to download or upload, and how to rotate them
//
//  The lists follow the API chosen in step 1 and the roles from Configure.
//

import SwiftUI

enum SetupEnvironmentTab: String, CaseIterable, Identifiable {
    case jamfPro, platform, delivery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .jamfPro: "Jamf Pro API"
        case .platform: "Jamf Platform API"
        case .delivery: "Credential Delivery"
        }
    }
}

struct SetupEnvironmentStep: View {
    @EnvironmentObject private var model: SetupModel
    @State private var tab: SetupEnvironmentTab = .jamfPro

    var body: some View {
        HStack(spacing: 12) {
            SetupSegmented(options: SetupEnvironmentTab.allCases.map { ($0, $0.title) }, selection: $tab, onGround: true)
            Text("FleetHub uses: \(model.api.title). Set in step 1.")
                .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
        }
        switch tab {
        case .jamfPro: SetupJamfProTab()
        case .platform: SetupPlatformTab()
        case .delivery: SetupCredentialDeliveryTab()
        }
    }
}

// MARK: - Jamf Pro API tab

struct SetupJamfProTab: View {
    @EnvironmentObject private var model: SetupModel
    @State private var test: SetupTestState = .idle
    @State private var roleID: UUID?

    private var role: SetupRole? {
        model.usableRoles.first { $0.id == roleID } ?? model.usableRoles.first
    }

    var body: some View {
        // ---- For Setup -------------------------------------------------
        SetupSectionHeading(
            title: "For Setup",
            subtitle: "A temporary API client that lets Setup upload the configuration profiles. Optional: skip it to export files and upload them yourself."
        )
        HStack(alignment: .top, spacing: 20) {
            SetupCard {
                SetupCardHeading(title: "Upload Client", tag: model.canUpload ? "Entered" : "Optional",
                                 tone: model.canUpload ? .good : .neutral)
                SetupField(label: "Jamf Pro Tenant URL", text: $model.jamfURL,
                           placeholder: "https://yourtenant.jamfcloud.com", help: model.jamfURLHint)
                if !model.jamfURLIsDetected, let detected = SetupModel.detectedJamfURL {
                    SetupButton(title: "Use Detected URL", kind: .quiet) { model.jamfURL = detected }
                }
                SetupField(label: "Client ID", text: $model.uploadClientID, placeholder: "Paste the client ID")
                SetupField(label: "Client Secret", text: $model.uploadClientSecret,
                           placeholder: "Paste the client secret", secure: true)
                SetupButton(title: "Test Connection", isBusy: test == .running, fullWidth: true) { runTest() }
                SetupTestStatus(state: test,
                                untested: "Test the connection to confirm the URL, client and privileges.")
                Text("The secret is held in memory while Setup is open and used only for the upload. It is never written into a profile, plist or schema.")
                    .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            SetupCard("How to Create the Client") {
                SetupHowTo(
                    steps: [
                        "In Jamf Pro, open **Settings › System › API Roles and Clients**.",
                        "On **API Roles**, select **New**. Name it “FleetHub Setup” and add these privileges (the Scripts ones are only for uploading the credential script):",
                        "On **API Clients**, select **New**. Assign the “FleetHub Setup” role, then **Enable API Client** and save.",
                        "Select **Generate Client Secret**. Jamf Pro shows the secret once, so paste the client ID and secret here straight away."
                    ],
                    lists: [1: SetupModel.uploadPrivileges]
                )
                SetupCopyButton(text: SetupModel.uploadPrivileges.joined(separator: "\n"))
                SetupNotice(text: "When setup is finished you can disable or delete this client. FleetHub does not need it to run.",
                            tone: .warn)
            }
            .frame(maxWidth: .infinity)
        }

        // ---- For the App -----------------------------------------------
        SetupSectionHeading(
            title: "For the App",
            subtitle: "The API clients and roles FleetHub itself runs on."
        )
        if model.api.usesPerUserClients {
            if model.provisionsClients {
                provisioningCard
            } else {
                precreatedClientsCard
            }
            perUserCard
        } else {
            SetupNotice(
                text: "The Platform API cannot create Jamf Pro API clients or read API roles, so there is no personal client per person. Everyone on a Mac acts as the one Platform integration on the Jamf Platform API tab. FleetHub's own roles still decide what each person can do, and FleetHub's log records who did it.",
                tone: .warn, lead: "The provisioning client and per-user roles do not apply."
            )
        }
    }

    private func runTest() {
        test = .running
        let url = model.normalizedJamfURL
        let id = model.uploadClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = model.uploadClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                test = .passed(try await SetupConnection.testJamfPro(jamfURL: url, clientID: id, secret: secret))
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Provisioning client

    /// Shown when automatic client creation is off.
    private var precreatedClientsCard: some View {
        SetupCard {
            VStack(alignment: .leading, spacing: 10) {
                SetupCardHeading(title: "Pre-Created API Clients", tag: "One per Person", tone: .neutral)
                Text("FleetHub creates nothing in Jamf Pro and holds no provisioning secret. For each person who will use FleetHub:")
                    .font(.system(size: 14)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Create an API role for each FleetHub role, with the privileges listed below.\n2. Create an API client for the person and attach the API role for their FleetHub role.\n3. Generate the client secret and give the person the client ID and secret.\n4. FleetHub asks them for it once, checks it with Jamf, and keeps it in their Keychain.")
                    .font(.system(size: 13)).foregroundStyle(SetupTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("When someone's role changes, change the API role on their client in Jamf Pro. To revoke access, disable or delete their client.")
                    .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var provisioningCard: some View {
        SetupCard {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    SetupCardHeading(title: "Provisioning Client", tag: "One per Tenant", tone: .neutral)
                    Text("Also called the master client. FleetHub uses it for one thing: when someone signs in and has no API client of their own yet, it creates one and attaches their role. It is never used to search, read inventory or send a command.")
                        .font(.system(size: 14)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Each person's client is named “FleetHub-first.last@example.com (CLIENT-ID)”.")
                        .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    SetupField(label: "Provisioning (Master) Client ID", text: $model.masterClientID,
                               placeholder: "Client ID",
                               help: "Goes into the Core profile. The same field as on the Configure step.")
                    Text("Its secret is not part of any profile. Deliver it to each Mac's Keychain with the policy on the Credential Delivery tab, or have it typed into FleetHub at first launch.")
                        .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    SetupPrivilegeList(title: "API Role Privileges · \(SetupModel.provisioningPrivileges.count)",
                                       items: SetupModel.provisioningPrivileges)
                    SetupCopyButton(text: SetupModel.provisioningPrivileges.joined(separator: "\n"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Per-user role

    private var perUserCard: some View {
        let options = model.usableRoles.map { (value: $0.id, title: $0.displayName) }
        return SetupCard {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SetupCardHeading(title: "Per-User Role",
                                     tag: model.api == .hybrid ? "Actions Only" : "One per FleetHub Role", tone: .accent)
                    Text(model.api == .hybrid
                         ? "Each person's own Jamf Pro API client carries out their device actions, Cleanup and secret lookups. Pick a role to see what it needs."
                         : "Everything a person does in FleetHub runs as their own Jamf Pro API client. Pick a role to see what it can do and what its client needs.")
                        .font(.system(size: 14)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if options.count > 1 {
                    SetupSegmented(options: options,
                                   selection: Binding(get: { role?.id ?? UUID() }, set: { roleID = $0 }))
                        .fixedSize()
                }
            }

            if let role {
                let groups = model.jamfPrivileges(for: role)
                let all = groups.flatMap(\.items)
                let jamfRole = model.jamfRoleName(for: role)
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("What \(role.displayName) Can Do in FleetHub")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                            .padding(.bottom, 8)
                        ForEach(model.functions(for: role)) { function in
                            SetupRowLine()
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: function.granted ? "checkmark" : "xmark")
                                    .font(.system(size: 10, weight: .heavy))
                                    .foregroundStyle(function.granted ? SetupTheme.goodText : SetupTheme.muted)
                                    .frame(width: 20, height: 20)
                                    .background(function.granted ? SetupTheme.goodFill : SetupTheme.pill,
                                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(function.label).font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(SetupTheme.ink)
                                    Text(function.needs).font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 9)
                            .opacity(function.granted ? 1 : 0.55)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Jamf Privileges for \(role.displayName)")
                                .font(.system(size: 15, weight: .bold)).foregroundStyle(SetupTheme.ink)
                            Spacer(minLength: 8)
                            Text("\(all.count) privileges").font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                        }
                        if jamfRole.isEmpty {
                            SetupNotice(text: "This role names no Jamf API role and there is no Fallback Jamf API Role. Set one on the Configure step.", tone: .bad)
                        } else {
                            (Text("Create a Jamf API role named ") + Text(verbatim: jamfRole).fontWeight(.bold)
                             + Text(" with these privileges. Setup writes that name into this role's entry in the Access profile."))
                                .font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        ForEach(groups) { group in
                            SetupPrivilegeList(title: group.title, items: group.items)
                        }
                        SetupCopyButton(text: all.joined(separator: "\n"))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(SetupTheme.border))
                }
            } else {
                SetupNotice(text: "No roles are defined yet. Add one on the Configure step, under Access and Roles.", tone: .warn)
            }

            SetupNotice(
                text: "Each role in the Access profile names its own Jamf API role, so Admins and Technicians share the same profiles and still get different Jamf privileges. When someone's role changes, FleetHub updates their API client at their next sign-in. A function a person's role grants but their Jamf role lacks fails with a clear error. It never falls back to the provisioning client.",
                tone: .warn, lead: "One Jamf API role per FleetHub role."
            )
        }
    }
}

// MARK: - Jamf Platform API tab

struct SetupPlatformTab: View {
    @EnvironmentObject private var model: SetupModel
    @State private var test: SetupTestState = .idle
    @State private var roleID: UUID?

    private var role: SetupRole? {
        model.usableRoles.first { $0.id == roleID } ?? model.usableRoles.first
    }

    var body: some View {
        if !model.api.usesPlatformIntegration {
            SetupNotice(
                text: "You chose the Jamf Pro API, so this integration is optional. Create it if you want Compliance Benchmarks, or want Jamf Protect to run without a Protect API client of its own.",
                tone: .accent
            )
        }
        HStack(alignment: .top, spacing: 20) {
            SetupCard {
                SetupCardHeading(title: "Platform Integration",
                                 tag: model.api.usesPlatformIntegration ? "Required" : "Optional",
                                 tone: model.api.usesPlatformIntegration ? .accent : .neutral)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Region").font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                    SetupSegmented(options: [("us", "US"), ("eu", "EU"), ("apac", "APAC")],
                                   selection: $model.platformRegion, fill: true)
                    Text(verbatim: "Gateway: \(SetupConnection.gatewayURL(region: model.platformRegion))")
                        .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                }
                SetupField(label: "Client ID", text: $model.platformClientID, placeholder: "Paste the client ID")
                SetupField(label: "Client Secret", text: $model.platformClientSecret,
                           placeholder: "Paste the client secret", secure: true)
                SetupField(label: "Tenant ID", text: $model.platformTenantID,
                           placeholder: "UUID of your Jamf Pro instance",
                           help: "The Jamf Pro instance. Needed when FleetHub reads or acts through the Platform API.")
                SetupField(label: "Environment ID", text: $model.platformEnvironmentID,
                           placeholder: "UUID of the platform environment",
                           help: "Needed for Compliance Benchmarks.")
                if model.protectEnabled {
                    SetupField(label: "Jamf Protect Tenant ID", text: $model.platformProtectTenantID,
                               placeholder: "UUID of your Jamf Protect tenant",
                               help: "Not the Jamf Pro tenant ID above: each product has its own. FleetHub sends this one with Jamf Protect requests, so lookups and deletions go to Protect.")
                }
                SetupButton(title: "Test Connection", isBusy: test == .running, fullWidth: true) { runTest() }
                SetupTestStatus(state: test, untested: "Test the connection to confirm the region and client.")
                Text("The secret is held in memory while Setup is open and is never written into a profile, plist or schema. The region, client ID, tenant ID and environment ID go into the Core settings. Each admin enters the secret in FleetHub on first launch.")
                    .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .onChange(of: model.platformRegion) { _, _ in test = .idle }

            SetupCard("How to Create the Integration") {
                SetupHowTo(steps: [
                    "Sign in to **Jamf Account** (account.jamf.com) as an administrator for your organization.",
                    "Open **APIs › APIs** and select **Create Credential**. Name it “FleetHub”.",
                    "Choose the **Region**, the **API** scope and the **Environment** that contains your Jamf Pro tenant, then grant the permissions listed below.",
                    "Open **Credentials › Get Credentials**. The secret is shown once, so paste the client ID and secret here straight away.",
                    "Copy the **Tenant ID** and **Environment ID** from the Integration Details panel. If you use Jamf Protect, include your Protect tenant in the integration and copy its tenant ID too: it is a separate value from the Jamf Pro one."
                ])
                SetupNotice(text: "Platform API tokens are locked to a region. If the test fails with an authorization error, check the region first.",
                            tone: .accent)
                SetupNotice(text: "Renew the credential in Jamf Account before then, and enter the new secret in FleetHub on each Mac.",
                            tone: .warn, lead: "Integrations expire after six months.")
            }
            .frame(maxWidth: .infinity)
        }

        permissionsCard
    }

    private func runTest() {
        test = .running
        let region = model.platformRegion
        let id = model.platformClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = model.platformClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                test = .passed(try await SetupConnection.testPlatform(region: region, clientID: id, secret: secret))
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    private var tag: (String, SetupTone) {
        switch model.api {
        case .jamfPro: (model.protectEnabled ? "Benchmarks and Jamf Protect" : "Compliance Benchmarks Only", .neutral)
        case .hybrid: ("Reads Only", .accent)
        case .platform: ("Serves Everyone", .warn)
        }
    }

    private var intro: String {
        switch model.api {
        case .jamfPro: model.protectEnabled ? "Needed for Compliance Benchmarks and for Jamf Protect, which both run through the Platform API." : "Needed only for Compliance Benchmarks, which exist only on the Platform API."
        case .hybrid: "The one Jamf Account credential FleetHub reads through. It needs read permissions only: every action runs as the person's own Jamf Pro client."
        case .platform: "The one Jamf Account credential everyone on a Mac shares. Pick the most privileged FleetHub role on those Macs to see what it must hold."
        }
    }

    private var permissionsCard: some View {
        let options = model.usableRoles.map { (value: $0.id, title: $0.displayName) }
        let groups = model.api == .platform
            ? model.platformPermissions(for: role.map { [$0] } ?? [])
            : model.platformPermissions
        let always = groups.first?.items ?? []
        let restItems = groups.dropFirst().flatMap(\.items)
        return SetupCard {
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    SetupCardHeading(title: "Permissions for the Integration", tag: tag.0, tone: tag.1)
                    Text(intro).font(.system(size: 14)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if model.api == .platform, options.count > 1 {
                    SetupSegmented(options: options,
                                   selection: Binding(get: { role?.id ?? UUID() }, set: { roleID = $0 }))
                        .fixedSize()
                }
            }

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    SetupPrivilegeList(
                        title: model.api == .jamfPro ? "Always Needed · Compliance Benchmarks" : "Always Needed · Reads and Compliance Benchmarks",
                        items: always
                    )
                    Text("Read-only. Used to show inventory and benchmark results on Overview and on a device's page.")
                        .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.protectEnabled {
                        Text("Jamf Protect also runs through this integration: devices:read lists Protect computers and devices:delete removes a record.")
                            .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if restItems.isEmpty {
                        SetupCopyButton(text: always.joined(separator: "\n"), title: "Copy Permission List")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !restItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(model.api == .platform ? "Jamf Protect and Actions for \(role?.displayName ?? "This Role")" : "Jamf Protect")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                            Spacer()
                            Text("\(restItems.count) permissions").font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                        }
                        SetupListBox(items: restItems)
                        SetupCopyButton(text: (always + restItems).joined(separator: "\n"), title: "Copy Permission List")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if model.api == .hybrid {
                SetupNotice(
                    text: "Anyone signed in to FleetHub reads inventory through this one integration, so FleetHub's own roles are what limit who can see what. Everything that changes a device or shows a secret still runs as the person, and Jamf audits it against them.",
                    tone: .warn, lead: "Reads are shared, actions are personal."
                )
            }
            if model.api == .platform {
                SetupNotice(
                    text: "Grant it what the most privileged FleetHub role on those Macs needs. To limit Technicians in Jamf itself, create a second integration with the Technician list and scope a separate Core profile to their Macs.",
                    tone: .warn, lead: "One integration serves everyone on a Mac."
                )
            }
            SetupNotice(
                text: "Permission names marked “(confirm)” were not named in Jamf's reference, so check them against the permission picker in Jamf Account.",
                tone: .neutral
            )
        }
    }
}

// MARK: - Credential Delivery tab

struct SetupCredentialDeliveryTab: View {
    @EnvironmentObject private var model: SetupModel
    @State private var result: SetupTestState = .idle
    @State private var uploading = false
    @State private var showingScript = false
    @State private var keyResult: SetupTestState = .idle
    /// A key pasted for encoding. Held only in this view: never in the
    /// model, so it is never saved, and cleared as soon as it is encoded.
    @State private var pastedKey = ""

    private var jamfClientID: String { model.masterClientID.trimmingCharacters(in: .whitespaces) }
    /// Why policy parameters 4 and 5 stay empty.
    private var noProvisioningText: String {
        model.api.usesPerUserClients ? "Leave empty: API clients are pre-created" : "Leave empty on the Platform API"
    }
    private var platformClientID: String { model.platformClientID.trimmingCharacters(in: .whitespaces) }
    private var abmKeyID: String { model.abmKeyID.trimmingCharacters(in: .whitespaces) }
    private var entraCleanupClientID: String { model.entraCleanupClientID.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SetupNotice(
            text: "FleetHub keeps its API client secrets and the Apple Business Manager key in each user's Keychain, never in a profile. This script lets the same Jamf policy that installs FleetHub hand them to the app, so nobody types or pastes them. Without it, each person is asked once.",
            tone: .accent
        )

        HStack(alignment: .top, spacing: 20) {
            SetupCard {
                SetupCardHeading(title: "The Script", tag: "Import-FleetHub-Credentials.sh", tone: .neutral)
                Text("Runs as root in a Jamf policy, finds the logged-in user, and passes each secret to FleetHub, which writes its own Keychain item. Running it again with the same values does nothing, so it is safe on every check-in.")
                    .font(.system(size: 14)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    SetupButton(title: "Download Script", icon: "arrow.down.to.line") { download() }
                    SetupButton(title: "View", icon: "eye") { showingScript = true }
                    if model.canUpload {
                        SetupButton(title: "Upload to Jamf Pro", icon: "arrow.up.to.line", kind: .primary,
                                    isBusy: uploading) { upload() }
                    }
                }
                if !model.canUpload {
                    Text("To upload it from here, enter the upload client on the Jamf Pro API tab, under For Setup. Its API role needs Create, Read and Update Scripts.")
                        .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SetupTestResult(state: result)

                SetupRowLine()
                Text("Policy Parameters").font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                parameterRow(4, "Jamf Pro Provisioning Client ID", value: model.provisionsClients ? jamfClientID : nil,
                             empty: model.provisionsClients ? "Enter it on the Jamf Pro API tab" : noProvisioningText)
                parameterRow(5, "Jamf Pro Provisioning Client Secret", value: nil,
                             empty: model.provisionsClients ? "Paste from Jamf Pro into the policy" : noProvisioningText)
                parameterRow(6, "Jamf Platform API Client ID", value: platformClientID.isEmpty ? nil : platformClientID,
                             empty: "Leave empty if you have no Platform integration")
                parameterRow(7, "Jamf Platform API Client Secret", value: nil,
                             empty: platformClientID.isEmpty ? "Leave empty if you have no Platform integration" : "Paste from Jamf Account into the policy")
                parameterRow(8, "Apple Business Manager Key ID", value: model.abmEnabled && !abmKeyID.isEmpty ? abmKeyID : nil,
                             empty: model.abmEnabled ? "Enter it on the Configure step, under Optional Integrations" : "Leave empty unless you use Apple Business Manager")
                parameterRow(9, "Apple Business Manager Private Key", value: nil,
                             empty: model.abmEnabled ? "The .pem file, base64-encoded on one line" : "Leave empty unless you use Apple Business Manager")
                parameterRow(10, "Entra Device Cleanup Client ID",
                             value: model.entraCleanupEnabled && !entraCleanupClientID.isEmpty ? entraCleanupClientID : nil,
                             empty: model.entraCleanupEnabled ? "Enter it on the Configure step, under Optional Integrations" : "Leave empty unless you use Entra device cleanup")
                parameterRow(11, "Entra Device Cleanup Client Secret", value: nil,
                             empty: model.entraCleanupEnabled ? "Paste from the Entra app registration into the policy" : "Leave empty unless you use Entra device cleanup")
                if model.abmEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Encode the Key for Parameter 9")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(SetupTheme.control)
                        HStack(spacing: 10) {
                            SetupButton(title: "Choose a .pem File…", icon: "doc") { encodeKeyFile() }
                            Text("or paste the key below").font(.system(size: 13)).foregroundStyle(SetupTheme.muted)
                            Spacer(minLength: 0)
                        }
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $pastedKey)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(SetupTheme.ink)
                                .scrollContentBackground(.hidden)
                                .autocorrectionDisabled()
                                .padding(8)
                            if pastedKey.isEmpty {
                                Text(verbatim: "-----BEGIN EC PRIVATE KEY-----\n…\n-----END EC PRIVATE KEY-----")
                                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(SetupTheme.muted)
                                    .padding(.horizontal, 13).padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(height: 110)
                        .background(SetupTheme.surface, in: RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: SetupTheme.controlRadius, style: .continuous).stroke(SetupTheme.fieldBorder))
                        .accessibilityLabel("Paste the private key")
                        HStack(spacing: 10) {
                            SetupButton(title: "Copy Encoded Key", icon: "key", kind: .primary,
                                        disabled: pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { encodePastedKey() }
                            Text("The box is cleared once the key is copied.")
                                .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                            Spacer(minLength: 0)
                        }
                    }
                    SetupTestResult(state: keyResult)
                    SetupNotice(
                        text: "Jamf parameters hold one line, so the key goes in base64-encoded. Setup takes the key from a file or from what you paste, copies the encoded text to the clipboard for you to paste into parameter 9, and keeps nothing: the pasted key is not part of the automatic save. This key can assign and unassign devices across your whole ABM organization, and anyone who can view the policy can read it.",
                        tone: .warn, lead: "Handle parameter 9 with care."
                    )
                }
                Text("Setup never sends the secrets: you paste them into the policy in Jamf Pro. Anyone who can view that policy can read them, so limit who holds Read Policies.")
                    .font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 20) {
                SetupCard("Set Up the Policy") {
                    SetupHowTo(steps: [
                        "Add the script to Jamf Pro: upload it from here, or download it and add it under **Settings › Computer Management › Scripts**.",
                        "Open the policy that installs the FleetHub package and add the script under **Scripts**, with priority **After** so the app is installed first.",
                        "Fill in parameters 4 to 11 with the values on the left. Leave a pair empty if you do not use it.",
                        "Set **Execution Frequency** to **Ongoing** and turn on the **Recurring Check-in** and **Login** triggers. The Keychain belongs to a user, so the import waits until someone is logged in.",
                        "Scope the policy to the Macs that run FleetHub."
                    ])
                }
                SetupCard("Rotate a Secret") {
                    SetupHowTo(steps: [
                        "Create a **new** API client (or Platform credential) rather than regenerating the old one's secret. Regenerating cuts off every Mac until its next check-in.",
                        "Put the new client ID and secret in the policy parameters. Macs import it at their next check-in and keep the old one too.",
                        "Change the client ID in the Core profile to the new one. Each Mac switches the moment it has both.",
                        "When the fleet has checked in, delete the old client in Jamf."
                    ])
                    SetupNotice(text: "Platform credentials expire every six months, so this is also the routine renewal path.",
                                tone: .warn)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingScript) { scriptSheet }
    }

    private func parameterRow(_ number: Int, _ label: String, value: String?, empty: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(SetupTheme.accentInk)
                .frame(width: 24, height: 24)
                .background(SetupTheme.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(SetupTheme.ink)
                if let value, !value.isEmpty {
                    Text(verbatim: value).font(.system(size: 12, design: .monospaced)).foregroundStyle(SetupTheme.muted)
                        .textSelection(.enabled)
                } else {
                    Text(empty).font(.system(size: 12)).foregroundStyle(SetupTheme.muted)
                }
            }
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                SetupCopyButton(text: value, title: "Copy")
            }
        }
    }

    private var scriptSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "Import-FleetHub-Credentials.sh").font(.system(size: 16, weight: .bold)).foregroundStyle(SetupTheme.ink)
                Spacer()
                SetupCopyButton(text: (try? SetupOutput.credentialScript()) ?? "", title: "Copy Script")
                SetupButton(title: "Done", kind: .primary) { showingScript = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            Divider().overlay(SetupTheme.border)
            ScrollView([.vertical, .horizontal]) {
                Text(verbatim: (try? SetupOutput.credentialScript()) ?? "The script is missing from this copy of FleetHub Setup.")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(SetupTheme.previewText)
                    .textSelection(.enabled)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(SetupTheme.previewWell)
        }
        .frame(width: 900, height: 640)
        .background(SetupTheme.surface)
    }

    /// Puts the base64 form of a PEM private key on the clipboard. The key
    /// is tidied first (see SetupOutput.normalizedPrivateKeyPEM). Nothing is
    /// kept or written.
    private func copyEncodedKey(from text: String, source: String) -> Bool {
        guard let encoded = SetupOutput.encodedPrivateKey(text) else {
            keyResult = .failed("\(source) is not a PEM private key. It should start with a BEGIN PRIVATE KEY or BEGIN EC PRIVATE KEY line and end with the matching END line.")
            return false
        }
        // Marked so clipboard managers skip it, and removed again after two
        // minutes unless something else has been copied since.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(encoded, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
        }
        keyResult = .passed("Encoded key copied. Paste it into parameter 9 of the policy. The clipboard clears itself in 2 minutes.")
        return true
    }

    /// Reads a chosen key file and copies its encoded form.
    private func encodeKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Encode"
        panel.message = "Choose the Apple Business Manager private key (.pem or .p8)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            keyResult = .failed("That file could not be read as text.")
            return
        }
        _ = copyEncodedKey(from: text, source: "That file")
    }

    /// Copies the encoded form of the pasted key, then clears the box so
    /// the key does not stay on screen.
    private func encodePastedKey() {
        if copyEncodedKey(from: pastedKey, source: "The pasted text") {
            pastedKey = ""
        }
    }

    private func download() {
        do {
            let script = try SetupOutput.credentialScript()
            if let url = try SetupOutput.save(Data(script.utf8), suggestedName: SetupOutput.credentialScriptName + ".sh") {
                result = .passed("Saved \(url.lastPathComponent).")
            }
        } catch {
            result = .failed(error.localizedDescription)
        }
    }

    private func upload() {
        uploading = true
        Task {
            do {
                let script = try SetupOutput.credentialScript()
                let outcome = try await SetupConnection.uploadScript(
                    named: SetupOutput.credentialScriptName, contents: script,
                    jamfURL: model.normalizedJamfURL,
                    clientID: model.uploadClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                    secret: model.uploadClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                result = .passed(outcome.updated
                    ? "Updated script \(outcome.profileID) in Jamf Pro. Add it to your FleetHub policy and fill in its parameters."
                    : "Created script \(outcome.profileID) in Jamf Pro. Add it to your FleetHub policy and fill in its parameters.")
            } catch {
                result = .failed(error.localizedDescription)
            }
            uploading = false
        }
    }
}
