//
//  ComputerInventoryService.swift
//  FleetHub
//
//  Service for fetching computer inventory list from Jamf Pro API v3
//

import Foundation
import Combine

// MARK: - Computer Inventory Error

enum ComputerInventoryError: LocalizedError {
    case invalidURL
    case noCredentials
    case networkError(Error)
    case decodingError(Error)
    case httpError(statusCode: Int, message: String)
    case notAuthenticated
    
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
        case .notAuthenticated:
            return "Authentication required. Please log in."
        }
    }
}

// MARK: - Computer Inventory Service

@MainActor
final class ComputerInventoryService: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var computers: [ComputerInventoryItem] = []
    @Published var totalCount: Int = 0
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    
    private let cache = ComputerInventoryCache.shared
    
    /// Absolute ceiling on pages per sweep. At 100 per page this is 1,000,000
    /// devices — far beyond any real fleet, so tripping it means the server
    /// is misreporting `totalCount` or returning the same page forever.
    private static let maxPages = 10_000
    
    private var configuration: MDMConfiguration {
        MDMConfigurationManager.shared.configuration
    }
    
    private var jamfURL: String {
        configuration.jamfURL
    }
    
    // MARK: - Public Methods
    
    /// Fetch all computers - uses cache if available, otherwise fetches from API
    /// - Parameters:
    ///   - forceRefresh: If true, ignores cache and fetches fresh data
    ///   - sortField: Field to sort by (e.g., "general.name")
    ///   - sortOrder: Sort order ("asc" or "desc")
    func fetchAllComputers(
        forceRefresh: Bool = false,
        sortField: String = "general.name",
        sortOrder: String = "asc"
    ) async {
        // Check cache first (unless force refresh)
        if !forceRefresh && cache.hasCachedData {
            AppLog.notice("📦 ComputerInventoryService: Using cached data (\(cache.computers.count) computers)")
            computers = cache.computers
            totalCount = cache.totalCount
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let token = try await JamfTokenProvider.token(for: .inventory)
            var allComputers: [ComputerInventoryItem] = []
            var page = 0
            let pageSize = 100
            var reportedTotal = 0
            var truncated = false
            
            // Paginate until the pages fetched cover the server's totalCount.
            // `totalCount` and `computers` are only published together once
            // the whole sweep succeeds, so a failure on page N never leaves a
            // count that disagrees with the data on screen.
            while true {
                let response = try await performFetch(
                    page: page,
                    pageSize: pageSize,
                    sortField: sortField,
                    sortOrder: sortOrder,
                    bearerToken: token
                )
                
                allComputers.append(contentsOf: response.results)
                reportedTotal = response.totalCount
                
                AppLog.notice("📥 ComputerInventoryService: Fetched page \(page) (\(response.results.count) items, total: \(response.totalCount))")
                
                let coveredThroughThisPage = (page + 1) * pageSize
                if coveredThroughThisPage >= response.totalCount
                    || allComputers.count >= response.totalCount
                    || response.results.isEmpty {
                    break
                }
                
                page += 1
                if page >= Self.maxPages {
                    truncated = true
                    break
                }
            }
            
            computers = allComputers
            totalCount = reportedTotal
            
            // Update cache
            cache.updateCache(computers: allComputers, totalCount: reportedTotal)
            
            if truncated {
                errorMessage = "Computer inventory truncated: stopped after \(Self.maxPages) pages (\(allComputers.count) of \(reportedTotal) computers). Jamf Pro is reporting more devices than the sweep could fetch."
                AppLog.notice("⚠️ ComputerInventoryService: \(errorMessage ?? "")")
            } else {
                AppLog.notice("✅ ComputerInventoryService: Fetched all \(computers.count) computers")
            }
            
        } catch let error as ComputerInventoryError {
            // Previous computers/totalCount are left intact on failure.
            errorMessage = error.errorDescription
            AppLog.error("❌ ComputerInventoryService: \(errorMessage ?? "Unknown error")")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unexpected error occurred: \(error.localizedDescription)"
            AppLog.error("❌ ComputerInventoryService: \(errorMessage ?? "Unknown error")")
        }
        
        isLoading = false
    }
    
    /// Fetch computers with pagination (single page)
    /// - Parameters:
    ///   - page: Page number (0-indexed)
    ///   - pageSize: Number of items per page
    ///   - sortField: Field to sort by (e.g., "general.name")
    ///   - sortOrder: Sort order ("asc" or "desc")
    func fetchComputers(
        page: Int = 0,
        pageSize: Int = 100,
        sortField: String = "general.name",
        sortOrder: String = "asc"
    ) async {
        isLoading = true
        errorMessage = nil
        
        do {
            let token = try await JamfTokenProvider.token(for: .inventory)
            let response = try await performFetch(
                page: page,
                pageSize: pageSize,
                sortField: sortField,
                sortOrder: sortOrder,
                bearerToken: token
            )
            
            computers = response.results
            totalCount = response.totalCount
            
            AppLog.notice("✅ ComputerInventoryService: Fetched \(computers.count) computers (total: \(totalCount))")
            
        } catch let error as ComputerInventoryError {
            errorMessage = error.errorDescription
            AppLog.error("❌ ComputerInventoryService: \(errorMessage ?? "Unknown error")")
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "An unexpected error occurred: \(error.localizedDescription)"
            AppLog.error("❌ ComputerInventoryService: \(errorMessage ?? "Unknown error")")
        }
        
        isLoading = false
    }
    
    /// Clear the cache and force next fetch to get fresh data
    func refreshCache() {
        cache.invalidateCache()
    }
    
    // MARK: - Private Methods
    
    // Bearer tokens come from JamfTokenProvider.token(for: .inventory), which
    // honours the profile's credential routing and caches per session.
    
    /// Perform the API fetch request
    private func performFetch(
        page: Int,
        pageSize: Int,
        sortField: String,
        sortOrder: String,
        bearerToken: String
    ) async throws -> ComputerInventoryResponse {
        // Build URL with query parameters
        // Try v1 API first: /api/v1/computers-inventory (more widely supported)
        let sortParam = "\(sortField):\(sortOrder)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "\(sortField):\(sortOrder)"
        
        let endpoint = "/api/v1/computers-inventory"
        // Sections come from features.computers.inventorySections, validated
        // against the values /api/v1/computers-inventory accepts (an invalid
        // one 400s the whole request). Falls back to the default list.
        let sectionNames = (MDMConfigurationManager.shared.configuration
            .features?.effectiveComputers ?? .empty).validatedInventorySections
        let sections = sectionNames
            .map { "section=\($0)" }
            .joined(separator: "&")
        let queryParams = "\(sections)&page=\(page)&page-size=\(pageSize)&sort=\(sortParam)"
        
        guard let url = URL(string: "\(jamfURL)\(endpoint)?\(queryParams)") else {
            throw ComputerInventoryError.invalidURL
        }
        
        AppLog.notice("📥 ComputerInventoryService: Fetching from \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTuning.requestTimeout  // heavy paginated fetch
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ComputerInventoryError.networkError(URLError(.badServerResponse))
        }
        
        AppLog.notice("📥 ComputerInventoryService: Response status \(httpResponse.statusCode)")
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLog.error("❌ ComputerInventoryService: HTTP error: \(message)")
            throw ComputerInventoryError.httpError(statusCode: httpResponse.statusCode, message: message)
        }
        
        do {
            let inventoryResponse = try JSONDecoder().decode(ComputerInventoryResponse.self, from: data)
            return inventoryResponse
        } catch {
            AppLog.error("❌ ComputerInventoryService: Decode error: \(String(describing: error))")
            throw ComputerInventoryError.decodingError(error)
        }
    }
}

