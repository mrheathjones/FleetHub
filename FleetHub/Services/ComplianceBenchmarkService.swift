//
//  ComplianceBenchmarkService.swift
//  FleetHub
//
//  Jamf Compliance Benchmarks: fleet summary for the Overview and a
//  per-device result for the device page.
//
//  Compliance Benchmarks exist ONLY on the Jamf Platform API, so this
//  service always talks to the Platform gateway with the Platform
//  integration's token (`JamfTokenProvider.platformToken()`), whichever
//  backend the rest of the app uses. It is available whenever the Core
//  profile delivers a Platform integration with an environment ID and its
//  secret has been entered in Settings → Credentials.
//
//  Endpoints (developer.jamf.com/platform-api, verified 2026-11), all on
//  `https://{region}.api.jamfcloud.com` with `X-Environment-Id`:
//
//    GET /compliance-benchmarks/v1/benchmarks
//    GET /compliance-benchmarks/v1/benchmarks/{id}/compliance-percentage
//    GET /compliance-benchmarks/v1/benchmarks/{id}/rules
//        → per rule: ruleId, ruleTitle, ruleNumber, discussion, passed,
//          failed, unknown, passPercentage, numberOfDevices
//    GET /compliance-benchmarks/v1/benchmarks/{id}/devices?rule-id=…
//        &device-search=… (matches device NAME or Platform device ID)
//        → per device: deviceId, deviceName, state PASSED|FAILED|UNKNOWN
//    GET /devices/v1/devices?filter=serialNumber=="…"   (RSQL)
//
//  There is NO endpoint that returns every rule's result for one device:
//  the API only goes from a rule to its devices. A device's page therefore
//  costs one request per rule, which is why that lookup is bounded,
//  retried on rate limiting, tolerant of single-rule failures, and cached
//  for a few minutes.
//
//  Platform permissions: `compliance-benchmarks:read`, `devices:read`.
//
//  These are not Jamf Pro paths, so they are NOT sent through
//  `JamfTransport`. Tokens are never logged.
//

import Foundation
import Combine

// MARK: - Models

struct ComplianceRuleStat: Identifiable, Hashable {
    let ruleId: String
    let ruleTitle: String
    let ruleNumber: String?
    /// Jamf's explanation of the rule, when it supplies one.
    let discussion: String?
    let passed: Int
    let failed: Int
    let unknown: Int
    /// 0–100 as Jamf reports it; nil when the API did not send one.
    let passPercentage: Double?
    let numberOfDevices: Int

    var id: String { ruleId }

    init(ruleId: String, ruleTitle: String, ruleNumber: String?, discussion: String? = nil,
         passed: Int, failed: Int, unknown: Int, passPercentage: Double? = nil, numberOfDevices: Int) {
        self.ruleId = ruleId
        self.ruleTitle = ruleTitle
        self.ruleNumber = ruleNumber
        self.discussion = discussion
        self.passed = passed
        self.failed = failed
        self.unknown = unknown
        self.passPercentage = passPercentage
        self.numberOfDevices = numberOfDevices
    }

    /// Jamf's pass percentage, or one worked out from the counts when it
    /// sent none. Nil when no device has reported a result.
    var effectivePassPercentage: Double? {
        if let passPercentage { return passPercentage }
        let reported = passed + failed + unknown
        return reported > 0 ? Double(passed) / Double(reported) * 100 : nil
    }
}

/// One benchmark as the Overview shows it.
struct ComplianceBenchmarkSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let syncState: String
    /// 0–100, or nil when the benchmark has no applicable rules yet.
    let compliancePercentage: Double?
    let rules: [ComplianceRuleStat]

    /// Rules failing on at least one device.
    var failingRuleCount: Int { rules.count(where: { $0.failed > 0 }) }
    var deviceCount: Int { rules.map(\.numberOfDevices).max() ?? 0 }
}

