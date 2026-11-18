//
//  ActionLogService.swift
//  FleetHub
//
//  Singleton service for auditing MDM actions with disk persistence
//

import Foundation

/// Versioned envelope written to `action_logs.json`. Older builds wrote a
/// bare `[ActionLogEntry]`; `loadFromDisk` still reads that shape. Kept at
/// file scope (not nested in the @MainActor class) so it can be encoded on
/// the background I/O queue.
private struct ActionLogFile: Codable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let entries: [ActionLogEntry]
}

@MainActor
class ActionLogService: ObservableObject {
    static let shared = ActionLogService()
    
    // MARK: - Published Properties
    
    @Published private(set) var logs: [ActionLogEntry] = []
    @Published private(set) var isLoading: Bool = false
    
    // MARK: - File Paths
    
    nonisolated private static let logsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FleetHub/Logs", isDirectory: true)
    }()
    
    nonisolated private static let logsFileURL: URL = {
        logsDirectory.appendingPathComponent("action_logs.json")
    }()
    
    /// Serial FIFO queue for disk writes so a later snapshot can never land
    /// before an earlier one (the previous per-save `Task.detached` could
    /// reorder writes).
    nonisolated private static let ioQueue = DispatchQueue(
        label: "com.herojoneslabs.fleethub.actionlog.io",
        qos: .utility
    )
    
    /// Set when the on-disk file could not be read AND could not be moved
    /// aside. While true, no write ever touches `action_logs.json`, so an
    /// unreadable audit trail is never silently replaced.
    private var diskWritesSuppressed = false
    
    // MARK: - Init
    
    private init() {
        ensureDirectoryExists()
        loadFromDisk()
    }
    
    // MARK: - Public Methods
    
    /// Log a new action entry. Auto-saves to disk.
    func logAction(
        actionName: String,
        actionCategory: String,
        deviceName: String,
        deviceSerialNumber: String,
        deviceId: String,
        devicePlatform: String = "macOS",
        performedBy: String? = nil,
        ipAddressUsed: String? = nil,
        success: Bool,
        errorMessage: String? = nil,
        source: ActionLogEntry.LogSource = .fleetHub
    ) {
        let userEmail = performedBy ?? KeychainManager.shared.loadUserEmail() ?? "Unknown"
        
        let entry = ActionLogEntry(
            actionName: actionName,
            actionCategory: actionCategory,
            deviceName: deviceName,
            deviceSerialNumber: deviceSerialNumber,
            deviceId: deviceId,
            devicePlatform: devicePlatform,
            performedBy: userEmail,
            ipAddressUsed: ipAddressUsed,
            success: success,
            errorMessage: errorMessage,
            source: source
        )
        
        logs.insert(entry, at: 0) // Newest first
        applyRetention()
        saveToDisk()
        AppLog.notice("📋 ActionLogService: Logged '\(actionName)' on '\(deviceName)' — \(success ? "Success" : "Failed")")
    }
    
    /// Get logs filtered to a specific device by ID
    func logs(forDeviceId deviceId: String) -> [ActionLogEntry] {
        logs.filter { $0.deviceId == deviceId }
    }
    
    /// Get logs with multiple filter criteria
    func filteredLogs(
        searchText: String = "",
        source: ActionLogEntry.LogSource? = nil,
        category: String? = nil,
        successOnly: Bool? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil
    ) -> [ActionLogEntry] {
        var result = logs
        
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.deviceName.lowercased().contains(query) ||
                $0.deviceSerialNumber.lowercased().contains(query) ||
                $0.actionName.lowercased().contains(query) ||
                $0.performedBy.lowercased().contains(query)
            }
        }
        if let source = source {
            result = result.filter { $0.source == source }
        }
        if let category = category {
            result = result.filter { $0.actionCategory == category }
        }
        if let successOnly = successOnly {
            result = result.filter { $0.success == successOnly }
        }
        if let startDate = startDate {
            result = result.filter { $0.timestamp >= startDate }
        }
        if let endDate = endDate {
            result = result.filter { $0.timestamp <= endDate }
        }
        
        return result
    }
    
    /// Get unique action categories from all logs
    var availableCategories: [String] {
        Array(Set(logs.map { $0.actionCategory })).sorted()
    }
    
    /// Clear all logs
    func clearLogs() {
        logs.removeAll()
        saveToDisk()
        AppLog.notice("🗑️ ActionLogService: All logs cleared")
    }
    
    /// Export logs as CSV string
    func exportAsCSV() -> String {
        var csv = "Timestamp,Action,Category,Device,Serial Number,Platform,Performed By,IP Address,Success,Error,Source\n"
        let formatter = ISO8601DateFormatter()
        
        for log in logs {
            let row = [
                formatter.string(from: log.timestamp),
                log.actionName,
                log.actionCategory,
                log.deviceName,
                log.deviceSerialNumber,
                log.devicePlatform,
                log.performedBy,
                log.ipAddressUsed ?? "",
                log.success ? "Yes" : "No",
                log.errorMessage ?? "",
                log.source.rawValue
            ].map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: ",")
            
            csv += row + "\n"
        }
        return csv
    }
    
    /// Enforce the features-domain retention policy
    /// (features actionLog.retentionDays / maxEntries; 0 = unlimited).
    /// The audit trail previously grew without bound.
    private func applyRetention() {
        let settings = MDMConfigurationManager.shared.configuration
            .features?.effectiveActionLog
            ?? FeaturesConfiguration.ActionLogSettings.empty

        let days = settings.effectiveRetentionDays
        if days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) {
            logs.removeAll { $0.timestamp < cutoff }
        }

        let cap = settings.effectiveMaxEntries
        if cap > 0 && logs.count > cap {
            logs.removeLast(logs.count - cap) // logs are newest-first
        }
    }

    // MARK: - Private Persistence
    
    private func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(
            at: Self.logsDirectory,
            withIntermediateDirectories: true
        )
    }
    
    private func loadFromDisk() {
        let fileURL = Self.logsFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Unreadable at the I/O level (permissions, corruption): never
            // write over it. Move it aside so we can start a fresh file.
            AppLog.error("❌ ActionLogService: Failed to read logs: \(error.localizedDescription)")
            quarantineUnreadableFile()
            return
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let decoded: [ActionLogEntry]
        if let envelope = try? decoder.decode(ActionLogFile.self, from: data) {
            decoded = envelope.entries
            if envelope.schemaVersion > ActionLogFile.currentSchemaVersion {
                AppLog.notice("⚠️ ActionLogService: action_logs.json is schema v\(envelope.schemaVersion) (this build writes v\(ActionLogFile.currentSchemaVersion))")
            }
        } else if let legacy = try? decoder.decode([ActionLogEntry].self, from: data) {
            // Pre-envelope format: bare array. Re-saved in the new shape below.
            decoded = legacy
        } else {
            // Neither shape decodes. The old behaviour left `logs = []` and the
            // next logAction overwrote the file with a 1-element array — data
            // loss. Move the file aside instead and keep the original bytes.
            AppLog.error("❌ ActionLogService: action_logs.json could not be decoded; moving it aside")
            quarantineUnreadableFile()
            return
        }
        
        logs = decoded
        AppLog.notice("✅ ActionLogService: Loaded \(logs.count) log entries from disk")
        let before = logs.count
        applyRetention()
        if logs.count != before { saveToDisk() }
    }
    
    /// Rename an unreadable `action_logs.json` to
    /// `action_logs.json.unreadable-<epoch>` so it is preserved for recovery.
    /// If the rename itself fails, disk writes are suppressed for the rest of
    /// the session rather than risk clobbering the file.
    private func quarantineUnreadableFile() {
        let fileURL = Self.logsFileURL
        let epoch = Int(Date().timeIntervalSince1970)
        let asideURL = fileURL.appendingPathExtension("unreadable-\(epoch)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: asideURL)
            AppLog.notice("⚠️ ActionLogService: Unreadable log file moved aside to \(asideURL.lastPathComponent)")
        } catch {
            diskWritesSuppressed = true
            AppLog.error("❌ ActionLogService: Could not move unreadable log file aside (\(error.localizedDescription)); disk writes suppressed this session")
        }
    }
    
    private func saveToDisk() {
        guard !diskWritesSuppressed else {
            AppLog.notice("⚠️ ActionLogService: Skipping save — on-disk log file is unreadable and could not be moved aside")
            return
        }
        
        let snapshot = ActionLogFile(
            schemaVersion: ActionLogFile.currentSchemaVersion,
            entries: logs
        )
        let fileURL = Self.logsFileURL
        
        // Serial queue: each snapshot is encoded and written in the order it
        // was taken, so the newest state always wins.
        Self.ioQueue.async {
            do {
                let encoder = JSONEncoder()
                // No .prettyPrinted: with unlimited retention every save
                // rewrites the whole file, so keep it compact.
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(snapshot)
                try data.write(to: fileURL, options: .atomic)
                // Owner-only: the file carries operator UPNs and device serials.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: fileURL.path
                )
            } catch {
                AppLog.error("❌ ActionLogService: Failed to save logs: \(error.localizedDescription)")
            }
        }
    }
}
