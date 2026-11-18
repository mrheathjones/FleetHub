//
//  JamfAPIError 2.swift
//  FleetHub
//


import Foundation
import os.log

private let authLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.herojoneslabs.fleethub", category: "JamfAuth")

// MARK: - Jamf Credentials Model
struct JamfCredentials: Codable {
    let clientID: String
    let clientSecret: String
    let email: String
    let expiresAt: Date?

    var isExpired: Bool {
        guard let expiresAt = expiresAt else {
            return false
        }
        return expiresAt < Date()
    }
}

// MARK: - Jamf error formatting

/// Turns Jamf Pro's JSON error envelope into something an operator can act on.
///
/// Jamf answers a rejected call with, e.g.:
/// ```json
/// { "httpStatus": 403, "errors": [ { "code": "INVALID_PRIVILEGE",
///   "description": "User <clientId> not privileged for [SETTINGS]" } ] }
/// ```
/// Dumping that verbatim into an alert tells the operator nothing. This maps
/// the common cases — above all a missing MDM command privilege — onto the
/// exact Jamf privilege they need to be granted.
enum JamfErrorFormatter {

    /// MDM command type (as it appears in Jamf's `[BRACKETS]`) → the Jamf API
    /// role privilege that authorizes it. Verified against a Jamf Pro
    /// instance's `GET /api/v1/api-role-privileges`.
    private static let commandPrivileges: [String: String] = [
        "SETTINGS": "Send Computer Bluetooth Command",
        "ENABLE_REMOTE_DESKTOP": "Send Computer Remote Desktop Command",
        "DISABLE_REMOTE_DESKTOP": "Send Computer Remote Desktop Command",
        "RESTART_DEVICE": "Send Computer Restart Command",
        "SHUT_DOWN_DEVICE": "Send Computer Shut Down Command",
        "ERASE_DEVICE": "Send Computer Remote Wipe Command",
        "DEVICE_LOCK": "Send Computer Remote Lock Command",
        "UNLOCK_USER_ACCOUNT": "Send Computer Unlock User Account Command",
        "DELETE_USER": "Send Computer Delete User Account Command",
    ]

    /// A human-readable message for a failed Jamf response.
    /// - Parameters:
    ///   - status: HTTP status code.
    ///   - body: Raw response body (may or may not be Jamf's JSON envelope).
    ///   - fallbackAction: Short description of what was attempted, used when
    ///     the body carries nothing useful (e.g. "send the restart command").
    static func message(status: Int, body: Data?, fallbackAction: String? = nil) -> String {
        let raw = body.flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let parsed = parseEnvelope(raw, status: status) {
            return parsed
        }

        // Not Jamf's envelope — say something useful about the status itself.
        let action = fallbackAction.map { " while trying to \($0)" } ?? ""
        switch status {
        case 401:
            return "Jamf Pro rejected the credentials\(action). Sign out and back in, then try again."
        case 403:
            return "Jamf Pro denied this request\(action) — your API role is missing a required privilege."
        case 404:
            return "Jamf Pro could not find the target of this request\(action)."
        case 409:
            return "Jamf Pro reported a conflict\(action) — the record changed while the update was being applied. Try again."
        case 500...599:
            return "Jamf Pro returned a server error (\(status))\(action). Try again shortly."
        default:
            let detail = raw.isEmpty ? "" : ": \(truncated(raw))"
            return "Jamf Pro returned status \(status)\(action)\(detail)"
        }
    }

    /// Parses Jamf's `{ httpStatus, errors: [{ code, description }] }` shape.
    private static func parseEnvelope(_ raw: String, status: Int) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              let first = errors.first else {
            return nil
        }