/// How one rule stands on one device.
enum DeviceRuleState: Hashable {
    case failed
    case passed
    /// Jamf reports the rule's result on this device as unknown.
    case unknown
    /// Jamf lists no result for this device under the rule: the device is
    /// outside the benchmark's target, or has not reported yet.
    case notReported
    /// The request for this rule failed; the text says why.
    case notChecked(String)

    var title: String {
        switch self {
        case .failed: "Failed"
        case .passed: "Passed"
        case .unknown: "Unknown"
        case .notReported: "Not Reported"
        case .notChecked: "Not Checked"
        }
    }

    /// Failed first, then the states that need a look, then passed.
    var sortRank: Int {
        switch self {
        case .failed: 0
        case .notChecked: 1
        case .unknown: 2
        case .notReported: 3
        case .passed: 4
        }
    }
}

/// One benchmark's result for a single device: every rule, with its state.
struct DeviceBenchmarkCompliance: Identifiable, Hashable {
    struct RuleResult: Identifiable, Hashable {
        let ruleId: String
        let ruleTitle: String
        let ruleNumber: String?
        let discussion: String?
        let state: DeviceRuleState
        var id: String { ruleId }
    }

    let benchmarkID: String
    let title: String
    /// Every rule in the benchmark, in the benchmark's own order.
    let rules: [RuleResult]

    var id: String { benchmarkID }
    var passed: Int { rules.count(where: { $0.state == .passed }) }
    var failed: Int { rules.count(where: { $0.state == .failed }) }
    var unknown: Int { rules.count(where: { $0.state == .unknown }) }
    var notReported: Int { rules.count(where: { $0.state == .notReported }) }
    var notChecked: Int {
        rules.count(where: { if case .notChecked = $0.state { true } else { false } })
    }
    /// Rules Jamf returned a result for on this device.
    var evaluated: Int { passed + failed + unknown }
}

enum ComplianceBenchmarkError: LocalizedError {
    case notConfigured
    case unauthorized
    case forbidden
    case rateLimited
    case server(Int)
    case deviceNotFound(String)
    case noSerialNumber
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Compliance Benchmarks need a Jamf Platform API integration with an environment ID. The identity comes from the configuration profile; the client secret is entered in Settings → Credentials."
        case .unauthorized:
            return "The Jamf Platform API rejected the integration's token. Check the region, client ID and secret."
        case .forbidden:
            return "The Jamf Platform API integration lacks a permission this needs (compliance-benchmarks:read, devices:read)."
        case .rateLimited:
            return "Rate limited: the Jamf Platform API is turning requests away for now. Try again in a minute."
        case .server(let code):
            return "The Jamf Platform API returned \(code)."
        case .deviceNotFound(let serial):
            return "Jamf has no device record for serial number \(serial) in the Platform inventory, so there is nothing to look its results up by. A device appears there once it has reported inventory to the environment this integration is scoped to."
        case .network(let message):
            return "The Jamf Platform API could not be reached: \(message)"
        case .noSerialNumber:
            return "This device has no serial number to look up."
        }
    }
}

// MARK: - Service

@MainActor
final class ComplianceBenchmarkService: ObservableObject {
    static let shared = ComplianceBenchmarkService()
    private init() {}

    @Published private(set) var summaries: [ComplianceBenchmarkSummary] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastLoaded: Date?

    /// Benchmarks whose rule list is open on the Overview card. Kept here,
    /// not in the view, so it survives the card being rebuilt; it lasts as
    /// long as the app runs.
    @Published private(set) var expandedBenchmarkIDs: Set<String> = []

    func toggleExpanded(_ benchmarkID: String) {
        if expandedBenchmarkIDs.contains(benchmarkID) {
            expandedBenchmarkIDs.remove(benchmarkID)
        } else {
            expandedBenchmarkIDs.insert(benchmarkID)
        }
    }

    /// Recent per-device results, so reopening a device's Compliance
    /// section does not repeat one request per rule.
    private var deviceResultCache: [String: (loaded: Date, results: [DeviceBenchmarkCompliance])] = [:]
    private static let deviceResultLifetime: TimeInterval = 600

