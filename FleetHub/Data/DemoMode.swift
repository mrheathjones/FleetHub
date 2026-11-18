//
//  DemoMode.swift
//  FleetHub
//
//  DEBUG-ONLY demo mode: launch with `-FleetHubDemo` to skip sign-in and
//  browse the app with generated sample data. Nothing in this file exists
//  in a Release build, so a shipped app cannot bypass sign-in this way.
//
//  Safety: every Jamf / Entra / ABM token minter throws while the flag is
//  set (see the `-FleetHubDemo` guards in the token providers), so no action
//  taken in demo mode can reach a real tenant — even on a Mac that holds
//  real credentials.
//

#if DEBUG
import Foundation
import AppKit

enum DemoMode {

    /// The launch argument that turns demo mode on.
    static let launchArgument = "-FleetHubDemo"

    static let isEnabled = ProcessInfo.processInfo.arguments.contains(launchArgument)

    /// `-FleetHubPreview <screen>`: opens one pre-dashboard screen for a
    /// layout check. Read from the launch-argument domain only.
    static let previewScreen: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-FleetHubPreview"),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }()

    /// `-FleetHubSnapshots <folder>`: the app walks its own screens and saves
    /// a picture of each into the folder, for documentation. It draws its
    /// own window only, so nothing else on screen is captured.
    static let snapshotDirectory: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-FleetHubSnapshots"),
              arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()

    @MainActor
    static func resizeWindow(width: CGFloat, height: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { return }
        var frame = window.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = top - height
        window.setFrame(frame, display: true)
    }

    @MainActor
    static func snapshot(_ name: String, titled title: String? = nil) {
        guard let directory = snapshotDirectory,
              let window = NSApp.windows.first(where: {
                  $0.isVisible && $0.contentView != nil && (title == nil || $0.title.contains(title ?? ""))
              }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).png")
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        NSLog("SNAPSHOT %@ %dx%d", name, bitmap.pixelsWide, bitmap.pixelsHigh)
    }

    /// Full JSON for each generated computer, keyed by Jamf id, so the detail
    /// view can show the same device the list showed.
    private static var computerJSON: [String: Data] = [:]

    // MARK: - Activation

    /// Signs in a sample operator with every capability and seeds both
    /// inventory caches. Returns the counts the dashboard opens with.
    @MainActor
    static func activate() -> DeviceCounts {
        UserSession.shared.establish(
            email: "sam.rivera@example.org",
            displayName: "Sam Rivera",
            roles: ["Help Desk"],
            capabilities: capabilities
        )

        // Scorecard rules are profile-defined; without a features profile the
        // cards have nothing to evaluate, so the demo supplies its own.
        if let features = demoFeatures() {
            MDMConfigurationManager.shared.applyDemoFeatures(features)
        }

        let computers = makeComputers()
        ComputerInventoryCache.shared.updateCache(computers: computers, totalCount: computers.count)

        let mobiles = makeMobileDevices()
        MobileDeviceInventoryCache.shared.updateCache(devices: mobiles, totalCount: mobiles.count)

        HealthMetricsCalculator.shared.recalculateMetrics()

        let mobileCache = MobileDeviceInventoryCache.shared
        return DeviceCounts(
            macOS: computers.count,
            iOS: mobileCache.iOSCount,
            iPadOS: mobileCache.iPadOSCount,
            visionOS: mobileCache.visionOSCount
        )
    }

    /// Everything on, so every screen and menu can be looked at. Execution
    /// is still impossible: the token minters refuse in demo mode.
    private static var capabilities: UserCapabilities {
        UserCapabilities(
            // Pill order follows module order: the order of the design mock.
            modules: ["dashboard", "devices", "myDevices", "reports", "cleanup", "logs", "announcements", "settings"],
            deviceTabs: DevicesTab.allCases.map(\.rawValue),
            computerActions: Set(DeviceAction.allCases.map(\.rawValue)),
            mobileDeviceActions: Set(DeviceAction.allCases.map(\.rawValue)),
            cleanupActions: Set(CleanupAction.allCases.map(\.configID)),
            allowedMdmServers: ["all"],
            allowedPrestages: ["all"],
            allowedSites: ["all"],
            allowExport: true,
            allowScorecardDiagnostics: true
        )
    }

