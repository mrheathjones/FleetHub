//
//  CredentialsSettingsSection.swift
//  FleetHub
//
//  Settings → Credentials: the ONLY place integration secrets enter the app.
//  Every value typed here goes straight to the Keychain through SecretStore;
//  nothing is written to UserDefaults, a profile, or a log. The matching
//  non-secret identities (server URL, client IDs, key IDs, tenant ID) come
//  from the core configuration profile and are shown read-only for context.
//
//  `SecretEntryRow` is shared with the first-run onboarding sheet.
//

import SwiftUI
import Security

// MARK: - Shared control styling

/// Button label in the three weights Settings uses.
struct SettingsButtonLabel: View {
    enum Kind { case primary, outline, destructive }

    let text: String
    var kind: Kind = .outline
    var icon: String?

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(ink)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .fill(kind == .primary ? FleetHubTheme.accentFill : FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(border, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var ink: Color {
        switch kind {
        case .primary: .white
        case .outline: FleetHubTheme.ink
        case .destructive: FleetHubTheme.badText
        }
    }

    private var border: Color {
        switch kind {
        case .primary: .clear
        case .outline: FleetHubTheme.border
        case .destructive: FleetHubTheme.badText.opacity(0.35)
        }
    }
}

/// Small rounded status tag.
struct SettingsTag: View {
    enum Tone { case good, bad, warn, neutral, accent }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fill))
    }

    private var ink: Color {
        switch tone {
        case .good: FleetHubTheme.goodText
        case .bad: FleetHubTheme.badText
        case .warn: FleetHubTheme.warnText
        case .neutral: FleetHubTheme.control
        case .accent: FleetHubTheme.accent
        }
    }

    private var fill: Color {
        switch tone {
        case .good: FleetHubTheme.goodFill
        case .bad: FleetHubTheme.badFill
        case .warn: FleetHubTheme.warnFill
        case .neutral: FleetHubTheme.trough
        case .accent: FleetHubTheme.accent.opacity(0.12)
        }
    }
}

extension View {
    /// Outlined text-entry box.
    func settingsFieldBox(minHeight: CGFloat = 36) -> some View {
        self
            .padding(.horizontal, 12)
            .frame(minHeight: minHeight)
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

/// A labelled field: caption above, control below.
struct SettingsLabelled<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FleetHubTheme.control)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A value delivered by the configuration profile: shown, selectable, not
/// editable.
struct SettingsReadOnlyField: View {
    let label: String
    let value: String?

    var body: some View {
        SettingsLabelled(label: label) {
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "Not Delivered by Profile")
                .font(.system(size: 13))
                .foregroundStyle((value ?? "").isEmpty ? FleetHubTheme.muted : FleetHubTheme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                        .fill(FleetHubTheme.ground)
                )
                .help("Set by your configuration profile")
        }
    }
}

// MARK: - One secret

/// Entry row for a single secret: masked field (or PEM editor), Save, Remove,
/// a "Saved in Keychain" tag, and an inline error when the Keychain write
/// fails. The typed value is kept in view state only until it is saved, then
/// discarded.
struct SecretEntryRow: View {
    let secret: FleetHubSecret
    var required: Bool = false
    var relevance: String? = nil
    /// The profile-delivered identifier this secret pairs with (API client
    /// ID, ABM key ID). When the Jamf credential policy has delivered a
    /// secret for exactly this identifier, the row is MANAGED: it shows
    /// that, and offers nothing to type, save or remove.
    var managedBy: String? = nil
    var onChanged: (() -> Void)? = nil

    private var isManaged: Bool { SecretStore.shared.hasImported(secret, clientID: managedBy) }