    /// Whether the feature can be offered at all. False hides every
    /// Compliance surface — nothing is shown as broken on a tenant that
    /// simply has no Platform integration.
    static var isAvailable: Bool {
        #if DEBUG
        if DemoMode.isEnabled { return true }
        #endif
        let config = MDMConfigurationManager.shared.configuration
        return config.isPlatformAPIReady && (config.platformAPI?.canReachPlatformServices ?? false)
    }

    /// Why Compliance Benchmarks cannot be shown although the Core profile
    /// names a Platform integration — so the Overview can say what is
    /// missing instead of silently leaving the card out. Nil when the
    /// feature is available, and nil when no integration is named at all
    /// (a tenant without one sees no card).
    static var unavailableReason: String? {
        guard !isAvailable else { return nil }
        let config = MDMConfigurationManager.shared.configuration
        guard let platform = config.platformAPI else { return nil }
        if !config.isPlatformAPIReady {
            return "Your configuration profile names a Jamf Platform API integration, but its client secret is not on this Mac yet. It arrives with your organization's credential policy, or can be entered in Settings → Credentials. The client ID the secret was delivered for must match the one in the profile."
        }
        if !platform.canReachPlatformServices {
            return "Compliance Benchmarks need the platform Environment ID, which is missing from your configuration profile (Core → Platform API Integration → Environment ID). The Tenant ID alone is not enough for benchmarks."
        }
        return nil
    }

    // MARK: Fleet summary

