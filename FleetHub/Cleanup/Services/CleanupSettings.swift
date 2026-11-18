//
//  CleanupSettings.swift
//  FleetHub
//
//  Configuration provider for the Cleanup feature. The Jamf Pro server
//  comes from the core profile and every call runs as the signed-in
//  operator's own API client; the cleanup-specific tunables (stale
//  threshold, Jamf Protect identity) are read from the MDM configuration as
//  defaults, overridable in-app via UserDefaults, with the Protect password
//  kept ONLY in the Keychain.
//

import Foundation

@MainActor
final class CleanupSettings {
    private let defaults = UserDefaults.standard

    // UserDefaults keys for in-app overrides.
    enum Key {
        static let staleDays = "Cleanup.StaleDays"
        static let protectEnabled = "Cleanup.ProtectEnabled"
        static let protectURL = "Cleanup.ProtectURL"
        static let protectClientID = "Cleanup.ProtectClientID"
        static let protectAutoCleanup = "Cleanup.ProtectAutoCleanup"
    }

    /// Keychain account for the Jamf Protect API password (owned by SecretStore).
    static let protectPasswordKeychainKey = FleetHubSecret.jamfProtectPassword.keychainKey

    private var mdm: MDMConfiguration { MDMConfigurationManager.shared.configuration }

    // MARK: - Jamf Pro (server from the profile; calls run as the operator)

    var normalizedJamfURL: URL? { Self.normalize(mdm.jamfURL) }
    var pageSize: Int { 100 }

    /// Cleanup needs only a Jamf Pro server to talk to. Every call it makes
    /// authenticates as the signed-in operator's own API client
    /// (`JamfTokenProvider.token(for: .cleanup)`), which fails closed when
    /// that client is missing — the master client is never used here.
    var isConfigured: Bool {
        !mdm.jamfURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Stale threshold (MDM default, user-overridable)

    var staleDays: Int {
        get { defaults.object(forKey: Key.staleDays) as? Int ?? mdm.cleanupStaleDays }
        set { defaults.set(newValue, forKey: Key.staleDays) }
    }

    // MARK: - Default action targets (from MDM)

    var defaultStaticGroupID: Int { Int(mdm.cleanupDefaultStaticGroupID ?? "") ?? 0 }
    var defaultSiteID: Int { Int(mdm.cleanupDefaultSiteID ?? "") ?? -1 }

    // MARK: - Jamf Protect (MDM identity defaults, user-overridable; password ONLY in Keychain)

    /// True when the Core profile delivers a `jamfProtect` block. The
    /// organization then decides whether Protect is on and where it lives:
    /// the profile's values are used as they are and cannot be changed in
    /// the app. Without the block, these are the user's own choices.
    var protectIsManaged: Bool {
        CFPreferencesCopyAppValue("jamfProtect" as CFString, "com.herojoneslabs.fleethub.core" as CFString) != nil
    }

    var protectEnabled: Bool {
        get { protectIsManaged ? mdm.protectEnabled : (defaults.object(forKey: Key.protectEnabled) as? Bool ?? mdm.protectEnabled) }
        set { if !protectIsManaged { defaults.set(newValue, forKey: Key.protectEnabled) } }
    }

    var protectURL: String {
        get { protectIsManaged ? (mdm.protectURL ?? "") : (defaults.string(forKey: Key.protectURL) ?? mdm.protectURL ?? "") }
        set { if !protectIsManaged { defaults.set(newValue, forKey: Key.protectURL) } }
    }

    var protectClientID: String {
        get { protectIsManaged ? (mdm.protectClientID ?? "") : (defaults.string(forKey: Key.protectClientID) ?? mdm.protectClientID ?? "") }
        set { if !protectIsManaged { defaults.set(newValue, forKey: Key.protectClientID) } }
    }

    /// The Protect API password from the Keychain ("" when none is saved).
    var protectClientPassword: String {
        SecretStore.shared.value(.jamfProtectPassword) ?? ""
    }

    /// Stores (or, for a blank value, removes) the Protect API password.
    /// Returns the Keychain status so the caller can show a failed write
    /// instead of pretending it saved.
    @discardableResult
    func setProtectPassword(_ password: String) -> OSStatus {
        let status = SecretStore.shared.set(.jamfProtectPassword, to: password)
        if status == errSecSuccess {
            MDMConfigurationManager.shared.reloadConfiguration()
        }
        return status
    }

    /// When on, deleting a Jamf Pro record also deletes the matching Jamf
    /// Protect record (by serial).
    var protectAutoCleanup: Bool {
        get { defaults.bool(forKey: Key.protectAutoCleanup) }
        set { defaults.set(newValue, forKey: Key.protectAutoCleanup) }
    }

    var normalizedProtectURL: URL? { Self.normalize(protectURL) }

    /// True when Protect requests go through the Jamf Platform API
    /// integration: one is configured (identity in the Core profile, secret
    /// in the Keychain) and it can address the PROTECT tenant (its own
    /// tenant ID, or the environment ID). Preferred whenever available, on
    /// every API backend.
    var protectUsesPlatform: Bool {
        mdm.isPlatformAPIReady && (mdm.platformAPI?.canReachProtect ?? false)
    }

    /// True when the Protect tenant's own API client is fully entered.
    private var isDirectProtectConfigured: Bool {
        !protectURL.isEmpty && !protectClientID.isEmpty && !protectClientPassword.isEmpty
    }

    var isProtectConfigured: Bool {
        protectEnabled && (protectUsesPlatform || isDirectProtectConfigured)
    }

    /// The client for the route in use, or nil when Protect is off or not
    /// set up. The Platform route wins when both are available.
    func makeProtectClient() -> JamfProtectClient? {
        guard protectEnabled else { return nil }
        if protectUsesPlatform, let platform = mdm.platformAPI {
            return JamfProtectClient(route: .platform(platform))
        }
        guard isDirectProtectConfigured, let url = normalizedProtectURL else { return nil }
        return JamfProtectClient(baseURL: url, clientID: protectClientID, password: protectClientPassword)
    }

    // MARK: - Helpers

    /// URL normalized: scheme added if missing, trailing slash stripped.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

// MARK: - Connection tests

/// Standalone Jamf Pro / Jamf Protect connection tests. Builds throwaway
/// clients from a `CleanupSettings`, so any screen (the main Settings view or
/// the Cleanup view model) can run a test without owning a full view model.
enum CleanupConnectionTester {
    @MainActor
    static func testJamf(_ settings: CleanupSettings) async -> Result<String, Error> {
        do {
            guard settings.isConfigured, let url = settings.normalizedJamfURL else {
                throw JamfCleanupError.notConfigured
            }
            let client = JamfCleanupClient(
                baseURL: url,
                tokenProvider: { try await JamfTokenProvider.token(for: .cleanup) },
                pageSize: settings.pageSize
            )
            let version = try await client.testConnection()
            await client.invalidateToken()
            return .success("Connected — Jamf Pro \(version)")
        } catch {
            return .failure(error)
        }
    }

    @MainActor
    static func testProtect(_ settings: CleanupSettings) async -> Result<String, Error> {
        do {
            guard let client = settings.makeProtectClient() else {
                throw JamfCleanupError.protectNotConfigured
            }
            try await client.testConnection()
            await client.invalidate()
            return .success(settings.protectUsesPlatform
                ? "Connected to Jamf Protect through the Platform API"
                : "Connected to Jamf Protect")
        } catch {
            return .failure(error)
        }
    }
}
