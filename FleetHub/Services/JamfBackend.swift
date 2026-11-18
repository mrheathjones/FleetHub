//
//  JamfBackend.swift
//  FleetHub
//
//  Which API the app talks to, and the one place a request is adapted to it.
//
//  FleetHub can reach Jamf two ways, chosen by the Core profile's
//  `apiBackend` key:
//
//    • jamfPro  (default) — the Jamf Pro API on the tenant's own URL, with
//      the signed-in operator's personal API client.
//    • platform — the Jamf Platform API gateway
//      (`https://{region}.api.jamfcloud.com`), which proxies the Jamf Pro
//      API under `/pro` and the Classic API under `/proclassic`, with a
//      Platform integration credential created in Jamf Account.
//    • hybrid — both: READS (inventory, search, reports) go through the
//      gateway as the Platform integration; ACTIONS and anything gated or
//      sensitive (MDM commands, wipe, LAPS password, FileVault key, Move to
//      Site, PreStage, Cleanup, DDM status) stay on the Jamf Pro API as the
//      operator's own client, so Jamf's audit still names the person. The
//      split is decided per call by its `CredentialScope` — see
//      `JamfAPIBackend.usesPlatform(for:)`.
//
//  Call sites are written once, against Jamf Pro API paths
//  (`{jamfURL}/api/v2/...`). `JamfTransport` rewrites those requests for the
//  gateway when the Platform backend is selected, so every service follows
//  the choice without knowing about it. Requests to any other host (Entra,
//  Apple Business Manager, Jamf Protect) pass through untouched.
//
//  Path mapping (verified against developer.jamf.com/platform-api, 2026-11):
//
//    {jamfURL}/api/v{n}/…            →  {gateway}/pro/v{n}/…
//    {jamfURL}/JSSResource/…         →  {gateway}/proclassic/…
//    /api/v1|v3/computers-inventory… →  /pro/v4/computers-inventory…
//        (v3 is deprecated on the gateway; v4 is current)
//
//  NOT available on the gateway, so never rewritten — they throw instead:
//    /api/v1/oauth/token, /api/v1/auth/…   (the gateway issues its own token)
//    /api/v1/api-integrations, /api/v1/api-roles
//        (per-user API clients do not exist on the Platform API)
//
//  Tokens are never logged.
//

import Foundation

// MARK: - Backend choice

enum JamfAPIBackend: String, Codable {
    case jamfPro
    case platform
    case hybrid

    /// Whether a call in `scope` is served by the Platform integration.
    ///
    /// On `hybrid` only the plain read scopes are: fleet inventory, device
    /// search/detail and reports. Everything that changes a device, deletes
    /// a record or discloses a secret stays per-user. The list is an
    /// allow-list on purpose — a NEW scope is per-user until someone decides
    /// otherwise.
    func usesPlatform(for scope: CredentialScope) -> Bool {
        switch self {
        case .jamfPro: return false
        case .platform: return true
        case .hybrid:
            switch scope {
            case .inventory, .deviceSearch, .reports:
                return true
            case .mdmCommands, .returnToService, .sensitiveReads, .moveToSite,
                 .prestage, .cleanup, .declarativeStatus:
                return false
            }
        }
    }

    /// True when a Platform integration is part of this backend at all.
    var needsPlatformIntegration: Bool { self != .jamfPro }
    /// True when operators have their own Jamf Pro API clients (and the
    /// master client that provisions them is therefore required).
    var needsPerUserClients: Bool { self != .platform }

    /// Tolerant parse of the profile string; anything unrecognized is the
    /// default Jamf Pro API.
    static func parse(_ raw: String?) -> JamfAPIBackend {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "platform", "platformapi", "platform-api": return .platform
        case "hybrid": return .hybrid
        default: return .jamfPro
        }
    }
}

/// The non-secret identity of a Jamf Platform API integration. The client
/// secret is never delivered by a profile: it is entered in Settings →
/// Credentials and kept in the Keychain (`SecretStore`).
struct PlatformAPIConnection: Codable, Equatable {
    /// Gateway region: `us`, `eu` or `apac`. Tokens are region-locked.
    let region: String
    let clientID: String
    /// Jamf Pro tenant UUID — sent as `X-Tenant-Id` on `/pro` and
    /// `/proclassic` requests. May be empty when only platform services
    /// (Compliance Benchmarks, declaration reports) are used.
    let tenantID: String
    /// Platform environment UUID — sent as `X-Environment-Id` on platform
    /// services. May be empty when only the Jamf Pro proxy is used.
    let environmentID: String
    /// Jamf Protect tenant UUID — sent as `X-Tenant-Id` on `/protect`
    /// requests. A tenant ID names ONE product instance, so the Jamf Pro
    /// `tenantID` above is never sent to Protect. May be empty when Protect
    /// is not used through the gateway.
    var protectTenantID: String = ""