    /// Loads once per session; later calls are free unless `force` is set.
    func loadSummary(force: Bool = false) async {
        guard Self.isAvailable, !isLoading else { return }
        if !force, lastLoaded != nil { return }

        #if DEBUG
        if DemoMode.isEnabled {
            summaries = DemoMode.complianceBenchmarks
            errorMessage = nil
            lastLoaded = Date()
            return
        }
        #endif

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            summaries = try await Self.fetchSummaries()
            lastLoaded = Date()
        } catch is CancellationError {
            // Leave the previous state; the next appearance retries.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Drops the cached summary (sign-out, credential change).
    func reset() {
        summaries = []
        errorMessage = nil
        lastLoaded = nil
        deviceResultCache = [:]
    }

    // MARK: Per device

    /// Every rule's state on this device, under every benchmark.
    ///
    /// Expensive: the API has no per-device report, so this is one request
    /// per rule per benchmark. Call it only when the operator opens the
    /// device's Compliance section. `progress` reports (done, total) rules.
    /// A result is reused for ten minutes unless `force` is set.
    ///
    /// A single rule whose request fails does not abandon the rest: that
    /// rule comes back as `.notChecked` with the reason. Failures that make
    /// the whole lookup pointless (no access, not configured, cancelled)
    /// are thrown.
    func deviceCompliance(
        serialNumber: String?,
        force: Bool = false,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> [DeviceBenchmarkCompliance] {
        guard Self.isAvailable else { throw ComplianceBenchmarkError.notConfigured }

        #if DEBUG
        if DemoMode.isEnabled {
            return DemoMode.deviceCompliance(serialNumber: serialNumber)
        }
        #endif

        let serial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !serial.isEmpty else { throw ComplianceBenchmarkError.noSerialNumber }

        let cacheKey = serial.uppercased()
        if !force, let cached = deviceResultCache[cacheKey],
           Date().timeIntervalSince(cached.loaded) < Self.deviceResultLifetime {
            return cached.results
        }

        if lastLoaded == nil || force {
            await loadSummary(force: force && lastLoaded != nil)
            if summaries.isEmpty, let errorMessage {
                throw NSError(domain: "ComplianceBenchmarks", code: 0,
                              userInfo: [NSLocalizedDescriptionKey: errorMessage])
            }
        }
        let benchmarks = summaries
        guard !benchmarks.isEmpty else { return [] }
        let deviceID = try await Self.platformDeviceID(serialNumber: serial)

        struct Job { let benchmarkID: String; let rule: ComplianceRuleStat }
        let jobs = benchmarks.flatMap { benchmark in
            benchmark.rules.map { Job(benchmarkID: benchmark.id, rule: $0) }
        }
        progress(0, jobs.count)

        // Four at a time: enough to finish a few hundred rules quickly,
        // few enough not to trip the gateway's rate limit by itself.
        var states: [String: [String: DeviceRuleState]] = [:]
        var done = 0
        try await withThrowingTaskGroup(of: (String, String, DeviceRuleState).self) { group in
            var iterator = jobs.makeIterator()
            func addNext() {
                guard let job = iterator.next() else { return }
                group.addTask {
                    try Task.checkCancellation()
                    do {
                        let state = try await Self.ruleState(
                            benchmarkID: job.benchmarkID, ruleID: job.rule.ruleId, deviceID: deviceID
                        )
                        return (job.benchmarkID, job.rule.ruleId, state)
                    } catch let error as ComplianceBenchmarkError {
                        switch error {
                        case .unauthorized, .forbidden, .notConfigured:
                            throw error               // nothing else will work either
                        default:
                            return (job.benchmarkID, job.rule.ruleId, .notChecked(error.localizedDescription))
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return (job.benchmarkID, job.rule.ruleId, .notChecked(error.localizedDescription))
                    }
                }
            }
            for _ in 0..<4 { addNext() }
            while let (benchmarkID, ruleID, state) = try await group.next() {
                states[benchmarkID, default: [:]][ruleID] = state
                done += 1
                progress(done, jobs.count)
                addNext()
            }
        }

        let results = benchmarks.map { benchmark in
            DeviceBenchmarkCompliance(
                benchmarkID: benchmark.id,
                title: benchmark.title,
                rules: benchmark.rules.map { rule in
                    DeviceBenchmarkCompliance.RuleResult(
                        ruleId: rule.ruleId, ruleTitle: rule.ruleTitle, ruleNumber: rule.ruleNumber,
                        discussion: rule.discussion,
                        state: states[benchmark.id]?[rule.ruleId] ?? .notReported
                    )
                }
            )
        }
        // A run in which rules could not be checked is not worth keeping.
        if results.allSatisfy({ $0.notChecked == 0 }) {
            deviceResultCache[cacheKey] = (Date(), results)
        }
        return results
    }

    // MARK: - Networking (nonisolated; no UI state)

    private nonisolated static func connection() throws -> PlatformAPIConnection {
        let config = MDMConfigurationManager.shared.configuration
        guard config.isPlatformAPIReady, let platform = config.platformAPI,
              platform.canReachPlatformServices else {
            throw ComplianceBenchmarkError.notConfigured
        }
        return platform
    }

    /// GET a Platform service path. Returns the body and status for 2xx and
    /// 404 (some endpoints use 404 for "no data"); throws otherwise. A 429
    /// is retried a few times with a short, growing pause.
    private nonisolated static func get(
        _ path: String, query: [URLQueryItem] = []
    ) async throws -> (data: Data, status: Int) {
        let platform = try connection()
        guard var components = URLComponents(string: platform.gatewayBaseURL + path) else {
            throw ComplianceBenchmarkError.notConfigured
        }
        if !query.isEmpty { components.queryItems = query }
        // URLComponents leaves '+' and '"' as-is in a query; RSQL filters
        // need the quotes encoded, which percentEncodedQuery already does.
        guard let url = components.url else { throw ComplianceBenchmarkError.notConfigured }

        // Up to six tries. A 429 waits for Jamf's Retry-After when it sends
        // one, otherwise 0.5 s, 1 s, 2 s, 4 s, 8 s (with a little jitter so
        // parallel requests do not all come back at once). A dropped or
        // timed-out connection gets two more tries.
        let maxAttempts = 6
        var transientFailures = 0
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            let token = try await JamfTokenProvider.platformToken()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = NetworkTuning.connectionTimeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(platform.environmentID, forHTTPHeaderField: "X-Environment-Id")

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                let transient: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed]
                transientFailures += 1
                if transient.contains(error.code), transientFailures <= 2, attempt < maxAttempts - 1 {
                    try await Task.sleep(nanoseconds: 700_000_000)
                    continue
                }
                throw ComplianceBenchmarkError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ComplianceBenchmarkError.server(-1)
            }
            switch http.statusCode {
            case 200...299, 404:
                return (data, http.statusCode)
            case 401:
                // A token minted just before expiry can lapse in flight.
                JamfPlatformSession.shared.invalidate()
                if attempt == 0 { continue }
                throw ComplianceBenchmarkError.unauthorized
            case 403:
                throw ComplianceBenchmarkError.forbidden
            case 429:
                if attempt == maxAttempts - 1 { throw ComplianceBenchmarkError.rateLimited }
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let backoff = min(8, 0.5 * pow(2, Double(attempt)))
                let pause = min(20, max(retryAfter ?? 0, backoff)) + Double.random(in: 0...0.3)
                try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
            case 502, 503, 504:
                if attempt == maxAttempts - 1 { throw ComplianceBenchmarkError.server(http.statusCode) }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            default:
                throw ComplianceBenchmarkError.server(http.statusCode)
            }
        }
        throw ComplianceBenchmarkError.rateLimited
    }

