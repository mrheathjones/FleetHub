//
//  SetupConnection.swift
//  FleetHubSetup
//
//  The only network code in Setup: testing the two API credentials and
//  uploading a configuration profile to Jamf Pro.
//
//  Secrets are passed in as arguments, used for one token request, and
//  never stored, logged or echoed. Every Jamf Pro token minted here is
//  invalidated before the call returns.
//

import Foundation

enum SetupConnectionError: LocalizedError {
    case missing(String)
    case badURL
    case http(Int, String)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missing(let what): "Enter \(what) first."
        case .badURL: "That address is not a valid URL."
        case .http(let status, let action):
            switch status {
            case 401: "Jamf rejected the client ID or secret while trying to \(action) (401)."
            case 403: "The API client is not allowed to \(action) (403). Check its API role's privileges."
            case 404: "Jamf could not find what was needed to \(action) (404). Check the server address."
            case 409: "Jamf reported a conflict while trying to \(action) (409). A profile with this name may already exist with different content."
            default: "Jamf returned \(status) while trying to \(action)."
            }
        case .unreadable(let what): "Jamf's reply could not be read (\(what))."
        }
    }
}

struct SetupUploadResult {
    let profileID: Int
    let updated: Bool
}

enum SetupConnection {

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func send(_ request: URLRequest, action: String) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SetupConnectionError.unreadable("no HTTP response") }
        guard (200...299).contains(http.statusCode) else { throw SetupConnectionError.http(http.statusCode, action) }
        return (data, http.statusCode)
    }

    private struct TokenResponse: Decodable { let access_token: String }

    private static func clientCredentialsToken(at url: URL, clientID: String, secret: String, action: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=client_credentials&client_id=\(formEncode(clientID))&client_secret=\(formEncode(secret))".utf8)
        let (data, _) = try await send(request, action: action)
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data).access_token else {
            throw SetupConnectionError.unreadable("no access token")
        }
        return token
    }

    // MARK: Jamf Pro

    private static func jamfToken(jamfURL: String, clientID: String, secret: String) async throws -> String {
        guard !jamfURL.isEmpty else { throw SetupConnectionError.missing("the Jamf Pro server URL") }
        guard !clientID.isEmpty, !secret.isEmpty else { throw SetupConnectionError.missing("the client ID and secret") }
        guard let url = URL(string: "\(jamfURL)/api/oauth/token") else { throw SetupConnectionError.badURL }
        return try await clientCredentialsToken(at: url, clientID: clientID, secret: secret, action: "sign in")
    }

    private static func invalidate(jamfURL: String, token: String) async {
        guard let url = URL(string: "\(jamfURL)/api/v1/auth/invalidate-token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: request)
    }

    private static func classicRequest(_ jamfURL: String, path: String, token: String, method: String = "GET", body: String? = nil) throws -> URLRequest {
        guard let url = URL(string: "\(jamfURL)/JSSResource/\(path)") else { throw SetupConnectionError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        return request
    }

    /// Signs in as the upload client and confirms it can read configuration
    /// profiles. Returns a sentence describing what worked.
    static func testJamfPro(jamfURL: String, clientID: String, secret: String) async throws -> String {
        let token = try await jamfToken(jamfURL: jamfURL, clientID: clientID, secret: secret)
        defer { Task { await invalidate(jamfURL: jamfURL, token: token) } }
        _ = try await send(
            try classicRequest(jamfURL, path: "osxconfigurationprofiles", token: token),
            action: "read configuration profiles"
        )
        return "Signed in and read configuration profiles. Creating and updating are checked at upload."
    }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func firstID(in data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8),
              let open = text.range(of: "<id>"),
              let close = text.range(of: "</id>", range: open.upperBound..<text.endIndex) else { return nil }
        return Int(text[open.upperBound..<close.lowerBound])
    }

    /// Creates the profile in Jamf Pro, or updates the one already holding
    /// this name. A new profile is created with NO scope, so nothing is
    /// delivered until an admin scopes it; an update leaves scope untouched.
    static func uploadProfile(named name: String, profile: Data, jamfURL: String, clientID: String, secret: String) async throws -> SetupUploadResult {
        guard let payloads = String(data: profile, encoding: .utf8) else { throw SetupConnectionError.unreadable("profile text") }
        let token = try await jamfToken(jamfURL: jamfURL, clientID: clientID, secret: secret)
        defer { Task { await invalidate(jamfURL: jamfURL, token: token) } }

        // Is there already a profile with this name?
        var existingID: Int?
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        do {
            let (data, _) = try await send(
                try classicRequest(jamfURL, path: "osxconfigurationprofiles/name/\(encodedName)", token: token),
                action: "look for an existing profile"
            )
            existingID = firstID(in: data)
        } catch SetupConnectionError.http(404, _) {
            existingID = nil
        }

        let general = "<name>\(xmlEscape(name))</name><payloads>\(xmlEscape(payloads))</payloads>"
        if let existingID {
            let body = "<os_x_configuration_profile><general>\(general)</general></os_x_configuration_profile>"
            _ = try await send(
                try classicRequest(jamfURL, path: "osxconfigurationprofiles/id/\(existingID)", token: token, method: "PUT", body: body),
                action: "update the profile"
            )
            return SetupUploadResult(profileID: existingID, updated: true)
        }

        let body = """
        <os_x_configuration_profile><general>\(general)\
        <description>FleetHub settings generated by FleetHub Setup.</description>\
        <distribution_method>Install Automatically</distribution_method>\
        <user_removable>false</user_removable><level>computer</level>\
        <redeploy_on_update>Newly Assigned</redeploy_on_update></general>\
        <scope><all_computers>false</all_computers></scope></os_x_configuration_profile>
        """
        let (data, _) = try await send(
            try classicRequest(jamfURL, path: "osxconfigurationprofiles/id/0", token: token, method: "POST", body: body),
            action: "create the profile"
        )
        guard let id = firstID(in: data) else { throw SetupConnectionError.unreadable("no profile ID") }
        return SetupUploadResult(profileID: id, updated: false)
    }

    // MARK: Jamf Pro script

    /// Creates the script in Jamf Pro, or updates the one already holding
    /// this name. Parameter labels are set so the policy shows what goes
    /// where; NO parameter VALUES are sent — the admin enters the secrets
    /// on the policy in Jamf Pro.
    static func uploadScript(named name: String, contents: String, jamfURL: String, clientID: String, secret: String) async throws -> SetupUploadResult {
        let token = try await jamfToken(jamfURL: jamfURL, clientID: clientID, secret: secret)
        defer { Task { await invalidate(jamfURL: jamfURL, token: token) } }

        func request(_ path: String, method: String, body: Data? = nil) throws -> URLRequest {
            guard let url = URL(string: "\(jamfURL)/api/v1/scripts\(path)") else { throw SetupConnectionError.badURL }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            return request
        }

        // Is there already a script with this name?
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "filter", value: "name==\"\(name)\""), URLQueryItem(name: "page-size", value: "1")]
        let (listData, _) = try await send(try request("?\(components.percentEncodedQuery ?? "")", method: "GET"),
                                           action: "look for an existing script")
        struct ScriptList: Decodable { struct Item: Decodable { let id: String }; let results: [Item] }
        let existingID = (try? JSONDecoder().decode(ScriptList.self, from: listData))?.results.first?.id

        let body: [String: Any] = [
            "name": name,
            "info": "Hands FleetHub's API client secrets to the FleetHub app, which stores them in the logged-in user's Keychain.",
            "notes": "Generated by FleetHub Setup. Run after the FleetHub package, frequency Ongoing, triggers Recurring Check-in and Login.",
            "priority": "AFTER",
            "parameter4": "Jamf Pro provisioning client ID",
            "parameter5": "Jamf Pro provisioning client secret",
            "parameter6": "Jamf Platform API client ID",
            "parameter7": "Jamf Platform API client secret",
            "parameter8": "Apple Business Manager key ID",
            "parameter9": "Apple Business Manager private key (base64, one line)",
            "parameter10": "Entra device cleanup client ID",
            "parameter11": "Entra device cleanup client secret",
            "scriptContents": contents
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        if let existingID {
            _ = try await send(try request("/\(existingID)", method: "PUT", body: payload), action: "update the script")
            return SetupUploadResult(profileID: Int(existingID) ?? 0, updated: true)
        }
        let (created, _) = try await send(try request("", method: "POST", body: payload), action: "create the script")
        struct Created: Decodable { let id: String }
        guard let id = (try? JSONDecoder().decode(Created.self, from: created))?.id else {
            throw SetupConnectionError.unreadable("no script ID")
        }
        return SetupUploadResult(profileID: Int(id) ?? 0, updated: false)
    }

    // MARK: Platform

    static func gatewayURL(region: String) -> String { "https://\(region).api.jamfcloud.com" }

    /// Signs in as the Platform integration. Tokens are region-locked, so a
    /// success also confirms the region.
    static func testPlatform(region: String, clientID: String, secret: String) async throws -> String {
        guard !clientID.isEmpty, !secret.isEmpty else { throw SetupConnectionError.missing("the client ID and secret") }
        guard let url = URL(string: "\(gatewayURL(region: region))/auth/token") else { throw SetupConnectionError.badURL }
        _ = try await clientCredentialsToken(at: url, clientID: clientID, secret: secret, action: "sign in to the Platform gateway")
        return "Signed in to the \(region.uppercased()) gateway. The token expires by itself after 15 minutes."
    }
}
