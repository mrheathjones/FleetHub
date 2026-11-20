//
//  SetupModel.swift
//  FleetHubSetup
//
//  Everything the admin enters in FleetHub Setup, and the settings it turns
//  into: one dictionary per FleetHub preference domain (core, access,
//  features, ui), written exactly as the app's schemas define them.
//
//  NO SECRET IS EVER PART OF A DOMAIN. The secrets Setup can hold — the
//  upload client's and the Platform integration's, both only for testing a
//  connection or uploading — live in memory for this session and are never
//  written to a profile, a file, UserDefaults or a log. FleetHub's own
//  secrets reach each Mac's Keychain by being typed into FleetHub, or by
//  the credential import policy (Import-FleetHub-Credentials.sh), whose
//  secret values the admin enters in Jamf Pro, not here.
//

import Foundation
import Combine

// MARK: - Choices

enum SetupAPIChoice: String, CaseIterable, Identifiable, Codable {
    case jamfPro, hybrid, platform
    var id: String { rawValue }

    var title: String {
        switch self {
        case .jamfPro: "Jamf Pro API"
        case .hybrid: "Hybrid"
        case .platform: "Jamf Platform API"
        }
    }

    var summary: String {
        switch self {
        case .jamfPro: "Each person gets their own API client, created at their first sign-in. Jamf audits every action against that person by name."
        case .hybrid: "Reads go through one Platform integration. Device actions, Cleanup and secrets run as each person's own Jamf Pro API client, so Jamf still audits every action by name. Includes Compliance Benchmarks."
        case .platform: "One integration from Jamf Account serves everyone, through the Platform gateway. Includes Compliance Benchmarks. Renewed every six months."
        }
    }

    var needs: String {
        switch self {
        case .jamfPro: "Needs a provisioning client and an API role per FleetHub role."
        case .hybrid: "Needs both: a Jamf Account API credential, and a provisioning client with an API role per FleetHub role."
        case .platform: "Needs a Jamf Account API credential. Jamf audits the integration; FleetHub logs the person."
        }
    }

    var usesPlatformIntegration: Bool { self != .jamfPro }
    var usesPerUserClients: Bool { self != .platform }
}

enum SetupDomain: String, CaseIterable, Identifiable {
    case core, access, features, ui
    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: "Core"
        case .access: "Access and Roles"
        case .features: "Features"
        case .ui: "Branding"
        }
    }

    var preferenceDomain: String { "com.herojoneslabs.fleethub.\(rawValue)" }
    var profileName: String { "FleetHub — \(title)" }
    var schemaResource: String {
        switch self {
        case .core: "FleetHub_Core_SCHEMA"
        case .access: "FleetHub_Access_SCHEMA"
        case .features: "FleetHub_Features_SCHEMA"
        case .ui: "FleetHub_UI_SCHEMA"
        }
    }

    var scopeAdvice: String {
        switch self {
        case .core: "Scope to every Mac that runs FleetHub."
        case .access: "Scope to the Macs whose users should hold these roles."
        case .features: "Scope to every Mac that runs FleetHub."
        case .ui: "Scope to every Mac that runs FleetHub."
        }
    }
}

// MARK: - Scope

/// Which objects a role's scoped actions may touch: everything, or a list.
/// An empty list means none — the matching actions stay unavailable.
struct SetupScope: Equatable, Codable {
    var all = false
    var values: [String] = []

    static let everything = SetupScope(all: true)
    static let none = SetupScope()

    /// The access profile's form: `["all"]`, or the values.
    var profileValue: [String] { all ? ["all"] : values }

    mutating func add(_ text: String) {
        // A pasted "a, b, c" adds three values.
        for piece in text.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let value = piece.trimmingCharacters(in: .whitespaces)
            if value.lowercased() == "all" { all = true; continue }
            if !value.isEmpty, !values.contains(value) { values.append(value) }
        }
    }
}

enum SetupScopeKind: String, CaseIterable, Identifiable {
    case site, mdmServer, prestage, visibleSite
    var id: String { rawValue }

    var title: String {
        switch self {
        case .visibleSite: "Visible Site"
        case .site: "Site"
        case .mdmServer: "ABM Server"
        case .prestage: "PreStage"
        }
    }

    var allTitle: String {
        switch self {
        case .visibleSite: "All Sites"
        case .site: "All Sites"
        case .mdmServer: "All ABM Device Servers"
        case .prestage: "All PreStages"
        }
    }

    var placeholder: String {
        switch self {
        case .visibleSite: "Jamf Pro site ID, for example 3 (-1 for devices in no site)"
        case .site: "Jamf Pro site ID, for example 3"
        case .mdmServer: "ABM device server name"
        case .prestage: "PreStage enrollment ID, for example 12"
        }
    }

    var explanation: String {
        switch self {
        case .visibleSite: "Sites whose devices this role sees and acts on. With nothing added, this role sees no devices."
        case .site: "Sites this role may move devices into with Move to Site. With nothing added, the matching actions stay unavailable."
        case .mdmServer: "Apple Business Manager device servers this role may assign devices to. With nothing added, the matching actions stay unavailable."
        case .prestage: "PreStage enrollments this role may assign devices to. With nothing added, the matching actions stay unavailable."
        }
    }
}

// MARK: - Health card exclusions

/// Which devices one Health Scorecard card measures.
///
/// Two independent lists, usable together:
///   · EXCLUDE — sites and groups left out. A device in any of them is not
///     counted by the card at all, neither passing nor failing.
///   · ONLY INCLUDE — when any is given, the card measures ONLY devices in
///     those sites or groups, in place of the whole fleet. Handy when
///     listing everything to leave out would be longer.
/// A device that is both included and excluded is excluded.
struct SetupCardExclusion: Equatable, Codable {
    var siteIDs: [String] = []
    var computerGroupIDs: [String] = []
    var mobileGroupIDs: [String] = []
    var onlySiteIDs: [String] = []
    var onlyComputerGroupIDs: [String] = []
    var onlyMobileGroupIDs: [String] = []

    init() {}

    init(siteIDs: [String] = [], computerGroupIDs: [String] = [], mobileGroupIDs: [String] = [],
         onlySiteIDs: [String] = [], onlyComputerGroupIDs: [String] = [], onlyMobileGroupIDs: [String] = []) {
        self.siteIDs = siteIDs; self.computerGroupIDs = computerGroupIDs; self.mobileGroupIDs = mobileGroupIDs
        self.onlySiteIDs = onlySiteIDs; self.onlyComputerGroupIDs = onlyComputerGroupIDs
        self.onlyMobileGroupIDs = onlyMobileGroupIDs
    }

    /// Tolerant of files saved before a list existed: a missing list is empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) -> [String] { (try? c.decodeIfPresent([String].self, forKey: key)) ?? [] }
        siteIDs = list(.siteIDs); computerGroupIDs = list(.computerGroupIDs); mobileGroupIDs = list(.mobileGroupIDs)
        onlySiteIDs = list(.onlySiteIDs); onlyComputerGroupIDs = list(.onlyComputerGroupIDs)
        onlyMobileGroupIDs = list(.onlyMobileGroupIDs)
    }

    var excludeCount: Int { siteIDs.count + computerGroupIDs.count + mobileGroupIDs.count }
    var onlyCount: Int { onlySiteIDs.count + onlyComputerGroupIDs.count + onlyMobileGroupIDs.count }
    var isEmpty: Bool { excludeCount == 0 && onlyCount == 0 }
    var count: Int { excludeCount + onlyCount }

    /// Adds the scope keys to a card's profile entry.
    func apply(to card: inout [String: Any]) {
        if !siteIDs.isEmpty { card["excludeSiteIds"] = siteIDs }
        if !computerGroupIDs.isEmpty { card["excludeComputerGroupIds"] = computerGroupIDs }
        if !mobileGroupIDs.isEmpty { card["excludeMobileGroupIds"] = mobileGroupIDs }
        if onlyCount > 0 {
            // Measuring only the listed sites and groups replaces "the
            // whole fleet".
            card["allDevices"] = false
            if !onlySiteIDs.isEmpty { card["siteIds"] = onlySiteIDs }
            if !onlyComputerGroupIDs.isEmpty { card["computerGroupIds"] = onlyComputerGroupIDs }
            if !onlyMobileGroupIDs.isEmpty { card["mobileGroupIds"] = onlyMobileGroupIDs }
        }
    }
}

