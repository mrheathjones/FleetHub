//
//  ReportsView.swift
//  FleetHub
//
//  Report Builder with saved reports and export functionality
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Filter Types

enum ReportFilterCategory: String, CaseIterable, Identifiable, Codable {
    case lastCheckIn = "Last Check-In"
    case supervision = "Supervision Status"
    case encryption = "Encryption"
    case osVersion = "OS Version"
    case model = "Device Model"
    case site = "Site"
    case building = "Building"
    case department = "Department"
    case applications = "Applications"
    case appleCare = "AppleCare"
    case softwareUpdates = "Software Updates"
    case staleDevices = "Stale Devices"
    case unmanaged = "Unmanaged"
    case protectCoverage = "Jamf Protect"
    case computerGroup = "Computer Group"
    case deviceGroup = "Device Group"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .lastCheckIn: return "clock.arrow.circlepath"
        case .supervision: return "lock.shield"
        case .encryption: return "lock.fill"
        case .osVersion: return "gear.badge"
        case .model: return "desktopcomputer"
        case .site: return "building.2"
        case .building: return "building"
        case .department: return "person.3"
        case .applications: return "app.badge"
        case .appleCare: return "checkmark.seal.fill"
        case .softwareUpdates: return "arrow.down.circle"
        case .staleDevices: return "clock.badge.exclamationmark"
        case .unmanaged: return "antenna.radiowaves.left.and.right.slash"
        case .protectCoverage: return "shield.lefthalf.filled"
        case .computerGroup: return "rectangle.3.group"
        case .deviceGroup: return "square.grid.3x3.fill"
        }
    }
    var color: Color {
        switch self {
        case .lastCheckIn: return .blue
        case .supervision: return .green
        case .encryption: return .orange
        case .osVersion: return .cyan
        case .model: return .indigo
        case .site: return .purple
        case .building: return .brown
        case .department: return .teal
        case .applications: return .pink
        case .appleCare: return .teal
        case .softwareUpdates: return .mint
        case .staleDevices: return .orange
        case .unmanaged: return .red
        case .protectCoverage: return .indigo
        case .computerGroup: return .blue
        case .deviceGroup: return .green
        }
    }
    var description: String {
        switch self {
        case .lastCheckIn: return "Filter by when devices last checked in"
        case .supervision: return "Filter by supervision status"
        case .encryption: return "Filter by FileVault/encryption status"
        case .osVersion: return "Filter by operating system version"
        case .model: return "Filter by device model"
        case .site: return "Filter by Jamf site assignment"
        case .building: return "Filter by the building on the device record"
        case .department: return "Filter by the department on the device record"
        case .applications: return "Filter by installed applications"
        case .appleCare: return "Filter by AppleCare coverage status"
        case .softwareUpdates: return "Filter by pending software updates"
        case .staleDevices: return "Cleanup: devices that have gone quiet (no check-in)"
        case .unmanaged: return "Cleanup: devices without active MDM management"
        case .protectCoverage: return "Cleanup: Jamf Protect agent coverage"
        case .computerGroup: return "Filter by computer smart/static group"
        case .deviceGroup: return "Filter by mobile device smart/static group"
        }
    }

    /// Height for the filter config overlay - some filters need more space
    var configOverlayHeight: CGFloat {
        switch self {
        case .computerGroup, .deviceGroup: return 540  // search + scrollable group list
        case .appleCare: return 520  // 5 options + info text needs more height
        case .softwareUpdates: return 480  // 4 options + info text
        case .protectCoverage: return 480  // 3 options + info text
        case .applications: return 460  // Has quick buttons
        case .site, .building, .department: return 540  // scrollable list
        default: return 420
        }
    }
}

enum TimeRangeUnit: String, CaseIterable, Identifiable, Codable {
    case days = "Days", weeks = "Weeks", months = "Months", years = "Years"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .days: return 86400
        case .weeks: return 604800
        case .months: return 2592000
        case .years: return 31536000
        }
    }
}

enum TimeRangeComparison: String, CaseIterable, Identifiable, Codable {
    case within = "Within last", moreThan = "More than"
    var id: String { rawValue }
}

enum SupervisionFilter: String, CaseIterable, Identifiable, Codable {
    case all = "All Devices", supervised = "Supervised Only", unsupervised = "Unsupervised Only"
    var id: String { rawValue }
}

enum EncryptionFilter: String, CaseIterable, Identifiable, Codable {
    case all = "All Devices", encrypted = "Encrypted Only", notEncrypted = "Not Encrypted"
    var id: String { rawValue }
}

enum SiteFilterComparison: String, CaseIterable, Identifiable, Codable {
    case memberOf = "Member of"
    case notMemberOf = "Not member of"
    var id: String { rawValue }
}

enum ApplicationFilterType: String, CaseIterable, Identifiable, Codable {
    case hasApp = "Has Application"
    case missingApp = "Missing Application"
    var id: String { rawValue }
}

enum AppleCareFilter: String, CaseIterable, Identifiable, Codable {
    case all = "All Devices"
    case active = "Active Coverage"
    case expiringSoon = "Expiring Soon (90 days)"
    case expired = "Expired"
    case noCoverage = "No Coverage Data"
    var id: String { rawValue }
}

enum SoftwareUpdateFilter: String, CaseIterable, Identifiable, Codable {
    case all = "All Devices"
    case hasPendingUpdates = "Has Pending Updates"
    /// "No pending updates" — deliberately NOT named `upToDate`. That name belongs
    /// to HealthMetricType.upToDate, which means something different (OS major
    /// version vs a configured minimum). The rawValue is unchanged so persisted
    /// filter selections still decode.
    case noPendingUpdates = "Up to Date"
    case noUpdateData = "No Update Data"
    var id: String { rawValue }
}

// MARK: - Cleanup filters

enum StalenessLevel: String, CaseIterable, Identifiable, Codable {
    case over30 = "Over 30 days"
    case over90 = "Over 90 days"
    case over180 = "Over 180 days"
    case overOneYear = "Over 1 year"
    var id: String { rawValue }
    var days: Int {
        switch self {
        case .over30: return 30
        case .over90: return 90
        case .over180: return 180
        case .overOneYear: return 365
        }
    }
}

enum ManagedFilter: String, CaseIterable, Identifiable, Codable {
    case unmanagedOnly = "Unmanaged Only"
    case managedOnly = "Managed Only"
    var id: String { rawValue }
}

enum ProtectCoverageFilter: String, CaseIterable, Identifiable, Codable {
    case covered = "Has Protect Record"
    case notCovered = "Missing Protect Record"
    case protectStale = "Protect Stale"
    var id: String { rawValue }
}

// MARK: - Report Filter (Codable for persistence)

struct ReportFilter: Identifiable, Codable {
    let id: UUID
    let category: ReportFilterCategory
    var parameters: FilterParameters
    
    init(id: UUID = UUID(), category: ReportFilterCategory, parameters: FilterParameters) {
        self.id = id
        self.category = category
        self.parameters = parameters
    }
    
    enum FilterParameters: Codable {
        case lastCheckIn(comparison: TimeRangeComparison, value: Int, unit: TimeRangeUnit)
        case supervision(status: SupervisionFilter)
        case encryption(status: EncryptionFilter)
        case osVersion(version: String, comparison: String)
        case model(identifier: String)
        case site(name: String, comparison: SiteFilterComparison)
        case building(name: String, comparison: SiteFilterComparison)
        case department(name: String, comparison: SiteFilterComparison)
        case applications(type: ApplicationFilterType, appName: String)
        case appleCare(status: AppleCareFilter)
        case softwareUpdates(status: SoftwareUpdateFilter)
        case staleDevices(level: StalenessLevel)
        case unmanaged(status: ManagedFilter)
        case protectCoverage(status: ProtectCoverageFilter)
        case computerGroup(name: String)
        case deviceGroup(name: String)
    }
    
    /// Site, building and department filters can hold several names. They
    /// are stored in the one `name` string, separated by a character no
    /// name contains, so reports saved with a single name still load.
    static let nameSeparator: Character = "\u{1F}"

    static func names(in stored: String) -> [String] {
        stored.split(separator: nameSeparator).map(String.init)
    }

    static func store(_ names: Set<String>) -> String {
        names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: String(nameSeparator))
    }

    /// "East", "East or West", "East, West or 2 more".
    static func listText(_ stored: String) -> String {
        let all = names(in: stored)
        switch all.count {
        case 0: return ""
        case 1: return all[0]
        case 2, 3: return all.dropLast().joined(separator: ", ") + " or " + all[all.count - 1]
        default: return "\(all[0]), \(all[1]) or \(all.count - 2) more"
        }
    }

    var displayDescription: String {
        switch parameters {
        case .lastCheckIn(let c, let v, let u): return "\(c.rawValue) \(v) \(u.rawValue.lowercased())"
        case .supervision(let s): return s.rawValue
        case .encryption(let s): return s.rawValue
        case .osVersion(let v, let c): return "\(c) \(v)"
        case .model(let i): return i
        case .site(let s, let c): return "\(c.rawValue) \(ReportFilter.listText(s))"
        case .building(let s, let c): return "\(c == .memberOf ? "In" : "Not in") \(ReportFilter.listText(s))"
        case .department(let s, let c): return "\(c == .memberOf ? "In" : "Not in") \(ReportFilter.listText(s))"
        case .applications(let t, let n): return "\(t.rawValue): \(n)"
        case .appleCare(let s): return s.rawValue
        case .softwareUpdates(let s): return s.rawValue
        case .staleDevices(let l): return l.rawValue
        case .unmanaged(let s): return s.rawValue
        case .protectCoverage(let s): return s.rawValue
        case .computerGroup(let n): return n
        case .deviceGroup(let n): return n
        }
    }
}

// MARK: - Saved Report

struct SavedReport: Identifiable, Codable {
    let id: UUID
    var name: String
    var description: String
    var platforms: [String] // Store as strings for Codable
    var filters: [ReportFilter]
    // Devices scope + enrollment. Optional so reports saved before item 4b
    // still decode (missing keys → nil → defaults on load).
    var deviceScope: DeviceScope?
    var individualQuery: String?
    var includeEnrollment: Bool?
    let createdAt: Date
    var lastRunAt: Date?

    init(id: UUID = UUID(), name: String, description: String = "", platforms: Set<PlatformType>, filters: [ReportFilter], deviceScope: DeviceScope = .all, individualQuery: String = "", includeEnrollment: Bool = false, createdAt: Date = Date(), lastRunAt: Date? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.platforms = platforms.map { $0.rawValue }
        self.filters = filters
        self.deviceScope = deviceScope
        self.individualQuery = individualQuery
        self.includeEnrollment = includeEnrollment
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
    }

    var platformTypes: Set<PlatformType> {
        Set(platforms.compactMap { PlatformType(rawValue: $0) })
    }
}

// MARK: - Saved Reports Manager

@MainActor
class SavedReportsManager: ObservableObject {
    static let shared = SavedReportsManager()
    
    @Published var savedReports: [SavedReport] = []
    
    private let saveKey = "fleethub_saved_reports"
    
    private init() {
        loadReports()
    }
    
    func saveReport(_ report: SavedReport) {
        if let index = savedReports.firstIndex(where: { $0.id == report.id }) {
            savedReports[index] = report
        } else {
            savedReports.append(report)
        }
        persistReports()
    }
    
    func deleteReport(_ report: SavedReport) {
        savedReports.removeAll { $0.id == report.id }
        persistReports()
    }
    
    func updateLastRun(_ report: SavedReport) {
        if let index = savedReports.firstIndex(where: { $0.id == report.id }) {
            savedReports[index].lastRunAt = Date()
            persistReports()
        }
    }
    
    private func loadReports() {
        guard let data = UserDefaults.standard.data(forKey: saveKey) else { return }
        do {
            savedReports = try JSONDecoder().decode([SavedReport].self, from: data)
        } catch {
            // A model change must never destroy saved reports: keep the
            // unreadable payload under a dated key and start empty.
            let aside = "\(saveKey).unreadable-\(Int(Date().timeIntervalSince1970))"
            UserDefaults.standard.set(data, forKey: aside)
            AppLog.error("❌ SavedReportsManager: saved reports could not be decoded; kept under \(aside): \(error.localizedDescription)")
        }
    }

    private func persistReports() {
        do {
            let data = try JSONEncoder().encode(savedReports)
            UserDefaults.standard.set(data, forKey: saveKey)
        } catch {
            AppLog.error("❌ SavedReportsManager: could not encode saved reports: \(error.localizedDescription)")
        }
    }
}

// MARK: - Report Device Result

