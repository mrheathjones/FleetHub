//
//  MobileDeviceInventoryCache.swift
//  FleetHub
//
//  In-memory cache for mobile device inventory data (iOS, iPadOS, visionOS),
//  shared across views for the lifetime of the process.
//
//  The cache lives in memory only and is rebuilt each launch.
//

import Foundation
import Combine

final class MobileDeviceInventoryCache: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = MobileDeviceInventoryCache()
    
    // MARK: - Published Properties
    
    /// The devices in the site scope in force (see ComputerInventoryCache).
    @Published private(set) var devices: [MobileDeviceInventoryItem] = []
    @Published private(set) var totalCount: Int = 0

    /// Everything Jamf returned, before the site scope is applied.
    private var allDevices: [MobileDeviceInventoryItem] = []
    private var reportedTotal = 0
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var isCacheValid: Bool = false
    
    // Platform counts
    @Published private(set) var iOSCount: Int = 0
    @Published private(set) var iPadOSCount: Int = 0
    @Published private(set) var visionOSCount: Int = 0
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Check if we have valid cached data for this session
    var hasCachedData: Bool {
        return isCacheValid && !allDevices.isEmpty
    }
    
    /// Update cache with new data
    func updateCache(devices: [MobileDeviceInventoryItem], totalCount: Int) {
        allDevices = devices
        reportedTotal = totalCount
        publishScoped()
        self.lastFetchDate = Date()
        self.isCacheValid = true
        
        AppLog.notice("✅ MobileDeviceInventoryCache: Updated cache with \(devices.count) devices, \(self.devices.count) in the site scope (iOS: \(iOSCount), iPadOS: \(iPadOSCount), visionOS: \(visionOSCount))")
    }
    
    /// Re-filters the inventory after the site scope changed.
    func reapplyScope() {
        guard !allDevices.isEmpty else { return }
        publishScoped()
    }

    private func publishScoped() {
        let scope = SiteScopeStore.current
        if scope.isRestricted {
            let scoped = allDevices.filter { scope.includes(siteID: $0.general?.siteId) }
            totalCount = scoped.count
            devices = scoped
        } else {
            totalCount = reportedTotal
            devices = allDevices
        }
        updatePlatformCounts()
    }

    /// Clear the cache (called on logout or manual refresh)
    func clearCache() {
        devices = []
        allDevices = []
        reportedTotal = 0
        totalCount = 0
        iOSCount = 0
        iPadOSCount = 0
        visionOSCount = 0
        lastFetchDate = nil
        isCacheValid = false
        
        AppLog.notice("🗑️ MobileDeviceInventoryCache: Cache cleared")
    }
    
    /// Force refresh - invalidates cache so next load fetches fresh data
    func invalidateCache() {
        isCacheValid = false
        AppLog.notice("⚠️ MobileDeviceInventoryCache: Cache invalidated")
    }
    
    /// Get devices for a specific platform
    func devices(for platform: PlatformType) -> [MobileDeviceInventoryItem] {
        switch platform {
        case .iOS:
            return devices.filter { $0.platformType == .iOS }
        case .iPadOS:
            return devices.filter { $0.platformType == .iPadOS }
        case .visionOS:
            return devices.filter { $0.platformType == .visionOS }
        default:
            return devices
        }
    }
    
    // MARK: - Private Methods
    
    private func updatePlatformCounts() {
        iOSCount = devices.filter { $0.platformType == .iOS }.count
        iPadOSCount = devices.filter { $0.platformType == .iPadOS }.count
        visionOSCount = devices.filter { $0.platformType == .visionOS }.count
    }
    
}