    @State private var draft = ""
    @State private var isSaved = false
    @State private var error: String?
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(secret.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.control)
                if required {
                    Text("Required")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.badText)
                }
                Spacer(minLength: 8)
                SettingsTag(text: isManaged ? "Delivered by Jamf Policy" : isSaved ? "Saved in Keychain" : "Not Saved",
                            tone: isManaged || isSaved ? .good : .neutral)
            }

            if isManaged {
                Text("Managed by your organization. This was delivered to this Mac's Keychain by a Jamf policy and is in use, so there is nothing to enter here. To change it, update the policy in Jamf Pro.")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                editor
            }
        }
        .onAppear { isSaved = SecretStore.shared.has(secret) }
    }

    /// The typed-in path: field, help, Save and Remove.
    @ViewBuilder private var editor: some View {
            if secret.isMultiline {
                TextEditor(text: $draft)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96, maxHeight: 160)
                    .padding(.vertical, 6)
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(isSaved ? "Paste a new PEM to replace the saved one" : "Paste PEM here")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(FleetHubTheme.muted)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .settingsFieldBox()
            } else {
                SecureField(
                    "",
                    text: $draft,
                    prompt: Text(isSaved ? "Saved — enter a new value to replace" : "Paste value")
                        .foregroundColor(FleetHubTheme.muted)
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .settingsFieldBox()
                .onSubmit { save() }
            }

            Text(secret.help)
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if let relevance {
                Text(relevance)
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                let isBlank = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button { save() } label: {
                    SettingsButtonLabel(text: "Save", kind: .primary)
                        .opacity(isBlank ? 0.45 : 1)
                }
                .buttonStyle(.plain)
                .disabled(isBlank)

                if let error {
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.badText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isSaved {
                    Button { confirmClear = true } label: {
                        SettingsButtonLabel(text: "Remove from Keychain", kind: .destructive)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Remove the saved \(secret.title)?", isPresented: $confirmClear) {
                        Button("Remove from Keychain", role: .destructive) { clear() }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
    }

    private func save() {
        let status = SecretStore.shared.set(secret, to: draft)
        if status == errSecSuccess {
            draft = ""
            error = nil
            isSaved = true
            MDMConfigurationManager.shared.reloadConfiguration()
            onChanged?()
        } else {
            // Keep the draft so the operator can retry; never pretend it saved.
            error = "Could not save to the Keychain: \(SecretStore.describe(status))"
        }
    }

    private func clear() {
        if SecretStore.shared.remove(secret) {
            isSaved = false
            error = nil
            MDMConfigurationManager.shared.reloadConfiguration()
            onChanged?()
        } else {
            error = "Could not remove the item from the Keychain."
        }
    }
}

// MARK: - Settings card content

/// The Credentials card in Settings: one bordered block per integration,
/// each with its profile-delivered identities (read-only), its secret(s) and
/// a connection test where one exists.
struct CredentialsSettingsSection: View {
    /// True → the Jamf Protect block also carries the Cleanup module's own
    /// Protect controls (enable, tenant, client ID, auto-delete).
    var showsProtectControls = false

    @ObservedObject private var configManager = MDMConfigurationManager.shared

    @State private var jamfTestResult: String?
    @State private var jamfTestOK = false
    @State private var protectTestResult: String?
    @State private var protectTestOK = false
    @State private var platformTestResult: String?
    @State private var platformTestOK = false
    @State private var testing = false
    /// Bumped when a secret or a Protect preference changes, so the status
    /// tags (read from the Keychain and UserDefaults) re-evaluate.
    @State private var revision = 0

    private let cleanupSettings = CleanupSettings()
    private var config: MDMConfiguration { configManager.configuration }

    var body: some View {
        let _ = revision

        VStack(alignment: .leading, spacing: 16) {
            jamfProBlock
            platformBlock
            abmBlock
            protectBlock
            entraBlock
        }
    }

    // MARK: Blocks

    /// Shown in place of the provisioning client when automatic creation is
    /// off: the person's own pre-created Jamf API client.
    private var ownClientBlock: some View {
        let stored = KeychainManager.shared.loadJamfCredentials()
        return block(title: "Your Jamf API Client", note: "Required", noteIsRequired: true,
                     status: stored == nil ? "Not Set Up" : "Configured",
                     statusTone: stored == nil ? .warn : .good) {
            twoUp {
                SettingsReadOnlyField(label: "Server URL", value: config.jamfURL)
                SettingsReadOnlyField(label: "Client ID", value: stored?.clientID)
            }
            Text("Your Jamf administrator creates this client and decides what it may do. Enter a new client ID and secret here to replace it.")
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            OwnAPIClientEntry(saveTitle: stored == nil ? "Save" : "Replace") { revision += 1 }
        }
    }

    @ViewBuilder
    private var jamfProBlock: some View {
        if config.effectiveAPIBackend.needsPerUserClients, !config.effectiveAutoCreateUserApiClient {
            ownClientBlock
        } else {
            provisioningClientBlock
        }
    }

    private var provisioningClientBlock: some View {
        // On the Platform backend the master client has no job: there are
        // no per-user API clients for it to provision.
        let onPlatform = !config.effectiveAPIBackend.needsPerUserClients
        // The secret is either typed here or imported for this client ID by
        // the credential policy; `config.masterClientSecret` is whichever applies.
        let fromPolicy = SecretStore.shared.hasImported(.jamfMasterClientSecret, clientID: config.masterClientID)
        let ready = !config.jamfURL.isEmpty && !config.masterClientID.isEmpty
            && !config.masterClientSecret.isEmpty
        return block(title: "Jamf Pro", note: onPlatform ? "Not Used on the Platform API" : "Required",
                     noteIsRequired: !onPlatform,
                     status: ready ? "Configured" : "Not Set Up",
                     statusTone: ready ? .good : (onPlatform ? .neutral : .warn)) {
            twoUp {
                SettingsReadOnlyField(label: "Server URL", value: config.jamfURL)
                SettingsReadOnlyField(label: "Master API Client ID", value: config.masterClientID)
            }
            SecretEntryRow(
                secret: .jamfMasterClientSecret,
                required: !onPlatform && !fromPolicy,
                relevance: onPlatform ? "FleetHub is set to use the Jamf Platform API, so this secret is kept but unused." : nil,
                managedBy: config.masterClientID
            ) {
                jamfTestResult = nil
                revision += 1
            }
            testRow(title: "Test Jamf Pro Connection", result: jamfTestResult, ok: jamfTestOK,
                    disabled: testing || !ready) { testJamf() }
        }
    }

    /// The Jamf Platform API integration (created in Jamf Account). Required
    /// when the Core profile selects the Platform backend; optional
    /// otherwise, where it only powers Compliance Benchmarks.
    private var platformBlock: some View {
        let backend = config.effectiveAPIBackend
        let onPlatform = backend.needsPlatformIntegration
        let ready = config.isPlatformAPIReady
        return block(title: "Jamf Platform API", note: onPlatform ? "Required" : "Optional",
                     noteIsRequired: onPlatform,
                     status: ready ? "Configured" : "Not Set Up",
                     statusTone: ready ? .good : (onPlatform ? .warn : .neutral)) {
            if let platform = config.platformAPI {
                twoUp {
                    SettingsReadOnlyField(label: "Region", value: platform.region.uppercased())
                    SettingsReadOnlyField(label: "Client ID", value: platform.clientID)
                }
                twoUp {
                    SettingsReadOnlyField(label: "Jamf Pro Tenant ID", value: platform.tenantID)
                    SettingsReadOnlyField(label: "Environment ID", value: platform.environmentID)
                }
                if !platform.protectTenantID.isEmpty {
                    SettingsReadOnlyField(label: "Jamf Protect Tenant ID", value: platform.protectTenantID)
                }
                if platform.environmentID.isEmpty {
                    Text("No Environment ID is delivered, so Compliance Benchmarks cannot be shown. Add it to the Core profile (Platform API Integration → Environment ID).")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.warnText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(platformExplanation(for: backend))
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            SecretEntryRow(
                secret: .platformClientSecret,
                required: onPlatform,
                relevance: config.platformAPI == nil ? "No Platform API integration is named in your configuration profile (core platformAPI); the secret is kept but unused." : nil,
                managedBy: config.platformAPI?.clientID
            ) {
                platformTestResult = nil
                JamfPlatformSession.shared.invalidate()
                revision += 1
            }
            testRow(title: "Test Platform API Connection", result: platformTestResult, ok: platformTestOK,
                    disabled: testing || !ready) { testPlatform() }
        }
    }

    private func platformExplanation(for backend: JamfAPIBackend) -> String {
        switch backend {
        case .platform:
            return "FleetHub is set to use the Jamf Platform API for everything. Every person using FleetHub on this Mac acts as this one integration; FleetHub's own action log records who did what."
        case .hybrid:
            return "FleetHub reads inventory, search results and reports through this integration, and it powers Compliance Benchmarks. Device actions, Cleanup and secrets still run on each person's own Jamf Pro API client, so Jamf's audit names them."
        case .jamfPro:
            return "Used for Compliance Benchmarks. Everything else runs on each person's own Jamf Pro API client."
        }
    }

    private var abmBlock: some View {
        let enabled = !(config.abmClientId ?? "").isEmpty
        // Typed here, or imported for this key ID by the credential policy.
        let fromPolicy = SecretStore.shared.hasImported(.abmPrivateKey, clientID: config.abmKeyId)
        let saved = SecretStore.shared.has(.abmPrivateKey) || fromPolicy
        return block(title: "Apple Business Manager", note: "Optional",
                     status: enabled && saved ? "Configured" : "Not Set Up",
                     statusTone: enabled && saved ? .good : .neutral) {
            if enabled {
                twoUp {
                    SettingsReadOnlyField(label: "Client ID", value: config.abmClientId)
                    SettingsReadOnlyField(label: "Key ID", value: config.abmKeyId)
                }
            }
            SecretEntryRow(
                secret: .abmPrivateKey,
                relevance: !enabled ? "Apple Business Manager is not enabled in your configuration profile; the key is kept but unused." : nil,
                managedBy: config.abmKeyId
            ) { revision += 1 }
        }
    }

    /// Which ID Protect requests are addressed with, for the note below.
    private var protectScopeDescription: String {
        guard let platform = config.platformAPI else { return "your Protect tenant" }
        return platform.protectTenantID.isEmpty
            ? "the environment \(platform.environmentID)"
            : "the Protect tenant \(platform.protectTenantID)"
    }

    private var protectBlock: some View {
        let ready = cleanupSettings.isProtectConfigured
        // With a Platform integration in place, Protect runs through it and
        // its own tenant URL, client ID and password are not used.
        let viaPlatform = cleanupSettings.protectUsesPlatform
        return block(title: "Jamf Protect", note: viaPlatform ? "Through the Platform API" : "Optional",
                     status: ready ? "Configured" : "Not Set Up", statusTone: ready ? .good : .neutral) {
            if viaPlatform {
                Text("Jamf Protect requests go through your Jamf Platform API integration, addressed to \(protectScopeDescription), so no Protect address, client ID or password is needed. The integration needs the devices:read permission, and devices:delete to remove Protect records.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if cleanupSettings.protectIsManaged {
                // Set by the configuration profile: shown, not editable.
                HStack(spacing: 8) {
                    Text("Use Jamf Protect")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                    SettingsTag(text: cleanupSettings.protectEnabled ? "On" : "Off",
                                tone: cleanupSettings.protectEnabled ? .good : .neutral)
                    Spacer(minLength: 8)
                    Text("Set by your configuration profile")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                }
                if cleanupSettings.protectEnabled, !viaPlatform {
                    twoUp {
                        SettingsReadOnlyField(label: "Tenant URL", value: config.protectURL)
                        SettingsReadOnlyField(label: "API Client ID", value: config.protectClientID)
                    }
                }
            } else if showsProtectControls {
                toggleRow(
                    "Use Jamf Protect",
                    "Show Protect counts in Cleanup and allow deleting Protect records.",
                    isOn: Binding(
                        get: { cleanupSettings.protectEnabled },
                        set: { cleanupSettings.protectEnabled = $0; revision += 1 }
                    )
                )

                if cleanupSettings.protectEnabled, !viaPlatform {
                    twoUp {
                        SettingsLabelled(label: "Tenant URL") {
                            TextField(
                                "",
                                text: Binding(
                                    get: { cleanupSettings.protectURL },
                                    set: { cleanupSettings.protectURL = $0; revision += 1 }
                                ),
                                prompt: Text("https://yourtenant.protect.jamfcloud.com").foregroundColor(FleetHubTheme.muted)
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .settingsFieldBox()
                        }
                        SettingsLabelled(label: "API Client ID") {
                            TextField(
                                "",
                                text: Binding(
                                    get: { cleanupSettings.protectClientID },
                                    set: { cleanupSettings.protectClientID = $0; revision += 1 }
                                ),
                                prompt: Text("Client ID").foregroundColor(FleetHubTheme.muted)
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .settingsFieldBox()
                        }
                    }
                }
            } else if config.protectEnabled, !viaPlatform {
                twoUp {
                    SettingsReadOnlyField(label: "Tenant URL", value: config.protectURL)
                    SettingsReadOnlyField(label: "API Client ID", value: config.protectClientID)
                }
            }

            if !viaPlatform {
                SecretEntryRow(
                    secret: .jamfProtectPassword,
                    relevance: cleanupSettings.protectEnabled ? nil : "Jamf Protect is not turned on; the password is kept but unused."
                ) {
                    protectTestResult = nil
                    revision += 1
                }
            }

            testRow(title: "Test Jamf Protect Connection", result: protectTestResult, ok: protectTestOK,
                    disabled: testing) { testProtect() }

            if showsProtectControls, cleanupSettings.protectEnabled {
                toggleRow(
                    "Auto-Delete Protect Record",
                    "When deleting a Jamf Pro record in Cleanup, also delete the matching Protect record.",
                    isOn: Binding(
                        get: { cleanupSettings.protectAutoCleanup },
                        set: { cleanupSettings.protectAutoCleanup = $0; revision += 1 }
                    )
                )
            }
        }
    }

    private var entraBlock: some View {
        let enabled = config.entraTenantId != nil && config.entraClientId != nil
        // Typed here, or the client secret delivered for this app by the
        // credential policy. `isEntraConfigured` reads the merged values.
        let secretFromPolicy = SecretStore.shared.hasImported(.entraClientSecret, clientID: config.entraClientId)
        let saved = config.isEntraConfigured || secretFromPolicy
        return block(title: "Microsoft Entra — Device Cleanup", note: "Optional",
                     status: enabled && saved ? "Configured" : "Not Set Up",
                     statusTone: enabled && saved ? .good : .neutral) {
            if enabled {
                twoUp {
                    SettingsReadOnlyField(label: "Tenant ID", value: config.entraTenantId)
                    SettingsReadOnlyField(label: "Client ID", value: config.entraClientId)
                }
            } else {
                Text("Entra device cleanup is not configured in your profile (core entra.tenantID / clientID). Secrets saved here are kept but unused.")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // With the secret delivered by policy the certificate is not
            // needed, so its entry field is not offered.
            if !secretFromPolicy {
                SecretEntryRow(secret: .entraCertificatePEM) { revision += 1 }
                Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
            }
            SecretEntryRow(secret: .entraClientSecret, managedBy: config.entraClientId) { revision += 1 }
        }
    }

    // MARK: Tests

    private func testJamf() {
        testing = true
        jamfTestResult = nil
        Task { @MainActor in
            do {
                JamfTokenProvider.invalidateAll()
                _ = try await JamfTokenProvider.provisioningToken()
                jamfTestOK = true
                jamfTestResult = "Connected — the master API client authenticated"
            } catch {
                jamfTestOK = false
                jamfTestResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func testPlatform() {
        testing = true
        platformTestResult = nil
        Task { @MainActor in
            do {
                JamfPlatformSession.shared.invalidate()
                _ = try await JamfTokenProvider.platformToken()
                platformTestOK = true
                platformTestResult = "Connected — the Platform integration authenticated"
            } catch {
                platformTestOK = false
                platformTestResult = error.localizedDescription
            }
            testing = false
        }
    }

    private func testProtect() {
        testing = true
        protectTestResult = nil
        Task { @MainActor in
            let result = await CleanupConnectionTester.testProtect(CleanupSettings())
            switch result {
            case .success(let m): protectTestOK = true; protectTestResult = m
            case .failure(let e): protectTestOK = false; protectTestResult = e.localizedDescription
            }
            testing = false
        }
    }

    // MARK: Small helpers

    private func block<Content: View>(
        title: String,
        note: String,
        noteIsRequired: Bool = false,
        status: String,
        statusTone: SettingsTag.Tone,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text(note)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(noteIsRequired ? FleetHubTheme.badText : FleetHubTheme.muted)
                Spacer(minLength: 8)
                SettingsTag(text: status, tone: statusTone)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(FleetHubTheme.border, lineWidth: 1)
        )
    }

    /// Two fields side by side, stacked when the card is too narrow.
    private func twoUp<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let fields = content()
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) { fields }
                .frame(minWidth: 420)
            VStack(alignment: .leading, spacing: 12) { fields }
        }
    }

    private func toggleRow(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }

    private func testRow(title: String, result: String?, ok: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: action) {
                SettingsButtonLabel(text: title)
                    .opacity(disabled ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(disabled)

            if testing {
                ProgressView().controlSize(.small)
            }
            if let result {
                Label(result, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(ok ? FleetHubTheme.goodText : FleetHubTheme.badText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}


// MARK: - Own API client entry

/// Client ID and secret fields for the person's own pre-created Jamf API
/// client. Saving proves the client works before it is kept.
struct OwnAPIClientEntry: View {
    var saveTitle = "Save"
    var onSaved: () -> Void = {}

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isSaving = false
    @State private var problem: String?

    private var canSave: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty && !isSaving
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Client ID").font(.system(size: 12, weight: .semibold)).foregroundStyle(FleetHubTheme.control)
                    TextField("", text: $clientID, prompt: Text("Client ID"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .autocorrectionDisabled()
                        .settingsFieldBox()
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Client Secret").font(.system(size: 12, weight: .semibold)).foregroundStyle(FleetHubTheme.control)
                    SecureField("", text: $clientSecret, prompt: Text("Client Secret"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .settingsFieldBox()
                        .onSubmit { if canSave { save() } }
                }
            }
            HStack(spacing: 10) {
                Button(action: save) {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small) }
                        Text(isSaving ? "Checking With Jamf…" : saveTitle)
                    }
                }
                .disabled(!canSave)
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.badText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func save() {
        isSaving = true
        problem = nil
        Task { @MainActor in
            let result = await OwnJamfAPIClient.save(clientID: clientID, clientSecret: clientSecret)
            isSaving = false
            if let result {
                problem = result
            } else {
                clientID = ""
                clientSecret = ""
                onSaved()
            }
        }
    }
}
