//
//  ComputerInventoryCache.swift
//  FleetHub
//
//  In-memory cache for computer inventory data, shared across views for the
//  lifetime of the process.
//
//  The cache lives in memory only and is rebuilt each launch.
//

import Foundation
import Combine

@MainActor
final class ComputerInventoryCache: ObservableObject {
    
    // MARK: - Singleton
    
    static let shared = ComputerInventoryCache()
    
    // MARK: - Published Properties
    
    /// The computers in the site scope in force. Every screen reads this,
    /// which is what keeps out-of-scope devices off all of them.
    @Published private(set) var computers: [ComputerInventoryItem] = []
    @Published private(set) var totalCount: Int = 0
    /// Site names seen in the whole inventory, by site id. Names only:
    /// used to label the site switcher.
    @Published private(set) var knownSites: [String: String] = [:]

    /// Everything Jamf returned, before the site scope is applied.
    private var allComputers: [ComputerInventoryItem] = []
    private var reportedTotal = 0
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var isCacheValid: Bool = false
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Check if we have valid cached data for this session
    var hasCachedData: Bool {
        return isCacheValid && !allComputers.isEmpty
    }
    
    /// Update cache with new data
    func updateCache(computers: [ComputerInventoryItem], totalCount: Int) {
        allComputers = computers
        reportedTotal = totalCount
        var sites: [String: String] = [:]
        for computer in computers {
            if let id = computer.general?.site?.id, let name = computer.general?.site?.name,
               !id.isEmpty, !name.isEmpty, id != SiteScope.noSiteID {
                sites[id] = name
            }
        }
        if sites != knownSites { knownSites = sites }
        publishScoped()
        self.lastFetchDate = Date()
        self.isCacheValid = true
        
        AppLog.notice("✅ ComputerInventoryCache: Updated cache with \(computers.count) computers (\(self.computers.count) in the site scope)")
    }

    /// Re-filters the inventory after the site scope changed.
    func reapplyScope() {
        guard !allComputers.isEmpty else { return }
        publishScoped()
    }

    private func publishScoped() {
        let scope = SiteScopeStore.current
        if scope.isRestricted {
            let scoped = allComputers.filter { scope.includes(siteID: $0.general?.site?.id) }
            totalCount = scoped.count
            computers = scoped
        } else {
            totalCount = reportedTotal
            computers = allComputers
        }
    }
    
    /// Clear the cache (called on logout or manual refresh)
    func clearCache() {
        computers = []
        allComputers = []
        reportedTotal = 0
        totalCount = 0
        lastFetchDate = nil
        isCacheValid = false
        
        AppLog.notice("🗑️ ComputerInventoryCache: Cache cleared")
    }
    
    /// Force refresh - invalidates cache so next load fetches fresh data
    func invalidateCache() {
        isCacheValid = false
        AppLog.notice("⚠️ ComputerInventoryCache: Cache invalidated")
    }
    
}