    /// Sample scorecard rules covering the three demo sites.
    private static func demoFeatures() -> FeaturesConfiguration? {
        let json = """
        {
          "computers": { "vpnIPExtensionAttributeID": 9001 },
          "healthScorecard": {
            "enabled": true,
            "cards": [
              { "id": "checkedIn", "enabled": true, "siteIds": ["1", "2", "3"], "checkedInDays": 30 },
              { "id": "protected", "enabled": true, "platforms": ["macOS"], "siteIds": ["1", "2", "3"],
                "requireMode": "all", "requiredApps": [ { "name": "Xcode" } ] },
              { "id": "encrypted", "enabled": true, "siteIds": ["1", "2", "3"] },
              { "id": "secured", "enabled": true, "platforms": ["macOS"], "siteIds": ["1", "2", "3"],
                "checks": ["firewall", "sip", "gatekeeper", "managed", "supervised", "diskEncrypted"] },
              { "id": "upToDate", "enabled": true, "siteIds": ["1", "2", "3"],
                "minimumOSVersions": { "macOS": 26, "iOS": 26, "iPadOS": 26, "visionOS": 2 } }
            ]
          }
        }
        """
        do {
            return try JSONDecoder().decode(FeaturesConfiguration.self, from: Data(json.utf8))
        } catch {
            NSLog("DemoMode: sample features did not decode: %@", String(describing: error))
            return nil
        }
    }

    /// The full sample record for a computer the demo generated, or nil for
    /// an id it did not generate.
    static func computer(id: String) -> Computer? {
        guard let data = computerJSON[id] else {
            NSLog("DemoMode: no sample computer with id %@", id)
            return nil
        }
        do {
            return try JSONDecoder().decode(Computer.self, from: data)
        } catch {
            NSLog("DemoMode: sample computer %@ detail did not decode: %@", id, String(describing: error))
            return nil
        }
    }

    // MARK: - Overview samples

    // Shown on the Overview only. They are never written to the real
    // action-log store, so the Logs page still shows what is actually on
    // this Mac.

    static var recentActions: [ActionLogEntry] {
        let samples: [(String, String, String, String, TimeInterval, Bool)] = [
            ("Restart", "Power", "DEMO-MBP-0001", "Sam Rivera", 4 * 60, true),
            ("Viewed local admin password", "Security", "DEMO-MBA-0002", "Sam Rivera", 32 * 60, true),
            ("Moved to site", "Site", "DEMO-MINI-0004", "Jo Park", 3_600, true),
            ("Return to Service", "Device Actions", "DEMO-IMAC-0005", "Jo Park", 2 * 3_600, false)
        ]
        return samples.enumerated().map { index, sample in
            ActionLogEntry(
                timestamp: Date().addingTimeInterval(-sample.4),
                actionName: sample.0,
                actionCategory: sample.1,
                deviceName: sample.2,
                deviceSerialNumber: "C02DEMO000\(index + 1)",
                deviceId: String(1000 + index),
                performedBy: sample.3,
                success: sample.5
            )
        }
    }

    // MARK: - Sample computers

    private struct ModelSpec {
        let name: String
        let identifier: String
        let prefix: String
    }

    private static let models: [ModelSpec] = [
        ModelSpec(name: "MacBook Pro (14-inch, M4)", identifier: "Mac16,1", prefix: "MBP"),
        ModelSpec(name: "MacBook Air (13-inch, M3)", identifier: "Mac15,12", prefix: "MBA"),
        ModelSpec(name: "MacBook Pro (16-inch, M3 Pro)", identifier: "Mac15,7", prefix: "MBP"),
        ModelSpec(name: "Mac mini (M4)", identifier: "Mac16,10", prefix: "MINI"),
        ModelSpec(name: "iMac (24-inch, M3)", identifier: "Mac15,5", prefix: "IMAC"),
        ModelSpec(name: "Mac Studio (M2 Max)", identifier: "Mac14,13", prefix: "STUDIO")
    ]