        let code = first["code"] as? String ?? ""
        let description = (first["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if code == "INVALID_PRIVILEGE" {
            // "User <clientId> not privileged for [SETTINGS]" → name the exact
            // privilege to grant, plus the per-scope escape hatch.
            if let commandType = bracketedToken(in: description) {
                if let privilege = commandPrivileges[commandType.uppercased()] {
                    return """
                    Your Jamf API role isn't allowed to send the \(commandType) command.

                    Ask a Jamf administrator to add the “\(privilege)” privilege to your API role \
                    (plus “Send MDM command information in Jamf Pro API”), then sign out and back \
                    in. Alternatively this action can be routed to the master credential.
                    """
                }
                return """
                Your Jamf API role isn't allowed to send the \(commandType) command.

                Ask a Jamf administrator to grant the matching “Send Computer …” privilege for \
                \(commandType) on your API role, then sign out and back in.
                """
            }
            return """
            Your Jamf API role is missing a privilege required for this action.

            \(description.isEmpty ? "" : description)
            """.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Any other coded Jamf error: lead with the description, keep the code
        // for support, and drop the JSON scaffolding.
        if !description.isEmpty {
            return code.isEmpty ? description : "\(description)\n\n(Jamf error \(code), HTTP \(status))"
        }
        return code.isEmpty ? nil : "Jamf error \(code) (HTTP \(status))"
    }

    /// First `[TOKEN]` in a string — Jamf names the offending command type there.
    private static func bracketedToken(in text: String) -> String? {
        guard let open = text.firstIndex(of: "["),
              let close = text[open...].firstIndex(of: "]"),
              open < close else { return nil }
        let token = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    private static func truncated(_ text: String, limit: Int = 300) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }
}

// MARK: - Per-user Jamf token provider

enum JamfUserSessionError: LocalizedError {
    /// No per-user credential is provisioned, so an action that must be
    /// attributed to the operator cannot proceed (fail-closed).
    case credentialsUnavailable
    case invalidURL
    case authenticationFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable:
            return "Your personal Jamf credential isn't available on this Mac. Sign out and back in to provision it, then try again."
        case .invalidURL:
            return "Invalid Jamf Pro URL."
        case .authenticationFailed(let code, let message):
            return "Could not obtain your per-user Jamf token (\(code)): \(message)"
        }
    }
}

/// Shared, cached source of a **per-user** Jamf bearer token, minted from the
/// signed-in operator's Keychain credentials (`KeychainManager.loadJamfCredentials`).
///
/// User-initiated actions (MDM commands, delete, Move to Site, Return to
/// Service, Cleanup, PreStage register/assign, Inventory Preload) authenticate
/// through this so Jamf's own audit log attributes them to the operator instead
/// of the shared master client. Every app function authenticates this way.
///
/// Fail-closed: `bearerToken()` throws `.credentialsUnavailable` when no
/// per-user credential exists. Callers must NOT silently fall back to master.
final class JamfUserSession {
    static let shared = JamfUserSession()
    private init() {}

    private let keychain = KeychainManager.shared
    private let lock = NSLock()
    private var cachedToken: String?
    private var expiration: Date?

    private var jamfURL: String { MDMConfigurationManager.shared.configuration.jamfURL }

    /// True when a per-user credential exists to mint a token from.
    var hasCredentials: Bool { keychain.loadJamfCredentials() != nil }

    /// Drops the cached token — call on sign-out / credential rotation so the
    /// next operator never reuses the previous one's bearer token.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cachedToken = nil
        expiration = nil
    }

    private func cachedValidToken() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let token = cachedToken, let exp = expiration, exp > Date().addingTimeInterval(60) {
            return token
        }
        return nil
    }

    private func store(_ token: String, expiresIn: Int) {
        lock.lock(); defer { lock.unlock() }
        cachedToken = token
        expiration = Date().addingTimeInterval(TimeInterval(expiresIn))
    }

    /// x-www-form-urlencoded escaping: unreserved characters only, so a
    /// client id/secret containing '+', '&', or '=' can't corrupt the body.
    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Returns a cached, or freshly minted, per-user bearer token.
    /// Fail-closed: throws `.credentialsUnavailable` when the operator has no
    /// provisioned per-user client.
    func bearerToken() async throws -> String {
        #if DEBUG
        // Demo mode never talks to a real tenant (see Data/DemoMode.swift).
        if ProcessInfo.processInfo.arguments.contains("-FleetHubDemo") {
            throw NSError(domain: "FleetHubDemo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Demo mode: this needs a live connection, which is turned off."
            ])
        }
        #endif
        if let token = cachedValidToken() { return token }

        guard let credentials = keychain.loadJamfCredentials() else {
            throw JamfUserSessionError.credentialsUnavailable
        }
        guard let url = URL(string: "\(jamfURL)/api/v1/oauth/token") else {
            throw JamfUserSessionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        request.httpBody = "grant_type=client_credentials&client_id=\(formEncode(credentials.clientID))&client_secret=\(formEncode(credentials.clientSecret))"
            .data(using: .utf8)

        let (data, response) = try await JamfTransport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JamfUserSessionError.authenticationFailed(-1, "No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw JamfUserSessionError.authenticationFailed(http.statusCode,
                String(data: data, encoding: .utf8) ?? "Unknown error")
        }

        struct TokenResponse: Codable { let access_token: String; let expires_in: Int }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        store(decoded.access_token, expiresIn: decoded.expires_in)
        return decoded.access_token
    }
}