struct ReportDeviceResult: Identifiable {
    let id: String
    let deviceName: String
    let serialNumber: String
    let platform: PlatformType
    let lastCheckIn: Date?
    let isSupervised: Bool
    let isEncrypted: Bool
    let osVersion: String
    let model: String
    let siteName: String
    let siteId: String
    /// Building and department as Jamf reports them: ids, plus the name
    /// when the record carries one (mobile devices sometimes do).
    var buildingId: String = ""
    var departmentId: String = ""
    var buildingName: String?
    var departmentName: String?
    /// False for a row synthesized from a Device Enrollment (ADE) record that
    /// has no matching Jamf inventory device.
    let inJamf: Bool
    /// Device Enrollment (ADE/DEP) record attached during a Devices-scope run.
    var enrollment: DeviceEnrollmentDevice?
    var enrollmentInstanceName: String?

    init(from computer: ComputerInventoryItem) {
        self.id = computer.id
        self.deviceName = computer.name
        self.serialNumber = computer.hardware?.serialNumber ?? "N/A"
        self.platform = .macOS
        self.lastCheckIn = computer.lastContactTime
        self.isSupervised = computer.isSupervised
        // Use boot partition encryption state for accurate encryption status
        self.isEncrypted = computer.diskEncryption?.isBootPartitionEncrypted ?? false
        self.osVersion = computer.operatingSystem?.version ?? "Unknown"
        self.model = computer.hardware?.modelIdentifier ?? computer.hardware?.model ?? "Unknown"
        self.siteName = computer.siteName ?? "None"
        self.siteId = computer.general?.site?.id ?? ""
        self.buildingId = computer.userAndLocation?.buildingId ?? ""
        self.departmentId = computer.userAndLocation?.departmentId ?? ""
        self.departmentName = computer.userAndLocation?.department
        self.inJamf = true
    }

    init(from device: MobileDeviceInventoryItem) {
        self.id = device.id
        self.deviceName = device.displayName ?? "Unknown Device"
        self.serialNumber = device.serialNumber ?? "N/A"
        self.platform = device.platformType

        // Try to parse last inventory update date
        if let timestamp = device.general?.lastInventoryUpdateDate {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var parsedDate = formatter.date(from: timestamp)

            // Try without fractional seconds if that didn't work
            if parsedDate == nil {
                formatter.formatOptions = [.withInternetDateTime]
                parsedDate = formatter.date(from: timestamp)
            }

            self.lastCheckIn = parsedDate
        } else {
            self.lastCheckIn = nil
        }

        self.isSupervised = device.isSupervised
        // Use hardware encryption == 3 for accurate encryption status (full encryption)
        self.isEncrypted = device.security?.hardwareEncryption == 3
        self.osVersion = device.osVersion ?? "Unknown"
        self.model = device.modelIdentifier ?? device.model ?? "Unknown"
        // Mobile devices only have siteId, not site name
        self.siteName = device.general?.siteId ?? "None"
        self.siteId = device.general?.siteId ?? ""
        self.buildingId = device.userAndLocation?.buildingId ?? ""
        self.departmentId = device.userAndLocation?.departmentId ?? ""
        self.buildingName = device.userAndLocation?.building
        self.departmentName = device.userAndLocation?.department
        self.inJamf = true
    }

    /// A row synthesized from a Device Enrollment record that has no Jamf
    /// inventory device — the "in ADE, not in Jamf" case.
    init(orphan record: DeviceEnrollmentDevice, siteId: String, instanceName: String?) {
        self.id = "ade-\(record.serialNumber)"
        self.deviceName = record.description ?? record.model ?? "(Not in Jamf)"
        self.serialNumber = record.serialNumber
        self.platform = Self.inferPlatform(fromModel: record.model)
        self.lastCheckIn = nil
        self.isSupervised = false
        self.isEncrypted = false
        self.osVersion = "—"
        self.model = record.model ?? "—"
        self.siteName = "—"
        self.siteId = siteId
        self.inJamf = false
        self.enrollment = record
        self.enrollmentInstanceName = instanceName
    }

    private static func inferPlatform(fromModel model: String?) -> PlatformType {
        let m = (model ?? "").lowercased()
        if m.contains("iphone") { return .iOS }
        if m.contains("ipad") { return .iPadOS }
        if m.contains("vision") || m.contains("reality") { return .visionOS }
        return .macOS
    }
}

enum DeviceScope: String, CaseIterable, Identifiable, Codable {
    case all = "All Devices"
    case individual = "Individual Device"
    var id: String { rawValue }
}

enum ReportsTab: String, CaseIterable, Identifiable {
    case builder, scorecard, saved, scheduled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .builder: return "Report Builder"
        case .scorecard: return "Health Scorecard"
        case .saved: return "Saved Reports"
        case .scheduled: return "Scheduled"
        }
    }
    var icon: String {
        switch self {
        case .builder: return "hammer"
        case .scorecard: return "heart.text.square"
        case .saved: return "bookmark"
        case .scheduled: return "calendar.badge.clock"
        }
    }
}

// MARK: - Reports View

