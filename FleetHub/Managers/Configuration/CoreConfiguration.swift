//
//  CoreConfiguration.swift
//  FleetHub
//
//  FleetHub — Core (connection & integrations tier of the 5-domain
//  config split). Delivered via Jamf Pro > Configuration Profiles >
//  Application & Custom Settings as its own profile, scoped to ALL managed
//  Macs running FleetHub.
//
//  Preference Domain MUST match the domain FleetHub reads:
//      com.herojoneslabs.fleethub.core
//  (Matches `CoreConfiguration.domain` below, the
//   schemas/FleetHub_Core_SCHEMA.json `$id`, and the domain table in
//   docs/Configuration.md — keep all three in sync.)
//
//  Decoded by ManagedDomainLoader: the domain's top-level keys are read out
//  of UserDefaults(suiteName: CoreConfiguration.domain) into a [String: Any],
//  then run through PropertyListSerialization → PropertyListDecoder. Every
//  stored property is optional so a missing key — or an entirely absent
//  profile — never fails the domain decode. Defaults live in the computed
//  `effective*` accessors, never in decode.
//
//  This domain carries NO secrets, and neither does any other profile: the
//  Jamf Pro client secret, ABM private key, Jamf Protect password and the
//  Entra client secret / certificate are entered in the app (first-run
//  onboarding or Settings → Credentials) and stored in the Keychain
//  (SecretStore). Profiles deliver only the non-secret identities that pair
//  with those secrets (server URL, client IDs, key IDs, tenant ID).
//

import Foundation

/// The `authentication` dictionary: sign-in behavior preferences.
///
/// Lives in the CORE domain — this is sign-in policy, so it belongs beside
/// the `signIn` block rather than with branding in ui, where it used to sit.
/// The distinct Jamf call categories. Every one authenticates as the
/// signed-in operator's own API client (see `JamfTokenProvider`); the scope
/// names what a call is for.
enum CredentialScope: String {
    case mdmCommands        // lock, restart, shutdown, wipe, unlock, blank push, etc.
    case returnToService    // erase + Jamf record delete legs
    case sensitiveReads     // LAPS local-admin password + FileVault recovery key
    case moveToSite
    case prestage           // PreStage register/assign + Inventory Preload
    case cleanup            // stale/protect listing + deletes
    case deviceSearch
    case inventory          // dashboard counts + health metrics
    case reports
    case declarativeStatus  // a device's DDM status items
}

struct AuthenticationSettings: Codable {
    var requireBiometric: Bool?
    var allowBiometricSetup: Bool?
    var sessionTimeout: Int?
    var allowRememberMe: Bool?
    var autoCreateUserApiClient: Bool?

    var effectiveRequireBiometric: Bool { requireBiometric ?? false }

    var effectiveAllowBiometricSetup: Bool { allowBiometricSetup ?? true }

    /// Idle session timeout in minutes; 0 = no timeout. Negative values from
    /// a malformed profile are clamped to 0 (disabled) rather than trusted.
    var effectiveSessionTimeoutMinutes: Int { max(0, sessionTimeout ?? 0) }

    var effectiveAllowRememberMe: Bool { allowRememberMe ?? true }

    /// Whether the MASTER client may create a per-user Jamf API client (and
    /// assign it `jamfPro.requiredRoleName`) when the signed-in operator does
    /// not have one yet. Default **false**: holding the master client's
    /// secret on every Mac lets whoever extracts it create an API client
    /// with any API role, so a deployment has to opt in. Off, the app never
    /// creates API clients and needs no master client: each operator enters
    /// a client a Jamf administrator created for them, and without one
    /// every call fails closed. On, creating that client is the only thing
    /// the master client is used for; everything the app does still runs as
    /// the operator's own client.
    ///
    /// Newly created clients are named `<UPN> (<clientId>)` so the client id
    /// Jamf records in its audit log maps back to the person who ran the
    /// command.
    var effectiveAutoCreateUserApiClient: Bool { autoCreateUserApiClient ?? false }
}

