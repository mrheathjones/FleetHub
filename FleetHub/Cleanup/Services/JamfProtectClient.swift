//
//  JamfProtectClient.swift
//  FleetHub
//
//  Minimal Jamf Protect GraphQL client for the Cleanup feature: look up a
//  computer by serial number, list computers, delete a record.
//
//  Two routes carry the same GraphQL:
//
//    · PLATFORM (preferred) — POST https://{region}.api.jamfcloud.com/protect
//      as the Jamf Platform API integration, with a Bearer token and the
//      PROTECT tenant ID (or the environment ID) as the scope header. No Protect URL, client ID or
//      password is needed. Integration permissions: devices:read
//      (listComputers) and devices:delete (deleteComputer).
//
//    · DIRECT — the Protect tenant's own /token and /graphql with a Protect
//      API client. Used only when no Platform integration is configured.
//

import Foundation

actor JamfProtectClient {
    /// How requests reach Jamf Protect.
    enum Route {
        case platform(PlatformAPIConnection)
        case direct(baseURL: URL, clientID: String, password: String)
    }

    private let route: Route
    private let session: URLSession

    private var accessToken: String?
    private var tokenExpiry: Date = .distantPast

    /// Direct route: the Protect tenant's own API client.
    init(baseURL: URL, clientID: String, password: String) {
        self.init(route: .direct(baseURL: baseURL, clientID: clientID, password: password))
    }

    init(route: Route) {
        self.route = route
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = NetworkTuning.requestTimeout
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth

    /// Direct route only: a token from the Protect tenant.
    private func directToken(baseURL: URL, clientID: String, password: String) async throws -> String {
        if let token = accessToken, Date() < tokenExpiry {
            return token
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "password": password,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw JamfCleanupError.authenticationFailed("Jamf Protect token request returned HTTP \(code).")
        }
        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        accessToken = token.access_token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(max(60, token.expires_in - 120)))
        return token.access_token
    }

    func invalidate() {
        accessToken = nil
        tokenExpiry = .distantPast
    }

    // MARK: - GraphQL plumbing

    private func graphQL(query: String, variables: [String: Any]) async throws -> [String: Any] {
        var request: URLRequest
        switch route {
        case .platform(let platform):
            guard let url = URL(string: "\(platform.gatewayBaseURL)/protect") else {
                throw JamfTransportError.platformNotConfigured
            }
            request = URLRequest(url: url)
            let token = try await JamfTokenProvider.platformToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Exactly one scope header (gateway rule). It must name the
            // PROTECT tenant — never the Jamf Pro tenant ID, which is a
            // different product instance. Without one, fall back to the
            // environment that contains the Protect tenant (Jamf notes an
            // environment-scoped integration may be refused with 403).
            if !platform.protectTenantID.isEmpty {
                request.setValue(platform.protectTenantID, forHTTPHeaderField: "X-Tenant-Id")
            } else if !platform.environmentID.isEmpty {
                request.setValue(platform.environmentID, forHTTPHeaderField: "X-Environment-Id")
            } else {
                throw JamfCleanupError.protectNotConfigured
            }
        case .direct(let baseURL, let clientID, let password):
            let token = try await directToken(baseURL: baseURL, clientID: clientID, password: password)
            request = URLRequest(url: baseURL.appendingPathComponent("graphql"))
            // The Protect tenant expects the raw token with no "Bearer " prefix.
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables,
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw JamfCleanupError.http(code, snippet)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JamfCleanupError.decoding("Jamf Protect response was not a JSON object.")
        }
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            throw JamfCleanupError.protectGraphQL(messages.isEmpty ? "Unknown GraphQL error" : messages)
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    // MARK: - API

    /// Fetches every computer record in the tenant (paginated). Counts
    /// and staleness are computed client-side so we never depend on
    /// unverified server-side filter shapes.
    func fetchAllComputers() async throws -> [ProtectDevice] {
        let query = """
        query list($next: String) {
          listComputers(input: {pageSize: 200, next: $next}) {
            items { uuid serial hostName checkin }
            pageInfo { next }
          }
        }
        """
        var devices: [ProtectDevice] = []
        var next: String?
        for _ in 0..<500 { // safety cap: 100k records
            var variables: [String: Any] = [:]
            if let next { variables["next"] = next }
            let data = try await graphQL(query: query, variables: variables)
            guard let list = data["listComputers"] as? [String: Any],
                  let items = list["items"] as? [[String: Any]]
            else { break }
            devices.append(contentsOf: items.compactMap { item in
                guard let uuid = item["uuid"] as? String else { return nil }
                return ProtectDevice(
                    uuid: uuid,
                    hostName: item["hostName"] as? String ?? "Unknown",
                    serial: item["serial"] as? String ?? "—",
                    checkin: (item["checkin"] as? String).flatMap(Self.parseDate)
                )
            })
            let pageInfo = list["pageInfo"] as? [String: Any]
            guard let cursor = pageInfo?["next"] as? String, !cursor.isEmpty else { break }
            next = cursor
        }
        return devices
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso = ISO8601DateFormatter()

    private static func parseDate(_ value: String) -> Date? {
        isoFractional.date(from: value) ?? iso.date(from: value)
    }

    /// Verifies credentials by listing a single computer.
    func testConnection() async throws {
        let query = """
        query test {
          listComputers(input: {pageSize: 1}) {
            items { uuid }
          }
        }
        """
        _ = try await graphQL(query: query, variables: [:])
    }

    /// Returns the Protect record UUID for a serial number, if one exists.
    /// Tries a server-side serial filter first; if the tenant's schema
    /// rejects it, falls back to paging the computer list and matching
    /// client-side (the shape Jamf's own cleanup scripts use).
    func findComputerUUID(serial: String) async throws -> String? {
        let filtered = """
        query find($serial: String) {
          listComputers(input: {filter: {serial: {equals: $serial}}, pageSize: 50}) {
            items { uuid serial }
          }
        }
        """
        do {
            let data = try await graphQL(query: filtered, variables: ["serial": serial])
            return Self.match(serial: serial, in: data)
        } catch JamfCleanupError.protectGraphQL {
            return try await findByPaging(serial: serial)
        }
    }

    private func findByPaging(serial: String) async throws -> String? {
        let query = """
        query list($next: String) {
          listComputers(input: {pageSize: 200, next: $next}) {
            items { uuid serial }
            pageInfo { next }
          }
        }
        """
        var next: String?
        for _ in 0..<100 { // safety cap: 20k records
            var variables: [String: Any] = [:]
            if let next { variables["next"] = next }
            let data = try await graphQL(query: query, variables: variables)
            if let uuid = Self.match(serial: serial, in: data) { return uuid }
            let list = data["listComputers"] as? [String: Any]
            let pageInfo = list?["pageInfo"] as? [String: Any]
            guard let cursor = pageInfo?["next"] as? String, !cursor.isEmpty else { return nil }
            next = cursor
        }
        return nil
    }

    private static func match(serial: String, in data: [String: Any]) -> String? {
        guard let list = data["listComputers"] as? [String: Any],
              let items = list["items"] as? [[String: Any]]
        else { return nil }
        return items.first {
            ($0["serial"] as? String)?.caseInsensitiveCompare(serial) == .orderedSame
        }?["uuid"] as? String
    }

    /// Deletes a computer record by UUID.
    func deleteComputer(uuid: String) async throws {
        let mutation = """
        mutation remove($uuid: ID!) {
          deleteComputer(uuid: $uuid) {
            hostName
          }
        }
        """
        _ = try await graphQL(query: mutation, variables: ["uuid": uuid])
    }
}