enum JamfAPIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case networkError(Error)
    case decodingError(Error)
    case serverError(statusCode: Int, message: String)
    case credentialsNotFound
    case expiredCredentials
    case authenticationFailed
    case invalidEmailFormat
    case roleNotFound
    /// `authentication.autoCreateUserApiClient` is false and this operator has
    /// no pre-created per-user API client, so FleetHub must not mint one.
    case userClientCreationDisabled
    /// Automatic creation is off and this Mac holds no working API client
    /// for the person signing in; they have to enter their own.
    case ownClientRequired(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .credentialsNotFound:
            return "No credentials found for this email"
        case .expiredCredentials:
            return "Credentials have expired. Please sign in again."
        case .authenticationFailed:
            return "Failed to authenticate with Jamf API"
        case .invalidEmailFormat:
            return "Invalid email address format"
        case .roleNotFound:
            return "Required role not found in Jamf Pro"
        case .ownClientRequired(let reason):
            return reason
        case .userClientCreationDisabled:
            return "You do not have a personal Jamf API client, and this Mac's configuration does not permit FleetHub to create one (automatic creation is off). Ask a Jamf administrator to create an API client for you."
        }
    }
}

// MARK: - Jamf API Response Models
struct JamfAPIClientCredential: Codable {
    let id: Int
    let clientId: String
    let displayName: String?
    let enabled: Bool
    let accessTokenLifetimeSeconds: Int?
    let appType: String?
    let authorizationScopes: [String]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case clientId
        case displayName
        case enabled
        case accessTokenLifetimeSeconds
        case appType
        case authorizationScopes
    }
}

struct JamfAPIClientCredentialsListResponse: Codable {
    let totalCount: Int?
    let results: [JamfAPIClientCredential]
}

struct JamfAPIClientCredentialCreateRequest: Codable {
    let displayName: String
    let authorizationScopes: [String]
}

struct JamfAPIClientCredentialCreateResponse: Codable {
    let id: Int
    let clientId: String
    let clientSecret: String
    let displayName: String?
    let enabled: Bool
    let accessTokenLifetimeSeconds: Int?
    let appType: String?
    let authorizationScopes: [String]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case clientId
        case clientSecret
        case displayName
        case enabled
        case accessTokenLifetimeSeconds
        case appType
        case authorizationScopes
    }
}

struct JamfAPIClientCredentialUpdateRequest: Codable {
    let displayName: String?
    let authorizationScopes: [String]?
    let enabled: Bool?
}

struct JamfBearerTokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let scope: String?
    let expiresIn: Int
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }
}

struct JamfRole: Codable {
    let id: String
    let displayName: String
}

struct JamfRolesListResponse: Codable {
    let totalCount: Int?
    let results: [JamfRole]
}

class JamfAPIService {
    static let shared = JamfAPIService()
    
    private var cachedUserRoleId: String? // Role for user credentials, not master
    
    private init() {}
    
    // MARK: - Configuration Properties
    private var configuration: MDMConfiguration {
        return MDMConfigurationManager.shared.configuration
    }
    
    private var jamfURL: String {
        return configuration.jamfURL
    }
    
    private var masterClientID: String {
        return configuration.masterClientID
    }
    
    private var userRoleName: String {
        return configuration.requiredRoleName
    }

    /// Name prefix shared by every API client the app provisions:
    /// `FleetHub-<email>`. It marks the client as FleetHub's and is what
    /// `searchCredentialByEmail` matches on.
    static func userClientNamePrefix(email: String) -> String {
        "FleetHub-\(email)"
    }

    /// Display name for a per-user API client:
    /// `FleetHub-<email> (<clientId>)`.
    ///
    /// Jamf's audit log records the client id that performed an action, so
    /// embedding the id in the name is what ties an audited action back to
    /// the operator.
    static func userClientDisplayName(email: String, clientId: String) -> String {
        "\(userClientNamePrefix(email: email)) (\(clientId))"
    }

    /// True when `displayName` is this operator's FleetHub client: the
    /// `FleetHub-<email>` prefix followed by nothing or by ` (<clientId>)`.
    /// The boundary check stops `jo@example.com` matching
    /// `jo@example.community`. Clients in any OTHER format (including the
    /// pre-rename `<email> (<clientId>)`) are deliberately not adopted — a
    /// client in the FleetHub format is created instead.
    static func isUserClient(displayName: String, email: String) -> Bool {
        let name = displayName.lowercased()
        let prefix = userClientNamePrefix(email: email).lowercased()
        guard name.hasPrefix(prefix) else { return false }
        let remainder = name.dropFirst(prefix.count)
        return remainder.isEmpty || remainder.hasPrefix(" (")
    }

