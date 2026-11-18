//
//  JamfSiteService.swift
//  FleetHub
//
//  Jamf Pro site client for the `moveToSite` device action. Master-credential
//  OAuth per the JamfPreStageService / ComputerInventoryService pattern (this
//  is the DEVICE-scoped site client; the Cleanup module has its own
//  JamfCleanupClient.fetchSites/moveComputer for the bulk-cleanup flow, which
//  runs on separate credentials and cannot be reached from a device view).
//
//  API facts this file is built on (Jamf Pro API):
//    • GET  /api/v1/sites            → [{ id: String, name: String }]
//    • PATCH /api/v3/computers-inventory-detail/{id} with
//      { "general": { "siteId": "<id>" } } moves ONE computer between sites.
//      The WRITE schema takes a flat `siteId` string — NOT the nested
//      { site: { id, name } } object the read returns. `{id}` is the Jamf
//      computer INVENTORY id (Computer.id), not the managementId that MDM
//      commands use.
//

import Foundation

struct JamfSiteRecord: Identifiable, Hashable {
    let id: String
    let name: String
}

enum JamfSiteError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Jamf Pro URL."
        case .invalidResponse:
            return "Invalid response from Jamf Pro."
        case .httpError(let code, let message):
            return "Jamf Pro request failed (\(code)): \(message)"
        }
    }
}

final class JamfSiteService: ObservableObject {

    static let shared = JamfSiteService()
    private init() {}

    private var jamfURL: String {
        MDMConfigurationManager.shared.configuration.jamfURL
    }

    // MARK: - Auth

    /// Attribution: Move to Site runs on the per-user credential
    /// (fail-closed) when the profile routes the `moveToSite` scope to
    /// the operator; otherwise the shared master session.
    private func getBearerToken() async throws -> String {
        try await JamfTokenProvider.token(for: .moveToSite)
    }

    private func request(
        _ method: String,
        path: String,
        body: Data? = nil,
        timeout: TimeInterval = NetworkTuning.connectionTimeout
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "\(jamfURL)\(path)") else {
            throw JamfSiteError.invalidURL
        }
        let token = try await getBearerToken()

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await JamfTransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JamfSiteError.invalidResponse
        }
        return (data, httpResponse)
    }

    // MARK: - Sites

    /// Every Jamf Pro site, sorted by display name. `/api/v1/sites` returns
    /// the full list in one response (there is no paging envelope on this
    /// endpoint), so the caller filters to the role's allow-list itself.
    func fetchSites() async throws -> [JamfSiteRecord] {
        let (data, response) = try await request(
            "GET", path: "/api/v1/sites",
            timeout: NetworkTuning.requestTimeout
        )
        guard response.statusCode == 200 else {
            throw JamfSiteError.httpError(response.statusCode,
                                          String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        struct Entry: Decodable {
            let id: String
            let name: String
        }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        return entries
            .map { JamfSiteRecord(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Moves one computer to a site. The write schema takes a flat `siteId`
    /// string, not the nested `site` object the read returns. `computerID`
    /// is the Jamf computer INVENTORY id (Computer.id). Endpoint confirmed
    /// working on-device 2026-07-20 (v3 detail PATCH, not v1).
    func moveComputer(computerID: String, toSiteID siteID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "general": ["siteId": siteID]
        ])
        let (data, response) = try await request(
            "PATCH",
            path: "/api/v3/computers-inventory-detail/\(computerID)",
            body: body
        )
        guard (200...299).contains(response.statusCode) else {
            throw JamfSiteError.httpError(response.statusCode,
                                          String(data: data, encoding: .utf8) ?? "Unknown error")
        }
    }

    /// Moves one mobile device to a site. Mobile devices use a DIFFERENT
    /// endpoint and body from computers: the v2 UpdateMobileDevice schema
    /// takes a flat root-level `siteId` string (PATCH /api/v2/mobile-devices/{id}),
    /// NOT the computer's `{"general":{"siteId":…}}` wrapper and NOT the
    /// `{"site":{"id":…}}` object the read returns. Endpoint/body confirmed
    /// against developer.jamf.com (UpdateMobileDeviceV2, 2026-07-20).
    /// `mobileDeviceID` is the Jamf mobile-device INVENTORY id (MobileDevice.id).
    func moveMobileDevice(mobileDeviceID: String, toSiteID siteID: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "siteId": siteID
        ])
        let (data, response) = try await request(
            "PATCH",
            path: "/api/v2/mobile-devices/\(mobileDeviceID)",
            body: body
        )
        guard (200...299).contains(response.statusCode) else {
            throw JamfSiteError.httpError(response.statusCode,
                                          String(data: data, encoding: .utf8) ?? "Unknown error")
        }
    }
}


// MARK: - Buildings and Departments

/// Names for the building and department ids on device records.
///
/// Jamf's inventory carries only the ids. The names come from
/// GET /api/v1/buildings and GET /api/v1/departments (API privileges Read
/// Buildings and Read Departments). Loaded once per launch and on demand;
/// when the role cannot read them, callers fall back to showing the id.
@MainActor
final class JamfLocationLookup: ObservableObject {
    static let shared = JamfLocationLookup()
    private init() {}

    @Published private(set) var buildings: [String: String] = [:]
    @Published private(set) var departments: [String: String] = [:]
    /// Set when a list could not be read, in words for the operator.
    @Published private(set) var problem: String?
    private var loaded = false
    private var loading = false

    func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        loading = true
        defer { loading = false }

        #if DEBUG
        if DemoMode.isEnabled {
            buildings = ["1": "Headquarters", "2": "North Campus", "3": "Warehouse"]
            departments = ["1": "Engineering", "2": "Finance", "3": "Operations", "4": "Sales"]
            loaded = true
            return
        }
        #endif

        var problems: [String] = []
        do { buildings = try await fetch("buildings") } catch { problems.append("buildings") }
        do { departments = try await fetch("departments") } catch { problems.append("departments") }
        problem = problems.isEmpty ? nil
            : "FleetHub could not read \(problems.joined(separator: " or ")) from Jamf, so ids are shown instead of names. The Jamf API role needs Read Buildings and Read Departments."
        // Retry next time only if something failed.
        loaded = problems.isEmpty
    }

    /// Every id and name in one list, following Jamf's paging.
    private func fetch(_ list: String) async throws -> [String: String] {
        struct Page: Decodable {
            struct Entry: Decodable { let id: String; let name: String }
            let totalCount: Int?
            let results: [Entry]
        }
        let jamfURL = MDMConfigurationManager.shared.configuration.jamfURL
        let token = try await JamfTokenProvider.token(for: .reports)
        var names: [String: String] = [:]
        let pageSize = 200
        var page = 0
        while page < 50 {
            guard let url = URL(string: "\(jamfURL)/api/v1/\(list)?page=\(page)&page-size=\(pageSize)&sort=name%3Aasc") else {
                throw JamfSiteError.invalidURL
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = NetworkTuning.requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await JamfTransport.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw JamfSiteError.invalidResponse }
            guard http.statusCode == 200 else { throw JamfSiteError.httpError(http.statusCode, list) }
            let decoded = try JSONDecoder().decode(Page.self, from: data)
            for entry in decoded.results { names[entry.id] = entry.name }
            if decoded.results.count < pageSize || names.count >= (decoded.totalCount ?? Int.max) { break }
            page += 1
        }
        return names
    }
}