/// Managed connection & integration settings for FleetHub, delivered
/// by the `com.herojoneslabs.fleethub.core` configuration profile.
///
/// Non-secret tier: Jamf Pro server + master client identity, optional Apple
/// Business Manager, Jamf Protect and Microsoft Entra identities, and local
/// administration settings. The secrets that pair with these identities are
/// entered in-app and live only in the Keychain (`SecretStore`).
struct CoreConfiguration: Codable {

    /// The managed-preference domain this model is decoded from.
    /// Sync points: schemas/FleetHub_Core_SCHEMA.json `$id` and
    /// docs/Configuration.md.
    static let domain = "com.herojoneslabs.fleethub.core"

    /// Informational schema version (loader logs it, nothing else reads it).
    var configurationVersion: String?

    /// Jamf Pro server connection and master API client identity. Required
    /// for the app to be considered configured — validity is enforced at the
    /// aggregation layer (`MDMConfigurationManager.isConfigured`), never by
    /// decode failure.
    var jamfPro: JamfProSettings?

    /// Which API the app talks to: `jamfPro` (default) or `platform` (the
    /// Jamf Platform API gateway). See Services/JamfBackend.swift.
    var apiBackend: String?

    /// Optional Jamf Platform API integration (identity only; the client
    /// secret is entered in-app and kept in the Keychain). Needed for the
    /// `platform` backend and for Compliance Benchmarks on either backend.
    var platformAPI: PlatformAPISettings?

    /// Optional Apple Business Manager API connection (identity only; the
    /// PEM private key is entered in-app and kept in the Keychain).
    var appleBusinessManager: ABMSettings?

    /// Optional Jamf Protect tenant connection (identity only; the API
    /// password is entered in-app and kept in the Keychain).
    var jamfProtect: JamfProtectSettings?

    /// Optional Microsoft Entra app-only identity (tenant + client ID) for
    /// Return to Service cleanup. Its client secret or certificate is entered
    /// in-app and kept in the Keychain; no Entra secret lives in any profile.
    var entra: EntraSettings?

    /// Optional interactive sign-in configuration (`signIn` block): how
    /// users sign into FleetHub itself — the built-in email flow (default)
    /// or Microsoft Entra ID via a separate PUBLIC-client app registration.
    /// Distinct from `entra` above, which carries app-only cleanup
    /// credentials. An absent block keeps the email flow unchanged.
    var signIn: SignInSettings?

    /// Sign-in behavior preferences: biometric requirement, idle session
    /// timeout, Remember Me. Lives here rather than in the ui domain because
    /// it is sign-in POLICY — it belongs beside the `signIn` block that
    /// decides how sign-in happens at all, not with branding.
    var authentication: AuthenticationSettings?

    // MARK: - Effective accessors (defaults live here, never in decode)

    /// Schema version with the documented default applied.
    var effectiveConfigurationVersion: String {
        let version = configurationVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "2.0" : version
    }

    /// The core-domain half of the app-level configured check: serverURL and
    /// masterClientID both delivered non-empty. The aggregation layer's
    /// `isConfigured` combines this with the credentials domain's
    /// `jamfProClientSecret` being non-empty.
    var isJamfProConnectionConfigured: Bool {
        let url = jamfPro?.serverURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clientID = jamfPro?.masterClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !url.isEmpty && !clientID.isEmpty
    }

    // MARK: - Jamf Pro

    /// `jamfPro` block: server connection and master API client identity.
    /// The paired OAuth client secret is `jamfProClientSecret` in the
    /// credentials domain — deliberately NOT part of this model.
    /// `platformAPI` block: the NON-SECRET identity of a Jamf Platform API
    /// integration created in Jamf Account.
    struct PlatformAPISettings: Codable {
        /// Gateway region: `us`, `eu` or `apac`.
        var region: String?
        /// The integration's client ID. Not secret.
        var clientID: String?
        /// Jamf Pro tenant UUID (Integration details in Jamf Account).
        var tenantID: String?
        /// Platform environment UUID (Integration details in Jamf Account).
        var environmentID: String?
        /// Jamf PROTECT tenant UUID (Integration details in Jamf Account).
        /// A tenant ID names one product instance, so this is a different
        /// value from `tenantID`, which is the Jamf Pro instance.
        var protectTenantID: String?