enum SetupHealthCard: String, CaseIterable, Identifiable {
    case checkedIn, protected, encrypted, secured, upToDate
    var id: String { rawValue }

    var title: String {
        switch self {
        case .checkedIn: "Checked In"
        case .protected: "Protected"
        case .encrypted: "Encrypted"
        case .secured: "Secured"
        case .upToDate: "Up to Date"
        }
    }
}

// MARK: - Role draft

/// One FleetHub role as the admin is defining it. Order of `modules` is the
/// order of the app's navigation, so it is kept as the canonical list order.
struct SetupRole: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var jamfApiRoleName: String
    var modules: Set<String>
    var deviceTabs: Set<String>
    var computerActions: Set<String>
    var mobileDeviceActions: Set<String>
    var cleanupActions: Set<String>
    var allowExport: Bool
    var allowScorecardDiagnostics: Bool
    var allowedSites: SetupScope
    var allowedMdmServers: SetupScope
    var allowedPrestages: SetupScope
    /// Sites whose devices this role sees, written only while Limit
    /// Devices By Site is on. Optional so a setup saved before the list
    /// existed still opens; absent means every site.
    var visibleSites: SetupScope?
    /// Exempts the role from the Screen Share approval prompt. Optional so
    /// roles saved before the prompt existed still load.
    var screenShareWithoutPrompt: Bool?

    func scope(_ kind: SetupScopeKind) -> SetupScope {
        switch kind {
        case .visibleSite: visibleSites ?? .everything
        case .site: allowedSites
        case .mdmServer: allowedMdmServers
        case .prestage: allowedPrestages
        }
    }

    mutating func setScope(_ scope: SetupScope, for kind: SetupScopeKind) {
        switch kind {
        case .visibleSite: visibleSites = scope
        case .site: allowedSites = scope
        case .mdmServer: allowedMdmServers = scope
        case .prestage: allowedPrestages = scope
        }
    }

    static let allModules = ["dashboard", "devices", "myDevices", "reports", "cleanup", "logs", "announcements", "settings"]
    static let moduleTitles: [String: String] = [
        "dashboard": "Overview", "devices": "Devices", "myDevices": "My Devices", "reports": "Reports",
        "cleanup": "Cleanup", "logs": "Logs", "announcements": "Announcements", "settings": "Settings"
    ]
    static let allDeviceTabs = ["abmLookup", "prestage"]
    static let deviceTabTitles = ["abmLookup": "ABM Lookup", "prestage": "Pre-Stage"]
    static let allComputerActions = [
        "sendBlankPush", "restart", "restartSilent", "shutdown",
        "enableRemoteDesktop", "disableRemoteDesktop", "enableBluetooth", "disableBluetooth",
        "screenShare", "ssh", "unlockUserAccount", "viewLocalAdminPassword", "viewFileVaultKey",
        "moveToSite", "assignPreStage", "abmAssign", "abmUnassign", "returnToService", "wipe"
    ]
    static let computerActionTitles: [String: String] = [
        "sendBlankPush": "Send Blank Push", "restart": "Restart", "restartSilent": "Restart (No Prompt)",
        "shutdown": "Shut Down", "enableRemoteDesktop": "Enable Remote Desktop",
        "disableRemoteDesktop": "Disable Remote Desktop", "enableBluetooth": "Enable Bluetooth",
        "disableBluetooth": "Disable Bluetooth", "screenShare": "Screen Share", "ssh": "SSH",
        "unlockUserAccount": "Unlock User Account", "viewLocalAdminPassword": "Local Admin Password",
        "viewFileVaultKey": "FileVault Key", "moveToSite": "Move to Site", "assignPreStage": "Assign PreStage",
        "abmAssign": "ABM Assign", "abmUnassign": "ABM Unassign", "returnToService": "Return to Service",
        "wipe": "Wipe"
    ]
    static let allMobileActions = ["sendBlankPush", "restart", "shutdown", "moveToSite", "wipe"]
    static let mobileActionTitles: [String: String] = [
        "sendBlankPush": "Send Blank Push", "restart": "Restart", "shutdown": "Shut Down",
        "moveToSite": "Move to Site", "wipe": "Wipe"
    ]
    static let allCleanupActions = ["unmanage", "addToGroup", "moveToSite", "deleteFromProtect", "deleteRecord"]
    static let cleanupActionTitles: [String: String] = [
        "unmanage": "Unmanage", "addToGroup": "Add to Static Group", "moveToSite": "Move to Site",
        "deleteFromProtect": "Delete from Protect", "deleteRecord": "Delete Jamf Record"
    ]

    static func admin() -> SetupRole {
        SetupRole(
            name: "FleetHub.Admin", jamfApiRoleName: "FleetHub Admin",
            modules: Set(allModules), deviceTabs: Set(allDeviceTabs),
            computerActions: Set(allComputerActions), mobileDeviceActions: Set(allMobileActions),
            cleanupActions: Set(allCleanupActions),
            allowExport: true, allowScorecardDiagnostics: true,
            allowedSites: .everything, allowedMdmServers: .everything, allowedPrestages: .everything
        )
    }

    static func technician() -> SetupRole {
        SetupRole(
            name: "FleetHub.Technician", jamfApiRoleName: "FleetHub Technician",
            modules: ["dashboard", "devices", "myDevices", "reports", "logs", "announcements", "settings"],
            deviceTabs: [],
            computerActions: ["sendBlankPush", "restart", "shutdown", "enableRemoteDesktop", "disableRemoteDesktop",
                              "enableBluetooth", "disableBluetooth", "screenShare", "unlockUserAccount",
                              "viewLocalAdminPassword"],
            mobileDeviceActions: ["sendBlankPush", "restart"],
            cleanupActions: [],
            allowExport: false, allowScorecardDiagnostics: false,
            allowedSites: .none, allowedMdmServers: .none, allowedPrestages: .none
        )
    }

    static func blank() -> SetupRole {
        SetupRole(
            name: "", jamfApiRoleName: "", modules: ["dashboard", "devices"], deviceTabs: [],
            computerActions: [], mobileDeviceActions: [], cleanupActions: [],
            allowExport: false, allowScorecardDiagnostics: false,
            allowedSites: .none, allowedMdmServers: .none, allowedPrestages: .none
        )
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled Role" : trimmed
    }

    fileprivate func ordered(_ selection: Set<String>, by canonical: [String]) -> [String] {
        canonical.filter(selection.contains)
    }

    /// The role as an entry of the access profile's `roles` array.
    var dictionary: [String: Any] {
        var entry: [String: Any] = ["name": name.trimmingCharacters(in: .whitespaces)]
        let jamfRole = jamfApiRoleName.trimmingCharacters(in: .whitespaces)
        if !jamfRole.isEmpty { entry["jamfApiRoleName"] = jamfRole }
        entry["modules"] = ordered(modules, by: Self.allModules)
        if !deviceTabs.isEmpty { entry["deviceTabs"] = ordered(deviceTabs, by: Self.allDeviceTabs) }
        if !computerActions.isEmpty { entry["computerActions"] = ordered(computerActions, by: Self.allComputerActions) }
        if !mobileDeviceActions.isEmpty { entry["mobileDeviceActions"] = ordered(mobileDeviceActions, by: Self.allMobileActions) }
        if !cleanupActions.isEmpty { entry["cleanupActions"] = ordered(cleanupActions, by: Self.allCleanupActions) }
        if !allowedSites.profileValue.isEmpty { entry["allowedSites"] = allowedSites.profileValue }
        if !allowedMdmServers.profileValue.isEmpty { entry["allowedMdmServers"] = allowedMdmServers.profileValue }
        if !allowedPrestages.profileValue.isEmpty { entry["allowedPrestages"] = allowedPrestages.profileValue }
        // Removed again by the access profile when site scoping is off.
        entry["visibleSites"] = (visibleSites ?? .everything).profileValue
        if allowExport { entry["allowExport"] = true }
        if allowScorecardDiagnostics { entry["allowScorecardDiagnostics"] = true }
        // Removed again by the access profile when the prompt is off.
        if screenShareWithoutPrompt == true { entry["screenShareWithoutPrompt"] = true }
        return entry
    }
}