// MARK: - API Response Models

/// Response from /api/v3/computers-inventory
struct ComputerInventoryResponse: Codable {
    let totalCount: Int
    let results: [ComputerInventoryItem]
}

/// Lightweight computer item from inventory listing
struct ComputerInventoryItem: Codable, Identifiable, Hashable {
    let id: String
    let udid: String?
    let general: ComputerInventoryGeneral?
    
    // These are null when only requesting GENERAL section
    let diskEncryption: ComputerInventoryDiskEncryption?
    let hardware: ComputerInventoryHardware?
    let operatingSystem: ComputerInventoryOS?
    let userAndLocation: ComputerInventoryUserLocation?
    let security: ComputerInventorySecurity?
    let applications: [ComputerInventoryApplication]?
    let softwareUpdates: [ComputerInventorySoftwareUpdate]?
    let purchasing: ComputerInventoryPurchasing?
    let groupMemberships: [ComputerInventoryGroupMembership]?

    // Convenience properties
    var name: String {
        general?.name ?? "Unknown"
    }
    
    var isManaged: Bool {
        general?.remoteManagement?.managed ?? false
    }
    
    var isSupervised: Bool {
        general?.supervised ?? false
    }
    
    /// When the Mac last checked in: Jamf's last-contact time, or the last
    /// inventory report when there is none (some responses omit the
    /// first, and the column then read "Never"). Parsed here rather than
    /// through HealthEvaluator because the menu bar app shares this file.
    var lastContactTime: Date? {
        func parse(_ text: String?) -> Date? {
            guard let text, !text.isEmpty else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        return parse(general?.lastContactTime) ?? parse(general?.reportDate)
    }
    
    var siteName: String? {
        general?.site?.name
    }
    
    /// Check if a specific app is installed (by name, case-insensitive)
    func hasAppInstalled(_ appName: String) -> Bool {
        guard let apps = applications else { return false }
        let lowercaseAppName = appName.lowercased()
        return apps.contains { app in
            guard let name = app.name else { return false }
            return name.lowercased().contains(lowercaseAppName)
        }
    }
}

struct ComputerInventoryGeneral: Codable, Hashable {
    let name: String?
    let lastIpAddress: String?
    let lastReportedIp: String?
    let lastReportedIpV4: String?
    let lastReportedIpV6: String?
    let jamfBinaryVersion: String?
    let platform: String?
    let barcode1: String?
    let barcode2: String?
    let assetTag: String?
    let remoteManagement: ComputerInventoryRemoteManagement?
    let supervised: Bool?
    let mdmCapable: ComputerInventoryMDMCapable?
    let reportDate: String?
    let lastContactTime: String?
    let lastCloudBackupDate: String?
    let lastEnrolledDate: String?
    let mdmProfileExpiration: String?
    let initialEntryDate: String?
    let distributionPoint: String?
    let site: ComputerInventorySite?
    let itunesStoreAccountActive: Bool?
    let enrolledViaAutomatedDeviceEnrollment: Bool?
    let userApprovedMdm: Bool?
    let enrollmentMethod: ComputerInventoryEnrollmentMethod?
    let declarativeDeviceManagementEnabled: Bool?
    let managementId: String?
    let lastLoggedInUsernameSelfService: String?
    let lastLoggedInUsernameSelfServiceTimestamp: String?
    let lastLoggedInUsernameBinary: String?
    let lastLoggedInUsernameBinaryTimestamp: String?
    let extensionAttributes: [ComputerInventoryExtensionAttribute]?
}

struct ComputerInventoryRemoteManagement: Codable, Hashable {
    let managed: Bool?
    let managementUsername: String?
}

struct ComputerInventoryMDMCapable: Codable, Hashable {
    let capable: Bool?
    let capableUsers: [String]?
    let userManagementInfo: [ComputerInventoryUserManagementInfo]?
}

struct ComputerInventoryUserManagementInfo: Codable, Hashable {
    let capableUser: String?
    let managementId: String?
}

struct ComputerInventorySite: Codable, Hashable {
    let id: String?
    let name: String?
}

struct ComputerInventoryGroupMembership: Codable, Hashable {
    let groupId: String?
    let groupName: String?
    let smartGroup: Bool?
}

struct ComputerInventoryEnrollmentMethod: Codable, Hashable {
    let id: String?
    let objectName: String?
    let objectType: String?
}

struct ComputerInventoryExtensionAttribute: Codable, Hashable {
    let definitionId: String?
    let name: String?
    let description: String?
    let values: [String]?
    let dataType: String?
    let options: [String]?
    let inputType: String?
    let enabled: Bool?
    let multiValue: Bool?
}

// Optional sections (null when not requested)
struct ComputerInventoryDiskEncryption: Codable, Hashable {
    let bootPartitionEncryptionDetails: ComputerBootPartitionEncryption?
    let individualRecoveryKeyValidityStatus: String?
    let institutionalRecoveryKeyPresent: Bool?
    let diskEncryptionConfigurationName: String?
    let fileVault2Enabled: Bool?
    let fileVault2EnabledUserNames: [String]?
    let fileVault2EligibilityMessage: String?
    