        /// The usable connection, or nil when the block is incomplete: an
        /// unknown region or a missing client ID yields nothing rather than
        /// a guess (tokens are region-locked, so a wrong default would only
        /// produce confusing 401s).
        var connection: PlatformAPIConnection? {
            let region = region?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let clientID = clientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard PlatformAPIConnection.validRegions.contains(region), !clientID.isEmpty else { return nil }
            return PlatformAPIConnection(
                region: region,
                clientID: clientID,
                tenantID: tenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                environmentID: environmentID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                protectTenantID: protectTenantID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }

    struct JamfProSettings: Codable {

        /// Full HTTPS base URL, no trailing slash
        /// (e.g. `https://yourorg.jamfcloud.com`). Required in the profile.
        var serverURL: String?

        /// OAuth `client_id` of the Jamf API Client used by FleetHub.
        /// Not secret. Required in the profile.
        var masterClientID: String?

        /// Name of the Jamf API Role used when provisioning per-user API
        /// clients. Load-bearing — provisioning targets this role name.
        var requiredRoleName: String?

        /// URLSession connection timeout in seconds.
        var connectionTimeout: Int?

        /// URLSession request timeout in seconds.
        var requestTimeout: Int?

        /// Lifetime in days for per-user Jamf API client credentials
        /// provisioned by the app (expiry forces re-provisioning).
        var userCredentialLifetimeDays: Int?

        /// Seconds to wait for a device to acknowledge an ERASE_DEVICE
        /// command. Governs EVERY erase (Erase Device and Return to
        /// Service) — the acknowledgment wait is mandatory by design, and
        /// no cleanup step runs without acknowledgment.
        var eraseAckTimeoutSeconds: Int?

        /// Seconds between acknowledgment polls while waiting for an erase
        /// (see `eraseAckTimeoutSeconds`).
        var eraseAckPollIntervalSeconds: Int?

        /// Required role name, trimmed. There is deliberately NO built-in
        /// default: the app invents no role names, so an absent key yields
        /// an empty string and per-user API client provisioning fails
        /// closed with a clear message until the profile delivers the real
        /// Jamf API Role name (the docs show it as `YOUR-API-ROLE`).
        var effectiveRequiredRoleName: String {
            requiredRoleName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        /// Connection timeout with the documented default applied.
        /// Clamped 5...600 s — a profile typo (0, negative, huge) must
        /// never brick every network call app-wide.
        var effectiveConnectionTimeout: Int { min(max(connectionTimeout ?? 30, 5), 600) }

        /// Request timeout with the documented default applied.
        /// Clamped 5...3600 s (see effectiveConnectionTimeout).
        var effectiveRequestTimeout: Int { min(max(requestTimeout ?? 60, 5), 3600) }

        /// Credential lifetime with the documented default applied
        /// (clamped to 1...365 days).
        var effectiveUserCredentialLifetimeDays: Int {
            min(max(userCredentialLifetimeDays ?? 90, 1), 365)
        }

        /// Erase-acknowledgment timeout with the documented default applied
        /// (clamped to 30...1800 s). Governs EVERY erase — Erase Device and
        /// Return to Service alike. The ack wait is mandatory by design:
        /// no cleanup step (Jamf record or Entra object deletion) runs
        /// without acknowledgment.
        var effectiveEraseAckTimeoutSeconds: Int {
            min(max(eraseAckTimeoutSeconds ?? 180, 30), 1800)
        }

        /// Erase-acknowledgment poll interval with the documented default
        /// applied (clamped to 5...120 s). Applies to every erase alongside
        /// `effectiveEraseAckTimeoutSeconds`.
        var effectiveEraseAckPollIntervalSeconds: Int {
            min(max(eraseAckPollIntervalSeconds ?? 15, 5), 120)
        }
    }

    // MARK: - Apple Business Manager

    /// `appleBusinessManager` block: ABM API client identity. The PEM
    /// private key is entered in-app (Keychain, `SecretStore`) — ABM is
    /// considered configured only when clientID, keyID, AND that key are all
    /// present (checked at the aggregation layer).
    struct ABMSettings: Codable {

        /// Whether the ABM integration is enabled.
        var enabled: Bool?

        /// ABM API client identifier. Not secret.
        var clientID: String?

        /// Key ID of the ABM API private key. Not secret.
        var keyID: String?

        /// Which Apple service hosts the org: "business" (Apple Business
        /// Manager) or "school" (Apple School Manager). Same API, same
        /// tokens — different host.
        var serviceType: String?

        /// Default filter state for the ABM Lookup tab — a STARTING POINT the
        /// operator can still change or clear, not an enforced lock.
        ///   • defaultMdmServerName: preselect the server filter by NAME (as
        ///     shown in ABM), resolved to its id once the server list loads.
        ///     No match (or absent) → "Any Server".
        ///   • defaultDeviceType: one of all|mac|iphone|ipad|appletv|watch|
        ///     vision; anything else → all (see ABMDeviceType.from).
        var defaultMdmServerName: String?
        var defaultDeviceType: String?

        /// Enabled flag — absent key means disabled.
        var effectiveEnabled: Bool { enabled ?? false }

        /// Trimmed default server name, nil when blank.
        var effectiveDefaultMdmServerName: String? {
            let name = defaultMdmServerName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (name?.isEmpty ?? true) ? nil : name
        }

        enum ServiceType: String {
            case business
            case school

            /// AxM API base URL for this service.
            var apiBaseURL: String {
                switch self {
                case .business: return "https://api-business.apple.com/v1"
                case .school: return "https://api-school.apple.com/v1"
                }
            }

            /// OAuth scope paired with the host — ASM tokens must be
            /// requested with school.api or the API rejects them.
            var oauthScope: String {
                switch self {
                case .business: return "business.api"
                case .school: return "school.api"
                }
            }
        }

        /// Fail-safe service resolution: missing/unrecognized → business.
        var effectiveServiceType: ServiceType {
            let raw = serviceType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return ServiceType(rawValue: raw) ?? .business
        }
    }

    // MARK: - Jamf Protect

    /// `jamfProtect` block: Protect tenant connection identity. The API
    /// password is entered in-app and kept in the Keychain (`SecretStore`);
    /// it is never delivered by a profile.
    struct JamfProtectSettings: Codable {

        /// Whether the Jamf Protect integration is enabled.
        var enabled: Bool?

        /// Full HTTPS tenant URL
        /// (e.g. `https://yourorg.protect.jamfcloud.com`).
        var url: String?

        /// Jamf Protect API client identifier. Not secret.
        var clientID: String?

        /// Enabled flag — absent key means disabled.
        var effectiveEnabled: Bool { enabled ?? false }
    }

    // MARK: - Microsoft Entra (app-only cleanup identity)

    /// `entra` block: the NON-SECRET identity of the Entra app registration
    /// used for Return to Service cleanup — tenant ID, client ID and Azure
    /// cloud. The matching client secret or certificate PEM is never
    /// delivered by a profile: it is entered in Settings → Credentials (or
    /// first-run onboarding) and stored in the Keychain (`SecretStore`).
    struct EntraSettings: Codable {

        /// Microsoft Entra tenant ID (GUID). Not secret.
        var tenantID: String?

        /// Entra app registration (client) ID (GUID). Not secret.
        var clientID: String?

        /// Azure cloud instance: "global" (default), "usgov" (Azure
        /// Government / GCC High), or "china" (Azure operated by 21Vianet).
        /// Selects the token authority and Graph API hosts.
        var cloudInstance: String?

        /// Trimmed tenant ID, nil when blank.
        var effectiveTenantID: String? { Self.trimmed(tenantID) }

        /// Trimmed client ID, nil when blank.
        var effectiveClientID: String? { Self.trimmed(clientID) }

        private static func trimmed(_ value: String?) -> String? {
            let t = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }

        enum CloudInstance: String {
            case global
            case usgov
            case china

            /// OAuth token authority host.
            var authorityHost: String {
                switch self {
                case .global: return "login.microsoftonline.com"
                case .usgov: return "login.microsoftonline.us"
                case .china: return "login.chinacloudapi.cn"
                }
            }

            /// Microsoft Graph API host (also used for the token scope).
            var graphHost: String {
                switch self {
                case .global: return "graph.microsoft.com"
                case .usgov: return "graph.microsoft.us"
                case .china: return "microsoftgraph.chinacloudapi.cn"
                }
            }

            /// Shared fail-safe resolution from a raw profile value:
            /// missing/unrecognized → global.
            static func resolve(_ raw: String?) -> CloudInstance {
                let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                return CloudInstance(rawValue: normalized) ?? .global
            }
        }

        /// Fail-safe cloud resolution: missing/unrecognized → global.
        var effectiveCloudInstance: CloudInstance {
            CloudInstance.resolve(cloudInstance)
        }
    }

    // MARK: - Interactive sign-in

    /// `signIn` block: how users sign INTO FleetHub itself. Distinct from the
    /// `entra` block above — that one names the app-only Graph identity
    /// for Return to Service cleanup; this one configures the INTERACTIVE
    /// user OAuth flow against a separate PUBLIC-client Entra app
    /// registration (which has no client secret, ever, by design).
    /// Absent block → the built-in email sign-in flow, unchanged.
    struct SignInSettings: Codable {

        /// Sign-in method: "email" (default) or "entra", matched
        /// case-insensitively. FAIL-CLOSED direction: when "entra" is
        /// selected but misconfigured (missing tenant/client id), the app
        /// shows a configuration-error state — it NEVER silently falls
        /// back to the weaker email flow.
        var method: String?

        /// Entra ID interactive sign-in settings; required in practice
        /// when `method == "entra"`.
        var entra: EntraSignInSettings?
    }

    /// `signIn.entra` block: PUBLIC-client Entra app registration for the
    /// interactive user sign-in flow. Carries NO secrets, ever — a public
    /// client has none. Capabilities are granted by matching the token's
    /// roles claim against the role names defined in the ACCESS domain's
    /// `roles` block (no role names live here); sign-in restriction should
    /// ALSO be enforced Entra-side ("Assignment required" on the enterprise
    /// application) — the client-side checks are a UX gate, not a security
    /// boundary on their own.
    struct EntraSignInSettings: Codable {

        /// Entra tenant id (GUID). Required for Entra sign-in.
        var tenantId: String?

        /// Application (client) id of the PUBLIC-client app registration.
        /// Not secret — and no secret is ever paired with it.
        var clientId: String?

        /// Azure cloud instance: "global" (default), "usgov", or "china".
        /// Reuses the cleanup pointer's `CloudInstance` host mapping.
        var cloudInstance: String?

        /// The redirect URI registered on the app registration, when it is
        /// not the default. It must match the registration character for
        /// character. A custom-scheme URI only (for example
        /// `myapp://callback`); anything else is ignored and the default is
        /// used.
        var redirectURI: String?

        /// The redirect URI used when the profile sets none.
        static let defaultRedirectURI = "fleethubauth://callback"

        /// The redirect URI to send: the profile's when it is a usable
        /// custom-scheme URI, otherwise the default. http and https are
        /// refused because a public client on a Mac cannot receive them.
        var effectiveRedirectURI: String {
            guard let configured = redirectURI?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !configured.isEmpty,
                  let scheme = URL(string: configured)?.scheme?.lowercased(),
                  scheme != "http", scheme != "https" else {
                return Self.defaultRedirectURI
            }
            return configured
        }

        /// Optional extra client-side check: Entra group OBJECT ids the
        /// user must be a member of (token groups claim). Empty/absent =
        /// no group check. Prefer app roles — the groups claim is subject
        /// to Entra's overage limit on large memberships.
        var allowedGroupIds: [String]?

        /// Fail-safe cloud resolution: missing/unrecognized → global.
        /// Reuses the cleanup pointer's `CloudInstance` mapping so both
        /// Entra features agree on hosts per cloud.
        var effectiveCloudInstance: EntraSettings.CloudInstance {
            EntraSettings.CloudInstance.resolve(cloudInstance)
        }

        /// Group-id allow-list; empty = no group check (default).
        var effectiveAllowedGroupIds: [String] {
            Self.normalizedList(allowedGroupIds, default: [])
        }

        /// Trims each entry and drops empties. nil (key absent) → default;
        /// a delivered array — even one that trims to empty — is honored.
        private static func normalizedList(_ values: [String]?, default defaults: [String]) -> [String] {
            guard let values else { return defaults }
            return values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

}