// MARK: - Model

@MainActor
final class SetupModel: ObservableObject {

    /// The step on screen.
    @Published var step: SetupStep = .start

    /// When the settings were last written to the automatic save.
    @Published var lastSaved: Date?
    /// True when this launch picked up settings from an earlier one.
    @Published var restoredFromAutosave = false
    private var autosaveSubscription: AnyCancellable?

    /// `restoring` false gives an untouched model that neither loads nor
    /// writes the automatic save (used for defaults and comparisons).
    init(restoring: Bool = true) {
        guard restoring else { return }
        restoredFromAutosave = restoreAutosave()
        // Save shortly after any change. `objectWillChange` fires before
        // the value lands, so the debounce also lets it settle first.
        autosaveSubscription = objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Saving sets `lastSaved`, which would trigger another save;
                // skip when nothing but that changed.
                guard let data = try? self.encodedSetup(), data != self.lastAutosavedData else { return }
                self.lastAutosavedData = data
                self.autosave()
            }
    }
    private var lastAutosavedData: Data?

    // Step 1 — Start
    @Published var api: SetupAPIChoice = .jamfPro
    @Published var uploadProfiles = true

    // Step 2 — Jamf Pro API client used by Setup to upload profiles.
    // The secret is held in memory only.
    @Published var uploadClientID = ""
    @Published var uploadClientSecret = ""

    // Step 3 — Platform integration identity (+ secret in memory, for the
    // connection test only).
    @Published var platformRegion = "us"
    @Published var platformClientID = ""
    @Published var platformTenantID = ""
    @Published var platformEnvironmentID = ""
    /// The Jamf PROTECT tenant's UUID: a different value from the Jamf Pro
    /// tenant ID, since a tenant ID names one product instance.
    @Published var platformProtectTenantID = ""
    @Published var platformClientSecret = ""

    // Step 4 — Core
    /// Prefilled from this Mac's Jamf enrollment when there is one; the
    /// admin can change it.
    @Published var jamfURL = SetupModel.detectedJamfURL ?? ""
    @Published var masterClientID = ""
    /// On: FleetHub creates each person's Jamf API client with a provisioning
    /// client whose secret is deployed to every Mac. Off: an administrator
    /// creates the clients, each person enters their own, and no provisioning
    /// secret exists.
    @Published var autoCreateUserClients = false
    /// True when the settings include a provisioning client.
    var provisionsClients: Bool { api.usesPerUserClients && autoCreateUserClients }
    @Published var defaultJamfRoleName = ""
    @Published var signInMethod = "entra"          // "entra" | "email"
    @Published var entraTenantID = ""
    @Published var entraClientID = ""
    /// Only when the app registration uses a redirect URI other than the default.
    @Published var entraRedirectURI = ""
    static let defaultEntraRedirectURI = "fleethubauth://callback"
    var effectiveEntraRedirectURI: String {
        let value = trimmed(entraRedirectURI)
        return value.isEmpty ? Self.defaultEntraRedirectURI : value
    }
    /// Email sign-in only: the single role every user on the Mac holds.
    @Published var emailModeRoleName = ""
    /// Limit Devices By Site: each role then sees only its Visible Sites.
    @Published var siteScoping = false
    @Published var abmEnabled = false
    @Published var abmClientID = ""
    @Published var abmKeyID = ""
    @Published var protectEnabled = false
    @Published var protectURL = ""
    @Published var protectClientID = ""
    @Published var entraCleanupEnabled = false
    @Published var entraCleanupTenantID = ""
    @Published var entraCleanupClientID = ""
    @Published var requireBiometric = false
    @Published var sessionTimeoutMinutes = 0

    // Step 4 — Access
    @Published var roles: [SetupRole] = [.admin(), .technician()]

    // Step 4 — Features
    @Published var staleDays = 90
    @Published var localAdminUsername = ""
    @Published var showDeviceHistory = false
    @Published var screenShareAutoSignIn = false
    /// Ask Before Screen Share: the person at the Mac must allow a session.
    @Published var screenSharePrompt = false
    /// fleethubPrompt, swiftDialog or jamfHelper.
    @Published var screenSharePromptMethod = "fleethubPrompt"
    @Published var screenSharePromptTitle = ""
    @Published var screenSharePromptMessage = ""
    @Published var screenSharePromptIconPath = ""
    @Published var screenSharePromptTimeoutSeconds = 60
    @Published var screenSharePromptAllowWhenNoUser = true
    /// Numeric id of the extension attribute holding the VPN IP; blank = not collected.
    @Published var vpnIPExtensionAttributeID = ""
    /// Minutes Jamf waits after a LAPS password is viewed before rotating it.
    @Published var sshPasswordRotationMinutes = 60
    @Published var myDevicesEnabled = true
    @Published var scorecardEnabled = true
    @Published var scorecardCheckedInDays = 30
    @Published var scorecardMinimumMacOS = 26
    @Published var scorecardMinimumIOS = 26
    /// Apps that must be installed for a Mac to count as protected.
    @Published var scorecardRequiredApps: [String] = []
    /// The required apps matched by "contains" instead of by whole name.
    @Published var scorecardContainsApps: Set<String> = []
    /// Per-card exclusions, keyed by the card's id.
    @Published var scorecardExclusions: [String: SetupCardExclusion] = [:]

    // Step 4 — Branding
    @Published var appTitle = "FleetHub"
    @Published var companyName = ""
    @Published var supportURL = ""
    @Published var accentColorHex = ""
    @Published var defaultColorScheme = "system"

    // MARK: Jamf URL detection

    /// The Jamf Pro URL this Mac is enrolled with, read from the Jamf
    /// management framework's preferences (`jss_url`), without its trailing
    /// slash. Nil when the Mac is not enrolled or the value is unreadable.
    static let detectedJamfURL: String? = {
        let path = "/Library/Preferences/com.jamfsoftware.jamf.plist"
        var raw = (NSDictionary(contentsOfFile: path)?["jss_url"] as? String)
            ?? (CFPreferencesCopyAppValue("jss_url" as CFString, "com.jamfsoftware.jamf" as CFString) as? String)
            ?? ""
        raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while raw.hasSuffix("/") { raw.removeLast() }
        guard raw.lowercased().hasPrefix("https://"), URL(string: raw)?.host != nil else { return nil }
        return raw
    }()

    /// True while the URL field still holds the detected value.
    var jamfURLIsDetected: Bool {
        guard let detected = Self.detectedJamfURL else { return false }
        return normalizedJamfURL == detected
    }

    /// The line under a Jamf Pro URL field.
    var jamfURLHint: String? {
        guard let detected = Self.detectedJamfURL else { return nil }
        return jamfURLIsDetected
            ? "Detected from this Mac's Jamf enrollment. Change it if FleetHub should use a different server."
            : "This Mac is enrolled with \(detected)."
    }

    // MARK: Helpers

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The Jamf Pro URL with a scheme and no trailing slash.
    var normalizedJamfURL: String {
        var url = trimmed(jamfURL)
        guard !url.isEmpty else { return "" }
        if !url.lowercased().hasPrefix("http") { url = "https://" + url }
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }

    /// True when the upload client is filled in, so Setup can upload.
    var canUpload: Bool {
        !normalizedJamfURL.isEmpty && !trimmed(uploadClientID).isEmpty && !trimmed(uploadClientSecret).isEmpty
    }

    /// True when a Platform integration is named AND can address the
    /// Protect tenant (its tenant ID, or the environment ID), so Jamf
    /// Protect runs through it instead of a Protect API client of its own.
    var protectUsesPlatform: Bool {
        !trimmed(platformClientID).isEmpty
            && (!trimmed(platformProtectTenantID).isEmpty || !trimmed(platformEnvironmentID).isEmpty)
    }

    /// Platform permissions Jamf Protect adds for the given roles.
    private func protectPermissions(for roles: [SetupRole]) -> [String] {
        guard protectEnabled else { return [] }
        var items = ["devices:read"]
        if roles.contains(where: { $0.cleanupActions.contains("deleteFromProtect") }) { items.append("devices:delete") }
        return items
    }

    var usableRoles: [SetupRole] {
        roles.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Validation

    /// What still stops the settings from working, in plain words. Empty
    /// means the Core and Access profiles are complete enough to deliver.
    var problems: [String] {
        var list: [String] = []
        if normalizedJamfURL.isEmpty {
            list.append("Enter the Jamf Pro server URL (Configure → Core).")
        }
        if provisionsClients, trimmed(masterClientID).isEmpty {
            list.append("Enter the provisioning client ID (Configure → Core).")
        }
        if api.usesPlatformIntegration {
            if trimmed(platformClientID).isEmpty { list.append("Enter the Platform integration's client ID (Jamf Environment Setup → Jamf Platform API).") }
            if trimmed(platformTenantID).isEmpty { list.append("Enter the Platform tenant ID (Jamf Environment Setup → Jamf Platform API).") }
        }
        if protectEnabled, !trimmed(platformClientID).isEmpty, trimmed(platformProtectTenantID).isEmpty {
            list.append(trimmed(platformEnvironmentID).isEmpty
                ? "Jamf Protect is on: enter the Jamf Protect tenant ID (Jamf Environment Setup → Jamf Platform API)."
                : "Jamf Protect will use the environment ID, which Jamf may refuse. Enter the Jamf Protect tenant ID (Jamf Environment Setup → Jamf Platform API).")
        }
        if signInMethod == "entra", trimmed(entraTenantID).isEmpty || trimmed(entraClientID).isEmpty {
            list.append("Enter the Entra tenant ID and client ID for sign-in (Configure → Core).")
        }
        if usableRoles.isEmpty { list.append("Define at least one role (Configure → Access and Roles).") }
        if provisionsClients {
            let unnamed = usableRoles.filter { $0.jamfApiRoleName.trimmingCharacters(in: .whitespaces).isEmpty }
            if !unnamed.isEmpty, trimmed(defaultJamfRoleName).isEmpty {
                list.append("Give \(unnamed.map(\.displayName).joined(separator: ", ")) a Jamf API role name, or set a Fallback Jamf API Role (Configure → Core).")
            }
        }
        if signInMethod == "email", provisionsClients {
            list.append("Email sign-in cannot be used while FleetHub creates API clients automatically: a typed address proves nothing. Turn automatic creation off, or use Microsoft Entra ID sign-in (Configure → Core).")
        }
        if signInMethod == "email", !usableRoles.contains(where: { $0.name == trimmed(emailModeRoleName) }) {
            list.append("Pick the role every user holds under email sign-in (Configure → Access and Roles).")
        }
        return list
    }

    // MARK: Domain dictionaries

    func dictionary(for domain: SetupDomain) -> [String: Any] {
        switch domain {
        case .core: coreDictionary
        case .access: accessDictionary
        case .features: featuresDictionary
        case .ui: uiDictionary
        }
    }

    private var coreDictionary: [String: Any] {
        var core: [String: Any] = ["configurationVersion": "3.0"]

        var jamfPro: [String: Any] = ["serverURL": normalizedJamfURL]
        if provisionsClients {
            if !trimmed(masterClientID).isEmpty { jamfPro["masterClientID"] = trimmed(masterClientID) }
            if !trimmed(defaultJamfRoleName).isEmpty { jamfPro["requiredRoleName"] = trimmed(defaultJamfRoleName) }
        }
        core["jamfPro"] = jamfPro

        if api != .jamfPro { core["apiBackend"] = api.rawValue }
        // The identity alone (backend left on jamfPro) enables Compliance
        // Benchmarks, so it is written whenever one was entered.
        if !trimmed(platformClientID).isEmpty {
            var platform: [String: Any] = ["region": platformRegion, "clientID": trimmed(platformClientID)]
            if !trimmed(platformTenantID).isEmpty { platform["tenantID"] = trimmed(platformTenantID) }
            if !trimmed(platformEnvironmentID).isEmpty { platform["environmentID"] = trimmed(platformEnvironmentID) }
            if protectEnabled, !trimmed(platformProtectTenantID).isEmpty {
                platform["protectTenantID"] = trimmed(platformProtectTenantID)
            }
            core["platformAPI"] = platform
        }

        var signIn: [String: Any] = ["method": signInMethod]
        if signInMethod == "entra" {
            var entra = ["tenantId": trimmed(entraTenantID), "clientId": trimmed(entraClientID)]
            if !trimmed(entraRedirectURI).isEmpty { entra["redirectURI"] = trimmed(entraRedirectURI) }
            signIn["entra"] = entra
        }
        core["signIn"] = signIn

        if abmEnabled {
            var abm: [String: Any] = ["enabled": true]
            if !trimmed(abmClientID).isEmpty { abm["clientID"] = trimmed(abmClientID) }
            if !trimmed(abmKeyID).isEmpty { abm["keyID"] = trimmed(abmKeyID) }
            core["appleBusinessManager"] = abm
        }
        if protectEnabled {
            // Through the Platform integration, Protect needs no address or
            // client of its own.
            var protect: [String: Any] = ["enabled": true]
            if !protectUsesPlatform {
                if !trimmed(protectURL).isEmpty { protect["url"] = trimmed(protectURL) }
                if !trimmed(protectClientID).isEmpty { protect["clientID"] = trimmed(protectClientID) }
            }
            core["jamfProtect"] = protect
        }
        if entraCleanupEnabled {
            core["entra"] = ["tenantID": trimmed(entraCleanupTenantID), "clientID": trimmed(entraCleanupClientID)]
        }

        var authentication: [String: Any] = [:]
        if requireBiometric { authentication["requireBiometric"] = true }
        // Written either way: the app's default is off, and an explicit
        // value keeps a profile's meaning fixed if a default ever changes.
        if api.usesPerUserClients { authentication["autoCreateUserApiClient"] = autoCreateUserClients }
        if sessionTimeoutMinutes > 0 { authentication["sessionTimeout"] = sessionTimeoutMinutes }
        if !authentication.isEmpty { core["authentication"] = authentication }

        return core
    }

    private var accessDictionary: [String: Any] {
        var access: [String: Any] = ["configurationVersion": "3.0"]
        if signInMethod == "email", !trimmed(emailModeRoleName).isEmpty {
            access["role"] = trimmed(emailModeRoleName)
        }
        // On the Platform backend there are no per-user clients, so a Jamf
        // API role name would name nothing.
        // Site scoping is opt-in. Off: the key and every role's
        // visibleSites list are left out, so nobody is limited by site.
        if siteScoping { access["siteScoping"] = true }
        access["roles"] = usableRoles.map { role -> [String: Any] in
            var entry = role.dictionary
            if !siteScoping { entry.removeValue(forKey: "visibleSites") }
            if !screenSharePrompt { entry.removeValue(forKey: "screenShareWithoutPrompt") }
            if !provisionsClients { entry.removeValue(forKey: "jamfApiRoleName") }
            return entry
        }
        return access
    }

    private var featuresDictionary: [String: Any] {
        var features: [String: Any] = ["configurationVersion": "3.0"]
        features["cleanup"] = ["staleDays": staleDays]
        if !trimmed(localAdminUsername).isEmpty {
            features["localAdministration"] = ["enabled": true, "username": trimmed(localAdminUsername)]
        }
        var computers: [String: Any] = [:]
        if showDeviceHistory { computers["showDeviceHistory"] = true }
        if screenShareAutoSignIn { computers["screenShareAutoSignIn"] = true }
        if screenSharePrompt {
            computers["screenSharePrompt"] = true
            computers["screenSharePromptMethod"] = screenSharePromptMethod
            if !trimmed(screenSharePromptTitle).isEmpty { computers["screenSharePromptTitle"] = trimmed(screenSharePromptTitle) }
            if !trimmed(screenSharePromptMessage).isEmpty { computers["screenSharePromptMessage"] = trimmed(screenSharePromptMessage) }
            if !trimmed(screenSharePromptIconPath).isEmpty { computers["screenSharePromptIconPath"] = trimmed(screenSharePromptIconPath) }
            if screenSharePromptTimeoutSeconds != 60 { computers["screenSharePromptTimeoutSeconds"] = screenSharePromptTimeoutSeconds }
            if !screenSharePromptAllowWhenNoUser { computers["screenSharePromptAllowWhenNoUser"] = false }
        }
        if let id = Int(trimmed(vpnIPExtensionAttributeID)), id > 0 { computers["vpnIPExtensionAttributeID"] = id }
        if sshPasswordRotationMinutes != 60 { computers["sshPasswordRotationMinutes"] = sshPasswordRotationMinutes }
        if !computers.isEmpty { features["computers"] = computers }
        if !myDevicesEnabled { features["myDevices"] = ["enabled": false] }

        if scorecardEnabled {
            // `allDevices` measures the whole fleet; narrow a card to sites
            // or groups later in Jamf Pro's schema form.
            var cards: [[String: Any]] = [
                ["id": "checkedIn", "enabled": true, "allDevices": true, "checkedInDays": scorecardCheckedInDays],
                ["id": "encrypted", "enabled": true, "allDevices": true],
                ["id": "secured", "enabled": true, "allDevices": true, "platforms": ["macOS"],
                 "checks": ["firewall", "sip", "gatekeeper", "managed", "diskEncrypted"]],
                ["id": "upToDate", "enabled": true, "allDevices": true,
                 "minimumOSVersions": ["macOS": scorecardMinimumMacOS, "iOS": scorecardMinimumIOS,
                                       "iPadOS": scorecardMinimumIOS]]
            ]
            let apps = scorecardRequiredApps.map(trimmed).filter { !$0.isEmpty }
            if !apps.isEmpty {
                cards.insert(
                    ["id": "protected", "enabled": true, "allDevices": true, "platforms": ["macOS"],
                     "requireMode": "all",
                     "requiredApps": apps.map { name -> [String: Any] in
                         scorecardContainsApps.contains(name)
                             ? ["name": name, "matchMode": "substring"] : ["name": name]
                     }],
                    at: 1
                )
            }
            // Leave excluded sites and groups out of each card's population.
            cards = cards.map { card in
                var card = card
                if let id = card["id"] as? String { scorecardExclusions[id]?.apply(to: &card) }
                return card
            }
            features["healthScorecard"] = ["enabled": true, "cards": cards]
        } else {
            features["healthScorecard"] = ["enabled": false]
        }
        return features
    }

    private var uiDictionary: [String: Any] {
        var userInterface: [String: Any] = [:]
        if !trimmed(appTitle).isEmpty { userInterface["appTitle"] = trimmed(appTitle) }
        // The schema's historical default subtitle is not part of the
        // FleetHub name; write it empty so no stray word appears.
        userInterface["appSubtitle"] = ""
        if !trimmed(companyName).isEmpty { userInterface["companyName"] = trimmed(companyName) }
        if !trimmed(supportURL).isEmpty { userInterface["supportURL"] = trimmed(supportURL) }
        if !trimmed(accentColorHex).isEmpty { userInterface["accentColor"] = trimmed(accentColorHex) }
        if defaultColorScheme != "system" { userInterface["defaultColorScheme"] = defaultColorScheme }
        return ["configurationVersion": "3.0", "userInterface": userInterface]
    }

    // MARK: Permissions

    struct PrivilegeGroup: Identifiable {
        let title: String
        let items: [String]
        var id: String { title }
    }

    static let provisioningPrivileges = [
        "Read API Integrations", "Create API Integrations", "Update API Integrations", "Read API Roles"
    ]

    static let uploadPrivileges = [
        "Create macOS Configuration Profiles", "Read macOS Configuration Profiles",
        "Update macOS Configuration Profiles",
        "Create Scripts", "Read Scripts", "Update Scripts"
    ]

    /// Jamf Pro API Role privileges the per-user client of someone holding
    /// `role` needs, grouped by area. On the Platform backend there is no
    /// per-user client, so this is empty.
    func jamfPrivileges(for role: SetupRole) -> [PrivilegeGroup] {
        guard api.usesPerUserClients else { return [] }
        var groups: [(String, [String])] = []
        let commands = role.computerActions.union(role.mobileDeviceActions)
        let mdm = ["Send MDM command information in Jamf Pro API", "View MDM command information in Jamf Pro API"]

        // Reads: on hybrid the fleet reads move to the integration, but an
        // action still reads the device record as part of the action.
        var inventory = ["Read Computers", "Read Mobile Devices"]
        if api == .jamfPro, role.modules.contains("myDevices") { inventory.append("Read Users") }
        // Names for the Building and Department report filters.
        if api == .jamfPro, role.modules.contains("reports") { inventory += ["Read Buildings", "Read Departments"] }
        groups.append((api == .hybrid ? "Needed by Every Action" : "Inventory", inventory))

        var mdmItems: [String] = []
        let sends: [(String, String)] = [
            ("restart", "Send Computer Restart Command"), ("restartSilent", "Send Computer Restart Command"),
            ("shutdown", "Send Computer Shut Down Command"),
            ("enableRemoteDesktop", "Send Computer Remote Desktop Command"),
            ("disableRemoteDesktop", "Send Computer Remote Desktop Command"),
            ("enableBluetooth", "Send Computer Bluetooth Command"),
            ("disableBluetooth", "Send Computer Bluetooth Command"),
            ("unlockUserAccount", "Send Computer Unlock User Account Command")
        ]
        for (action, privilege) in sends where role.computerActions.contains(action) {
            mdmItems.append(privilege)
        }
        let anyCommand = !mdmItems.isEmpty || commands.contains("sendBlankPush")
            || commands.contains("wipe") || commands.contains("returnToService")
            || role.mobileDeviceActions.contains("restart") || role.mobileDeviceActions.contains("shutdown")
        if anyCommand { groups.append(("MDM Commands", mdm + mdmItems)) }

        var secrets: [String] = []
        if role.computerActions.contains("viewLocalAdminPassword") || role.computerActions.contains("ssh")
            || (screenShareAutoSignIn && role.computerActions.contains("screenShare"))
            // The approval prompt is shown over SSH with the management account.
            || (screenSharePrompt && role.computerActions.contains("screenShare")
                && role.screenShareWithoutPrompt != true) {
            secrets.append("View Local Admin Password")
        }
        // Jamf rotates a password a set time after its FIRST view. The audit
        // history is how FleetHub learns when that was; without it the
        // countdown is an estimate that starts when FleetHub reads the password.
        if secrets.contains("View Local Admin Password") {
            secrets.append("View Local Admin Password Audit History (recommended: gives the real password rotation countdown)")
        }
        if role.computerActions.contains("viewFileVaultKey") { secrets.append("View Disk Encryption Recovery Key") }
        if !secrets.isEmpty { groups.append(("Secrets", secrets)) }

        var enrollment: [String] = []
        if commands.contains("moveToSite") {
            enrollment += ["Read Sites"]
            if role.computerActions.contains("moveToSite") { enrollment.append("Update Computers") }
            if role.mobileDeviceActions.contains("moveToSite") { enrollment.append("Update Mobile Devices") }
        }
        if role.computerActions.contains("assignPreStage") || role.deviceTabs.contains("prestage") {
            enrollment += ["Read Computer PreStage Enrollments", "Update Computer PreStage Enrollments",
                           "Read Inventory Preload Records", "Create Inventory Preload Records",
                           "Update Inventory Preload Records"]
        }
        if !enrollment.isEmpty { groups.append(("Enrollment and Site", enrollment)) }

        var destructive: [String] = []
        if commands.contains("wipe") || commands.contains("returnToService") {
            destructive.append("Send Computer Remote Wipe Command")
        }
        if role.computerActions.contains("returnToService") || role.cleanupActions.contains("deleteRecord") {
            destructive.append("Delete Computers")
        }
        if role.modules.contains("cleanup") {
            destructive.append("Read Sites")
            if role.cleanupActions.contains("addToGroup") {
                destructive += ["Read Static Computer Groups", "Update Static Computer Groups"]
            }
            if role.cleanupActions.contains("unmanage") || role.cleanupActions.contains("moveToSite") {
                destructive.append("Update Computers")
            }
        }
        if !destructive.isEmpty { groups.append(("Destructive", destructive)) }

        // A privilege already listed under an earlier group is not repeated.
        var seen = Set<String>()
        return groups.compactMap { title, items in
            let fresh = items.filter { seen.insert($0).inserted }
            return fresh.isEmpty ? nil : PrivilegeGroup(title: title, items: fresh)
        }
    }

    /// Permissions the one Platform integration needs. `(confirm)` marks a
    /// name inferred from Jamf's reference rather than read from it.
    var platformPermissions: [PrivilegeGroup] { platformPermissions(for: usableRoles) }

    /// The same, for the integration serving only people holding `all`.
    func platformPermissions(for all: [SetupRole]) -> [PrivilegeGroup] {
        var always = ["compliance-benchmarks:read", "devices:read"]
        // Jamf Protect rides the integration on every backend.
        let protect = protectPermissions(for: all).filter { !always.contains($0) }
        guard api.usesPlatformIntegration else {
            var groups = [PrivilegeGroup(title: "Compliance Benchmarks", items: always)]
            if !protect.isEmpty { groups.append(PrivilegeGroup(title: "Jamf Protect", items: protect)) }
            return groups
        }
        if all.contains(where: { $0.modules.contains("myDevices") }) { always.append("users:read") }
        always.append("device-history:read")
        if all.contains(where: { $0.modules.contains("reports") }) {
            always.append("Buildings and departments read, for report filters (confirm)")
        }
        var groups = [PrivilegeGroup(title: api == .hybrid ? "Reads" : "Reads and Compliance Benchmarks", items: always)]
        if !protect.isEmpty { groups.append(PrivilegeGroup(title: "Jamf Protect", items: protect)) }
        guard api == .platform else { return groups }

        var actions: [String] = []
        let computer = all.reduce(into: Set<String>()) { $0.formUnion($1.computerActions) }
        let mobile = all.reduce(into: Set<String>()) { $0.formUnion($1.mobileDeviceActions) }
        let cleanup = all.reduce(into: Set<String>()) { $0.formUnion($1.cleanupActions) }
        if !computer.isEmpty || !mobile.isEmpty { actions += ["device-actions:execute", "device-actions:read"] }
        if computer.contains("viewLocalAdminPassword") || computer.contains("ssh")
            || ((screenShareAutoSignIn || screenSharePrompt) && computer.contains("screenShare")) {
            actions.append("local-admin-passwords:read")
        }
        if computer.contains("viewFileVaultKey") { actions.append("FileVault recovery key read (confirm)") }
        if computer.contains("moveToSite") || mobile.contains("moveToSite") { actions += ["sites:read", "devices:update"] }
        if computer.contains("assignPreStage") || all.contains(where: { $0.deviceTabs.contains("prestage") }) {
            actions += ["prestage-enrollments:read", "prestage-enrollments:update (confirm)",
                        "Inventory Preload read and write (confirm)"]
        }
        if computer.contains("wipe") || computer.contains("returnToService") || mobile.contains("wipe")
            || cleanup.contains("deleteRecord") {
            actions.append("destructive-device-actions:execute")
        }
        if all.contains(where: { $0.modules.contains("cleanup") }) {
            actions += ["sites:read", "device-groups:read"]
            if cleanup.contains("addToGroup") { actions.append("device-groups:update (confirm)") }
            if cleanup.contains("unmanage") || cleanup.contains("moveToSite") { actions.append("devices:update") }
        }
        var seen = Set(always + protect)
        let fresh = actions.filter { seen.insert($0).inserted }
        if !fresh.isEmpty { groups.append(PrivilegeGroup(title: "Actions", items: fresh)) }
        return groups
    }
}