    private static let people: [(user: String, name: String)] = [
        ("achen", "Alex Chen"), ("bokafor", "Blessing Okafor"), ("dsilva", "Dana Silva"),
        ("ewong", "Eli Wong"), ("fmartin", "Fran Martin"), ("gnovak", "Greta Novak"),
        ("hpatel", "Hari Patel"), ("ikim", "Ina Kim"), ("jlopez", "Jo Lopez"),
        ("kross", "Kai Ross"), ("mdiaz", "Mara Diaz"), ("nabe", "Noa Abe")
    ]

    private static let sites: [(id: String, name: String)] = [
        ("1", "East"), ("2", "West"), ("3", "Central")
    ]

    private static let osVersions = ["26.1.0", "26.1.0", "26.1.0", "26.0.1", "15.7.2", "15.6.1", "14.8.1"]

    /// Days since last check-in. Mostly recent, with a tail of stale devices
    /// so Cleanup and the Checked-In metric have something to show.
    private static let staleness = [0, 0, 0, 0, 1, 1, 2, 3, 5, 8, 34, 0, 0, 1, 2, 57, 0, 0, 4, 92, 0, 1, 0, 128]

    private static func makeComputers() -> [ComputerInventoryItem] {
        guard let baseData = MockData.testComputerJSON.data(using: .utf8),
              let base = try? JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            return []
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decoder = JSONDecoder()
        var items: [ComputerInventoryItem] = []

        for index in 0..<72 {
            let model = models[index % models.count]
            let person = people[index % people.count]
            let site = sites[index % sites.count]
            let os = osVersions[index % osVersions.count]
            let daysStale = staleness[index % staleness.count]
            let number = String(format: "%04d", index + 1)
            let id = String(1000 + index)
            // Hours are spread so "last check-in" is not identical everywhere.
            let lastContact = Date().addingTimeInterval(-Double(daysStale) * 86_400 - Double(index % 9) * 1_800)
            let encrypted = index % 11 != 7
            let firewall = index % 9 != 4

            var record = base
            record["id"] = id
            record["udid"] = "DEMO-UDID-\(number)"

            var general = record["general"] as? [String: Any] ?? [:]
            general["name"] = "DEMO-\(model.prefix)-\(number)"
            general["assetTag"] = "IT-\(number)"
            // Every other sample Mac is "on VPN", to show the VPN address.
            if index % 2 == 0 {
                var attributes = general["extensionAttributes"] as? [[String: Any]] ?? []
                attributes.append([
                    "definitionId": 9001, "name": "VPN IP Address", "description": "",
                    "values": ["10.99.\(index % 200).\(20 + index % 200)"], "dataType": "STRING",
                    "options": [], "inputType": "SCRIPT", "enabled": true, "multiValue": false
                ])
                general["extensionAttributes"] = attributes
            }
            general["lastContactTime"] = isoFormatter.string(from: lastContact)
            general["reportDate"] = isoFormatter.string(from: lastContact)
            general["site"] = ["id": site.id, "name": site.name]
            general["lastLoggedInUsernameBinary"] = person.user
            general["lastIpAddress"] = "203.0.113.\(10 + index % 200)"
            general["lastReportedIp"] = "10.20.\(index % 8).\(20 + index % 200)"
            general["lastReportedIpV4"] = general["lastReportedIp"]
            // A few Macs without DDM, so the Overview figure is not 100%.
            general["declarativeDeviceManagementEnabled"] = index % 9 != 6
            record["general"] = general

            var hardware = record["hardware"] as? [String: Any] ?? [:]
            hardware["model"] = model.name
            hardware["modelIdentifier"] = model.identifier
            hardware["serialNumber"] = "C02DEMO\(number)"
            record["hardware"] = hardware

            var operatingSystem = record["operatingSystem"] as? [String: Any] ?? [:]
            operatingSystem["version"] = os
            operatingSystem["fileVault2Status"] = encrypted ? "BOOT_ENCRYPTED" : "NOT_ENCRYPTED"
            record["operatingSystem"] = operatingSystem

            var userAndLocation = record["userAndLocation"] as? [String: Any] ?? [:]
            userAndLocation["username"] = person.user
            userAndLocation["realname"] = person.name
            userAndLocation["email"] = "\(person.user)@example.org"
            userAndLocation["buildingId"] = String(index % 3 + 1)
            userAndLocation["departmentId"] = String(index % 4 + 1)
            record["userAndLocation"] = userAndLocation

            var diskEncryption = record["diskEncryption"] as? [String: Any] ?? [:]
            // As in real Jamf records: the flag is absent and only the boot
            // partition state says whether the Mac is encrypted.
            diskEncryption.removeValue(forKey: "fileVault2Enabled")
            var boot = diskEncryption["bootPartitionEncryptionDetails"] as? [String: Any] ?? [:]
            boot["partitionFileVault2State"] = encrypted ? "ENCRYPTED" : "UNENCRYPTED"
            boot["partitionFileVault2Percent"] = encrypted ? 100 : 0
            diskEncryption["bootPartitionEncryptionDetails"] = boot
            record["diskEncryption"] = diskEncryption

            var security = record["security"] as? [String: Any] ?? [:]
            security["firewallEnabled"] = firewall
            record["security"] = security

            // Only devices on an older OS have an update waiting.
            if os.hasPrefix("26.1") {
                record["softwareUpdates"] = [[String: Any]]()
            }

            // A fifth of the fleet is missing the app the Protected card requires.
            if index % 5 == 3, var apps = record["applications"] as? [[String: Any]], !apps.isEmpty {
                apps.removeFirst()
                record["applications"] = apps
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: record)
                // The list item model is stricter than the detail model about
                // extension-attribute ids, and the list never shows them.
                var listRecord = record
                var listGeneral = general
                listGeneral.removeValue(forKey: "extensionAttributes")
                listRecord["general"] = listGeneral
                let listData = try JSONSerialization.data(withJSONObject: listRecord)
                let item = try decoder.decode(ComputerInventoryItem.self, from: listData)
                computerJSON[id] = data
                items.append(item)
            } catch {
                NSLog("DemoMode: sample computer %@ did not decode: %@", id, String(describing: error))
            }
        }
        return items
    }

    // MARK: - Sample mobile detail

    /// A detail record for a mobile device the demo generated, built from
    /// its inventory item, or nil for an id it did not generate.
    @MainActor
    static func mobileDevice(id: String) -> MobileDevice? {
        guard let item = MobileDeviceInventoryCache.shared.devices.first(where: { $0.id == id }) else {
            NSLog("DemoMode: no sample mobile device with id %@", id)
            return nil
        }
        let site = sites.first { $0.id == item.general?.siteId }
        let lastUpdate = item.general?.lastInventoryUpdateDate ?? ""
        var record: [String: Any] = [
            "id": id,
            "name": item.general?.displayName ?? "Unknown",
            "assetTag": item.general?.assetTag ?? "",
            "lastInventoryUpdateTimestamp": lastUpdate,
            "osVersion": item.general?.osVersion ?? "",
            "osBuild": "23B85",
            "serialNumber": item.hardware?.serialNumber ?? "",
            "udid": item.general?.udid ?? "",
            "initialEntryTimestamp": lastUpdate,
            "ipAddress": item.general?.ipAddress ?? "",
            "enrollmentMethod": "Automated Device Enrollment",
            "lastEnrollmentTimestamp": lastUpdate,
            "managed": item.general?.managed ?? true,
            "type": (item.deviceType ?? "iOS").lowercased(),
            "location": [
                "username": item.userAndLocation?.username ?? "",
                "realName": item.userAndLocation?.realName ?? "",
                "emailAddress": item.userAndLocation?.emailAddress ?? ""
            ]
        ]
        if let site {
            record["site"] = ["id": site.id, "name": site.name]
        }
        let platformDetail: [String: Any] = [
            "model": item.hardware?.model ?? "",
            "modelIdentifier": item.hardware?.modelIdentifier ?? "",
            "supervised": item.general?.supervised ?? false
        ]
        record[(item.deviceType ?? "iOS").lowercased() == "visionos" ? "visionos" : "ios"] = platformDetail

        do {
            let data = try JSONSerialization.data(withJSONObject: record)
            return try JSONDecoder().decode(MobileDevice.self, from: data)
        } catch {
            NSLog("DemoMode: sample mobile device %@ detail did not decode: %@", id, String(describing: error))
            return nil
        }
    }

    // MARK: - Sample mobile devices

    private static let mobileModels: [(type: String, model: String, identifier: String, prefix: String, os: String)] = [
        ("iOS", "iPhone 16", "iPhone17,3", "IPHONE", "26.1"),
        ("iOS", "iPhone 15", "iPhone15,4", "IPHONE", "26.0.1"),
        ("iOS", "iPad Air (11-inch, M2)", "iPad14,8", "IPAD", "26.1"),
        ("iOS", "iPad (10th generation)", "iPad13,18", "IPAD", "18.6"),
        ("iOS", "iPhone 16 Pro", "iPhone17,1", "IPHONE", "26.1"),
        ("visionOS", "Apple Vision Pro", "RealityDevice14,1", "VISION", "26.1")
    ]

    private static func makeMobileDevices() -> [MobileDeviceInventoryItem] {
        let isoFormatter = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        var items: [MobileDeviceInventoryItem] = []

        for index in 0..<34 {
            // One Vision Pro in every twelve; the rest cycle iPhone / iPad.
            let model = index % 12 == 11 ? mobileModels[5] : mobileModels[index % 5]
            let person = people[(index + 3) % people.count]
            let number = String(format: "%04d", index + 1)
            let lastUpdate = Date().addingTimeInterval(-Double(staleness[(index + 5) % staleness.count]) * 86_400)
            let usedPercent = 20 + (index * 7) % 70

            let record: [String: Any] = [
                "mobileDeviceId": String(5000 + index),
                "deviceType": model.type,
                "general": [
                    "udid": "DEMO-MOBILE-UDID-\(number)",
                    "displayName": "DEMO-\(model.prefix)-\(number)",
                    "assetTag": "IT-M\(number)",
                    "siteId": sites[index % sites.count].id,
                    "lastInventoryUpdateDate": isoFormatter.string(from: lastUpdate),
                    "osVersion": model.os,
                    "ipAddress": "10.30.\(index % 6).\(20 + index)",
                    "managed": true,
                    "supervised": index % 6 != 5
                ],
                "hardware": [
                    "capacityMb": 256_000,
                    "availableSpaceMb": 256_000 * (100 - usedPercent) / 100,
                    "usedSpacePercentage": usedPercent,
                    "batteryLevel": 30 + (index * 11) % 70,
                    "serialNumber": "F17DEMO\(number)",
                    "model": model.model,
                    "modelIdentifier": model.identifier
                ],
                "userAndLocation": [
                    "username": person.user,
                    "realName": person.name,
                    "emailAddress": "\(person.user)@example.org"
                ]
            ]

            guard let data = try? JSONSerialization.data(withJSONObject: record),
                  let item = try? decoder.decode(MobileDeviceInventoryItem.self, from: data) else {
                continue
            }
            items.append(item)
        }
        return items
    }
}
// MARK: - Compliance and DDM samples

