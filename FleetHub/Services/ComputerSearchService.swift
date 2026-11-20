//
//  ComputerSearchService.swift
//  FleetHub
//
//  Service for searching computers and fetching full details via Jamf Pro API
//

import Foundation
import Combine

// MARK: - Search Error

enum ComputerSearchError: LocalizedError {
    case invalidURL
    case noCredentials
    case networkError(Error)
    case decodingError(Error)
    case httpError(statusCode: Int, message: String)
    case noResults
    case notAuthenticated
    case computerNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL configuration"
        case .noCredentials:
            return "No API credentials available. Please log in again."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .httpError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .noResults:
            return "No devices found matching your search"
        case .notAuthenticated:
            return "Authentication required. Please log in."
        case .computerNotFound:
            return "Computer not found"
        }
    }
}

// MARK: - Computer Search Service

@MainActor
final class ComputerSearchService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var searchResults: [ComputerSearchResult] = []
    @Published var isSearching: Bool = false
    @Published var errorMessage: String?
    @Published var hasSearched: Bool = false
    
    @Published var selectedComputer: Computer?
    @Published var isLoadingDetails: Bool = false
    
    // MARK: - Private Properties
    
    private let keychain = KeychainManager.shared
    
    private var configuration: MDMConfiguration {
        MDMConfigurationManager.shared.configuration
    }
    
    private var jamfURL: String {
        configuration.jamfURL
    }
    
    // MARK: - Public Methods
    
    /// Search for a computer by name or serial number
    /// First attempts name lookup, then falls back to serial number
    func searchComputer(query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedQuery.isEmpty else {
            errorMessage = "Please enter a device name or serial number"
            return
        }
        
        isSearching = true
        errorMessage = nil
        hasSearched = true
        
        do {
            // Get bearer token for API calls
            let token = try await getBearerToken()
            
            // First, try searching by device name
            let nameResults = try await searchByName(trimmedQuery, bearerToken: token)
            
            if !nameResults.isEmpty {
                searchResults = nameResults
                isSearching = false
                return
            }
            
            // If no results by name, try searching by serial number
            let serialResults = try await searchBySerialNumber(trimmedQuery, bearerToken: token)
            
            if !serialResults.isEmpty {
                searchResults = serialResults
            } else {
                searchResults = []
                errorMessage = "No devices found matching '\(trimmedQuery)'"
            }
            
        } catch let error as ComputerSearchError {
            errorMessage = error.errorDescription
            searchResults = []
        } catch let error as JamfAPIError {
            errorMessage = error.errorDescription
            searchResults = []
        } catch {
            errorMessage = "An unexpected error occurred: \(error.localizedDescription)"
            searchResults = []
        }
        
        isSearching = false
    }
    
    /// Fetch full computer details by ID
    func fetchComputerDetails(id: String) async throws -> Computer {
        isLoadingDetails = true
        defer { isLoadingDetails = false }
        
        do {
            let token = try await getBearerToken()
            let computer = try await fetchComputerById(id, bearerToken: token)
            selectedComputer = computer
            return computer
        } catch {
            throw error
        }
    }
    
    /// Clear search results and reset state
    func clearSearch() {
        searchResults = []
        errorMessage = nil
        hasSearched = false
        selectedComputer = nil
    }
    
    // MARK: - Private Methods
    
    /// Routed per the `.deviceSearch` scope by `JamfTokenProvider`: user →
    /// the shared per-user session (fail-closed); master → the shared master
    /// session. This is what lets an org that never provisions per-user
    /// credentials run search (and device-detail loads) on the master client
    /// instead of hitting "no credentials".
    private func getBearerToken() async throws -> String {
        try await JamfTokenProvider.token(for: .deviceSearch)
    }
    
    /// Search for computers by device name
    private func searchByName(_ name: String, bearerToken: String) async throws -> [ComputerSearchResult] {
        // URL encode the name for the filter
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        let filter = "general.name%3D%3D%22\(encodedName)%22"
        return try await performSearch(filter: filter, bearerToken: bearerToken)
    }
    
    /// Search for computers by serial number
    private func searchBySerialNumber(_ serialNumber: String, bearerToken: String) async throws -> [ComputerSearchResult] {
        let encodedSerial = serialNumber.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? serialNumber
        let filter = "hardware.serialNumber%3D%3D%22\(encodedSerial)%22"
        return try await performSearch(filter: filter, bearerToken: bearerToken)
    }
    
    /// Perform the actual API search request
    private func performSearch(filter: String, bearerToken: String) async throws -> [ComputerSearchResult] {
        // Build the URL with sections we need for display
        let sections = "section=GENERAL&section=HARDWARE&section=OPERATING_SYSTEM&section=USER_AND_LOCATION"
        let endpoint = "/api/v1/computers-inventory"
        let queryParams = "\(sections)&page=0&page-size=100&sort=general.name%3Aasc&filter=\(filter)"
        
        guard let url = URL(string: "\(jamfURL)\(endpoint)?\(queryParams)") else {
            throw ComputerSearchError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComputerSearchError.networkError(URLError(.badServerResponse))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ComputerSearchError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
        
        do {
            let searchResponse = try JSONDecoder().decode(ComputerSearchResponse.self, from: data)
            // Site scope: a search never returns a device outside it.
            let scope = SiteScopeStore.current
            return (searchResponse.results ?? []).filter { scope.includes(siteID: $0.general?.site?.id) }
        } catch {
            throw ComputerSearchError.decodingError(error)
        }
    }
    
    /// Fetch full computer details by ID
    private func fetchComputerById(_ id: String, bearerToken: String) async throws -> Computer {
        // Use the computers-inventory endpoint with all sections and filter by ID
        // This returns the same format as search but with complete data
        let allSections = [
            "GENERAL", "HARDWARE", "OPERATING_SYSTEM", "USER_AND_LOCATION",
            "DISK_ENCRYPTION", "SECURITY", "APPLICATIONS", "STORAGE",
            "CONFIGURATION_PROFILES", "PRINTERS", "SERVICES", "LOCAL_USER_ACCOUNTS",
            "CERTIFICATES", "ATTACHMENTS", "PLUGINS", "PACKAGE_RECEIPTS",
            "FONTS", "LICENSED_SOFTWARE", "IBEACONS", "SOFTWARE_UPDATES",
            "EXTENSION_ATTRIBUTES", "CONTENT_CACHING", "GROUP_MEMBERSHIPS"
        ].joined(separator: "&section=")
        
        let endpoint = "/api/v1/computers-inventory"
        let queryParams = "section=\(allSections)&page=0&page-size=1&filter=id%3D%3D\(id)"
        
        guard let url = URL(string: "\(jamfURL)\(endpoint)?\(queryParams)") else {
            throw ComputerSearchError.invalidURL
        }
        
        AppLog.notice("📥 Fetching computer details from: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComputerSearchError.networkError(URLError(.badServerResponse))
        }
        
        AppLog.notice("📥 Computer details response status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 404 {
            throw ComputerSearchError.computerNotFound
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLog.error("❌ Computer details error: \(message)")
            throw ComputerSearchError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
        
        // Log raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            AppLog.notice("📥 Computer details response (first 1000 chars): \(String(responseString.prefix(1000)))")
        }
        
        do {
            // Parse as ComputerSearchResponse (same format as search)
            let searchResponse = try JSONDecoder().decode(ComputerSearchResponse.self, from: data)
            
            guard let firstResult = searchResponse.results?.first else {
                throw ComputerSearchError.computerNotFound
            }
            
            // Convert to Computer
            let computer = Computer.fromSearchResult(firstResult)
            // Site scope: every way of opening a Mac (lists, search, deep
            // links, My Devices) loads its record here, so this is the gate.
            guard SiteScopeStore.includes(computer) else {
                AppLog.notice("Computer \(id) is outside the signed-in person's sites; not opened")
                throw ComputerSearchError.computerNotFound
            }
            return computer
        } catch let error as ComputerSearchError {
            throw error
        } catch {
            AppLog.error("❌ Computer decode error: \(String(describing: error))")
            throw ComputerSearchError.decodingError(error)
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension ComputerSearchResult {
    static var preview: ComputerSearchResult {
        ComputerSearchResult(
            id: "958",
            udid: "00000000-0D30-0000-0000-000000000001",
            general: ComputerSearchGeneral(
                name: "Mac Studio",
                lastIpAddress: "10.0.20.201",
                lastReportedIp: "10.0.20.201",
                lastReportedIpV4: "10.0.20.201",
                lastReportedIpV6: nil,
                lastContactTime: "2026-01-19T23:55:32.937Z",
                reportDate: nil,
                remoteManagement: ComputerSearchRemoteManagement(managed: true, managementUsername: nil),
                supervised: true,
                mdmCapable: ComputerSearchMDMCapable(capable: true, capableUsers: nil),
                managementId: "00000000-0000-4000-8000-000000000003",
                platform: "Mac",
                jamfBinaryVersion: nil,
                barcode1: nil,
                barcode2: nil,
                assetTag: nil,
                site: nil,
                enrolledViaAutomatedDeviceEnrollment: nil,
                userApprovedMdm: nil,
                declarativeDeviceManagementEnabled: nil,
                extensionAttributes: nil
            ),
            hardware: ComputerSearchHardware(
                make: "Apple",
                model: "Mac Studio",
                modelIdentifier: "Mac13,2",
                serialNumber: "C02DEMO0001",
                processorType: "Apple M1 Ultra",
                processorArchitecture: "arm64",
                processorSpeedMhz: nil,
                processorCount: nil,
                coreCount: nil,
                totalRamMegabytes: 131072,
                appleSilicon: true,
                macAddress: nil,
                altMacAddress: nil,
                networkAdapterType: nil,
                bootRom: nil,
                batteryCapacityPercent: nil,
                batteryHealth: nil
            ),
            operatingSystem: ComputerSearchOS(
                name: "macOS",
                version: "15.2.0",
                build: "24C101",
                supplementalBuildVersion: nil,
                rapidSecurityResponse: nil,
                activeDirectoryStatus: nil,
                fileVault2Status: nil
            ),
            userAndLocation: ComputerSearchUserLocation(
                username: "jsmith",
                realname: "John Smith",
                email: "jsmith@example.com",
                position: "Engineer",
                phone: nil,
                department: "IT",
                departmentId: nil,
                building: "HQ",
                buildingId: nil,
                room: nil
            ),
            diskEncryption: nil,
            security: nil,
            applications: nil,
            storage: nil,
            configurationProfiles: nil,
            printers: nil,
            localUserAccounts: nil,
            certificates: nil,
            softwareUpdates: nil,
            groupMemberships: nil,
            extensionAttributes: nil,
            contentCaching: nil
        )
    }
    
    static var previewMacBook: ComputerSearchResult {
        ComputerSearchResult(
            id: "1024",
            udid: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            general: ComputerSearchGeneral(
                name: "MacBook-Pro-JDoe",
                lastIpAddress: "10.0.20.105",
                lastReportedIp: "10.0.20.105",
                lastReportedIpV4: "10.0.20.105",
                lastReportedIpV6: nil,
                lastContactTime: "2026-01-20T10:30:00.000Z",
                reportDate: nil,
                remoteManagement: ComputerSearchRemoteManagement(managed: true, managementUsername: nil),
                supervised: false,
                mdmCapable: ComputerSearchMDMCapable(capable: true, capableUsers: nil),
                managementId: "abc123-def456",
                platform: "Mac",
                jamfBinaryVersion: nil,
                barcode1: nil,
                barcode2: nil,
                assetTag: nil,
                site: nil,
                enrolledViaAutomatedDeviceEnrollment: nil,
                userApprovedMdm: nil,
                declarativeDeviceManagementEnabled: nil,
                extensionAttributes: nil
            ),
            hardware: ComputerSearchHardware(
                make: "Apple",
                model: "MacBook Pro (16-inch, 2023)",
                modelIdentifier: "Mac15,7",
                serialNumber: "C02XL1234567",
                processorType: "Apple M3 Pro",
                processorArchitecture: "arm64",
                processorSpeedMhz: nil,
                processorCount: nil,
                coreCount: nil,
                totalRamMegabytes: 36864,
                appleSilicon: true,
                macAddress: nil,
                altMacAddress: nil,
                networkAdapterType: nil,
                bootRom: nil,
                batteryCapacityPercent: nil,
                batteryHealth: nil
            ),
            operatingSystem: ComputerSearchOS(
                name: "macOS",
                version: "14.3.1",
                build: "23D60",
                supplementalBuildVersion: nil,
                rapidSecurityResponse: nil,
                activeDirectoryStatus: nil,
                fileVault2Status: nil
            ),
            userAndLocation: ComputerSearchUserLocation(
                username: "jdoe",
                realname: "Jane Doe",
                email: "jdoe@example.com",
                position: "Designer",
                phone: nil,
                department: "Creative",
                departmentId: nil,
                building: "West Campus",
                buildingId: nil,
                room: nil
            ),
            diskEncryption: nil,
            security: nil,
            applications: nil,
            storage: nil,
            configurationProfiles: nil,
            printers: nil,
            localUserAccounts: nil,
            certificates: nil,
            softwareUpdates: nil,
            groupMemberships: nil,
            extensionAttributes: nil,
            contentCaching: nil
        )
    }
}
#endif