// MARK: - What a role can do

extension SetupModel {

    struct RoleFunction: Identifiable {
        let label: String
        let granted: Bool
        /// What it needs in Jamf, or why it is off.
        let needs: String
        var id: String { label }
    }

    /// FleetHub's functions as `role` holds them, each with what it needs
    /// in Jamf under the chosen API. Shown beside the role's privilege list.
    func functions(for role: SetupRole) -> [RoleFunction] {
        let computer = role.computerActions
        let mobile = role.mobileDeviceActions
        let reads = api == .jamfPro ? "Read Computers, Read Mobile Devices" : "Read through the Platform integration"
        func entry(_ label: String, _ granted: Bool, _ needs: String) -> RoleFunction {
            RoleFunction(label: label, granted: granted, needs: granted ? needs : "Not granted to this role")
        }
        let commandSet: Set<String> = ["sendBlankPush", "restart", "restartSilent", "shutdown"]
        let remoteSet: Set<String> = ["enableRemoteDesktop", "disableRemoteDesktop", "enableBluetooth", "disableBluetooth"]
        let autoShare = (screenShareAutoSignIn || (screenSharePrompt && role.screenShareWithoutPrompt != true))
            && computer.contains("screenShare")
        return [
            entry("Search and View Devices", role.modules.contains("devices") || role.modules.contains("dashboard"), reads),
            entry("My Devices", role.modules.contains("myDevices") && myDevicesEnabled,
                  api == .jamfPro ? "Read Users" : "users:read on the Platform integration"),
            entry("Reports and Export", role.modules.contains("reports"),
                  role.allowExport ? "\(reads); export allowed" : "\(reads); export not allowed"),
            entry("Restart, Shut Down and Blank Push", !computer.isDisjoint(with: commandSet) || !mobile.isDisjoint(with: commandSet),
                  "Send and View MDM commands; Restart and Shut Down commands"),
            entry("Remote Desktop and Bluetooth", !computer.isDisjoint(with: remoteSet),
                  "Remote Desktop and Bluetooth commands"),
            entry("Screen Share", computer.contains("screenShare"),
                  autoShare ? "View Local Admin Password, for automatic sign-in or the approval prompt" : "No Jamf privilege; opens the built-in Screen Sharing"),
            entry("SSH", computer.contains("ssh"),
                  "View Local Admin Password; Remote Login must be on for the Mac and allow the management account"),
            entry("Unlock User Account", computer.contains("unlockUserAccount"), "Unlock User Account command"),
            entry("Local Admin Password", computer.contains("viewLocalAdminPassword"), "View Local Admin Password"),
            entry("FileVault Recovery Key", computer.contains("viewFileVaultKey"), "View Disk Encryption Recovery Key"),
            entry("Move to Site", computer.contains("moveToSite") || mobile.contains("moveToSite"),
                  "Read Sites; Update Computers or Mobile Devices"),
            entry("PreStage Assignment", computer.contains("assignPreStage") || role.deviceTabs.contains("prestage"),
                  "PreStage Enrollments and Inventory Preload, read and update"),
            entry("Apple Business Manager", computer.contains("abmAssign") || computer.contains("abmUnassign") || role.deviceTabs.contains("abmLookup"),
                  "No Jamf privilege; uses the ABM key entered in FleetHub"),
            entry("Wipe and Return to Service", computer.contains("wipe") || computer.contains("returnToService") || mobile.contains("wipe"),
                  "Remote Wipe command; Delete Computers for Return to Service"),
            entry("Cleanup", role.modules.contains("cleanup") && !role.cleanupActions.isEmpty,
                  "Update or Delete Computers; Static Computer Groups")
        ]
    }