extension DemoMode {
    private static func sampleRules(_ rows: [(String, String, String, Int, Int, Int)]) -> [ComplianceRuleStat] {
        rows.map {
            ComplianceRuleStat(
                ruleId: $0.0, ruleTitle: $0.1, ruleNumber: $0.2,
                passed: $0.3, failed: $0.4, unknown: $0.5, numberOfDevices: $0.3 + $0.4 + $0.5
            )
        }
    }

    /// Two sample benchmarks for the Overview card and the device page.
    static let complianceBenchmarks: [ComplianceBenchmarkSummary] = [
        ComplianceBenchmarkSummary(
            id: "demo-cis-l1",
            title: "CIS Level 1",
            description: "Sample benchmark",
            syncState: "SYNCED",
            compliancePercentage: 86.4,
            rules: sampleRules([
                ("os_firewall_enable", "Enable the Application Firewall", "2.2.1", 58, 14, 0),
                ("os_gatekeeper_enable", "Enable Gatekeeper", "2.6.1", 72, 0, 0),
                ("os_filevault_enable", "Enable FileVault", "2.6.6", 61, 9, 2),
                ("os_sip_enable", "Ensure System Integrity Protection Is Enabled", "5.1.2", 72, 0, 0),
                ("os_screensaver_timeout", "Set an Inactivity Interval of 20 Minutes or Less", "2.10.1", 49, 21, 2),
                ("os_guest_account_disable", "Disable the Guest Account", "2.12.1", 70, 2, 0),
                ("os_auto_update_enable", "Enable Automatic Software Updates", "1.2", 66, 6, 0),
                ("os_airdrop_disable", "Disable AirDrop", "2.3.1.1", 72, 0, 0)
            ])
        ),
        ComplianceBenchmarkSummary(
            id: "demo-nist-800-53",
            title: "NIST 800-53r5 Moderate",
            description: "Sample benchmark",
            syncState: "SYNCED",
            compliancePercentage: 68.9,
            rules: sampleRules([
                ("auth_smartcard_enforce", "Enforce Smart Card Authentication", "IA-2", 12, 58, 2),
                ("os_password_min_length", "Require a Minimum Password Length of 15", "IA-5", 44, 28, 0),
                ("audit_flags_configure", "Configure Audit Flags", "AU-12", 63, 7, 2),
                ("os_bluetooth_disable", "Disable Bluetooth When Not Required", "AC-18", 39, 33, 0),
                ("os_ssh_disable", "Disable Remote Login", "AC-17", 68, 4, 0),
                ("os_time_server_enforce", "Enforce a Time Server", "AU-8", 72, 0, 0)
            ])
        )
    ]