struct ReportsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var computerCache = ComputerInventoryCache.shared
    @ObservedObject private var mobileCache = MobileDeviceInventoryCache.shared
    @ObservedObject private var savedReportsManager = SavedReportsManager.shared
    @ObservedObject private var healthCalc = HealthMetricsCalculator.shared
    
    /// Set by a caller (the Overview's "Open scorecard") to choose the tab the
    /// next ReportsView opens on. Consumed once.
    @MainActor static var requestedTab: ReportsTab?

    @MainActor
    private static func consumeRequestedTab() -> ReportsTab {
        defer { requestedTab = nil }
        #if DEBUG
        // Test aid: the tab tour opens Reports on the Health Scorecard.
        if ProcessInfo.processInfo.arguments.contains("-FleetHubTourTabs")
            || ProcessInfo.processInfo.arguments.contains("-FleetHubSnapshotScorecard") { return .scorecard }
        #endif
        return requestedTab ?? .builder
    }

    @State private var selectedTab: ReportsTab = ReportsView.consumeRequestedTab()
    @State private var selectedPlatforms: Set<PlatformType> = Set(PlatformType.displayCases)
    @State private var filters: [ReportFilter] = []
    @State private var reportResults: [ReportDeviceResult] = []
    @State private var isRunningReport = false
    @State private var hasRunReport = false
    @State private var showingFilterConfig = false
    @State private var selectedFilterCategory: ReportFilterCategory = .lastCheckIn
    
    // Save report dialog
    @State private var showingSaveDialog = false
    @State private var saveReportName = ""
    @State private var saveReportDescription = ""

    // Filter params
    @State private var timeComparison: TimeRangeComparison = .within
    @State private var timeValue: Int = 7
    @State private var timeUnit: TimeRangeUnit = .days
    @State private var supervisionFilter: SupervisionFilter = .supervised
    @State private var encryptionFilter: EncryptionFilter = .encrypted
    @State private var osVersionComparison = "At least"
    @State private var osVersion = "26.0"
    @State private var modelIdentifier = ""
    @State private var siteFilter: Set<String> = []
    @State private var siteFilterComparison: SiteFilterComparison = .memberOf
    @State private var buildingFilter: Set<String> = []
    @State private var buildingFilterComparison: SiteFilterComparison = .memberOf
    @State private var departmentFilter: Set<String> = []
    @State private var departmentFilterComparison: SiteFilterComparison = .memberOf
    /// Narrows a long site, building or department list.
    @State private var locationQuery = ""
    /// The building and department lists the filter editor offers. Built
    /// when the editor opens and again when the inventory or the name
    /// lookup changes (see locationOptionsKey), not on every redraw: each
    /// build walks the whole inventory.
    @State private var buildingOptions: [String] = []
    @State private var departmentOptions: [String] = []
    @ObservedObject private var locationLookup = JamfLocationLookup.shared
    
    // New filter params
    @State private var applicationFilterType: ApplicationFilterType = .hasApp
    @State private var applicationName = ""
    @State private var appleCareFilter: AppleCareFilter = .active
    @State private var softwareUpdateFilter: SoftwareUpdateFilter = .hasPendingUpdates
    @State private var stalenessLevel: StalenessLevel = .over90
    @State private var managedFilter: ManagedFilter = .unmanagedOnly
    @State private var protectCoverageFilter: ProtectCoverageFilter = .covered
    @State private var computerGroupSelection = ""
    @State private var computerGroupQuery = ""
    @State private var deviceGroupSelection = ""
    @State private var deviceGroupQuery = ""

    // Jamf Protect coverage data, fetched at report-run when the filter is used.
    @State private var protectSerials: Set<String> = []
    @State private var protectStaleSerials: Set<String> = []

    // Collapsible builder sections
    @State private var expandedActiveFilters = true
    @State private var expandedPlatforms = true
    @State private var expandedScope = true
    @State private var expandedFilters = true

    // Devices scope + enrollment (item 4b)
    @State private var deviceScope: DeviceScope = .all
    @State private var individualQuery: String = ""
    @State private var includeEnrollment: Bool = false

    // Device detail navigation
    @State private var showingResults = false
    @State private var deviceLoadError: String?

    // Scorecard tab: the selected check, which of its devices to list, and
    // per-check pass/fail id sets for the row icons.
    @State private var scorecardMetric: HealthMetricType = .checkedIn
    @State private var scorecardSegment: HealthSegmentType = .nonCompliant
    @State private var scorecardRows: [DeviceListItem] = []
    @State private var scorecardSort = TableSort<String>()
    @State private var scorecardOSSort = TableSort<String>()
    @State private var scorecardPass: [HealthMetricType: Set<String>] = [:]
    @State private var scorecardFail: [HealthMetricType: Set<String>] = [:]
    /// Pass / fail / unknown ids for every check, built in the background.
    @State private var scorecardIndex = HealthMetricsCalculator.ScorecardIndex()
    /// True while the index is being built for the first time.
    @State private var scorecardLoading = false
    /// "Managed Devices by OS" rows, rebuilt with the index, not per render.
    @State private var scorecardOSRows: [HealthScorecardExportBuilder.OSRow] = []
    @State private var scorecardOpeningID: String?
    /// Width the Report Builder was last offered; drives its one/two-column layout.
    @State private var builderWidth: CGFloat = 1100
    @State private var savedWidth: CGFloat = 1100
    @State private var savedSearch = ""
    /// Width this view was last offered; drives its wide/narrow layout.
    @State private var scorecardWidth: CGFloat = 1100
    @State private var navigationPath = NavigationPath()
    
    private var isDark: Bool { colorScheme == .dark }
    private var totalDevices: Int { computerCache.totalCount + mobileCache.totalCount }

    /// Distinct computer / mobile groups (name + smart flag) across the cached
    /// fleet. Rebuilt ONCE per inventory change (see `rebuildGroupLists`), not
    /// on every overlay re-render.
    @State private var computerGroupList: [(name: String, smart: Bool)] = []
    @State private var deviceGroupList: [(name: String, smart: Bool)] = []

    /// Per-run lookup indexes so filters do dictionary lookups instead of a
    /// linear scan of the fleet for every device.
    @State private var computerIndex: [String: ComputerInventoryItem] = [:]
    @State private var mobileIndex: [String: MobileDeviceInventoryItem] = [:]

    /// Site presets come from the inventory itself (no site names are built
    /// into the app). "None" matches devices with no site.
    private var sitePresets: [String] {
        var names = Set(computerCache.computers.compactMap { $0.siteName }.filter { !$0.isEmpty })
        // Mobile records carry only the site id; show its name when a
        // computer in the same site tells us what it is.
        let byID = siteNamesByID
        for device in mobileCache.devices {
            if let id = device.general?.siteId, !id.isEmpty, id != "-1" {
                names.insert(byID[id] ?? "Site ID \(id)")
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } + ["None"]
    }

    /// Site names by id, learned from computer records.
    private var siteNamesByID: [String: String] {
        var names: [String: String] = [:]
        for computer in computerCache.computers {
            if let id = computer.general?.site?.id, !id.isEmpty, let name = computer.siteName, !name.isEmpty {
                names[id] = name
            }
        }
        return names
    }

    /// What a device's site, building or department is called in the lists
    /// and in filters. "None" when the record has none.
    private static func locationLabel(id: String, name: String?, names: [String: String], kind: String) -> String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "-1", trimmed != "0" else { return "None" }
        return names[trimmed] ?? "\(kind) ID \(trimmed)"
    }

    private func buildingLabel(_ row: ReportDeviceResult) -> String {
        Self.locationLabel(id: row.buildingId, name: row.buildingName, names: locationLookup.buildings, kind: "Building")
    }

    private func departmentLabel(_ row: ReportDeviceResult) -> String {
        Self.locationLabel(id: row.departmentId, name: row.departmentName, names: locationLookup.departments, kind: "Department")
    }

    private func siteLabel(_ row: ReportDeviceResult, names: [String: String]) -> String {
        guard row.platform != .macOS else { return row.siteName }
        return Self.locationLabel(id: row.siteId, name: nil, names: names, kind: "Site")
    }

    /// Changes whenever the option lists would: a device added or removed,
    /// or the building and department names arriving from Jamf.
    private var locationOptionsKey: String {
        "\(computerCache.computers.count)-\(mobileCache.devices.count)-\(locationLookup.buildings.count)-\(locationLookup.departments.count)"
    }

    /// Buildings or departments found on the devices in the inventory.
    private func detectedLocations(_ label: (ReportDeviceResult) -> String) -> [String] {
        var names = Set<String>()
        for computer in computerCache.computers { names.insert(label(ReportDeviceResult(from: computer))) }
        for device in mobileCache.devices { names.insert(label(ReportDeviceResult(from: device))) }
        names.remove("None")
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending } + ["None"]
    }

    /// A row that can be ticked on and off, for lists that take several choices.
    private func checkRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? FleetHubTheme.accent : FleetHubTheme.muted)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(selected ? FleetHubTheme.accent.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(selected ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Multiple-choice list for the Site, Building and Department filters:
    /// every value found in the inventory on its own full-width row, so a
    /// long name never wraps, with a search field once the list is long.
    private func locationEditor(
        title: String, noun: String, options: [String],
        comparison: Binding<SiteFilterComparison>, selection: Binding<Set<String>>,
        include: String, exclude: String, note: String? = nil
    ) -> some View {
        let query = locationQuery.trimmingCharacters(in: .whitespaces)
        let shown = query.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                Text("Choose one or more").font(.system(size: 12)).foregroundColor(FleetHubTheme.muted)
                Spacer(minLength: 0)
                if !selection.wrappedValue.isEmpty {
                    Button("Clear") { selection.wrappedValue = [] }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(FleetHubTheme.accent)
                }
            }

            Picker("", selection: comparison) {
                Text(include).tag(SiteFilterComparison.memberOf)
                Text(exclude).tag(SiteFilterComparison.notMemberOf)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if options.count > 8 {
                TextField("Search \(options.count) \(noun)", text: $locationQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13)).settingsFieldBox()
            }

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(shown, id: \.self) { option in
                        checkRow(option, selected: selection.wrappedValue.contains(option)) {
                            if selection.wrappedValue.contains(option) {
                                selection.wrappedValue.remove(option)
                            } else {
                                selection.wrappedValue.insert(option)
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text(options.count <= 1 ? "No \(noun) were found on the devices in the inventory." : "No \(noun) match \u{201C}\(query)\u{201D}.")
                            .font(.system(size: 12)).foregroundColor(FleetHubTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: 240)

            if let note {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(FleetHubTheme.muted)
                    Text(note).font(.system(size: 11)).foregroundColor(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !selection.wrappedValue.isEmpty {
                previewBox("\(comparison.wrappedValue == .memberOf ? include : exclude) \(ReportFilter.listText(ReportFilter.store(selection.wrappedValue)))")
            }
        }
    }

    /// Application presets come from the apps the configured health scorecard
    /// requires (features.healthScorecard.cards[].requiredApps) — nothing is
    /// hardcoded.
    private var applicationPresets: [String] {
        let names = HealthPolicy.current().cards.values
            .flatMap { $0.effectiveRequiredApps.map { $0.effectiveName } }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func rebuildGroupLists() {
        var cmap: [String: Bool] = [:]
        for c in computerCache.computers {
            for g in c.groupMemberships ?? [] where !(g.groupName ?? "").isEmpty {
                cmap[g.groupName!] = g.smartGroup ?? false
            }
        }
        computerGroupList = cmap.map { (name: $0.key, smart: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var dmap: [String: Bool] = [:]
        for d in mobileCache.devices {
            for g in d.groups ?? [] where !(g.groupName ?? "").isEmpty {
                dmap[g.groupName!] = g.smart ?? false
            }
        }
        deviceGroupList = dmap.map { (name: $0.key, smart: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    var body: some View {
        reportsStack
            .onShowTabRoot(.reports) {
                if !navigationPath.isEmpty { navigationPath = NavigationPath() }
            }
    }

    @ViewBuilder private var reportsStack: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                FleetHubTheme.ground.ignoresSafeArea()
                VStack(spacing: 0) {
                    headerSection
                    tabBar
                    switch selectedTab {
                    case .builder: reportBuilderContent
                    case .scorecard: scorecardContent
                    case .saved: savedReportsContent
                    case .scheduled:
                        ScrollView {
                            reportsEmptyState(
                                icon: "calendar.badge.clock",
                                title: "No Scheduled Reports",
                                message: "Scheduling reports to run automatically is not available yet."
                            )
                            .padding(.horizontal, 28)
                            .padding(.vertical, 20)
                        }
                    }
                }
                if showingFilterConfig { filterConfigOverlay }
                if showingSaveDialog { saveReportOverlay }
                if showingResults { resultsOverlay }
            }
            .navigationDestination(for: Computer.self) { computer in
                DeviceView(computer: computer)
            }
            .navigationDestination(for: MobileDevice.self) { device in
                MobileDeviceView(device: device)
            }
        }
        .onAppear { rebuildGroupLists() }
        #if DEBUG
        // Documentation aid: the snapshot walk opens one filter's editor.
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("FleetHubSnapshotReportFilter"))) { note in
            guard let raw = note.object as? String, let category = ReportFilterCategory(rawValue: raw) else { return }
            selectedFilterCategory = category
            if category == .site { siteFilter = Set(sitePresets.prefix(2)) }
            if category == .building { buildingFilter = ["North Campus"] }
            showingFilterConfig = true
        }
        #endif
        // Building and department names, for those filters and saved reports.
        .task { await locationLookup.loadIfNeeded() }
        .onReceive(computerCache.$computers) { _ in rebuildGroupLists() }
        .onReceive(mobileCache.$devices) { _ in rebuildGroupLists() }
        .alert("Error", isPresented: .init(
            get: { deviceLoadError != nil },
            set: { if !$0 { deviceLoadError = nil } }
        )) {
            Button("OK") { deviceLoadError = nil }
        } message: {
            Text(deviceLoadError ?? "Unknown error")
        }
    }
    
    // MARK: - Results Overlay (modal)

    private var resultsOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showingResults = false } }
            ReportResultsView(
                results: reportResults,
                exportFilename: exportFilename,
                makeExportTable: buildExportTable,
                isDark: isDark,
                onClose: { withAnimation(.easeInOut(duration: 0.2)) { showingResults = false } }
            )
            .frame(maxWidth: 1240, maxHeight: 840)
            .padding(28)
        }
        .transition(.opacity)
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Reports").font(.system(size: 28, weight: .bold)).foregroundColor(FleetHubTheme.ink)
                Text("\(totalDevices) devices in inventory").font(.system(size: 13)).foregroundColor(FleetHubTheme.muted)
            }
            Spacer()
        }.padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
    }
    
    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(ReportsTab.allCases) { tab in
                tabSegment(for: tab)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FleetHubTheme.trough)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private func tabSegment(for tab: ReportsTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
        } label: {
            HStack(spacing: 6) {
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .fixedSize()
                if tab == .saved && !allSavedReports.isEmpty {
                    Text("\(allSavedReports.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(FleetHubTheme.muted)
                }
            }
            .foregroundColor(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                    .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Report Builder Content
    
    private var reportBuilderContent: some View {
        ScrollView {
            // Filters to choose from on the left; the report being built —
            // platforms, scope, chosen filters, Run — on the right.
            Group {
                if builderWidth >= 980 {
                    HStack(alignment: .top, spacing: 20) {
                        builderFiltersCard
                            .frame(maxWidth: .infinity)
                        builderSummaryCard
                            .frame(width: 380)
                    }
                } else {
                    VStack(spacing: 20) {
                        builderSummaryCard
                        builderFiltersCard
                    }
                }
            }
            .readWidth(into: $builderWidth)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Saved Reports Content
    
    /// The DEBUG demo shows sample reports; the real saved reports on this
    /// Mac are neither shown nor changed while it runs.
    private var isDemo: Bool {
        #if DEBUG
        return DemoMode.isEnabled
        #else
        return false
        #endif
    }

    private var allSavedReports: [SavedReport] {
        #if DEBUG
        if DemoMode.isEnabled { return DemoMode.savedReports }
        #endif
        return savedReportsManager.savedReports
    }

    private var visibleSavedReports: [SavedReport] {
        let query = savedSearch.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allSavedReports }
        return allSavedReports.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    /// One to three equal columns, in explicit rows so every card in a row
    /// shares one height.
    private var savedColumnCount: Int {
        max(1, min(3, Int((savedWidth + 20) / 360)))
    }

    private var savedReportsContent: some View {
        let all = allSavedReports
        let visible = visibleSavedReports
        let columns = savedColumnCount
        let rows = stride(from: 0, to: visible.count, by: columns).map {
            Array(visible[$0..<min($0 + columns, visible.count)])
        }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if all.isEmpty {
                    reportsEmptyState(
                        icon: "bookmark",
                        title: "No Saved Reports",
                        message: "Build a report, then choose Save Report to keep its platforms, scope and filters here.",
                        buttonTitle: "Open Report Builder"
                    ) {
                        selectedTab = .builder
                    }
                } else {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(FleetHubTheme.muted)
                            TextField("", text: $savedSearch, prompt: Text("Search saved reports")
                                .foregroundColor(FleetHubTheme.muted))
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundStyle(FleetHubTheme.ink)
                            if !savedSearch.isEmpty {
                                Button {
                                    savedSearch = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(FleetHubTheme.muted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Clear search")
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .frame(maxWidth: 380)
                        .background(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .fill(FleetHubTheme.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .stroke(FleetHubTheme.border, lineWidth: 1)
                        )

                        Spacer(minLength: 8)

                        Text(visible.count == all.count
                             ? (all.count == 1 ? "1 Report" : "\(all.count) Reports")
                             : "\(visible.count) of \(all.count) Shown")
                            .font(.system(size: 13))
                            .monospacedDigit()
                            .foregroundStyle(FleetHubTheme.muted)
                    }

                    if visible.isEmpty {
                        reportsEmptyState(
                            icon: "magnifyingglass",
                            title: "No Matching Reports",
                            message: "Try a different name."
                        )
                    }

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 20) {
                            ForEach(row) { report in
                                SavedReportCard(report: report, canDelete: !isDemo) {
                                    loadSavedReport(report)
                                } onDelete: {
                                    guard !isDemo else { return }
                                    savedReportsManager.deleteReport(report)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            }
                            // Keep a short last row on the same column widths.
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .readWidth(into: $savedWidth)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    /// Empty-state card shared by the Saved Reports and Scheduled tabs.
    private func reportsEmptyState(
        icon: String,
        title: String,
        message: String,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(FleetHubTheme.ink)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            if let buttonTitle, let action {
                Button(action: action) {
                    SettingsButtonLabel(text: buttonTitle, kind: .primary)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .fleetHubCard()
    }

    private func loadSavedReport(_ report: SavedReport) {
        selectedPlatforms = report.platformTypes
        filters = report.filters
        deviceScope = report.deviceScope ?? .all
        individualQuery = report.individualQuery ?? ""
        includeEnrollment = report.includeEnrollment ?? false
        hasRunReport = false
        reportResults = []
        selectedTab = .builder
        if !isDemo {
            savedReportsManager.updateLastRun(report)
        }
    }

    // MARK: - Health Scorecard Content

    private var scorecardFilename: String {
        ExportNaming.filename(Branding.title, "Health-Scorecard", date: Date())
    }

    private var scorecardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Health Scorecard")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(FleetHubTheme.ink)
                        Text("Select a check to list the devices behind it.")
                            .font(.system(size: 13))
                            .foregroundColor(FleetHubTheme.muted)
                    }
                    Spacer(minLength: 8)
                    if !healthCalc.healthMetrics.isEmpty {
                        Text("\(HealthScorecardExportBuilder.pct(HealthScorecardExportBuilder.overallHealth())) Overall")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(FleetHubTheme.muted)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 8).fill(FleetHubTheme.surface))
                    }
                    ReportsExportMenu(
                        filename: scorecardFilename,
                        makeTable: { HealthScorecardExportBuilder.table(generatedAt: Date()) },
                        isDark: isDark,
                        prominent: true
                    )
                }

                if healthCalc.healthMetrics.isEmpty {
                    Text("No inventory loaded yet — open Overview or Devices to load data.")
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fleetHubCard()
                } else {
                    // One ring card per check. Widest arrangement that fits.
                    ViewThatFits(in: .horizontal) {
                        scorecardRingRow(healthCalc.healthMetrics)
                        VStack(spacing: 14) {
                            scorecardRingRow(Array(healthCalc.healthMetrics.prefix(3)))
                            scorecardRingRow(Array(healthCalc.healthMetrics.dropFirst(3)))
                        }
                    }

                    Group {
                        if scorecardWidth >= 980 {
                            HStack(alignment: .top, spacing: 20) {
                                scorecardDeviceTable
                                    .frame(maxWidth: .infinity)
                                scorecardOSCard
                                    .frame(width: 380)
                            }
                        } else {
                            VStack(spacing: 20) {
                                scorecardDeviceTable
                                scorecardOSCard
                            }
                        }
                    }
                    .readWidth(into: $scorecardWidth)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .onAppear {
            if healthCalc.healthMetrics.isEmpty { healthCalc.recalculateMetrics() }
        }
        // Builds the per-check index in the background: on first open, and
        // again whenever the metrics are recalculated. The page is on screen
        // straight away; the device table fills in when the index is ready.
        .task(id: healthCalc.lastCalculationDate) {
            await rebuildScorecardIndex()
        }
        .onChange(of: scorecardMetric) { _, _ in rebuildScorecardRows() }
        .onChange(of: scorecardSegment) { _, _ in rebuildScorecardRows() }
    }

    private func scorecardRingRow(_ metrics: [HealthMetricData]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(metrics) { metric in
                scorecardRingCard(metric)
                    .frame(minWidth: 196, maxWidth: .infinity)
            }
        }
    }

    private func scorecardRingCard(_ metric: HealthMetricData) -> some View {
        let isSelected = scorecardMetric == metric.type
        let color = metric.isConfigured
            ? HealthThresholds.color(forPercentage: metric.percentage, metricID: metric.type.configID)
            : FleetHubTheme.muted
        return Button {
            scorecardMetric = metric.type
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(FleetHubTheme.trough, lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: min(1, max(0, metric.percentage / 100)))
                            .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(metric.isConfigured ? "\(Int(metric.percentage.rounded()))%" : "—")
                            .font(.system(size: 16, weight: .bold))
                            .monospacedDigit()
                            .foregroundColor(FleetHubTheme.ink)
                    }
                    .frame(width: 68, height: 68)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(metric.effectiveTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(FleetHubTheme.ink)
                            .lineLimit(1)
                        Text(metric.isConfigured ? metric.type.compliantLabel : "Not scoped")
                            .font(.system(size: 12))
                            .foregroundColor(FleetHubTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 0) {
                    scorecardCount(metric.compliantCount, "Pass", FleetHubTheme.ink)
                    scorecardCount(metric.nonCompliantCount, "Fail",
                                   metric.nonCompliantCount > 0 ? FleetHubTheme.badText : FleetHubTheme.ink)
                    scorecardCount(metric.unknownCount, "Unknown", FleetHubTheme.ink)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func scorecardCount(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.formatted())
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(FleetHubTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // The devices behind the selected check.

    private var scorecardSegmentTitle: String {
        switch scorecardSegment {
        case .compliant: return scorecardMetric.compliantLabel
        case .nonCompliant: return scorecardMetric.nonCompliantLabel
        case .unknown: return scorecardMetric.unknownLabel
        }
    }

    private var scorecardDeviceTable: some View {
        // Sort the whole group, then show the first 50, so a header click
        // brings the true top of that order into view.
        let shown = Array(scorecardRows.sorted(by: scorecardSort) { item, column in
            switch column {
            case "User": .text(item.assignedUser)
            case "OS": .text(item.osVersion)
            case "Last Check-In": .date(item.lastCheckIn)
            // Most failing checks first when descending.
            case "Health Checks": .int(HealthMetricType.allCases.reduce(0) { $0 + ((scorecardFail[$1]?.contains(item.id) ?? false) ? 1 : 0) })
            default: .text(item.name)
            }
        }.prefix(50))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(scorecardSegmentTitle) · \(scorecardRows.count.formatted()) \(scorecardRows.count == 1 ? "Device" : "Devices")")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(FleetHubTheme.ink)
                    if scorecardRows.count > shown.count {
                        Text("Showing the first \(shown.count). Export for the full list.")
                            .font(.system(size: 12))
                            .foregroundColor(FleetHubTheme.muted)
                    }
                }
                if scorecardLoading {
                    ProgressView().controlSize(.small)
                    Text("Working Out Results…")
                        .font(.system(size: 12))
                        .foregroundColor(FleetHubTheme.muted)
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    scorecardSegmentButton("Failing", .nonCompliant)
                    scorecardSegmentButton("Unknown", .unknown)
                    scorecardSegmentButton("Passing", .compliant)
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(FleetHubTheme.trough))
            }
            .padding(.bottom, 12)

            ScorecardColumns(
                device: SortableHeaderText("Device", key: "Device", sort: $scorecardSort, fontSize: 12),
                user: SortableHeaderText("User", key: "User", sort: $scorecardSort, fontSize: 12),
                os: SortableHeaderText("OS", key: "OS", sort: $scorecardSort, fontSize: 12),
                checkIn: SortableHeaderText("Last Check-In", key: "Last Check-In", sort: $scorecardSort, fontSize: 12),
                checks: SortableHeaderText("Health Checks", key: "Health Checks", sort: $scorecardSort, fontSize: 12)
            )
            .padding(.vertical, 8)

            if shown.isEmpty {
                Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                Text("No devices in this group.")
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.muted)
                    .padding(.vertical, 20)
            } else {
                ForEach(shown) { item in
                    Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                    Button {
                        openScorecardDevice(item)
                    } label: {
                        ScorecardColumns(
                            device: VStack(alignment: .leading, spacing: 1) {
                                Text(item.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(FleetHubTheme.accent)
                                    .lineLimit(1)
                                Text(item.serialNumber)
                                    .font(.system(size: 11))
                                    .foregroundColor(FleetHubTheme.muted)
                                    .lineLimit(1)
                            },
                            user: scorecardCell(item.assignedUser ?? "—"),
                            os: scorecardCell(item.osVersion),
                            checkIn: scorecardCell(item.lastCheckIn?.formatted(.relative(presentation: .named)) ?? "Never"),
                            checks: HStack(spacing: 4) {
                                ForEach(HealthMetricType.allCases) { metric in
                                    scorecardCheckIcon(metric, for: item)
                                }
                                if scorecardOpeningID == item.id {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        )
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Checks, left to right: \(HealthMetricType.allCases.map(\.rawValue).joined(separator: ", ")). A tick passes, a cross fails, a dash is unknown or not measured.")
                .font(.system(size: 12))
                .foregroundColor(FleetHubTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
    }

    private func scorecardSegmentButton(_ title: String, _ segment: HealthSegmentType) -> some View {
        let isSelected = scorecardSegment == segment
        return Button {
            scorecardSegment = segment
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                        .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func scorecardCell(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(FleetHubTheme.ink)
            .lineLimit(1)
    }

    /// Tick, cross or dash for one check on one device. Shape carries the
    /// meaning as well as colour.
    private func scorecardCheckIcon(_ metric: HealthMetricType, for item: DeviceListItem) -> some View {
        let passes = scorecardPass[metric]?.contains(item.id) ?? false
        let fails = scorecardFail[metric]?.contains(item.id) ?? false
        let style: (icon: String, text: Color, fill: Color, word: String) = fails
            ? ("xmark", FleetHubTheme.badText, FleetHubTheme.badFill, "fails")
            : passes
                ? ("checkmark", FleetHubTheme.goodText, FleetHubTheme.goodFill, "passes")
                : ("minus", FleetHubTheme.muted, FleetHubTheme.trough, "unknown")
        return Image(systemName: style.icon)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(style.text)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(style.fill))
            .help("\(metric.rawValue): \(style.word)")
            .accessibilityLabel("\(metric.rawValue) \(style.word)")
    }

    private var scorecardOSCard: some View {
        let rows = scorecardOSRows.sorted(by: scorecardOSSort) { row, column in
            switch column {
            case "Total": .int(row.total)
            case "Managed": .int(row.managed)
            case "Unmanaged": .int(row.unmanaged)
            default: .text(row.label)
            }
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Managed Devices by OS")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(FleetHubTheme.ink)

            HStack {
                SortableHeaderText("OS", key: "OS", sort: $scorecardOSSort, fontSize: 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SortableHeaderText("Total", key: "Total", sort: $scorecardOSSort, fontSize: 12)
                    .frame(width: 66, alignment: .trailing)
                SortableHeaderText("Managed", key: "Managed", sort: $scorecardOSSort, fontSize: 12)
                    .frame(width: 80, alignment: .trailing)
                SortableHeaderText("Unmanaged", key: "Unmanaged", sort: $scorecardOSSort, fontSize: 12)
                    .frame(width: 94, alignment: .trailing)
            }

            if rows.isEmpty {
                Text("No devices in inventory.")
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.muted)
            } else {
                ForEach(rows) { row in
                    Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                    HStack {
                        Text(row.label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(FleetHubTheme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.total.formatted()).frame(width: 66, alignment: .trailing)
                        Text(row.managed.formatted()).frame(width: 80, alignment: .trailing)
                        Text(row.unmanaged.formatted())
                            .foregroundColor(row.unmanaged > 0 ? FleetHubTheme.warnText : FleetHubTheme.muted)
                            .frame(width: 94, alignment: .trailing)
                    }
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundColor(FleetHubTheme.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
        .textSelection(.enabled)
    }

    /// Rows for the selected check and group, from the index: only the
    /// devices shown are converted, and nothing is re-evaluated.
    private func rebuildScorecardRows() {
        scorecardRows = healthCalc.deviceItems(withIDs: scorecardIndex.ids(scorecardMetric, scorecardSegment))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func rebuildScorecardIndex() async {
        scorecardLoading = scorecardIndex.calculatedAt == nil
        let index = await healthCalc.scorecardIndex()
        guard !Task.isCancelled else { return }
        scorecardIndex = index
        var pass: [HealthMetricType: Set<String>] = [:]
        var fail: [HealthMetricType: Set<String>] = [:]
        for metric in HealthMetricType.allCases {
            pass[metric] = index.ids(metric, .compliant)
            fail[metric] = index.ids(metric, .nonCompliant)
        }
        scorecardPass = pass
        scorecardFail = fail
        scorecardOSRows = HealthScorecardExportBuilder.osBreakdown()
        rebuildScorecardRows()
        scorecardLoading = false
        #if DEBUG
        // Test aid: the background index must agree with the original
        // per-list evaluation for every check and group.
        if ProcessInfo.processInfo.arguments.contains("-FleetHubTourTabs") {
            var mismatches = 0
            for metric in HealthMetricType.allCases {
                for segment in HealthSegmentType.allCases
                where Set(healthCalc.getFilteredDevices(for: metric, segment: segment).map(\.id)) != index.ids(metric, segment) {
                    mismatches += 1
                }
            }
            NSLog("SCORECARD INDEX CHECK: %@ (%d rows shown)", mismatches == 0 ? "matches" : "\(mismatches) MISMATCHES", scorecardRows.count)
        }
        #endif
    }

    /// Opens a device from the scorecard table in this tab's own stack.
    private func openScorecardDevice(_ item: DeviceListItem) {
        if item.platform == .macOS {
            navigationPath.append(Computer.fromDeviceListItem(item))
            return
        }
        #if DEBUG
        if DemoMode.isEnabled, let demo = DemoMode.mobileDevice(id: item.originalId) {
            navigationPath.append(demo)
            return
        }
        #endif
        guard scorecardOpeningID == nil else { return }
        scorecardOpeningID = item.id
        Task {
            do {
                navigationPath.append(try await DeviceListView.fetchMobileDeviceDetail(id: item.originalId))
            } catch {
                deviceLoadError = "Could not open \(item.name): \(error.localizedDescription)"
            }
            scorecardOpeningID = nil
        }
    }


    // MARK: - Builder: Filters

    private var builderFiltersCard: some View {
        let columnCount = builderWidth >= 1280 ? 4 : 3
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add Filters")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(FleetHubTheme.ink)
                Text("Choose what the devices in the report must match. Each filter you add narrows the result.")
                    .font(.system(size: 13))
                    .foregroundColor(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount), spacing: 12) {
                ForEach(ReportFilterCategory.allCases) { category in
                    filterCategoryCard(category)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
    }

    private func filterCategoryCard(_ category: ReportFilterCategory) -> some View {
        let active = filters.contains { $0.category == category }
        return Button {
            selectedFilterCategory = category
            resetFilterParams(category)
            withAnimation { showingFilterConfig = true }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: category.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(category.color)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(category.color.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(FleetHubTheme.ink)
                        .lineLimit(1)
                    Text(category.description)
                        .font(.system(size: 12))
                        .foregroundColor(FleetHubTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 4)

                Image(systemName: active ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 16))
                    .foregroundColor(active ? FleetHubTheme.accent : FleetHubTheme.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(FleetHubTheme.ground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(active ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: active ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(category.rawValue). \(category.description)\(active ? ". Added" : "")")
    }

    // MARK: - Builder: Your Report

    private func builderLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundColor(FleetHubTheme.muted)
    }

    private var builderSummaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your Report")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(FleetHubTheme.ink)

            // Platforms
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    builderLabel("Platforms")
                    Spacer()
                    Button("Select All") {
                        selectedPlatforms = Set(PlatformType.displayCases)
                        hasRunReport = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FleetHubTheme.accent)
                }
                FlowLayout(spacing: 6) {
                    ForEach(PlatformType.displayCases) { platform in
                        platformTag(platform)
                    }
                }
            }

            // Scope
            VStack(alignment: .leading, spacing: 8) {
                builderLabel("Scope")
                HStack(spacing: 4) {
                    ForEach(DeviceScope.allCases) { scope in
                        let isSelected = deviceScope == scope
                        Button {
                            deviceScope = scope
                            hasRunReport = false
                        } label: {
                            Text(scope.rawValue)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(isSelected ? FleetHubTheme.ink : FleetHubTheme.control)
                                .frame(maxWidth: .infinity)
                                .frame(height: 30)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(isSelected ? FleetHubTheme.surface : Color.clear)
                                        .shadow(color: .black.opacity(isSelected ? 0.12 : 0), radius: 1, y: 1)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(FleetHubTheme.trough))

                if deviceScope == .individual {
                    TextField("", text: $individualQuery, prompt: Text("Serial number or asset tag")
                        .foregroundColor(FleetHubTheme.muted))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.ink)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .overlay(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .stroke(FleetHubTheme.border, lineWidth: 1)
                        )
                        .onChange(of: individualQuery) { hasRunReport = false }
                }
            }

            // Enrollment details
            Toggle(isOn: $includeEnrollment) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Enrollment Details")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FleetHubTheme.ink)
                    Text("Adds each device's Automated Device Enrollment record, and lists ADE serials that aren't in Jamf.")
                        .font(.system(size: 12))
                        .foregroundColor(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: includeEnrollment) { hasRunReport = false }

            // Chosen filters
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    builderLabel(filters.isEmpty ? "Filters" : "Filters · \(filters.count)")
                    Spacer()
                    if !filters.isEmpty {
                        Button("Clear All") {
                            filters.removeAll()
                            hasRunReport = false
                            reportResults = []
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(FleetHubTheme.badText)
                    }
                }
                if filters.isEmpty {
                    Text("None yet. The report will include every device in scope.")
                        .font(.system(size: 13))
                        .foregroundColor(FleetHubTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(filters) { filter in
                            filterTag(filter)
                        }
                    }
                }
            }

            // Run / Save
            VStack(spacing: 8) {
                Button { runReport() } label: {
                    HStack(spacing: 8) {
                        if isRunningReport {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 12))
                        }
                        Text("Run Report").font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                            .fill(FleetHubTheme.accentFill)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isRunningReport)

                if !filters.isEmpty {
                    Button { showingSaveDialog = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bookmark").font(.system(size: 12))
                            Text("Save Report").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(FleetHubTheme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                                .stroke(FleetHubTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fleetHubCard()
    }

    private func platformTag(_ platform: PlatformType) -> some View {
        let selected = selectedPlatforms.contains(platform)
        return Button {
            // At least one platform always stays selected.
            if selected { if selectedPlatforms.count > 1 { selectedPlatforms.remove(platform) } }
            else { selectedPlatforms.insert(platform) }
            hasRunReport = false
        } label: {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark" : platform.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(platform.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .fixedSize()
            }
            .foregroundColor(selected ? .white : FleetHubTheme.control)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(selected ? FleetHubTheme.accentFill : FleetHubTheme.surface))
            .overlay(Capsule().stroke(selected ? Color.clear : FleetHubTheme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func filterTag(_ filter: ReportFilter) -> some View {
        HStack(spacing: 8) {
            Image(systemName: filter.category.icon)
                .font(.system(size: 12))
                .foregroundColor(filter.category.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(filter.category.rawValue)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FleetHubTheme.ink)
                Text(filter.displayDescription)
                    .font(.system(size: 12))
                    .foregroundColor(FleetHubTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button {
                filters.removeAll { $0.id == filter.id }
                hasRunReport = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(FleetHubTheme.muted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(filter.category.rawValue) filter")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(FleetHubTheme.ground)
        )
    }

    // MARK: - Save Report Overlay
    
    private var saveReportOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { showingSaveDialog = false }

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Save Report")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(FleetHubTheme.ink)
                        Text("Keep this report's platforms, scope and filters for quick access.")
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    SettingsLabelled(label: "Name") {
                        TextField("", text: $saveReportName, prompt: Text("Report name").foregroundColor(FleetHubTheme.muted))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .settingsFieldBox()
                    }

                    SettingsLabelled(label: "Description (Optional)") {
                        TextField("", text: $saveReportDescription, prompt: Text("Brief description").foregroundColor(FleetHubTheme.muted))
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .settingsFieldBox()
                    }

                    HStack(spacing: 6) {
                        SettingsTag(text: selectedPlatforms.count == 1 ? "1 Platform" : "\(selectedPlatforms.count) Platforms")
                        SettingsTag(text: filters.count == 1 ? "1 Filter" : "\(filters.count) Filters")
                        SettingsTag(text: deviceScope.rawValue)
                    }
                }
                .padding(24)

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button { showingSaveDialog = false; saveReportName = ""; saveReportDescription = "" } label: {
                        SettingsButtonLabel(text: "Cancel")
                    }
                    .buttonStyle(.plain)
                    Button {
                        let report = SavedReport(name: saveReportName.isEmpty ? "Untitled Report" : saveReportName, description: saveReportDescription, platforms: selectedPlatforms, filters: filters, deviceScope: deviceScope, individualQuery: individualQuery, includeEnrollment: includeEnrollment)
                        savedReportsManager.saveReport(report)
                        showingSaveDialog = false
                        saveReportName = ""
                        saveReportDescription = ""
                    } label: {
                        SettingsButtonLabel(text: "Save Report", kind: .primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background(FleetHubTheme.ground)
                .overlay(alignment: .top) {
                    Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                }
            }
            .frame(width: 460)
            .background(FleetHubTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        }
    }

    // MARK: - Filter Config Overlay
    
    private var filterConfigOverlay: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { withAnimation { showingFilterConfig = false } }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: selectedFilterCategory.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(FleetHubTheme.accent)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(FleetHubTheme.accent.opacity(0.12))
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedFilterCategory.rawValue)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(FleetHubTheme.ink)
                        Text("Set up this filter, then add it to your report.")
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 8)

                ScrollView { VStack(alignment: .leading, spacing: 20) { filterConfigContent }.padding(24) }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button { withAnimation { showingFilterConfig = false } } label: {
                        SettingsButtonLabel(text: "Cancel")
                    }
                    .buttonStyle(.plain)
                    Button { addFilter(); withAnimation { showingFilterConfig = false } } label: {
                        SettingsButtonLabel(text: "Add Filter", kind: .primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .frame(height: 64)
                .background(FleetHubTheme.ground)
                .overlay(alignment: .top) {
                    Rectangle().fill(FleetHubTheme.border).frame(height: 1)
                }
            }
            .frame(width: 580, height: selectedFilterCategory.configOverlayHeight)
            .background(FleetHubTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        }
    }

    @ViewBuilder
    private var filterConfigContent: some View {
        switch selectedFilterCategory {
        case .lastCheckIn:
            VStack(alignment: .leading, spacing: 16) {
                Text("Find devices that checked in:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                
                HStack(spacing: 20) {
                    Picker("", selection: $timeComparison) { ForEach(TimeRangeComparison.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    
                    TextField("", value: $timeValue, format: .number)
                        .textFieldStyle(.plain)
                        .frame(width: 50)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 13)).settingsFieldBox()
                    
                    Picker("", selection: $timeUnit) { ForEach(TimeRangeUnit.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                        .frame(width: 240)
                }
                
                previewBox("\(timeComparison.rawValue) \(timeValue) \(timeUnit.rawValue.lowercased()) ago")
            }
        case .supervision:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by supervision status:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                VStack(spacing: 8) { ForEach(SupervisionFilter.allCases) { f in radioButton(f.rawValue, selected: supervisionFilter == f) { supervisionFilter = f } } }
                previewBox(supervisionFilter.rawValue)
            }
        case .encryption:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by encryption (FileVault):").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                VStack(spacing: 8) { ForEach(EncryptionFilter.allCases) { f in radioButton(f.rawValue, selected: encryptionFilter == f) { encryptionFilter = f } } }
                previewBox(encryptionFilter.rawValue)
            }
        case .osVersion:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by OS version:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                HStack(spacing: 12) {
                    Picker("", selection: $osVersionComparison) { Text("At least").tag("At least"); Text("Exactly").tag("Exactly"); Text("Below").tag("Below") }.pickerStyle(.segmented).frame(width: 200)
                    TextField("", text: $osVersion).textFieldStyle(.plain).frame(width: 80).font(.system(size: 13)).settingsFieldBox()
                }
                HStack(spacing: 8) { ForEach(["26.0", "15.0", "14.0"], id: \.self) { v in Button { osVersion = v } label: { Text(v).font(.system(size: 12)).foregroundColor(osVersion == v ? .white : FleetHubTheme.control).padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(osVersion == v ? FleetHubTheme.accentFill : FleetHubTheme.trough)) }.buttonStyle(.plain) } }
                previewBox("\(osVersionComparison) \(osVersion)")
            }
        case .model:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by model:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                TextField("e.g. MacBookPro", text: $modelIdentifier).textFieldStyle(.plain).font(.system(size: 13)).settingsFieldBox()
                HStack(spacing: 8) { ForEach(["MacBookPro", "MacBookAir", "iMac", "iPhone", "iPad", "RealityDevice"], id: \.self) { m in Button { modelIdentifier = m } label: { Text(m == "RealityDevice" ? "Vision Pro" : m).font(.system(size: 12)).foregroundColor(modelIdentifier == m ? .white : FleetHubTheme.control).padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(modelIdentifier == m ? FleetHubTheme.accentFill : FleetHubTheme.trough)) }.buttonStyle(.plain) } }
                if !modelIdentifier.isEmpty { previewBox("Model contains: \(modelIdentifier)") }
            }
        case .site:
            locationEditor(title: "Filter by site:", noun: "sites", options: sitePresets,
                           comparison: $siteFilterComparison, selection: $siteFilter,
                           include: "Member of", exclude: "Not member of")
        case .building:
            locationEditor(title: "Filter by building:", noun: "buildings",
                           options: buildingOptions,
                           comparison: $buildingFilterComparison, selection: $buildingFilter,
                           include: "In", exclude: "Not in", note: locationLookup.problem)
                .task(id: locationOptionsKey) {
                    await locationLookup.loadIfNeeded()
                    buildingOptions = detectedLocations(buildingLabel)
                }
        case .department:
            locationEditor(title: "Filter by department:", noun: "departments",
                           options: departmentOptions,
                           comparison: $departmentFilterComparison, selection: $departmentFilter,
                           include: "In", exclude: "Not in", note: locationLookup.problem)
                .task(id: locationOptionsKey) {
                    await locationLookup.loadIfNeeded()
                    departmentOptions = detectedLocations(departmentLabel)
                }

        case .applications:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by applications:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                
                HStack(spacing: 12) {
                    Picker("", selection: $applicationFilterType) {
                        ForEach(ApplicationFilterType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }
                
                TextField("Application name", text: $applicationName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13)).settingsFieldBox()
                
                HStack(spacing: 8) {
                    ForEach(applicationPresets, id: \.self) { app in
                        Button { applicationName = app } label: {
                            Text(app)
                                .font(.system(size: 11))
                                .foregroundColor(applicationName == app ? .white : FleetHubTheme.control)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(applicationName == app ? FleetHubTheme.accentFill : FleetHubTheme.trough))
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                if !applicationName.isEmpty {
                    previewBox("\(applicationFilterType.rawValue): \(applicationName)")
                }
            }
        case .appleCare:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by AppleCare coverage:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                
                VStack(spacing: 8) {
                    ForEach(AppleCareFilter.allCases) { filter in
                        radioButton(filter.rawValue, selected: appleCareFilter == filter) {
                            appleCareFilter = filter
                        }
                    }
                }
                
                previewBox(appleCareFilter.rawValue)
                
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(FleetHubTheme.muted)
                    Text("Uses Jamf Purchasing data (vendor & warrantyDate fields)")
                        .font(.system(size: 11))
                        .foregroundColor(FleetHubTheme.muted)
                }
                .padding(.top, 4)
            }
        case .softwareUpdates:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by software update status:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                
                VStack(spacing: 8) {
                    ForEach(SoftwareUpdateFilter.allCases) { filter in
                        radioButton(filter.rawValue, selected: softwareUpdateFilter == filter) {
                            softwareUpdateFilter = filter
                        }
                    }
                }
                
                previewBox(softwareUpdateFilter.rawValue)
                
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundColor(FleetHubTheme.muted)
                    Text("Uses availableSoftwareUpdates from device inventory (macOS only)")
                        .font(.system(size: 11))
                        .foregroundColor(FleetHubTheme.muted)
                }
                .padding(.top, 4)
            }
        case .staleDevices:
            VStack(alignment: .leading, spacing: 16) {
                Text("Find devices that haven't checked in for:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                VStack(spacing: 8) {
                    ForEach(StalenessLevel.allCases) { level in
                        radioButton(level.rawValue, selected: stalenessLevel == level) { stalenessLevel = level }
                    }
                }
                previewBox(stalenessLevel.rawValue)
            }
        case .unmanaged:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by MDM management status:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                VStack(spacing: 8) {
                    ForEach(ManagedFilter.allCases) { filter in
                        radioButton(filter.rawValue, selected: managedFilter == filter) { managedFilter = filter }
                    }
                }
                previewBox(managedFilter.rawValue)
            }
        case .protectCoverage:
            VStack(alignment: .leading, spacing: 16) {
                Text("Filter by Jamf Protect coverage:").font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                VStack(spacing: 8) {
                    ForEach(ProtectCoverageFilter.allCases) { filter in
                        radioButton(filter.rawValue, selected: protectCoverageFilter == filter) { protectCoverageFilter = filter }
                    }
                }
                previewBox(protectCoverageFilter.rawValue)
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(FleetHubTheme.muted)
                    Text("Matched by serial against your Jamf Protect tenant (macOS only). Configure Protect in Settings → Credentials.").font(.system(size: 11)).foregroundColor(FleetHubTheme.muted)
                }
                .padding(.top, 4)
            }
        case .computerGroup:
            groupPicker(
                title: "Filter macOS devices by computer group:",
                prompt: "Search computer groups…",
                query: $computerGroupQuery,
                selection: $computerGroupSelection,
                groups: computerGroupList,
                emptyNote: "No computer groups loaded. Refresh your computer inventory to load group memberships."
            )
        case .deviceGroup:
            groupPicker(
                title: "Filter mobile devices by device group:",
                prompt: "Search device groups…",
                query: $deviceGroupQuery,
                selection: $deviceGroupSelection,
                groups: deviceGroupList,
                emptyNote: "No device groups loaded. Load your mobile device inventory first."
            )
        }
    }

    private func groupPicker(
        title: String,
        prompt: String,
        query: Binding<String>,
        selection: Binding<String>,
        groups: [(name: String, smart: Bool)],
        emptyNote: String
    ) -> some View {
        let q = query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? groups : groups.filter { $0.name.lowercased().contains(q) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
            TextField(prompt, text: query)
                .textFieldStyle(.plain).font(.system(size: 14)).font(.system(size: 13)).settingsFieldBox()
            if groups.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 11)).foregroundColor(FleetHubTheme.muted)
                    Text(emptyNote).font(.system(size: 11)).foregroundColor(FleetHubTheme.muted)
                }.padding(.top, 4)
            } else if filtered.isEmpty {
                Text("No groups match your search.").font(.system(size: 12)).foregroundColor(FleetHubTheme.muted).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(filtered, id: \.name) { group in
                            Button { selection.wrappedValue = group.name } label: {
                                HStack {
                                    Image(systemName: selection.wrappedValue == group.name ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selection.wrappedValue == group.name ? FleetHubTheme.accent : FleetHubTheme.muted)
                                    Text(group.name).font(.system(size: 13)).foregroundColor(FleetHubTheme.ink).lineLimit(1)
                                    Spacer()
                                    SettingsTag(text: group.smart ? "Smart" : "Static", tone: group.smart ? .accent : .neutral)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selection.wrappedValue == group.name ? FleetHubTheme.accent.opacity(0.12) : Color.clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
                if !selection.wrappedValue.isEmpty { previewBox(selection.wrappedValue) }
            }
        }
    }

    private func radioButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(selected ? FleetHubTheme.accent : FleetHubTheme.muted)
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(FleetHubTheme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .fill(selected ? FleetHubTheme.accent.opacity(0.10) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(selected ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func previewBox(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Matches:")
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.muted)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous).fill(FleetHubTheme.ground))
    }

    // MARK: - Helpers
    
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous).fill(FleetHubTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous).stroke(FleetHubTheme.border, lineWidth: 1))
    }

    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(color)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
        }
    }

    /// A card whose content collapses behind a tappable header + chevron.
    private func collapsibleCard<Trailing: View, Content: View>(
        _ title: String,
        icon: String,
        color: Color,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.wrappedValue.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(color)
                            Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(FleetHubTheme.ink)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(FleetHubTheme.muted)
                                .rotationEffect(.degrees(isExpanded.wrappedValue ? 0 : -90))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    trailing()
                }
                if isExpanded.wrappedValue {
                    content()
                }
            }
        }
    }
    
    private func resetFilterParams(_ cat: ReportFilterCategory) {
        switch cat {
        case .lastCheckIn: timeComparison = .within; timeValue = 7; timeUnit = .days
        case .supervision: supervisionFilter = .supervised
        case .encryption: encryptionFilter = .encrypted
        case .osVersion: osVersionComparison = "At least"; osVersion = "26.0"
        case .model: modelIdentifier = ""
        case .site: siteFilter = []; siteFilterComparison = .memberOf; locationQuery = ""
        case .building: buildingFilter = []; buildingFilterComparison = .memberOf; locationQuery = ""
        case .department: departmentFilter = []; departmentFilterComparison = .memberOf; locationQuery = ""
        case .applications: applicationFilterType = .hasApp; applicationName = ""
        case .appleCare: appleCareFilter = .active
        case .softwareUpdates: softwareUpdateFilter = .hasPendingUpdates
        case .staleDevices: stalenessLevel = .over90
        case .unmanaged: managedFilter = .unmanagedOnly
        case .protectCoverage: protectCoverageFilter = .covered
        case .computerGroup: computerGroupSelection = ""; computerGroupQuery = ""
        case .deviceGroup: deviceGroupSelection = ""; deviceGroupQuery = ""
        }
    }
    
    private func addFilter() {
        let f: ReportFilter
        switch selectedFilterCategory {
        case .lastCheckIn: f = ReportFilter(category: selectedFilterCategory, parameters: .lastCheckIn(comparison: timeComparison, value: timeValue, unit: timeUnit))
        case .supervision: f = ReportFilter(category: selectedFilterCategory, parameters: .supervision(status: supervisionFilter))
        case .encryption: f = ReportFilter(category: selectedFilterCategory, parameters: .encryption(status: encryptionFilter))
        case .osVersion: f = ReportFilter(category: selectedFilterCategory, parameters: .osVersion(version: osVersion, comparison: osVersionComparison))
        case .model: guard !modelIdentifier.isEmpty else { return }; f = ReportFilter(category: selectedFilterCategory, parameters: .model(identifier: modelIdentifier))
        case .site: guard !siteFilter.isEmpty else { return }; f = ReportFilter(category: selectedFilterCategory, parameters: .site(name: ReportFilter.store(siteFilter), comparison: siteFilterComparison))
        case .building: guard !buildingFilter.isEmpty else { return }; f = ReportFilter(category: selectedFilterCategory, parameters: .building(name: ReportFilter.store(buildingFilter), comparison: buildingFilterComparison))
        case .department: guard !departmentFilter.isEmpty else { return }; f = ReportFilter(category: selectedFilterCategory, parameters: .department(name: ReportFilter.store(departmentFilter), comparison: departmentFilterComparison))
        case .applications: guard !applicationName.isEmpty else { return }; f = ReportFilter(category: selectedFilterCategory, parameters: .applications(type: applicationFilterType, appName: applicationName))
        case .appleCare: f = ReportFilter(category: selectedFilterCategory, parameters: .appleCare(status: appleCareFilter))
        case .softwareUpdates: f = ReportFilter(category: selectedFilterCategory, parameters: .softwareUpdates(status: softwareUpdateFilter))
        case .staleDevices: f = ReportFilter(category: selectedFilterCategory, parameters: .staleDevices(level: stalenessLevel))
        case .unmanaged: f = ReportFilter(category: selectedFilterCategory, parameters: .unmanaged(status: managedFilter))
        case .protectCoverage: f = ReportFilter(category: selectedFilterCategory, parameters: .protectCoverage(status: protectCoverageFilter))
        case .computerGroup: guard !computerGroupSelection.isEmpty else { return }; f = ReportFilter(category: selectedFilterCategory, parameters: .computerGroup(name: computerGroupSelection))
        case .deviceGroup: guard !deviceGroupSelection.isEmpty else { return }; f = ReportFilter(category: selectedFilterCategory, parameters: .deviceGroup(name: deviceGroupSelection))
        }
        filters.removeAll { $0.category == selectedFilterCategory }
        filters.append(f)
        hasRunReport = false
    }
    
    // MARK: - Export

    private var exportFilename: String {
        ExportNaming.filename(Branding.title, "Device-Report", date: Date())
    }

    private func buildExportTable() -> ReportTable {
        ReportsExportBuilder.table(
            results: reportResults,
            platforms: selectedPlatforms,
            filters: filters,
            scope: deviceScope,
            individualQuery: individualQuery,
            includeEnrollment: includeEnrollment,
            generatedAt: Date()
        )
    }

    // MARK: - Run Report

    private func runReport() {
        isRunningReport = true
        Task {
            // Index the fleet once so every filter is a dictionary lookup.
            computerIndex = Dictionary(computerCache.computers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            mobileIndex = Dictionary(mobileCache.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

            // Any data that must be fetched (not in the caches) is loaded first.
            await loadProtectDataIfNeeded()
            if deviceScope == .individual { EnrollmentService.shared.buildAssetTagMapping() }

            var enrollment: EnrollmentAggregate?
            if includeEnrollment {
                do {
                    enrollment = try await EnrollmentService.shared.fetchAllInstancesDevices()
                } catch {
                    deviceLoadError = "Failed to load Device Enrollment data: \(error.localizedDescription)"
                }
            }

            var results: [ReportDeviceResult] = []
            if selectedPlatforms.contains(.macOS) { results.append(contentsOf: computerCache.computers.map { ReportDeviceResult(from: $0) }) }
            if selectedPlatforms.contains(.iOS) { results.append(contentsOf: mobileCache.devices.filter { $0.platformType == .iOS }.map { ReportDeviceResult(from: $0) }) }
            if selectedPlatforms.contains(.iPadOS) { results.append(contentsOf: mobileCache.devices.filter { $0.platformType == .iPadOS }.map { ReportDeviceResult(from: $0) }) }
            if selectedPlatforms.contains(.visionOS) { results.append(contentsOf: mobileCache.devices.filter { $0.platformType == .visionOS }.map { ReportDeviceResult(from: $0) }) }

            results = applyScope(to: results)
            for f in filters {
                results = applyFilter(f, to: results)
                await Task.yield()   // keep the UI responsive between passes
            }

            // Attach enrollment records to matched devices, and surface ADE-only
            // (not-in-Jamf) serials. Orphans have no Jamf inventory to satisfy
            // content filters, so they're only appended for an unfiltered device
            // report — a filtered (compliance) query stays internally consistent
            // with its "Filters applied" preamble.
            if includeEnrollment, let agg = enrollment {
                results = results.map { attachEnrollment($0, from: agg) }
                if filters.isEmpty {
                    results.append(contentsOf: orphanRows(from: agg))
                }
            }

            reportResults = results
            hasRunReport = true
            isRunningReport = false
            withAnimation(.easeInOut(duration: 0.2)) { showingResults = true }
        }
    }

    /// Narrow the base device set by the selected scope (all device / one device).
    private func applyScope(to r: [ReportDeviceResult]) -> [ReportDeviceResult] {
        switch deviceScope {
        case .all:
            return r
        case .individual:
            let q = individualQuery.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !q.isEmpty else { return r }
            return r.filter {
                $0.serialNumber.uppercased() == q
                    || EnrollmentService.shared.assetTag(forSerial: $0.serialNumber)?.uppercased() == q
            }
        }
    }

    /// Attach a device's Device Enrollment record (matched by serial) if present.
    private func attachEnrollment(_ device: ReportDeviceResult, from agg: EnrollmentAggregate) -> ReportDeviceResult {
        var d = device
        let key = device.serialNumber.uppercased()
        guard key != "N/A", key != "—", !key.isEmpty, let record = agg.bySerial[key] else { return d }
        d.enrollment = record
        d.enrollmentInstanceName = agg.instanceName(for: record)
        return d
    }

    /// Rows for Device Enrollment serials that have no Jamf inventory record,
    /// respecting the active scope and platform selection.
    private func orphanRows(from agg: EnrollmentAggregate) -> [ReportDeviceResult] {
        var jamfSerials = Set(computerCache.computers.compactMap { $0.hardware?.serialNumber?.uppercased() })
        jamfSerials.formUnion(mobileCache.devices.compactMap { $0.serialNumber?.uppercased() })
        let individualQ = individualQuery.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        return agg.bySerial.values.compactMap { record -> ReportDeviceResult? in
            let key = record.serialNumber.uppercased()
            guard !key.isEmpty, !jamfSerials.contains(key) else { return nil }
            let orphan = ReportDeviceResult(
                orphan: record,
                siteId: agg.instanceSiteId(for: record) ?? "",
                instanceName: agg.instanceName(for: record)
            )
            guard selectedPlatforms.contains(orphan.platform) else { return nil }
            switch deviceScope {
            case .all:
                return orphan
            case .individual:
                guard !individualQ.isEmpty else { return nil }
                return key == individualQ ? orphan : nil
            }
        }
        .sorted { $0.serialNumber < $1.serialNumber }
    }

    /// If a Jamf Protect coverage filter is active, fetch the Protect computer
    /// list once and index it by serial (plus a stale subset). Failures surface
    /// via the device-load error alert and leave the sets empty (so those
    /// devices read as "not covered" rather than silently disappearing).
    private func loadProtectDataIfNeeded() async {
        let needsProtect = filters.contains {
            if case .protectCoverage = $0.parameters { return true }
            return false
        }
        guard needsProtect else { return }

        let settings = CleanupSettings()
        guard let client = settings.makeProtectClient() else {
            protectSerials = []
            protectStaleSerials = []
            deviceLoadError = "Jamf Protect isn't configured. Add it in Settings → Cleanup to use the Protect coverage filter."
            return
        }
        do {
            let devices = try await client.fetchAllComputers()
            await client.invalidate()
            let cutoff = Date().addingTimeInterval(-Double(settings.staleDays) * 86_400)
            func normalized(_ list: [ProtectDevice]) -> Set<String> {
                Set(list.map { $0.serial.uppercased() }.filter { !$0.isEmpty && $0 != "—" })
            }
            protectSerials = normalized(devices)
            protectStaleSerials = normalized(devices.filter { ($0.checkin ?? .distantPast) < cutoff })
        } catch {
            protectSerials = []
            protectStaleSerials = []
            deviceLoadError = "Failed to load Jamf Protect data: \(error.localizedDescription)"
        }
    }
    
    private func applyFilter(_ f: ReportFilter, to r: [ReportDeviceResult]) -> [ReportDeviceResult] {
        switch f.parameters {
        case .lastCheckIn(let cmp, let val, let unit):
            let cutoff = Date().addingTimeInterval(-Double(val) * unit.seconds)
            return r.filter { d in guard let lc = d.lastCheckIn else { return cmp == .moreThan }; return cmp == .within ? lc >= cutoff : lc < cutoff }
        case .supervision(let s): return s == .all ? r : r.filter { s == .supervised ? $0.isSupervised : !$0.isSupervised }
        case .encryption(let s): return s == .all ? r : r.filter { s == .encrypted ? $0.isEncrypted : !$0.isEncrypted }
        case .osVersion(let v, let cmp):
            return r.filter { d in guard d.osVersion != "Unknown" else { return false }; let c = d.osVersion.compare(v, options: .numeric); return cmp == "At least" ? c != .orderedAscending : (cmp == "Exactly" ? c == .orderedSame : c == .orderedAscending) }
        case .model(let id): return r.filter { $0.model.localizedCaseInsensitiveContains(id) }
        case .site(let stored, let comparison):
            let names = siteNamesByID
            let wanted = ReportFilter.names(in: stored).map { $0.lowercased() }
            let labels = r.map { siteLabel($0, names: names).lowercased() }
            let known = Set(labels)
            return zip(r, labels).filter { _, label in
                // A site chosen from the list matches by its whole name. A
                // report saved with part of a name still matches as it did.
                let matches = wanted.contains { want in
                    known.contains(want) || want == "none" ? label == want : label.contains(want)
                }
                return comparison == .memberOf ? matches : !matches
            }.map(\.0)
        case .building(let stored, let comparison):
            let wanted = Set(ReportFilter.names(in: stored).map { $0.lowercased() })
            return r.filter {
                let matches = wanted.contains(buildingLabel($0).lowercased())
                return comparison == .memberOf ? matches : !matches
            }
        case .department(let stored, let comparison):
            let wanted = Set(ReportFilter.names(in: stored).map { $0.lowercased() })
            return r.filter {
                let matches = wanted.contains(departmentLabel($0).lowercased())
                return comparison == .memberOf ? matches : !matches
            }
        case .applications(let type, let appName):
            return r.filter { device in
                guard device.platform == .macOS else { return type == .missingApp }
                guard let computer = computerIndex[device.id] else { return type == .missingApp }
                let hasApp = computer.hasAppInstalled(appName)
                return type == .hasApp ? hasApp : !hasApp
            }
        case .appleCare(let status):
            return r.filter { device in
                let coverageInfo = getDeviceCoverageInfo(device)
                switch status {
                case .all: return true
                case .active: return coverageInfo.hasData && !coverageInfo.isExpired && !coverageInfo.isExpiringSoon
                case .expiringSoon: return coverageInfo.hasData && coverageInfo.isExpiringSoon
                case .expired: return coverageInfo.hasData && coverageInfo.isExpired
                case .noCoverage: return !coverageInfo.hasData
                }
            }
        case .softwareUpdates(let status):
            return r.filter { device in
                let updateInfo = getDeviceSoftwareUpdateInfo(device)
                switch status {
                case .all: return true
                case .hasPendingUpdates: return updateInfo.hasData && updateInfo.pendingCount > 0
                case .noPendingUpdates: return updateInfo.hasData && updateInfo.pendingCount == 0
                case .noUpdateData: return !updateInfo.hasData
                }
            }
        case .staleDevices(let level):
            let cutoff = Date().addingTimeInterval(-Double(level.days) * 86400)
            return r.filter { device in
                guard let lc = device.lastCheckIn else { return true }  // never checked in counts as stale
                return lc < cutoff
            }
        case .unmanaged(let status):
            return r.filter { device in
                // Management status is tracked only for macOS computers.
                guard device.platform == .macOS,
                      let computer = computerIndex[device.id] else {
                    return false
                }
                return status == .managedOnly ? computer.isManaged : !computer.isManaged
            }
        case .protectCoverage(let status):
            return r.filter { device in
                // Jamf Protect covers macOS only; other platforms are excluded
                // entirely rather than reported as "missing coverage".
                guard device.platform == .macOS else { return false }
                let serial = device.serialNumber.uppercased()
                // Placeholder serials can't be matched — treat as "no record".
                guard serial != "N/A", serial != "—", !serial.isEmpty else {
                    return status == .notCovered
                }
                switch status {
                case .covered: return protectSerials.contains(serial)
                case .notCovered: return !protectSerials.contains(serial)
                case .protectStale: return protectStaleSerials.contains(serial)
                }
            }
        case .computerGroup(let name):
            return r.filter { device in
                guard device.platform == .macOS,
                      let computer = computerIndex[device.id] else { return false }
                return (computer.groupMemberships ?? []).contains { $0.groupName?.caseInsensitiveCompare(name) == .orderedSame }
            }
        case .deviceGroup(let name):
            return r.filter { device in
                guard device.platform != .macOS,
                      let mobile = mobileIndex[device.id] else { return false }
                return (mobile.groups ?? []).contains { $0.groupName?.caseInsensitiveCompare(name) == .orderedSame }
            }
        }
    }

    /// Get coverage info from a device result by looking up purchasing data
    private func getDeviceCoverageInfo(_ device: ReportDeviceResult) -> (hasData: Bool, isExpired: Bool, isExpiringSoon: Bool) {
        if device.platform == .macOS {
            guard let computer = computerIndex[device.id] else {
                return (false, false, false)
            }
            
            let vendor = computer.purchasing?.vendor
            let hasVendor = vendor != nil && !vendor!.isEmpty
            
            var warrantyDate: Date? = nil
            if let warrantyDateStr = computer.purchasing?.warrantyDate, !warrantyDateStr.isEmpty {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = isoFormatter.date(from: warrantyDateStr) {
                    warrantyDate = date
                } else {
                    isoFormatter.formatOptions = [.withInternetDateTime]
                    if let date = isoFormatter.date(from: warrantyDateStr) {
                        warrantyDate = date
                    } else {
                        let simpleFormatter = DateFormatter()
                        simpleFormatter.dateFormat = "yyyy-MM-dd"
                        warrantyDate = simpleFormatter.date(from: warrantyDateStr)
                    }
                }
            }
            
            let hasData = hasVendor || warrantyDate != nil
            
            var isExpired = false
            var isExpiringSoon = false
            if let date = warrantyDate {
                isExpired = date < Date()
                if !isExpired {
                    let daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
                    isExpiringSoon = daysRemaining <= 90
                }
            }
            
            return (hasData, isExpired, isExpiringSoon)
        }
        
        if let mobileDevice = mobileIndex[device.id] {
            let vendor = mobileDevice.purchasing?.vendor
            let hasVendor = vendor != nil && !vendor!.isEmpty
            
            var warrantyDate: Date? = nil
            if let warrantyDateStr = mobileDevice.purchasing?.warrantyExpiresDate, !warrantyDateStr.isEmpty {
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = isoFormatter.date(from: warrantyDateStr) {
                    warrantyDate = date
                } else {
                    isoFormatter.formatOptions = [.withInternetDateTime]
                    if let date = isoFormatter.date(from: warrantyDateStr) {
                        warrantyDate = date
                    } else {
                        let simpleFormatter = DateFormatter()
                        simpleFormatter.dateFormat = "yyyy-MM-dd"
                        warrantyDate = simpleFormatter.date(from: warrantyDateStr)
                    }
                }
            }
            
            let hasData = hasVendor || warrantyDate != nil
            
            var isExpired = false
            var isExpiringSoon = false
            if let date = warrantyDate {
                isExpired = date < Date()
                if !isExpired {
                    let daysRemaining = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
                    isExpiringSoon = daysRemaining <= 90
                }
            }
            
            return (hasData, isExpired, isExpiringSoon)
        }
        
        return (false, false, false)
    }
    
    /// Get software update info from a device result
    private func getDeviceSoftwareUpdateInfo(_ device: ReportDeviceResult) -> (hasData: Bool, pendingCount: Int) {
        // Software updates only available for macOS currently
        if device.platform == .macOS {
            guard let computer = computerIndex[device.id] else {
                return (false, 0)
            }
            
            // softwareUpdates is an array of pending updates from the inventory
            let updates = computer.softwareUpdates ?? []
            // hasData is true if we have the section (even if empty means up to date)
            // We consider having the computer record as having data
            return (true, updates.count)
        }
        
        // Mobile devices don't have software update data in the same way
        return (false, 0)
    }
    
    // MARK: - Device Detail Navigation
    
}

// MARK: - Saved Report Card

struct SavedReportCard: View {
    let report: SavedReport
    var canDelete = true
    let onLoad: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showingDeleteConfirm = false

    private static func dateString(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private var scopeTitle: String {
        switch report.deviceScope ?? .all {
        case .all: return "All Devices"
        default: return (report.deviceScope ?? .all).rawValue
        }
    }

    /// Platforms in the app's usual order, not the saved set's.
    private var platforms: [PlatformType] {
        let saved = report.platformTypes
        return PlatformType.displayCases.filter(saved.contains)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(FleetHubTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(FleetHubTheme.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(report.name)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(FleetHubTheme.ink)
                        .lineLimit(2)
                    Text(report.description.isEmpty ? "No description" : report.description)
                        .font(.system(size: 13))
                        .foregroundStyle(FleetHubTheme.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .textSelection(.enabled)

            FlowLayout(spacing: 6) {
                ForEach(platforms, id: \.self) { platform in
                    tag(platform.rawValue, icon: platform.icon)
                }
                if (report.includeEnrollment ?? false) {
                    tag("Enrollment Data", icon: "tray.full")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(report.filters.isEmpty ? "No Filters" : (report.filters.count == 1 ? "1 Filter" : "\(report.filters.count) Filters"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.control)

                ForEach(report.filters.prefix(3)) { filter in
                    HStack(spacing: 8) {
                        Image(systemName: filter.category.icon)
                            .font(.system(size: 11))
                            .foregroundStyle(FleetHubTheme.muted)
                            .frame(width: 16)
                        Text(filter.category.rawValue)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(FleetHubTheme.ink)
                            .fixedSize()
                        Text(filter.displayDescription)
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if report.filters.count > 3 {
                    Text("+\(report.filters.count - 3) more")
                        .font(.system(size: 12))
                        .foregroundStyle(FleetHubTheme.muted)
                        .padding(.leading, 24)
                }
            }

            Spacer(minLength: 0)

            VStack(spacing: 0) {
                factRow("Scope", scopeTitle)
                factRow("Created", Self.dateString(report.createdAt))
                factRow("Last Opened", report.lastRunAt.map(Self.dateString) ?? "Never")
            }

            HStack(spacing: 8) {
                Button(action: onLoad) {
                    SettingsButtonLabel(text: "Open in Builder", kind: .primary, icon: "arrow.right")
                }
                .buttonStyle(.plain)
                .help("Load this report's platforms, scope and filters into Report Builder")

                Spacer(minLength: 8)

                if canDelete {
                    Button {
                        showingDeleteConfirm = true
                    } label: {
                        SettingsButtonLabel(text: "Delete", kind: .destructive)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .fill(FleetHubTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                .stroke(isHovered ? FleetHubTheme.accent.opacity(0.6) : FleetHubTheme.border, lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .alert("Delete Report?", isPresented: $showingDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("This will permanently delete '\(report.name)'.")
        }
    }

    private func tag(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(FleetHubTheme.control)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FleetHubTheme.trough))
        .fixedSize()
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(FleetHubTheme.border.opacity(0.7)).frame(height: 1)
            HStack(spacing: 16) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
                Spacer(minLength: 8)
                Text(value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)
            }
            .padding(.vertical, 9)
        }
    }
}

// MARK: - Report Results View

/// The dedicated results screen (presented as a modal sheet): searchable,
/// sortable, with a prominent export and its own device-detail navigation.
struct ReportResultsView: View {
    let results: [ReportDeviceResult]
    let exportFilename: String
    let makeExportTable: () -> ReportTable
    let isDark: Bool
    let onClose: () -> Void

    @State private var path = NavigationPath()
    @State private var loadingDeviceId: String?
    @State private var isLoadingDeviceDetail = false
    @State private var deviceLoadError: String?
    @State private var search = ""
    @State private var sort = TableSort<Column>(key: .name)

    enum Column: String, CaseIterable {
        case name = "Device", serial = "Serial Number", platform = "Platform"
        case checkIn = "Last Check-In", supervised = "Supervised", encrypted = "Encrypted"
        case os = "OS", model = "Model"
        var width: CGFloat {
            switch self {
            case .name: return 220
            case .serial, .checkIn: return 140
            case .model: return 180
            case .platform, .supervised, .encrypted: return 96
            case .os: return 80
            }
        }
    }

    private static let df: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    private var displayed: [ReportDeviceResult] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = q.isEmpty ? results : results.filter { matches($0, q) }
        return base.sorted(by: sort) { result, column in
            switch column {
            case .name: .text(result.deviceName)
            case .serial: .text(result.serialNumber)
            case .platform: .text(result.platform.rawValue)
            case .checkIn: .date(result.lastCheckIn)
            case .supervised: .flag(result.isSupervised)
            case .encrypted: .flag(result.isEncrypted)
            case .os: .text(result.osVersion)
            case .model: .text(result.model)
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 0) {
                    searchBar
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            tableHeaderRow
                            if displayed.isEmpty {
                                emptyState
                            } else {
                                ScrollView {
                                    LazyVStack(spacing: 0) {
                                        ForEach(displayed) { r in
                                            row(r)
                                            Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(minWidth: Self.tableWidth, maxHeight: .infinity, alignment: .top)
                        .containerRelativeFrame(.horizontal) { length, _ in max(length, Self.tableWidth) }
                    }
                    .scrollIndicators(.never, axes: .horizontal)
                }
                .background(FleetHubTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: FleetHubTheme.cardRadius, style: .continuous)
                        .stroke(FleetHubTheme.border, lineWidth: 1)
                )
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(FleetHubTheme.ground.ignoresSafeArea())
            .navigationDestination(for: Computer.self) { computer in
                DeviceView(computer: computer)
            }
            .navigationDestination(for: MobileDevice.self) { device in
                MobileDeviceView(device: device)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(FleetHubTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
        .alert("Error Loading Device", isPresented: .init(
            get: { deviceLoadError != nil },
            set: { if !$0 { deviceLoadError = nil } }
        )) {
            Button("OK") { deviceLoadError = nil }
        } message: {
            Text(deviceLoadError ?? "Unknown error")
        }
    }

    /// Every column plus the row's spacing and padding; narrower windows
    /// scroll the table sideways instead of crushing the columns.
    private static let tableWidth: CGFloat =
        Column.allCases.reduce(0) { $0 + $1.width + 14 } + 26

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { onClose() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                            .fill(FleetHubTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                            .stroke(FleetHubTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Report Builder")
            .accessibilityLabel("Back to Report Builder")

            VStack(alignment: .leading, spacing: 4) {
                Text("Report Results")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text(results.count == 1 ? "1 device matched this report." : "\(results.count) devices matched this report.")
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.muted)
            }
            Spacer(minLength: 12)
            if !results.isEmpty {
                ReportsExportMenu(filename: exportFilename, makeTable: makeExportTable, isDark: isDark, prominent: true)
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(FleetHubTheme.muted)
                TextField("", text: $search, prompt: Text("Search name, serial, model, OS, or platform")
                    .foregroundColor(FleetHubTheme.muted))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(FleetHubTheme.ink)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(FleetHubTheme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: 380)
            .overlay(
                RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )

            Spacer(minLength: 8)

            Text("\(displayed.count) of \(results.count) Shown")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 14) {
            ForEach(Column.allCases, id: \.self) { col in
                SortableHeaderText(col.rawValue, key: col, sort: $sort)
                    .frame(width: col.width, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(FleetHubTheme.ground)
    }

    private func cell(_ text: String, _ column: Column) -> some View {
        Text(text.isEmpty ? "—" : text)
            .font(.system(size: 13))
            .foregroundStyle(FleetHubTheme.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: column.width, alignment: .leading)
    }

    private func row(_ r: ReportDeviceResult) -> some View {
        let isLoading = isLoadingDeviceDetail && loadingDeviceId == r.id
        return Button {
            handleDeviceTap(r)
        } label: {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: r.platform.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(FleetHubTheme.muted)
                            .frame(width: 14)
                    }
                    Text(r.deviceName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FleetHubTheme.ink)
                        .lineLimit(1)
                    if !r.inJamf {
                        Text("ADE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(FleetHubTheme.warnText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(FleetHubTheme.warnFill))
                            .help("In Automated Device Enrollment but not enrolled in Jamf Pro")
                    }
                }
                .frame(width: Column.name.width, alignment: .leading)
                cell(r.serialNumber, .serial)
                cell(r.platform.rawValue, .platform)
                cell(r.lastCheckIn.map { Self.df.string(from: $0) } ?? "N/A", .checkIn)
                statusBadge(r.isSupervised).frame(width: Column.supervised.width, alignment: .leading)
                statusBadge(r.isEncrypted).frame(width: Column.encrypted.width, alignment: .leading)
                cell(r.osVersion, .os)
                cell(r.model, .model)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isLoading ? 0.6 : 1.0)
    }

    private func statusBadge(_ v: Bool) -> some View {
        Text(v ? "Yes" : "No")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(v ? FleetHubTheme.goodText : FleetHubTheme.warnText)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(v ? FleetHubTheme.goodFill : FleetHubTheme.warnFill))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: results.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(FleetHubTheme.muted)
            Text(results.isEmpty ? "No Devices Match the Report" : "No Devices Match Your Search")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FleetHubTheme.ink)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ r: ReportDeviceResult, _ q: String) -> Bool {
        r.deviceName.lowercased().contains(q)
            || r.serialNumber.lowercased().contains(q)
            || r.platform.rawValue.lowercased().contains(q)
            || r.osVersion.lowercased().contains(q)
            || r.model.lowercased().contains(q)
            || r.siteName.lowercased().contains(q)
            || (r.enrollment?.profileStatus?.displayName.lowercased().contains(q) ?? false)
            || (r.enrollmentInstanceName?.lowercased().contains(q) ?? false)
    }

    // MARK: - Device detail navigation (within the modal)

    private func handleDeviceTap(_ device: ReportDeviceResult) {
        guard !isLoadingDeviceDetail else { return }
        // ADE-only rows have no Jamf record to open.
        guard device.inJamf else { return }

        if device.platform == .macOS {
            if let computer = ComputerInventoryCache.shared.computers.first(where: { $0.id == device.id }) {
                path.append(Computer.fromInventoryItem(computer))
            }
        } else {
            fetchMobileDeviceAndShow(device)
        }
    }

    private func fetchMobileDeviceAndShow(_ device: ReportDeviceResult) {
        isLoadingDeviceDetail = true
        loadingDeviceId = device.id
        Task {
            do {
                let mobileDevice = try await fetchMobileDeviceDetail(id: device.id)
                isLoadingDeviceDetail = false
                loadingDeviceId = nil
                path.append(mobileDevice)
            } catch {
                isLoadingDeviceDetail = false
                loadingDeviceId = nil
                deviceLoadError = "Failed to load device details: \(error.localizedDescription)"
            }
        }
    }

    private func fetchMobileDeviceDetail(id: String) async throws -> MobileDevice {
        let config = MDMConfigurationManager.shared.configuration
        let jamfURL = config.jamfURL

        // Routed per the `reports` scope by the single app-wide token provider.
        let token = try await JamfTokenProvider.token(for: .reports)

        let sections = [
            "GENERAL", "HARDWARE", "USER_AND_LOCATION", "PURCHASING", "SECURITY",
            "APPLICATIONS", "EBOOKS", "NETWORK", "SERVICE_SUBSCRIPTIONS",
            "CERTIFICATES", "PROFILES", "GROUPS", "EXTENSION_ATTRIBUTES",
        ]
        let sectionParams = sections.map { "section=\($0)" }.joined(separator: "&")
        guard let url = URL(string: "\(jamfURL)/api/v2/mobile-devices/\(id)/detail?\(sectionParams)") else {
            throw NSError(domain: "ReportResultsView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid device URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await JamfTransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ReportResultsView", code: -1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            // Say what Jamf actually said (401/403/500) instead of "not found".
            throw NSError(domain: "ReportResultsView", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: JamfErrorFormatter.message(status: httpResponse.statusCode, body: data, fallbackAction: "load the device record")
            ])
        }
        return try JSONDecoder().decode(MobileDevice.self, from: data)
    }
}

// MARK: - Scorecard Columns

/// One column layout shared by the scorecard table's header and rows.
private struct ScorecardColumns<Device: View, User: View, OS: View, CheckIn: View, Checks: View>: View {
    let device: Device
    let user: User
    let os: OS
    let checkIn: CheckIn
    let checks: Checks

    var body: some View {
        HStack(spacing: 14) {
            device.frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            user.frame(width: 130, alignment: .leading)
            os.frame(width: 64, alignment: .leading)
            checkIn.frame(width: 110, alignment: .leading)
            checks.frame(width: 160, alignment: .leading)
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (i, s) in subviews.enumerated() { s.place(at: CGPoint(x: bounds.minX + r.positions[i].x, y: bounds.minY + r.positions[i].y), proposal: .unspecified) }
    }
    struct FlowResult {
        var size: CGSize = .zero; var positions: [CGPoint] = []
        init(in maxW: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0, y: CGFloat = 0, lh: CGFloat = 0
            for s in subviews { let sz = s.sizeThatFits(.unspecified); if x + sz.width > maxW && x > 0 { x = 0; y += lh + spacing; lh = 0 }; positions.append(CGPoint(x: x, y: y)); lh = max(lh, sz.height); x += sz.width + spacing; size.width = max(size.width, x) }
            size.height = y + lh
        }
    }
}

#if DEBUG
#Preview("Reports") { ReportsView().frame(width: 1400, height: 900) }
#endif