    /// The Jamf API role a person holding `role` is given: the role's own,
    /// or the Core default.
    func jamfRoleName(for role: SetupRole) -> String {
        let own = role.jamfApiRoleName.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? defaultJamfRoleName.trimmingCharacters(in: .whitespaces) : own
    }

    // MARK: Domain status

    private static let baseline: [SetupDomain: NSDictionary] = {
        let fresh = SetupModel(restoring: false)
        return Dictionary(uniqueKeysWithValues: SetupDomain.allCases.map { ($0, fresh.dictionary(for: $0) as NSDictionary) })
    }()

    /// Whether the admin changed anything in `domain` from what Setup starts with.
    func isCustomized(_ domain: SetupDomain) -> Bool {
        !(dictionary(for: domain) as NSDictionary).isEqual(Self.baseline[domain])
    }

    /// One line on the choices made on the Start step.
    var startSummary: String {
        "\(api.title). " + (uploadProfiles ? "Delivering with configuration profiles." : "Export only. No uploads.")
    }

    var apiNote: String {
        switch api {
        case .jamfPro: "Compliance Benchmarks live only on the Platform API. You can stay on the Jamf Pro API and still add a Platform integration for them in step 3, Jamf Environment Setup."
        case .hybrid: "Everyone signed in reads inventory through the one integration, so FleetHub's roles limit who sees what. Actions stay personal. The integration must be renewed in Jamf Account every six months."
        case .platform: "On the Platform API there are no personal API clients. Role limits are enforced by FleetHub, and the integration must be renewed in Jamf Account every six months."
        }
    }
}