    /// One device's result: a fixed, plausible subset of the sample rules
    /// fails, chosen from the serial so different sample Macs differ.
    static func deviceCompliance(serialNumber: String?) -> [DeviceBenchmarkCompliance] {
        let seed = (serialNumber ?? "").unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return complianceBenchmarks.enumerated().map { offset, benchmark in
            DeviceBenchmarkCompliance(
                benchmarkID: benchmark.id,
                title: benchmark.title,
                rules: benchmark.rules.enumerated().map { index, rule in
                    let pick = index + seed + offset
                    let state: DeviceRuleState
                    if rule.failed > 0, pick % 3 == 0 {
                        state = .failed
                    } else if rule.unknown > 0, pick % 2 == 0 {
                        state = .unknown
                    } else if pick % 11 == 0 {
                        state = .notReported
                    } else {
                        state = .passed
                    }
                    return .init(ruleId: rule.ruleId, ruleTitle: rule.ruleTitle, ruleNumber: rule.ruleNumber,
                                 discussion: rule.discussion, state: state)
                }
            )
        }
    }

    /// Sample DDM status items, as a Mac reports them.
    static let ddmStatusItems: [DDMStatusItem] = {
        let stamp = "2026-11-17T09:14:22"
        let rows: [(String, String)] = [
            ("device.identifier.serial-number", "C02DEMO0001"),
            ("device.identifier.udid", "DEMO-UDID-0001"),
            ("device.model.family", "Mac"),
            ("device.model.identifier", "Mac16,1"),
            ("device.model.marketing-name", "MacBook Pro (14-inch, M4)"),
            ("device.operating-system.build-version", "25B78"),
            ("device.operating-system.family", "macOS"),
            ("device.operating-system.version", "26.1"),
            ("device.power.battery-health", "normal"),
            ("management.client-capabilities", "supported-versions: 1.0.0; supported-features: status-reports, software-update"),
            ("softwareupdate.install-state", "none"),
            ("softwareupdate.pending-version", ""),
            ("diskmanagement.filevault.enabled", "true"),
            ("passcode.is-compliant", "true")
        ]
        return rows.map { DDMStatusItem(key: $0.0, value: $0.1, lastUpdateTime: stamp) }
    }()
}