    /// Check if boot partition is encrypted (ENCRYPTED state)
    var isBootPartitionEncrypted: Bool {
        guard let state = bootPartitionEncryptionDetails?.partitionFileVault2State?.uppercased() else {
            return fileVault2Enabled ?? false
        }
        return state == "ENCRYPTED"
    }
}

struct ComputerBootPartitionEncryption: Codable, Hashable {
    let partitionName: String?
    let partitionFileVault2State: String?
    let partitionFileVault2Percent: Int?
}

struct ComputerInventoryHardware: Codable, Hashable {
    let make: String?
    let model: String?
    let modelIdentifier: String?
    let serialNumber: String?
    let processorType: String?
    let totalRamMegabytes: Int?
    let appleSilicon: Bool?
}

struct ComputerInventoryOS: Codable, Hashable {
    let name: String?
    let version: String?
    let build: String?
}

struct ComputerInventoryUserLocation: Codable, Hashable {
    let username: String?
    let realname: String?
    let email: String?
    let position: String?
    let department: String?
    /// Jamf reports building and department as ids; names come from
    /// JamfLocationLookup.
    let departmentId: String?
    let buildingId: String?
}

struct ComputerInventorySecurity: Codable, Hashable {
    let sipStatus: String?
    let gatekeeperStatus: String?
    let firewallEnabled: Bool?
    let xprotectVersion: String?
    let autoLoginDisabled: Bool?
    let remoteDesktopEnabled: Bool?
    let activationLockEnabled: Bool?
    let recoveryLockEnabled: Bool?
    let secureBootLevel: String?
    let externalBootLevel: String?
    let bootstrapTokenAllowed: Bool?
    let bootstrapTokenEscrowedStatus: String?
}

// MARK: - Application Model

struct ComputerInventoryApplication: Codable, Hashable {
    let name: String?
    let path: String?
    let version: String?
    let macAppStore: Bool?
    let sizeMegabytes: Int?
    let bundleId: String?
    let updateAvailable: Bool?
    let externalVersionId: String?
}

// MARK: - Software Update Model

struct ComputerInventorySoftwareUpdate: Codable, Hashable {
    let name: String?
    let version: String?
    let packageName: String?
}
// MARK: - Purchasing Model

struct ComputerInventoryPurchasing: Codable, Hashable {
    let purchased: Bool?
    let leased: Bool?
    let poNumber: String?
    let lifeExpectancy: Int?
    let purchasePrice: String?
    let purchasingAccount: String?
    let purchasingContact: String?
    let appleCareId: String?
    let vendor: String?
    let leaseDate: String?
    let poDate: String?
    let warrantyDate: String?
}

