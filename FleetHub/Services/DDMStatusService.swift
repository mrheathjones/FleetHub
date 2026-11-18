//
//  DDMStatusService.swift
//  FleetHub
//
//  Declarative Device Management status items for one device.
//
//  Jamf Pro API: GET /api/v1/ddm/{clientManagementId}/status-items
//  → { statusItems: [ { key, value, lastUpdateTime } ] }
//  (privileges: Read Computers / Read Mobile Devices; verified on
//  developer.jamf.com 2026-11). A 404 means Jamf holds no DDM status for
//  that client, which is reported as an empty list, not an error.
//
//  Sent through `JamfTransport`, so it follows the selected backend, with
//  the operator's own token (`deviceSearch` scope, fail-closed).
//

import Foundation

struct DDMStatusItem: Identifiable, Hashable {
    let key: String
    let value: String
    let lastUpdateTime: String

    var id: String { key }

    /// The update time for display. Jamf sends local server time without a
    /// zone ("2024-08-25T21:09:31"), so it is reformatted when it parses and
    /// shown as sent when it does not.
    var formattedUpdateTime: String {
        guard !lastUpdateTime.isEmpty else { return "" }
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.dateFormat = format
            if let date = parser.date(from: lastUpdateTime) {
                return date.formatted(date: .abbreviated, time: .shortened)
            }
        }
        if let date = ISO8601DateFormatter().date(from: lastUpdateTime) {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return lastUpdateTime
    }
}

enum DDMStatusError: LocalizedError {
    case noManagementID
    case forbidden
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .noManagementID:
            return "This device has no management ID, so its DDM status cannot be looked up."
        case .forbidden:
            return "Your Jamf API role lacks the privilege to read this device's DDM status (Read Computers / Read Mobile Devices)."
        case .server(let code):
            return "Jamf Pro returned \(code)."
        }
    }
}

enum DDMStatusService {

    static func statusItems(managementId: String?) async throws -> [DDMStatusItem] {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.ddmStatusItems }
        #endif

        let managementId = managementId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !managementId.isEmpty else { throw DDMStatusError.noManagementID }

        let jamfURL = MDMConfigurationManager.shared.configuration.jamfURL
        let escaped = managementId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? managementId
        guard let url = URL(string: "\(jamfURL)/api/v1/ddm/\(escaped)/status-items") else {
            throw DDMStatusError.server(-1)
        }
        let token = try await JamfTokenProvider.token(for: .declarativeStatus)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await JamfTransport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DDMStatusError.server(-1) }
        switch http.statusCode {
        case 200...299:
            break
        case 404:
            return []
        case 403:
            throw DDMStatusError.forbidden
        default:
            throw DDMStatusError.server(http.statusCode)
        }

        struct Envelope: Decodable {
            struct Item: Decodable {
                let key: String?
                let value: String?
                let lastUpdateTime: String?
            }
            let statusItems: [Item]?
        }
        return (try JSONDecoder().decode(Envelope.self, from: data).statusItems ?? [])
            .compactMap { item in
                guard let key = item.key, !key.isEmpty else { return nil }
                return DDMStatusItem(key: key, value: item.value ?? "", lastUpdateTime: item.lastUpdateTime ?? "")
            }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
}