// MARK: - Saved report samples

extension DemoMode {
    /// Sample saved reports for the Reports page. Never written to the real
    /// saved-report store.
    static let savedReports: [SavedReport] = {
        let day: TimeInterval = 86_400
        let now = Date()
        func id(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", n)) ?? UUID()
        }
        return [
            SavedReport(
                id: id(1),
                name: "Macs Not Checked In for 30 Days",
                description: "Weekly follow-up list for the help desk.",
                platforms: [.macOS],
                filters: [
                    ReportFilter(category: .lastCheckIn, parameters: .lastCheckIn(comparison: .moreThan, value: 30, unit: .days))
                ],
                createdAt: now.addingTimeInterval(-41 * day),
                lastRunAt: now.addingTimeInterval(-2 * day)
            ),
            SavedReport(
                id: id(2),
                name: "Unencrypted Macs in East",
                description: "FileVault gaps at the East site.",
                platforms: [.macOS],
                filters: [
                    ReportFilter(category: .encryption, parameters: .encryption(status: .notEncrypted)),
                    ReportFilter(category: .site, parameters: .site(name: "East", comparison: .memberOf))
                ],
                createdAt: now.addingTimeInterval(-18 * day),
                lastRunAt: now.addingTimeInterval(-18 * day)
            ),
            SavedReport(
                id: id(3),
                name: "Mobile Devices Below iOS 26",
                description: "",
                platforms: [.iOS, .iPadOS],
                filters: [
                    ReportFilter(category: .osVersion, parameters: .osVersion(version: "26.0", comparison: "Below")),
                    ReportFilter(category: .supervision, parameters: .supervision(status: .supervised))
                ],
                includeEnrollment: true,
                createdAt: now.addingTimeInterval(-9 * day)
            ),
            SavedReport(
                id: id(4),
                name: "Pending Software Updates",
                description: "Every platform, for the monthly patch review.",
                platforms: Set(PlatformType.displayCases),
                filters: [
                    ReportFilter(category: .softwareUpdates, parameters: .softwareUpdates(status: .hasPendingUpdates)),
                    ReportFilter(category: .lastCheckIn, parameters: .lastCheckIn(comparison: .within, value: 14, unit: .days)),
                    ReportFilter(category: .site, parameters: .site(name: "West", comparison: .memberOf)),
                    ReportFilter(category: .appleCare, parameters: .appleCare(status: .active))
                ],
                createdAt: now.addingTimeInterval(-3 * day),
                lastRunAt: now.addingTimeInterval(-3_600)
            )
        ]
    }()
}