    static let validRegions: Set<String> = ["us", "eu", "apac"]

    var gatewayBaseURL: String { "https://\(region).api.jamfcloud.com" }
    var gatewayHost: String { "\(region).api.jamfcloud.com" }

    /// Usable for the Jamf Pro proxy: needs the tenant to address.
    var canProxyJamfPro: Bool { !tenantID.isEmpty || !environmentID.isEmpty }
    /// Usable for platform services (Compliance Benchmarks, DDM reports).
    var canReachPlatformServices: Bool { !environmentID.isEmpty }
    /// Usable for Jamf Protect: its own tenant, or the environment that
    /// contains it. The Jamf Pro tenant ID does not count.
    var canReachProtect: Bool { !protectTenantID.isEmpty || !environmentID.isEmpty }
}

// MARK: - Errors

enum JamfTransportError: LocalizedError {
    case notAvailableOnPlatform(String)
    case platformNotConfigured
    case platformAuthenticationFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notAvailableOnPlatform(let what):
            return "\(what) is not available through the Jamf Platform API."
        case .platformNotConfigured:
            return "The Jamf Platform API isn't configured on this Mac. The region, client ID and tenant or environment ID come from the configuration profile; the client secret is entered in Settings → Credentials."
        case .platformAuthenticationFailed(let code, let message):
            return "The Jamf Platform API rejected the integration credential (\(code)): \(message)"
        }
    }
}

// MARK: - Platform token

/// Shared, cached source of a Jamf Platform API bearer token, minted from
/// the integration's client ID (Core profile) and secret (Keychain).
///
/// Platform tokens last 15 minutes and cannot be refreshed, so a new one is
/// requested with the same credentials shortly before expiry.
final class JamfPlatformSession {
    static let shared = JamfPlatformSession()
    private init() {}

    private let lock = NSLock()
    private var cachedToken: String?
    private var expiration: Date?
    private var mintedFor: String?
    /// The current token and the one before it. `JamfTransport` uses this to
    /// tell a request built with the Platform token from one built with a
    /// per-user token (hybrid backend); keeping the previous one covers a
    /// request already in hand when the token rolled over.
    private var recentTokens: [String] = []

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cachedToken = nil
        expiration = nil
        mintedFor = nil
    }

    /// True when `token` was issued to the Platform integration by this
    /// session. Compared in memory only; never logged.
    func issued(_ token: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recentTokens.contains(token)
    }

    private func cachedValidToken(for identity: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let token = cachedToken, let exp = expiration, mintedFor == identity,
           exp > Date().addingTimeInterval(60) {
            return token
        }
        return nil
    }

    private func store(_ token: String, expiresIn: Int, identity: String) {
        lock.lock(); defer { lock.unlock() }
        cachedToken = token
        expiration = Date().addingTimeInterval(TimeInterval(expiresIn))
        mintedFor = identity
        recentTokens = Array(([token] + recentTokens).prefix(2))
    }

    func bearerToken() async throws -> String {
        #if DEBUG
        // Demo mode never talks to a real tenant (see Data/DemoMode.swift).
        if ProcessInfo.processInfo.arguments.contains("-FleetHubDemo") {
            throw NSError(domain: "FleetHubDemo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Demo mode: this needs a live connection, which is turned off."
            ])
        }
        #endif
        let config = MDMConfigurationManager.shared.configuration
        let secret = (config.platformClientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let platform = config.platformAPI, !platform.clientID.isEmpty, !secret.isEmpty else {
            throw JamfTransportError.platformNotConfigured
        }
        // Keyed by region + client so a profile change never serves a token
        // minted for the previous integration (tokens are region-locked).
        let identity = "\(platform.region)|\(platform.clientID)"
        if let token = cachedValidToken(for: identity) { return token }

        guard let url = URL(string: "\(platform.gatewayBaseURL)/auth/token") else {
            throw JamfTransportError.platformNotConfigured
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "grant_type=client_credentials&client_id=\(JamfMasterSession.formEncode(platform.clientID))&client_secret=\(JamfMasterSession.formEncode(secret))"
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JamfTransportError.platformAuthenticationFailed(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            // A failed token body carries no token and is safe to surface;
            // a successful one is never logged.
            throw JamfTransportError.platformAuthenticationFailed(
                http.statusCode,
                JamfErrorFormatter.message(status: http.statusCode, body: data, fallbackAction: "authenticate the Platform API integration")
            )
        }

        struct TokenResponse: Decodable { let access_token: String; let expires_in: Int }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        store(decoded.access_token, expiresIn: decoded.expires_in, identity: identity)
        return decoded.access_token
    }
}