// MARK: - Saving and restoring

extension SetupModel {

    /// Everything the admin entered EXCEPT secrets. The upload client's
    /// secret and the Platform secret are deliberately not part of it: they
    /// are never written to disk, and are typed again after reopening.
    ///
    /// Every field is optional so a file saved by an older or newer Setup
    /// still opens: a field it lacks keeps this version's starting value.
    struct SavedSetup: Codable {
        var formatVersion: Int? = 1
        var step: Int?
        var api: SetupAPIChoice?
        var uploadProfiles: Bool?
        var uploadClientID: String?
        var platformRegion: String?
        var platformClientID: String?
        var platformTenantID: String?
        var platformEnvironmentID: String?
        var platformProtectTenantID: String?
        var jamfURL: String?
        var masterClientID: String?
        var autoCreateUserClients: Bool?
        var defaultJamfRoleName: String?
        var signInMethod: String?
        var entraTenantID: String?
        var entraClientID: String?
        var entraRedirectURI: String?
        var emailModeRoleName: String?
        var siteScoping: Bool?
        var abmEnabled: Bool?
        var abmClientID: String?
        var abmKeyID: String?
        var protectEnabled: Bool?
        var protectURL: String?
        var protectClientID: String?
        var entraCleanupEnabled: Bool?
        var entraCleanupTenantID: String?
        var entraCleanupClientID: String?
        var requireBiometric: Bool?
        var sessionTimeoutMinutes: Int?
        var roles: [SetupRole]?
        var staleDays: Int?
        var localAdminUsername: String?
        var showDeviceHistory: Bool?
        var screenShareAutoSignIn: Bool?
        var screenSharePrompt: Bool?
        var screenSharePromptMethod: String?
        var screenSharePromptTitle: String?
        var screenSharePromptMessage: String?
        var screenSharePromptIconPath: String?
        var screenSharePromptTimeoutSeconds: Int?
        var screenSharePromptAllowWhenNoUser: Bool?
        var sshPasswordRotationMinutes: Int?
        var vpnIPExtensionAttributeID: String?
        var myDevicesEnabled: Bool?
        var scorecardEnabled: Bool?
        var scorecardCheckedInDays: Int?
        var scorecardMinimumMacOS: Int?
        var scorecardMinimumIOS: Int?
        var scorecardRequiredApps: [String]?
        var scorecardContainsApps: [String]?
        var scorecardExclusions: [String: SetupCardExclusion]?
        var appTitle: String?
        var companyName: String?
        var supportURL: String?
        var accentColorHex: String?
        var defaultColorScheme: String?
    }