// MARK: - Action log samples

extension DemoMode {
    /// A few days of sample audit entries for the Logs page. Never written
    /// to the real action-log store.
    static let actionLogs: [ActionLogEntry] = {
        let actions: [(name: String, category: String, ok: Bool, error: String?)] = [
            ("Restart", "Power", true, nil),
            ("Viewed local admin password", "Security", true, nil),
            ("Moved to site", "Site", true, nil),
            ("Blank push sent", "Inventory", true, nil),
            ("Return to Service", "Destructive", false, "The device did not acknowledge the erase command."),
            ("Viewed FileVault key", "Security", true, nil),
            ("Assigned PreStage", "Inventory", true, nil),
            ("Unlocked user account", "Security", true, nil),
            ("Shut down", "Power", true, nil),
            ("Update inventory", "Inventory", true, nil),
            ("Lock device", "Security", false, "Jamf Pro returned 409: a lock command is already pending.")
        ]
        let operators = ["Sam Rivera", "Jo Park", "Sam Rivera", "Lee Tran"]
        let base = Date()
        return (0..<64).map { index in
            let action = actions[index % actions.count]
            let model = models[(index * 3) % models.count]
            let number = String(format: "%04d", 1 + (index * 13) % 72)
            return ActionLogEntry(
                // Fixed ids so an expanded row survives a re-render.
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index)) ?? UUID(),
                timestamp: base.addingTimeInterval(-Double(index) * 4_300 - 240),
                actionName: action.name,
                actionCategory: action.category,
                deviceName: "DEMO-\(model.prefix)-\(number)",
                deviceSerialNumber: "C02DEMO\(number)",
                deviceId: String(1000 + (index * 13) % 72),
                performedBy: operators[index % operators.count],
                ipAddressUsed: index % 4 == 0 ? "10.20.\(index % 6).\(40 + index)" : nil,
                success: action.ok,
                errorMessage: action.error,
                source: index % 9 == 5 ? .jamfPolicy : .fleetHub
            )
        }
    }()
}