    private nonisolated static func fetchSummaries() async throws -> [ComplianceBenchmarkSummary] {
        struct Envelope: Decodable {
            struct Benchmark: Decodable {
                let id: String
                let title: String
                let description: String?
                let syncState: String?
            }
            let benchmarks: [Benchmark]
        }
        let list = try JSONDecoder().decode(
            Envelope.self, from: try await get("/compliance-benchmarks/v1/benchmarks").data
        ).benchmarks

        return try await withThrowingTaskGroup(of: (Int, ComplianceBenchmarkSummary).self) { group in
            for (index, benchmark) in list.enumerated() {
                group.addTask {
                    async let percentage = compliancePercentage(benchmarkID: benchmark.id)
                    async let rules = ruleStats(benchmarkID: benchmark.id)
                    return (index, ComplianceBenchmarkSummary(
                        id: benchmark.id,
                        title: benchmark.title,
                        description: benchmark.description ?? "",
                        syncState: benchmark.syncState ?? "",
                        compliancePercentage: try await percentage,
                        rules: try await rules
                    ))
                }
            }
            var collected: [(Int, ComplianceBenchmarkSummary)] = []
            for try await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// nil for 404: the benchmark has no applicable rules to report on yet.
    private nonisolated static func compliancePercentage(benchmarkID: String) async throws -> Double? {
        struct Body: Decodable { let compliancePercentage: Double }
        let (data, status) = try await get(
            "/compliance-benchmarks/v1/benchmarks/\(pathEscape(benchmarkID))/compliance-percentage"
        )
        guard status != 404 else { return nil }
        return try JSONDecoder().decode(Body.self, from: data).compliancePercentage
    }

    private nonisolated static func ruleStats(benchmarkID: String) async throws -> [ComplianceRuleStat] {
        struct Page: Decodable {
            struct Rule: Decodable {
                let ruleId: String
                let ruleTitle: String
                let ruleNumber: String?
                let discussion: String?
                let passed: Int
                let failed: Int
                let unknown: Int
                let passPercentage: Double?
                let numberOfDevices: Int
            }
            let results: [Rule]
            let totalCount: Int?
        }
        var rules: [ComplianceRuleStat] = []
        var page = 0
        let pageSize = 500
        while true {
            let (data, status) = try await get(
                "/compliance-benchmarks/v1/benchmarks/\(pathEscape(benchmarkID))/rules",
                query: [
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page-size", value: String(pageSize))
                ]
            )
            guard status != 404 else { break }
            let decoded = try JSONDecoder().decode(Page.self, from: data)
            rules += decoded.results.map {
                ComplianceRuleStat(
                    ruleId: $0.ruleId, ruleTitle: $0.ruleTitle, ruleNumber: $0.ruleNumber,
                    discussion: $0.discussion,
                    passed: $0.passed, failed: $0.failed, unknown: $0.unknown,
                    passPercentage: $0.passPercentage,
                    numberOfDevices: $0.numberOfDevices
                )
            }
            if decoded.results.count < pageSize || rules.count >= (decoded.totalCount ?? rules.count) { break }
            page += 1
        }
        return rules
    }

    /// The Platform device ID (a UUID) for a serial number. Benchmark
    /// reports identify devices by this ID, not by any Jamf Pro identifier.
    ///
    /// The list covers computers and mobile devices alike. The filter is
    /// RSQL on `serialNumber`; because nothing says whether that match
    /// ignores case, the serial is tried as given, then upper- and
    /// lower-cased. Only a record whose serial really is this one is
    /// accepted — never "whatever came back first", which could show
    /// another device's results.
    private nonisolated static func platformDeviceID(serialNumber: String) async throws -> String {
        struct Page: Decodable {
            struct Device: Decodable { let id: String; let serialNumber: String? }
            let results: [Device]
        }
        let cleaned = serialNumber.replacingOccurrences(of: "\"", with: "")
        var candidates = [cleaned]
        for variant in [cleaned.uppercased(), cleaned.lowercased()] where !candidates.contains(variant) {
            candidates.append(variant)
        }
        for candidate in candidates {
            let (data, status) = try await get(
                "/devices/v1/devices",
                query: [
                    URLQueryItem(name: "filter", value: "serialNumber==\"\(candidate)\""),
                    URLQueryItem(name: "page-size", value: "20")
                ]
            )
            guard status != 404 else { continue }
            let devices = (try? JSONDecoder().decode(Page.self, from: data).results) ?? []
            if let match = devices.first(where: {
                $0.serialNumber?.caseInsensitiveCompare(cleaned) == .orderedSame
            }) {
                return match.id
            }
        }
        throw ComplianceBenchmarkError.deviceNotFound(serialNumber)
    }

    /// One rule's state on one device. `.notReported` when Jamf lists no
    /// result for the device under the rule.
    ///
    /// `device-search` matches a device NAME or its Platform ID, and may
    /// return other devices whose name contains the text, so the answer is
    /// taken only from the row whose `deviceId` is this device — paging on
    /// if the first page does not hold it.
    private nonisolated static func ruleState(
        benchmarkID: String, ruleID: String, deviceID: String
    ) async throws -> DeviceRuleState {
        struct Page: Decodable {
            struct Result: Decodable { let deviceId: String; let state: String }
            let results: [Result]
            let totalCount: Int?
        }
        let pageSize = 100
        var page = 0
        var seen = 0
        while page < 5 {
            let (data, status) = try await get(
                "/compliance-benchmarks/v1/benchmarks/\(pathEscape(benchmarkID))/devices",
                query: [
                    URLQueryItem(name: "rule-id", value: ruleID),
                    URLQueryItem(name: "device-search", value: deviceID),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "page-size", value: String(pageSize))
                ]
            )
            guard status != 404 else { return .notReported }
            let decoded = try JSONDecoder().decode(Page.self, from: data)
            if let row = decoded.results.first(where: {
                $0.deviceId.caseInsensitiveCompare(deviceID) == .orderedSame
            }) {
                switch row.state.uppercased() {
                case "PASSED": return .passed
                case "FAILED": return .failed
                default: return .unknown
                }
            }
            seen += decoded.results.count
            if decoded.results.count < pageSize || seen >= (decoded.totalCount ?? seen) { break }
            page += 1
        }
        return .notReported
    }

    private nonisolated static func pathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value
    }
}
