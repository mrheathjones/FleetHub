//
//  JamfTokenProvider.swift
//  FleetHub
//
//  The single place a Jamf Pro bearer token is minted. Every service and view
//  that used to build its own `/api/v1/oauth/token` request now asks here:
//
//      let token = try await JamfTokenProvider.token(for: .inventory)
//
//  Every app function authenticates as the signed-in operator's own Jamf API
//  client: `token(for:)` is always served by `JamfUserSession` and is
//  fail-closed when that client is not provisioned. There is no routing and
//  no fallback to the master client.
//
//  The master client (ID from the core profile, secret from the Keychain via
//  `SecretStore`) exists for ONE job: provisioning the operator's per-user
//  API client at sign-in when it does not exist yet. `provisioningToken()`
//  is the only way to reach it.
//
//  Tokens are cached per session with a safety margin and never logged.
//

import Foundation

enum JamfMasterSessionError: LocalizedError {
    case notConfigured
    case invalidURL
    case authenticationFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Jamf Pro isn't configured on this Mac. The server URL and client ID come from the configuration profile; the client secret is entered in Settings → Credentials."
        case .invalidURL:
            return "Invalid Jamf Pro URL."
        case .authenticationFailed(let code, let message):
            return "Jamf Pro rejected the master API client (\(code)): \(message)"
        }
    }
}

/// Shared, cached source of a **master-client** Jamf bearer token. Used only
/// to provision per-user API clients — never for app functionality.
final class JamfMasterSession {
    static let shared = JamfMasterSession()
    private init() {}

    private let lock = NSLock()
    private var cachedToken: String?
    private var expiration: Date?
    private var mintedFor: String?

    private var configuration: MDMConfiguration { MDMConfigurationManager.shared.configuration }

    /// Drops the cached token — call when the secret or client ID changes
    /// (Settings save, profile reload) so the next call re-authenticates.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cachedToken = nil
        expiration = nil
        mintedFor = nil
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
    }

    /// Returns a cached, or freshly minted, master bearer token.
    func bearerToken() async throws -> String {
        #if DEBUG
        // Demo mode never talks to a real tenant (see Data/DemoMode.swift).
        if ProcessInfo.processInfo.arguments.contains("-FleetHubDemo") {
            throw NSError(domain: "FleetHubDemo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Demo mode: this needs a live connection, which is turned off."
            ])
        }
        #endif
        let config = configuration
        let jamfURL = config.jamfURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientID = config.masterClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = config.masterClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jamfURL.isEmpty, !clientID.isEmpty, !clientSecret.isEmpty else {
            throw JamfMasterSessionError.notConfigured
        }
        // Cache is keyed by URL + client so a reload with a different client
        // never serves a token minted for the previous one.
        let identity = "\(jamfURL)|\(clientID)"
        if let token = cachedValidToken(for: identity) { return token }

        guard let url = URL(string: "\(jamfURL)/api/v1/oauth/token") else {
            throw JamfMasterSessionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = "grant_type=client_credentials&client_id=\(Self.formEncode(clientID))&client_secret=\(Self.formEncode(clientSecret))"
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JamfMasterSessionError.authenticationFailed(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            // The body of a failed token call is safe to surface (no token in
            // it); a successful body is never logged.
            throw JamfMasterSessionError.authenticationFailed(
                http.statusCode,
                JamfErrorFormatter.message(status: http.statusCode, body: data, fallbackAction: "authenticate the master API client")
            )
        }

        struct TokenResponse: Decodable { let access_token: String; let expires_in: Int }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        store(decoded.access_token, expiresIn: decoded.expires_in, identity: identity)
        return decoded.access_token
    }

    /// x-www-form-urlencoded escaping: unreserved characters only, so a
    /// client id/secret containing '+', '&', or '=' can't corrupt the body.
    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// The app's one token lookup. `scope` names what the call is for (it keeps
/// call sites self-describing and is where per-category policy would hang);
/// every scope is served by the signed-in operator's own client.
enum JamfTokenProvider {

    /// The token for an app function.
    ///
    /// Jamf Pro backend: the operator's per-user token. Fail-closed: throws
    /// when the operator has no provisioned per-user client, and never
    /// falls back to master.
    ///
    /// Platform backend: the Platform integration's token. The Platform API
    /// has no per-user clients, so every operator on this Mac acts as the
    /// one integration; the app's role gating and its own action log are
    /// what distinguish people there.
    ///
    /// Hybrid backend: read scopes get the Platform token, every action,
    /// gated or sensitive scope gets the operator's per-user token
    /// (`JamfAPIBackend.usesPlatform(for:)`). Neither falls back to the
    /// other: a read fails closed without the integration, an action fails
    /// closed without the operator's client.
    static func token(for scope: CredentialScope) async throws -> String {
        let backend = MDMConfigurationManager.shared.configuration.effectiveAPIBackend
        if backend.usesPlatform(for: scope) {
            return try await JamfPlatformSession.shared.bearerToken()
        }
        return try await JamfUserSession.shared.bearerToken()
    }

    /// The Platform integration's token, for services that exist only on
    /// the Platform API (Compliance Benchmarks, declaration reports) and are
    /// therefore reached with it on either backend.
    static func platformToken() async throws -> String {
        try await JamfPlatformSession.shared.bearerToken()
    }

    /// Master token, for provisioning the operator's per-user API client at
    /// sign-in (find it, create it if missing, attach the required role) and
    /// for the Settings connection test of the master client itself. Nothing
    /// else may call this.
    static func provisioningToken() async throws -> String {
        try await JamfMasterSession.shared.bearerToken()
    }

    /// Forget every cached token (sign-out, credential change).
    static func invalidateAll() {
        JamfMasterSession.shared.invalidate()
        JamfUserSession.shared.invalidate()
        JamfPlatformSession.shared.invalidate()
    }
}