// MARK: - Transport

/// The single send path for Jamf requests. Use `JamfTransport.data(for:)`
/// wherever a request is built against the Jamf Pro URL.
enum JamfTransport {

    /// Sends `request`, first adapting it to the selected backend.
    static func data(for request: URLRequest, session: URLSession = .shared) async throws -> (Data, URLResponse) {
        try await session.data(for: try prepare(request))
    }

    /// Returns `request` unchanged on the Jamf Pro backend or for any host
    /// other than the configured Jamf Pro server. On the Platform backend,
    /// rewrites a Jamf Pro / Classic API request to its gateway equivalent
    /// and adds the scope header.
    ///
    /// On the hybrid backend the request's own bearer token decides: one
    /// issued to the Platform integration goes to the gateway, a per-user
    /// token goes to Jamf Pro untouched. The token was chosen by
    /// `JamfTokenProvider.token(for:)` from the call's scope, so the route
    /// always matches the credential — a per-user token is never sent to
    /// the gateway and the Platform token is never sent to Jamf Pro.
    static func prepare(_ request: URLRequest) throws -> URLRequest {
        let config = MDMConfigurationManager.shared.configuration
        switch config.effectiveAPIBackend {
        case .jamfPro:
            return request
        case .platform:
            break
        case .hybrid:
            let bearer = request.value(forHTTPHeaderField: "Authorization")?
                .replacingOccurrences(of: "Bearer ", with: "") ?? ""
            guard !bearer.isEmpty, JamfPlatformSession.shared.issued(bearer) else { return request }
        }
        guard let url = request.url,
              let jamfHost = URL(string: config.jamfURL)?.host,
              url.host?.caseInsensitiveCompare(jamfHost) == .orderedSame else {
            return request
        }
        guard let platform = config.platformAPI, platform.canProxyJamfPro else {
            throw JamfTransportError.platformNotConfigured
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let gatewayPath = try gatewayPath(for: components.percentEncodedPath) else {
            return request
        }

        components.scheme = "https"
        components.host = platform.gatewayHost
        components.port = nil
        components.percentEncodedPath = gatewayPath
        // The gateway serves computers-inventory as v4, which dropped two
        // sections v1 accepts. Asking for either makes Jamf reject the WHOLE
        // request (400, "Invalid value of request parameter: section"), so
        // they are removed here; their data simply is not shown.
        if gatewayPath.contains("/v4/computers-inventory"), let items = components.percentEncodedQueryItems {
            let unsupported: Set<String> = ["PLUGINS", "FONTS"]
            components.percentEncodedQueryItems = items.filter {
                !($0.name == "section" && unsupported.contains(($0.value ?? "").uppercased()))
            }
        }
        guard let rewritten = components.url else { return request }

        var adapted = request
        adapted.url = rewritten
        // Exactly one scope header per request (gateway rule).
        if !platform.tenantID.isEmpty {
            adapted.setValue(platform.tenantID, forHTTPHeaderField: "X-Tenant-Id")
        } else {
            adapted.setValue(platform.environmentID, forHTTPHeaderField: "X-Environment-Id")
        }
        return adapted
    }

    /// The gateway path for a Jamf Pro / Classic API path, or nil when the
    /// path is neither (left untouched). Throws for endpoints the gateway
    /// does not offer.
    static func gatewayPath(for path: String) throws -> String? {
        if path.hasPrefix("/JSSResource/") {
            return "/proclassic/" + path.dropFirst("/JSSResource/".count)
        }
        guard path.hasPrefix("/api/") else { return nil }
        var rest = String(path.dropFirst("/api".count))   // "/v2/mdm/commands"

        let unavailable: [(prefix: String, name: String)] = [
            ("/v1/oauth/token", "Jamf Pro API token minting"),
            ("/oauth/token", "Jamf Pro API token minting"),
            ("/v1/auth/", "Jamf Pro API token management"),
            ("/v1/api-integrations", "Managing Jamf Pro API clients"),
            ("/v1/api-roles", "Reading Jamf Pro API roles"),
            ("/v1/api-role-privileges", "Reading Jamf Pro API role privileges")
        ]
        if let hit = unavailable.first(where: { rest.hasPrefix($0.prefix) }) {
            throw JamfTransportError.notAvailableOnPlatform(hit.name)
        }

        // Computer inventory: the gateway's current version is v4 (v3 is
        // deprecated there, v1 is not offered). `-detail` shares the prefix,
        // so one replacement covers both.
        for old in ["/v1/computers-inventory", "/v3/computers-inventory"] where rest.hasPrefix(old) {
            rest = "/v4/computers-inventory" + rest.dropFirst(old.count)
            break
        }
        return "/pro" + rest
    }
}