    // MARK: - Main Authentication Method
    /// Authenticates a user by email and creates/retrieves their API credentials
    /// The master API credentials are used to authenticate this request - they already have the necessary permissions
    /// The created/updated user credentials are assigned the Jamf API Role(s) passed in `roleNames`.
    ///
    /// `roleNames` are the Jamf API Role NAMES the client must carry — resolved
    /// by the caller from the operator's FleetHub roles
    /// (`MDMConfiguration.jamfApiRoleNames(forRoleNames:)`). The client is
    /// left with EXACTLY this set, so a role the operator no longer holds is
    /// removed, not just a new one added.
    func authenticateWithEmail(_ email: String, roleNames: [String]) async throws -> JamfCredentials {
        // Validate email format
        guard isValidEmail(email) else {
            throw JamfAPIError.invalidEmailFormat
        }

        // The app invents no role names: an empty list means the profiles
        // name no Jamf API Role for this person (neither a role's
        // jamfApiRoleName nor core jamfPro.requiredRoleName), so fail closed.
        let roleNames = Array(Set(roleNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        guard !roleNames.isEmpty else {
            throw JamfAPIError.serverError(
                statusCode: 0,
                message: "The configuration profiles name no Jamf API Role for your account (access roles → jamfApiRoleName, or core jamfPro.requiredRoleName). Ask your administrator to deliver one."
            )
        }

        // Get bearer token using master API credentials (these already have necessary permissions)
        let bearerToken = try await getBearerToken()
        
        // Search for existing credential by email
        if let existingCredential = try await searchCredentialByEmail(email, bearerToken: bearerToken) {
            // Credential exists, verify it has the correct user role assigned
            // Exact-set comparison: a missing role is added AND a role the
            // operator no longer holds is taken away.
            let hasCorrectRoles = Set(existingCredential.authorizationScopes ?? []) == Set(roleNames)

            if !hasCorrectRoles {
                try await updateCredentialRoles(
                    id: existingCredential.id,
                    roleNames: roleNames,
                    bearerToken: bearerToken
                )
            }

            // Make sure the name carries the client id
            // ("FleetHub-<email> (<clientId>)"), so audited actions map to a
            // person. Non-fatal — an audit nicety, not a sign-in gate.
            let expectedName = Self.userClientDisplayName(email: email, clientId: existingCredential.clientId)
            if existingCredential.displayName != expectedName {
                do {
                    try await updateCredentialDisplayName(
                        id: existingCredential.id,
                        displayName: expectedName,
                        bearerToken: bearerToken
                    )
                    authLogger.info("Renamed existing API client to: \(expectedName, privacy: .private)")
                } catch {
                    authLogger.warning("Could not rename existing API client for \(email, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }

            // Check if we have the secret stored in Keychain
            let keychain = KeychainManager.shared
            if let storedCredentials = keychain.loadJamfCredentials(),
               storedCredentials.email == email,
               storedCredentials.clientID == existingCredential.clientId {
                // We have matching credentials stored with the secret
                return storedCredentials
            } else {
                // Secret not available in Keychain
                // We cannot retrieve the secret from Jamf API after creation
                // Must create new user credentials with the required role
                return try await createUserCredential(for: email, roleNames: roleNames, bearerToken: bearerToken)
            }
        } else {
            // No existing credential, create new user credential with required role
            return try await createUserCredential(for: email, roleNames: roleNames, bearerToken: bearerToken)
        }
    }
    
    // MARK: - Get Bearer Token (Using Master Credentials)
    /// Authenticates using the master API client credentials
    /// The master credentials must already have the necessary permissions to create/manage API integrations
    /// No role assignment is needed for the master credentials
    private func getBearerToken() async throws -> String {
        // Single implementation app-wide (cached, never logged). The master
        // client secret comes from the Keychain via the composed configuration.
        do {
            return try await JamfTokenProvider.provisioningToken()
        } catch JamfMasterSessionError.notConfigured {
            throw JamfAPIError.invalidURL
        } catch JamfMasterSessionError.invalidURL {
            throw JamfAPIError.invalidURL
        } catch JamfMasterSessionError.authenticationFailed(let code, let message) {
            throw JamfAPIError.serverError(statusCode: code, message: message)
        } catch let error as JamfAPIError {
            throw error
        } catch {
            throw JamfAPIError.networkError(error)
        }
    }
    
    // MARK: - Get User Role ID
    /// Retrieves the role ID for the role that will be assigned to user credentials
    /// This role (e.g., YOUR-API-ROLE) defines what permissions the user will have
    /// The master credentials are NOT assigned this role - they already have the necessary permissions
    private func getUserRoleId(bearerToken: String) async throws -> String {
        // Check if we have cached role ID
        if let roleId = cachedUserRoleId {
            return roleId
        }
        
        guard let url = URL(string: "\(jamfURL)/api/v1/api-roles") else {
            throw JamfAPIError.invalidURL
        }
        
        AppLog.notice("🔍 Fetching API roles from: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, response) = try await JamfTransport.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JamfAPIError.invalidResponse
            }
            
            AppLog.notice("🔍 Roles response status: \(httpResponse.statusCode)")
            
            // Log the raw response for debugging
            if let responseString = String(data: data, encoding: .utf8) {
                AppLog.notice("🔍 Roles response body: \(responseString)")
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw JamfAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
            do {
                let rolesResponse = try JSONDecoder().decode(JamfRolesListResponse.self, from: data)
                
                AppLog.notice("🔍 Found \(rolesResponse.results.count) roles")
                for role in rolesResponse.results {
                    AppLog.notice("🔍 Role: \(role.displayName) (id: \(role.id))")
                }
                
                // Find the role that will be assigned to user credentials
                guard let role = rolesResponse.results.first(where: { $0.displayName == userRoleName }) else {
                    AppLog.error("❌ Role '\(userRoleName)' not found!")
                    throw JamfAPIError.roleNotFound
                }
                
                // Cache the role ID
                cachedUserRoleId = role.id
                
                return role.id
            } catch let decodeError {
                AppLog.error("❌ Roles decode error: \(decodeError.localizedDescription)")
                AppLog.error("❌ Roles decode error details: \(String(describing: decodeError))")
                throw JamfAPIError.decodingError(decodeError)
            }
            
        } catch let error as JamfAPIError {
            throw error
        } catch {
            throw JamfAPIError.networkError(error)
        }
    }
    
    // MARK: - Search Credential by Email
    private func searchCredentialByEmail(_ email: String, bearerToken: String) async throws -> JamfAPIClientCredential? {
        // Page through every API client: a tenant with more clients than
        // one page holds would otherwise miss the operator's and create a
        // duplicate at each sign-in.
        let pageSize = 200
        var page = 0
        do {
            while true {
                guard let url = URL(string: "\(jamfURL)/api/v1/api-integrations?page=\(page)&page-size=\(pageSize)") else {
                    throw JamfAPIError.invalidURL
                }

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                let (data, response) = try await JamfTransport.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw JamfAPIError.invalidResponse
                }

                guard httpResponse.statusCode == 200 else {
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw JamfAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
                }

                let listResponse = try JSONDecoder().decode(JamfAPIClientCredentialsListResponse.self, from: data)

                // Only a client in the FleetHub format is this operator's:
                // "FleetHub-<email> (<clientId>)".
                if let match = listResponse.results.first(where: { credential in
                    guard let displayName = credential.displayName else { return false }
                    return Self.isUserClient(displayName: displayName, email: email)
                }) {
                    return match
                }

                page += 1
                if listResponse.results.count < pageSize || page * pageSize >= (listResponse.totalCount ?? 0) {
                    return nil
                }
            }
        } catch let error as JamfAPIError {
            throw error
        } catch let error as DecodingError {
            throw JamfAPIError.decodingError(error)
        } catch {
            throw JamfAPIError.networkError(error)
        }
    }

    // MARK: - Create User Credential
    /// Creates a new API credential for a user with the specified role
    /// Flow: 1) Create integration, 2) Enable it, 3) Generate client credentials
    private func createUserCredential(for email: String, roleNames: [String], bearerToken: String) async throws -> JamfCredentials {
        // Single choke point for minting per-user clients (both the sign-in and
        // refresh paths land here), so the profile toggle is enforced once.
        guard configuration.effectiveAutoCreateUserApiClient else {
            authLogger.warning("autoCreateUserApiClient is off — refusing to create a Jamf API client for \(email, privacy: .private)")
            throw JamfAPIError.userClientCreationDisabled
        }

        // Step 1: Create the integration
        guard let createUrl = URL(string: "\(jamfURL)/api/v1/api-integrations") else {
            throw JamfAPIError.invalidURL
        }
        
        let createRequest = JamfAPIClientCredentialCreateRequest(
            displayName: Self.userClientNamePrefix(email: email),
            authorizationScopes: roleNames
        )
        
        var request = URLRequest(url: createUrl)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(createRequest)
        
        let (createData, createResponse) = try await JamfTransport.data(for: request)
        
        guard let createHttpResponse = createResponse as? HTTPURLResponse,
              createHttpResponse.statusCode == 201 || createHttpResponse.statusCode == 200 else {
            let errorMessage = String(data: createData, encoding: .utf8) ?? "Unknown error"
            throw JamfAPIError.serverError(statusCode: (createResponse as? HTTPURLResponse)?.statusCode ?? 0, message: errorMessage)
        }
        
        // Parse create response to get ID
        guard let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
              let integrationId = createJson["id"] as? Int else {
            throw JamfAPIError.decodingError(NSError(domain: "JamfAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not parse integration ID"]))
        }
        
        AppLog.notice("✅ Created integration with ID: \(integrationId)")
        
        // Step 2: Enable the integration
        // Jamf Pro API PUT requires both displayName and authorizationScopes
        guard let enableUrl = URL(string: "\(jamfURL)/api/v1/api-integrations/\(integrationId)") else {
            throw JamfAPIError.invalidURL
        }
        
        var enableRequest = URLRequest(url: enableUrl)
        enableRequest.httpMethod = "PUT"
        enableRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        enableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        enableRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let enableBody: [String: Any] = [
            "displayName": Self.userClientNamePrefix(email: email),
            "enabled": true,
            "authorizationScopes": roleNames
        ]
        enableRequest.httpBody = try JSONSerialization.data(withJSONObject: enableBody)
        
        let (enableData, enableResponse) = try await JamfTransport.data(for: enableRequest)
        
        guard let enableHttpResponse = enableResponse as? HTTPURLResponse,
              enableHttpResponse.statusCode == 200 else {
            let errorMessage = String(data: enableData, encoding: .utf8) ?? "Unknown error"
            throw JamfAPIError.serverError(statusCode: (enableResponse as? HTTPURLResponse)?.statusCode ?? 0, message: errorMessage)
        }
        
        AppLog.notice("✅ Enabled integration")
        
        // Brief delay for server-side state propagation
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Step 3: Generate client credentials
        guard let credentialsUrl = URL(string: "\(jamfURL)/api/v1/api-integrations/\(integrationId)/client-credentials") else {
            throw JamfAPIError.invalidURL
        }
        
        var credRequest = URLRequest(url: credentialsUrl)
        credRequest.httpMethod = "POST"
        credRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        credRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (credData, credResponse) = try await JamfTransport.data(for: credRequest)
        
        guard let credHttpResponse = credResponse as? HTTPURLResponse,
              credHttpResponse.statusCode == 200 else {
            let errorMessage = String(data: credData, encoding: .utf8) ?? "Unknown error"
            throw JamfAPIError.serverError(statusCode: (credResponse as? HTTPURLResponse)?.statusCode ?? 0, message: errorMessage)
        }
        
        // Parse credentials response
        guard let credJson = try? JSONSerialization.jsonObject(with: credData) as? [String: Any],
              let clientId = credJson["clientId"] as? String,
              let clientSecret = credJson["clientSecret"] as? String else {
            throw JamfAPIError.decodingError(NSError(domain: "JamfAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not parse client credentials"]))
        }
        
        AppLog.notice("✅ Generated client credentials")

        // Step 4: Stamp the client id into the display name — "<UPN> (<clientId>)".
        // Jamf's audit log records the CLIENT ID that ran a command, so carrying
        // the id in the name is what lets an auditor map that id back to a
        // person. The id only exists after step 3, hence the rename.
        //
        // Non-fatal: the credential itself is already valid and usable, and
        // failing here would strand a working client behind a failed sign-in.
        // The email prefix is preserved so searchCredentialByEmail still matches.
        do {
            try await updateCredentialDisplayName(
                id: integrationId,
                displayName: Self.userClientDisplayName(email: email, clientId: clientId),
                bearerToken: bearerToken
            )
            authLogger.info("Named API client: \(Self.userClientDisplayName(email: email, clientId: clientId), privacy: .private)")
        } catch {
            authLogger.warning("Could not stamp the client id into the API client name for \(email, privacy: .private) (audit mapping will be by email only): \(error.localizedDescription, privacy: .public)")
        }

        // Expiration from core jamfPro.userCredentialLifetimeDays (default 90)
        let lifetimeDays = MDMConfigurationManager.shared.configuration.userCredentialLifetimeDays
        let expirationDate = Calendar.current.date(byAdding: .day, value: lifetimeDays, to: Date())
        
        return JamfCredentials(
            clientID: clientId,
            clientSecret: clientSecret,
            email: email,
            expiresAt: expirationDate
        )
    }
    
    // MARK: - Update Credential Display Name
    private func updateCredentialDisplayName(id: Int, displayName: String, bearerToken: String) async throws {
        guard let url = URL(string: "\(jamfURL)/api/v1/api-integrations/\(id)") else {
            throw JamfAPIError.invalidURL
        }
        
        // GET current integration to preserve required fields
        var getRequest = URLRequest(url: url)
        getRequest.httpMethod = "GET"
        getRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        getRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (getData, getResponse) = try await JamfTransport.data(for: getRequest)
        guard let getHttpResponse = getResponse as? HTTPURLResponse,
              getHttpResponse.statusCode == 200,
              let getJson = try? JSONSerialization.jsonObject(with: getData) as? [String: Any],
              let currentScopes = getJson["authorizationScopes"] as? [String] else {
            throw JamfAPIError.invalidResponse
        }
        
        let currentEnabled = getJson["enabled"] as? Bool ?? true
        
        // PUT with all required fields
        let updateBody: [String: Any] = [
            "displayName": displayName,
            "authorizationScopes": currentScopes,
            "enabled": currentEnabled
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: updateBody)
        
        do {
            let (data, response) = try await JamfTransport.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JamfAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw JamfAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
        } catch let error as JamfAPIError {
            throw error
        } catch {
            throw JamfAPIError.networkError(error)
        }
    }
    
    // MARK: - Update Credential Role
    /// Updates a user credential to add/change the assigned role
    /// This ensures the user credential has the required permissions (e.g., YOUR-API-ROLE)
    private func updateCredentialRoles(id: Int, roleNames: [String], bearerToken: String) async throws {
        guard let url = URL(string: "\(jamfURL)/api/v1/api-integrations/\(id)") else {
            throw JamfAPIError.invalidURL
        }
        
        // GET current integration to preserve required fields
        var getRequest = URLRequest(url: url)
        getRequest.httpMethod = "GET"
        getRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        getRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (getData, getResponse) = try await JamfTransport.data(for: getRequest)
        guard let getHttpResponse = getResponse as? HTTPURLResponse,
              getHttpResponse.statusCode == 200,
              let getJson = try? JSONSerialization.jsonObject(with: getData) as? [String: Any],
              let currentDisplayName = getJson["displayName"] as? String else {
            throw JamfAPIError.invalidResponse
        }
        
        let currentEnabled = getJson["enabled"] as? Bool ?? true
        
        // PUT with all required fields
        let updateBody: [String: Any] = [
            "displayName": currentDisplayName,
            "authorizationScopes": roleNames,
            "enabled": currentEnabled
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: updateBody)
        
        do {
            let (data, response) = try await JamfTransport.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JamfAPIError.invalidResponse
            }
            
            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw JamfAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
            }
            
        } catch let error as JamfAPIError {
            throw error
        } catch {
            throw JamfAPIError.networkError(error)
        }
    }
    