    var savedSetup: SavedSetup {
        SavedSetup(
            step: step.rawValue,
            api: api,
            uploadProfiles: uploadProfiles,
            uploadClientID: uploadClientID,
            platformRegion: platformRegion,
            platformClientID: platformClientID,
            platformTenantID: platformTenantID,
            platformEnvironmentID: platformEnvironmentID,
            platformProtectTenantID: platformProtectTenantID,
            jamfURL: jamfURL,
            masterClientID: masterClientID,
            autoCreateUserClients: autoCreateUserClients,
            defaultJamfRoleName: defaultJamfRoleName,
            signInMethod: signInMethod,
            entraTenantID: entraTenantID,
            entraClientID: entraClientID,
            entraRedirectURI: entraRedirectURI,
            emailModeRoleName: emailModeRoleName,
            siteScoping: siteScoping,
            abmEnabled: abmEnabled,
            abmClientID: abmClientID,
            abmKeyID: abmKeyID,
            protectEnabled: protectEnabled,
            protectURL: protectURL,
            protectClientID: protectClientID,
            entraCleanupEnabled: entraCleanupEnabled,
            entraCleanupTenantID: entraCleanupTenantID,
            entraCleanupClientID: entraCleanupClientID,
            requireBiometric: requireBiometric,
            sessionTimeoutMinutes: sessionTimeoutMinutes,
            roles: roles,
            staleDays: staleDays,
            localAdminUsername: localAdminUsername,
            showDeviceHistory: showDeviceHistory,
            screenShareAutoSignIn: screenShareAutoSignIn,
            screenSharePrompt: screenSharePrompt,
            screenSharePromptMethod: screenSharePromptMethod,
            screenSharePromptTitle: screenSharePromptTitle,
            screenSharePromptMessage: screenSharePromptMessage,
            screenSharePromptIconPath: screenSharePromptIconPath,
            screenSharePromptTimeoutSeconds: screenSharePromptTimeoutSeconds,
            screenSharePromptAllowWhenNoUser: screenSharePromptAllowWhenNoUser,
            sshPasswordRotationMinutes: sshPasswordRotationMinutes,
            vpnIPExtensionAttributeID: vpnIPExtensionAttributeID,
            myDevicesEnabled: myDevicesEnabled,
            scorecardEnabled: scorecardEnabled,
            scorecardCheckedInDays: scorecardCheckedInDays,
            scorecardMinimumMacOS: scorecardMinimumMacOS,
            scorecardMinimumIOS: scorecardMinimumIOS,
            scorecardRequiredApps: scorecardRequiredApps,
            scorecardContainsApps: scorecardContainsApps.sorted(),
            scorecardExclusions: scorecardExclusions,
            appTitle: appTitle,
            companyName: companyName,
            supportURL: supportURL,
            accentColorHex: accentColorHex,
            defaultColorScheme: defaultColorScheme
        )
    }