// MARK: - My Devices samples

extension DemoMode {
    /// One Mac, one iPhone and one iPad from the seeded inventory, standing
    /// in for the devices assigned to the sample operator.
    @MainActor
    static var myDevices: [MyDevice] {
        var devices: [MyDevice] = []
        if let mac = computer(id: "1000") {
            devices.append(.computer(mac))
        }
        let mobiles = MobileDeviceInventoryCache.shared.devices
        for index in [0, 2] where mobiles.indices.contains(index) {
            devices.append(.mobileDevice(mobiles[index]))
        }
        return devices
    }
}

// MARK: - Cleanup samples

extension DemoMode {
    /// Matches the number of sample Macs the demo seeds.
    static let computerCount = 72

    /// (days since check-in, managed). A spread from just-stale to never
    /// seen, so every Cleanup scope and both badge colours have rows.
    private static let cleanupStaleness: [(days: Int?, managed: Bool)] = [
        (128, true), (106, true), (90, true), (69, true), (57, true), (46, true),
        (38, true), (33, true), (412, true), (377, true), (212, true), (151, true),
        (84, true), (63, true), (41, true), (35, true), (498, false), (240, false),
        (95, false), (nil, true), (72, true), (52, true)
    ]

    /// East-heavy, so the per-site bars differ.
    private static let cleanupSites = ["East", "West", "East", "Central", "East", "West", "East", "West", "Central"]

    static func staleDevices(olderThanDays threshold: Int) -> [StaleDevice] {
        cleanupStaleness.enumerated().compactMap { index, entry in
            if let days = entry.days, days < threshold { return nil }
            let model = models[index % models.count]
            let person = people[(index * 5) % people.count]
            let number = String(format: "%04d", 200 + index * 7)
            return StaleDevice(
                id: 9_000 + index,
                name: "DEMO-\(model.prefix)-\(number)",
                serialNumber: "C02DEMO\(number)",
                model: model.name,
                userEmail: "\(person.user)@example.org",
                username: person.user,
                lastContactTime: entry.days.map { Date().addingTimeInterval(-Double($0) * 86_400 - 3_600) },
                isManaged: entry.managed,
                managementId: nil,
                siteName: cleanupSites[index % cleanupSites.count]
            )
        }
    }

    static var protectDevices: [ProtectDevice] {
        let days = [0, 1, 2, 3, 5, 9, 14, 21, 36, 48, 61, 77, 93, 130, 205]
        return days.enumerated().map { index, age in
            let number = String(format: "%04d", 300 + index * 3)
            return ProtectDevice(
                uuid: "DEMO-PROTECT-\(number)",
                hostName: "DEMO-MBP-\(number)",
                serial: "C02DEMO\(number)",
                checkin: Date().addingTimeInterval(-Double(age) * 86_400 - 1_800)
            )
        }
    }
}

extension StaleDevice {
    /// Sample rows only; real rows come from `init?(record:)`.
    fileprivate init(
        id: Int, name: String, serialNumber: String, model: String, userEmail: String,
        username: String, lastContactTime: Date?, isManaged: Bool, managementId: String?, siteName: String
    ) {
        self.id = id
        self.name = name
        self.serialNumber = serialNumber
        self.model = model
        self.userEmail = userEmail
        self.username = username
        self.lastContactTime = lastContactTime
        self.isManaged = isManaged
        self.managementId = managementId
        self.siteName = siteName
    }
}
#endif
