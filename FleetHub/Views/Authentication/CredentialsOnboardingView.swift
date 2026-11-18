//
//  CredentialsOnboardingView.swift
//  FleetHub
//
//  First-run onboarding: shown before sign-in whenever something the
//  configuration needs is not yet in this Mac's Keychain — the provisioning
//  client secret, the Platform integration secret, or (when FleetHub does
//  not create API clients itself) the person's own Jamf API client.
//  Everything goes straight into the Keychain. Secrets are never read from
//  a profile.
//

import SwiftUI

struct CredentialsOnboardingView: View {
    @ObservedObject private var configManager = MDMConfigurationManager.shared
    @State private var showOptional = false

    private var config: MDMConfiguration { configManager.configuration }

    var body: some View {
        ZStack {
            FleetHubTheme.ground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        BrandMark(size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set Up \(Branding.productName)")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundStyle(FleetHubTheme.ink)
                            Text(headline)
                                .font(.system(size: 14))
                                .foregroundStyle(FleetHubTheme.muted)
                        }
                    }

                    // Who the app is running as: secrets are stored per person,
                    // so this is the first thing to check when a Mac that was
                    // set up asks again.
                    HStack(spacing: 10) {
                        Text("Signed in to this Mac as \(NSUserName()). Secrets delivered by your Jamf policy are stored per person.")
                            .font(.system(size: 12))
                            .foregroundStyle(FleetHubTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("Check Again") { MDMConfigurationManager.shared.reloadConfiguration() }
                            .controlSize(.small)
                    }

                    // One card per REQUIRED secret for the selected backend:
                    // the Platform integration (platform, hybrid) and/or the
                    // Jamf Pro master client (jamfPro, hybrid).
                    if config.effectiveAPIBackend.needsPlatformIntegration {
                        card(title: "Jamf Platform API", note: "Required") {
                            Text(config.effectiveAPIBackend == .hybrid
                                 ? "FleetHub reads inventory and reports through this Jamf Platform API integration. Its client secret is stored only in this Mac's Keychain."
                                 : "Your configuration profile set FleetHub to use the Jamf Platform API and delivered the integration's identity. Its client secret is stored only in this Mac's Keychain.")
                                .font(.system(size: 13))
                                .foregroundStyle(FleetHubTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .top, spacing: 12) {
                                SettingsReadOnlyField(label: "Region", value: config.platformAPI?.region.uppercased())
                                SettingsReadOnlyField(label: "Client ID", value: config.platformAPI?.clientID)
                            }
                            SecretEntryRow(secret: .platformClientSecret, required: true)
                        }
                    }
                    // Hidden when a secret for this client is already stored (typed, or
                    // imported by the credential policy).
                    if configManager.needsOwnAPIClient {
                        card(title: "Your Jamf API Client", note: "Required") {
                            if let notice = configManager.ownAPIClientNotice {
                                Text(notice)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(FleetHubTheme.warnText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Your Jamf administrator created an API client for you. Everything you do in \(Branding.productName) runs as that client, so Jamf's audit log names you. It is stored only in this Mac's Keychain.")
                                .font(.system(size: 13))
                                .foregroundStyle(FleetHubTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            OwnAPIClientEntry()
                        }
                    }
                    if config.effectiveAPIBackend.needsPerUserClients, config.effectiveAutoCreateUserApiClient,
                       config.masterClientSecret.isEmpty {
                        card(title: "Jamf Pro", note: "Required") {
                            Text("Your configuration profile delivered the Jamf Pro connection identity. This client only creates each person's own API client. The client secret is stored only in this Mac's Keychain.")
                                .font(.system(size: 13))
                                .foregroundStyle(FleetHubTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .top, spacing: 12) {
                                SettingsReadOnlyField(label: "Server URL", value: config.jamfURL)
                                SettingsReadOnlyField(label: "Master API Client ID", value: config.masterClientID)
                            }
                            SecretEntryRow(secret: .jamfMasterClientSecret, required: true)
                        }
                    }

                    if hasOptionalIntegrations {
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) { showOptional.toggle() }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Optional Integrations")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(FleetHubTheme.ink)
                                        Text("These can also be added later in Settings → Credentials.")
                                            .font(.system(size: 13))
                                            .foregroundStyle(FleetHubTheme.muted)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(FleetHubTheme.muted)
                                        .rotationEffect(.degrees(showOptional ? 180 : 0))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if showOptional {
                                VStack(alignment: .leading, spacing: 18) {
                                    // Not asked for when the credential policy already delivered the key.
                                    if config.abmClientId != nil, (config.abmPrivateKey ?? "").isEmpty {
                                        divider
                                        SecretEntryRow(secret: .abmPrivateKey)
                                    }
                                    // With a Platform integration named, Protect runs through it.
                                    if config.protectEnabled, !(config.platformAPI?.canReachProtect ?? false) {
                                        divider
                                        SecretEntryRow(secret: .jamfProtectPassword)
                                    }
                                    if config.entraTenantId != nil && config.entraClientId != nil {
                                        divider
                                        SecretEntryRow(secret: .entraCertificatePEM)
                                        divider
                                        SecretEntryRow(secret: .entraClientSecret)
                                    }
                                }
                                .padding(.top, 18)
                            }
                        }
                        .fleetHubCard(padding: 22)
                    }

                    let pending = configManager.needsCredentialOnboarding
                    Label(
                        pending ? "Save everything marked Required to continue." : "Saved. Continuing to sign-in…",
                        systemImage: pending ? "arrow.up.circle" : "checkmark.circle.fill"
                    )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(pending ? FleetHubTheme.warnText : FleetHubTheme.goodText)
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var headline: String {
        var needed = 0
        if config.effectiveAPIBackend.needsPlatformIntegration { needed += 1 }
        if config.effectiveAPIBackend.needsPerUserClients { needed += 1 }
        if configManager.needsOwnAPIClient, needed == 1 {
            return "Your own Jamf API client is needed before you can sign in on this Mac."
        }
        return needed > 1
            ? "Two things are needed before anyone can sign in on this Mac."
            : "One secret is needed before anyone can sign in on this Mac."
    }

    private var hasOptionalIntegrations: Bool {
        config.abmClientId != nil || (config.protectEnabled && !(config.platformAPI?.canReachProtect ?? false))
            || (config.entraTenantId != nil && config.entraClientId != nil)
    }

    private var divider: some View {
        Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
    }

    private func card<Content: View>(title: String, note: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text(note)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.badText)
            }
            content()
        }
        .fleetHubCard(padding: 22)
    }
}