    func apply(_ saved: SavedSetup) {
        if let value = saved.api { api = value }
        if let value = saved.uploadProfiles { uploadProfiles = value }
        if let value = saved.uploadClientID { uploadClientID = value }
        if let value = saved.platformRegion { platformRegion = value }
        if let value = saved.platformClientID { platformClientID = value }
        if let value = saved.platformTenantID { platformTenantID = value }
        if let value = saved.platformEnvironmentID { platformEnvironmentID = value }
        if let value = saved.platformProtectTenantID { platformProtectTenantID = value }
        if let value = saved.jamfURL { jamfURL = value }
        if let value = saved.masterClientID { masterClientID = value }
        if let value = saved.autoCreateUserClients { autoCreateUserClients = value }
        if let value = saved.defaultJamfRoleName { defaultJamfRoleName = value }
        if let value = saved.signInMethod { signInMethod = value }
        if let value = saved.entraTenantID { entraTenantID = value }
        if let value = saved.entraClientID { entraClientID = value }
        if let value = saved.entraRedirectURI { entraRedirectURI = value }
        if let value = saved.emailModeRoleName { emailModeRoleName = value }
        if let value = saved.siteScoping { siteScoping = value }
        if let value = saved.abmEnabled { abmEnabled = value }
        if let value = saved.abmClientID { abmClientID = value }
        if let value = saved.abmKeyID { abmKeyID = value }
        if let value = saved.protectEnabled { protectEnabled = value }
        if let value = saved.protectURL { protectURL = value }
        if let value = saved.protectClientID { protectClientID = value }
        if let value = saved.entraCleanupEnabled { entraCleanupEnabled = value }
        if let value = saved.entraCleanupTenantID { entraCleanupTenantID = value }
        if let value = saved.entraCleanupClientID { entraCleanupClientID = value }
        if let value = saved.requireBiometric { requireBiometric = value }
        if let value = saved.sessionTimeoutMinutes { sessionTimeoutMinutes = value }
        if let value = saved.roles { roles = value }
        if let value = saved.staleDays { staleDays = value }
        if let value = saved.localAdminUsername { localAdminUsername = value }
        if let value = saved.showDeviceHistory { showDeviceHistory = value }
        if let value = saved.screenShareAutoSignIn { screenShareAutoSignIn = value }
        if let value = saved.screenSharePrompt { screenSharePrompt = value }
        if let value = saved.screenSharePromptMethod { screenSharePromptMethod = value }
        if let value = saved.screenSharePromptTitle { screenSharePromptTitle = value }
        if let value = saved.screenSharePromptMessage { screenSharePromptMessage = value }
        if let value = saved.screenSharePromptIconPath { screenSharePromptIconPath = value }
        if let value = saved.screenSharePromptTimeoutSeconds { screenSharePromptTimeoutSeconds = value }
        if let value = saved.screenSharePromptAllowWhenNoUser { screenSharePromptAllowWhenNoUser = value }
        if let value = saved.sshPasswordRotationMinutes { sshPasswordRotationMinutes = value }
        if let value = saved.vpnIPExtensionAttributeID { vpnIPExtensionAttributeID = value }
        if let value = saved.myDevicesEnabled { myDevicesEnabled = value }
        if let value = saved.scorecardEnabled { scorecardEnabled = value }
        if let value = saved.scorecardCheckedInDays { scorecardCheckedInDays = value }
        if let value = saved.scorecardMinimumMacOS { scorecardMinimumMacOS = value }
        if let value = saved.scorecardMinimumIOS { scorecardMinimumIOS = value }
        if let value = saved.scorecardRequiredApps { scorecardRequiredApps = value }
        if let value = saved.scorecardContainsApps { scorecardContainsApps = Set(value) }
        if let value = saved.scorecardExclusions { scorecardExclusions = value }
        if let value = saved.appTitle { appTitle = value }
        if let value = saved.companyName { companyName = value }
        if let value = saved.supportURL { supportURL = value }
        if let value = saved.accentColorHex { accentColorHex = value }
        if let value = saved.defaultColorScheme { defaultColorScheme = value }
        if let raw = saved.step, let restored = SetupStep(rawValue: raw) { step = restored }
    }

    func encodedSetup() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(savedSetup)
    }

    func load(from data: Data) throws {
        apply(try JSONDecoder().decode(SavedSetup.self, from: data))
    }

    /// Back to how Setup starts, secrets included.
    func startOver() {
        let fresh = SetupModel(restoring: false)
        apply(fresh.savedSetup)
        uploadClientSecret = ""
        platformClientSecret = ""
        step = .start
    }

    // MARK: Automatic saving

    /// Where Setup keeps the work in progress between launches. It lives in
    /// the user's Application Support folder, not inside the app, so
    /// installing a newer Setup leaves it alone.
    static var autosaveURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FleetHub Setup", isDirectory: true).appendingPathComponent("Setup In Progress.json")
    }

    /// Writes the current settings to the automatic save. Returns false if
    /// the write failed.
    @discardableResult
    func autosave() -> Bool {
        do {
            let url = Self.autosaveURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encodedSetup().write(to: url, options: .atomic)
            lastSaved = Date()
            return true
        } catch {
            return false
        }
    }

    /// Loads the automatic save if there is one. Returns true when settings
    /// were restored.
    @discardableResult
    func restoreAutosave() -> Bool {
        guard let data = try? Data(contentsOf: Self.autosaveURL) else { return false }
        do {
            try load(from: data)
            return true
        } catch {
            return false
        }
    }
}