    // MARK: - Refresh Credentials
    func refreshCredentials(for email: String, roleNames: [String]) async throws -> JamfCredentials {
        let bearerToken = try await getBearerToken()

        // Create a new user credential carrying the given Jamf API Roles
        return try await createUserCredential(for: email, roleNames: roleNames, bearerToken: bearerToken)
    }
    
    // MARK: - Test Methods (for debugging)
    /// Public method to test bearer token retrieval
    func testGetBearerToken() async throws -> String {
        return try await getBearerToken()
    }
    
    /// Public method to test roles API - returns raw JSON string
    func testGetRoles(bearerToken: String) async throws -> String {
        guard let url = URL(string: "\(jamfURL)/api/v1/api-roles") else {
            throw JamfAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JamfAPIError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw JamfAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Return raw JSON for inspection
        let rawJSON = String(data: data, encoding: .utf8) ?? "Could not decode"
        return rawJSON
    }
    
    /// Public method to test integrations API - returns raw JSON string
    func testGetIntegrations(bearerToken: String) async throws -> String {
        guard let url = URL(string: "\(jamfURL)/api/v1/api-integrations") else {
            throw JamfAPIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JamfAPIError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw JamfAPIError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Return raw JSON for inspection
        let rawJSON = String(data: data, encoding: .utf8) ?? "Could not decode"
        return rawJSON
    }
    
    /// Public method to test create integration - returns raw JSON string
    func testCreateIntegration(email: String, bearerToken: String) async throws -> String {
        // Step 1: Create the integration
        guard let url = URL(string: "\(jamfURL)/api/v1/api-integrations") else {
            throw JamfAPIError.invalidURL
        }
        
        let integrationDisplayName = "TEST3_\(email)"
        
        let createRequest = JamfAPIClientCredentialCreateRequest(
            displayName: integrationDisplayName,
            authorizationScopes: [userRoleName]
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(createRequest)
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            return "Create failed: \(errorMessage)"
        }
        
        let createResponse = String(data: data, encoding: .utf8) ?? ""
        
        // Parse the response to get the ID
        guard let jsonData = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let integrationId = jsonData["id"] as? Int else {
            return "Created but couldn't parse ID:\n\(createResponse)"
        }
        
        // Step 2: Enable the integration (displayName and authorizationScopes are REQUIRED)
        guard let enableUrl = URL(string: "\(jamfURL)/api/v1/api-integrations/\(integrationId)") else {
            return "Created but failed to build enable URL.\n\nCreate response:\n\(createResponse)"
        }
        
        var enableRequest = URLRequest(url: enableUrl)
        enableRequest.httpMethod = "PUT"
        enableRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        enableRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        enableRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // Must include displayName — it's required by the Jamf Pro PUT schema
        let enableBody: [String: Any] = [
            "displayName": integrationDisplayName,
            "enabled": true,
            "authorizationScopes": [userRoleName]
        ]
        enableRequest.httpBody = try JSONSerialization.data(withJSONObject: enableBody)
        
        let (enableData, enableResponse) = try await JamfTransport.data(for: enableRequest)
        
        guard let enableHttpResponse = enableResponse as? HTTPURLResponse,
              enableHttpResponse.statusCode == 200 else {
            let enableError = String(data: enableData, encoding: .utf8) ?? "Unknown"
            return "Created but enable failed (status \((enableResponse as? HTTPURLResponse)?.statusCode ?? 0)):\n\(enableError)\n\nCreate response:\n\(createResponse)"
        }
        
        // Brief delay for server-side state propagation
        try await Task.sleep(nanoseconds: 500_000_000)
        
        // Step 3: Generate client credentials
        guard let credentialsUrl = URL(string: "\(jamfURL)/api/v1/api-integrations/\(integrationId)/client-credentials") else {
            return "Created & enabled but failed to build credentials URL.\n\nCreate response:\n\(createResponse)"
        }
        
        var credRequest = URLRequest(url: credentialsUrl)
        credRequest.httpMethod = "POST"
        credRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        credRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (credData, credResponse) = try await JamfTransport.data(for: credRequest)
        
        guard let credHttpResponse = credResponse as? HTTPURLResponse else {
            return "Created & enabled but credentials call failed.\n\nCreate response:\n\(createResponse)"
        }
        
        let credResult = String(data: credData, encoding: .utf8) ?? "No data"
        
        return "✅ CREDENTIALS RESPONSE (status \(credHttpResponse.statusCode)):\n\(credResult)"
    }
    
    // MARK: - Email Validation
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    // MARK: - Mock Authentication (For Development/Testing)
    func mockAuthenticate(email: String) async throws -> JamfCredentials {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds
        
        // Simulate success or failure based on email format
        guard isValidEmail(email) else {
            throw JamfAPIError.invalidEmailFormat
        }
        
        // Generate mock credentials
        let clientID = "client_" + UUID().uuidString.prefix(12).lowercased()
        let clientSecret = "secret_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let expiresAt = Calendar.current.date(byAdding: .day, value: MDMConfigurationManager.shared.configuration.userCredentialLifetimeDays, to: Date())
        
        return JamfCredentials(
            clientID: clientID,
            clientSecret: clientSecret,
            email: email,
            expiresAt: expiresAt
        )
    }
}


// MARK: - The operator's own pre-created API client

/// Used when `authentication.autoCreateUserApiClient` is off: FleetHub then
/// holds no provisioning secret and creates nothing in Jamf. Each person
/// enters the API client a Jamf administrator created for them.
enum OwnJamfAPIClient {
    /// Proves the client works by asking Jamf for a token, then keeps it in
    /// the Keychain. Returns nil on success, or what went wrong in words.
    @MainActor
    static func save(clientID: String, clientSecret: String) async -> String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return "Enter both the client ID and the client secret." }

        let keychain = KeychainManager.shared
        let previous = keychain.loadJamfCredentials()
        // The email is filled in at the first sign-in; a different client
        // must not inherit the last one's owner.
        let candidate = JamfCredentials(clientID: id, clientSecret: secret, email: "", expiresAt: nil)
        guard keychain.saveJamfCredentials(candidate) else {
            return "The client could not be saved to this Mac's Keychain."
        }
        JamfUserSession.shared.invalidate()
        do {
            _ = try await JamfUserSession.shared.bearerToken()
        } catch {
            // Put back what was there, so a typo never removes a working client.
            if let previous { _ = keychain.saveJamfCredentials(previous) } else { _ = keychain.deleteJamfCredentials() }
            JamfUserSession.shared.invalidate()
            return "Jamf did not accept this client: \(error.localizedDescription)"
        }
        MDMConfigurationManager.shared.ownAPIClientNotice = nil
        MDMConfigurationManager.shared.reloadConfiguration()
        return nil
    }

    /// Forgets the stored client, so the setup screen asks for one again.
    @MainActor
    static func forget(because notice: String?) {
        _ = KeychainManager.shared.deleteJamfCredentials()
        JamfUserSession.shared.invalidate()
        MDMConfigurationManager.shared.ownAPIClientNotice = notice
        MDMConfigurationManager.shared.reloadConfiguration()
    }
}
