//
//  MDMConfigurationManager.swift
//  FleetHub
//
//  Aggregation layer over the four FleetHub managed-preference domains
//  (com.herojoneslabs.fleethub.core / .access / .features / .ui — see
//  docs/Configuration.md) and the Keychain-held secrets
//  (SecretStore). Loads each domain uniformly via ManagedDomainLoader in
//  BOTH apps (no per-process branching) and composes the
//  flat MDMConfiguration consumer surface.
//
//  SECRETS NEVER COME FROM A PROFILE.
//
//  NOTE: no auto-observation of profile changes — configuration is loaded
//  at app init (and via reloadConfiguration()); profile pushes take effect
//  at relaunch. Secrets saved in-app call reloadConfiguration() themselves.
//

import Foundation
import Combine

class MDMConfigurationManager: ObservableObject {
    static let shared = MDMConfigurationManager()

    @Published private(set) var configuration: MDMConfiguration

    /// Short names of the managed domains that were actually delivered
    /// (e.g. ["core", "ui"]). Empty when running on defaults.
    @Published private(set) var loadedDomains: [String] = []

    /// Per-domain-aware summary: "mdm(core,…)" when at least one managed
    /// domain was delivered, "defaults" otherwise.
    @Published private(set) var configurationSource: String = "defaults"

    /// Whether the required connection settings are present (core
    /// serverURL + masterClientID non-empty AND the master client secret in
    /// the Keychain).
    var isConfigured: Bool { configuration.isConfigured }

    /// True when the profile names a Jamf Pro server and client but no master
    /// client secret has been entered yet — the first-run onboarding trigger.
    var needsCredentialOnboarding: Bool {
        guard !configuration.jamfURL.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let backend = configuration.effectiveAPIBackend
        // A required secret is "missing" only when the profile names the
        // identity it pairs with — otherwise there is nothing to ask for.
        let platformSecretMissing = backend.needsPlatformIntegration
            && configuration.platformAPI != nil && !configuration.isPlatformAPIReady
        // The provisioning ("master") secret is only needed when FleetHub
        // creates each operator's API client itself.
        let masterSecretMissing = backend.needsPerUserClients
            && configuration.effectiveAutoCreateUserApiClient
            && !configuration.masterClientID.trimmingCharacters(in: .whitespaces).isEmpty
            && configuration.masterClientSecret.trimmingCharacters(in: .whitespaces).isEmpty
        return platformSecretMissing || masterSecretMissing || needsOwnAPIClient
    }

    /// True when automatic client creation is off and this person has not
    /// yet entered their own pre-created Jamf API client on this Mac.
    var needsOwnAPIClient: Bool {
        configuration.effectiveAPIBackend.needsPerUserClients
            && !configuration.effectiveAutoCreateUserApiClient
            && KeychainManager.shared.loadJamfCredentials() == nil
    }

    /// Why the person is being asked for their API client again, when the
    /// stored one stopped working. Shown on the setup screen.
    @Published var ownAPIClientNotice: String?

    private init() {
        let result = Self.loadConfiguration()
        self.configuration = result.configuration
        self.loadedDomains = result.loadedDomains
        self.configurationSource = result.source
        observeCredentialImports()
    }

    // MARK: - Reload Configuration

    /// Re-reads every managed domain and the Keychain secrets. Call after a
    /// secret is saved in-app so the composed configuration (and everything
    /// reading it) sees the new value, and drop any cached bearer tokens.
    func reloadConfiguration() {
        let result = Self.loadConfiguration()
        self.configuration = result.configuration
        self.loadedDomains = result.loadedDomains
        self.configurationSource = result.source
        JamfTokenProvider.invalidateAll()
    }

    /// Reloads when the credential import command (run by a Jamf policy in
    /// a separate process) stores a new secret, so a running app picks it
    /// up without a relaunch.
    private func observeCredentialImports() {
        DistributedNotificationCenter.default().addObserver(
            forName: CredentialImportNotification.name, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadConfiguration()
        }
    }

    #if DEBUG
    /// Demo mode only (see Data/DemoMode.swift): recompose the configuration
    /// with sample `features`, leaving every other domain as delivered.
    func applyDemoFeatures(_ features: FeaturesConfiguration) {
        configuration = MDMConfiguration(
            core: ManagedDomainLoader.loadCore(),
            secrets: SecretStore.shared.snapshot(),
            access: ManagedDomainLoader.loadAccess(),
            features: features,
            ui: ManagedDomainLoader.loadUI()
        )
    }
    #endif

    // MARK: - Load Configuration (uniform 4-domain path + Keychain)

    private static func loadConfiguration()
        -> (configuration: MDMConfiguration, loadedDomains: [String], source: String)
    {
        let core = ManagedDomainLoader.loadCore()
        let access = ManagedDomainLoader.loadAccess()
        let features = ManagedDomainLoader.loadFeatures()
        let ui = ManagedDomainLoader.loadUI()
        // Secrets are resolved against the client IDs the profile names, so
        // a secret imported for a specific client (see CredentialImporter)
        // is used exactly while the profile names that client.
        let secrets = SecretStore.shared.snapshot(
            masterClientID: core?.jamfPro?.masterClientID,
            platformClientID: core?.platformAPI?.clientID,
            abmKeyID: core?.appleBusinessManager?.keyID,
            entraClientID: core?.entra?.clientID
        )

        var loaded: [String] = []
        if core != nil { loaded.append("core") }
        if access != nil { loaded.append("access") }
        if features != nil { loaded.append("features") }
        if ui != nil { loaded.append("ui") }

        let configuration = MDMConfiguration(
            core: core,
            secrets: secrets,
            access: access,
            features: features,
            ui: ui
        )

        guard !loaded.isEmpty else {
            print("⚠️ No managed configuration domain delivered — using built-in defaults")
            return (configuration, [], "defaults")
        }

        let source = "mdm(\(loaded.joined(separator: ",")))"
        print("✅ Loaded configuration from \(source); secrets present: \(secrets.presentSecrets.map(\.rawValue).sorted().joined(separator: ","))")
        logValidity(configuration, core: core, secrets: secrets)
        return (configuration, loaded, source)
    }

    /// Logs exactly which required domain/keys or secrets are missing when
    /// the composed configuration is not usable (partial delivery must be
    /// visible, never a silent placeholder fallback).
    private static func logValidity(
        _ configuration: MDMConfiguration,
        core: CoreConfiguration?,
        secrets: ManagedSecrets
    ) {
        guard !configuration.isConfigured else { return }

        var missing: [String] = []
        if core == nil {
            missing.append("core domain (\(CoreConfiguration.domain)) absent")
        } else {
            if (core?.jamfPro?.serverURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                missing.append("core: jamfPro.serverURL")
            }
            if configuration.effectiveAutoCreateUserApiClient,
               (core?.jamfPro?.masterClientID ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                missing.append("core: jamfPro.masterClientID")
            }
        }
        if configuration.effectiveAutoCreateUserApiClient,
           !secrets.presentSecrets.contains(.jamfMasterClientSecret) {
            missing.append("Keychain: Jamf Pro master client secret (enter it in Settings → Credentials, or deliver it with the credential import policy)")
        }

        print("⚠️ Configuration incomplete — missing: \(missing.joined(separator: "; "))")
    }

    // MARK: - Helper Methods

    /// The sidebar label/icon overrides this Mac delivers. UNORDERED with
    /// respect to display: row order comes from the signed-in user's role
    /// `modules` (access domain) and is resolved by SidebarView, not here.
    /// Presence is a role grant now — these entries are cosmetic overrides,
    /// so every delivered entry is returned.
    func getEnabledSidebarItems() -> [MDMConfiguration.SidebarItemConfig] {
        return configuration.sidebarItems
    }

    // MARK: - Debug

    func printDebugInfo() {
        print("=== MDMConfigurationManager Debug ===")
        print("Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")")
        print("Configuration Source: \(configurationSource)")
        print("Loaded Domains: \(loadedDomains.isEmpty ? "none" : loadedDomains.joined(separator: ","))")
        print("Jamf URL: \(configuration.jamfURL)")
        print("Client ID: \(String(configuration.masterClientID.prefix(12)))...")
        print("Has Secret: \(!configuration.masterClientSecret.isEmpty)")
        print("Is Configured: \(configuration.isConfigured)")
        print("ABM Configured: \(configuration.isABMConfigured)")
        print("=====================================")
    }
}
