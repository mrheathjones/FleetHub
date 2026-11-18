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
    
    @Published private(set) var computers: [ComputerInventoryItem] = []
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var lastFetchDate: Date?
    @Published private(set) var isCacheValid: Bool = false
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Check if we have valid cached data for this session
    var hasCachedData: Bool {
        return isCacheValid && !computers.isEmpty
    }
    
    /// Update cache with new data
    func updateCache(computers: [ComputerInventoryItem], totalCount: Int) {
        self.computers = computers
        self.totalCount = totalCount
        self.lastFetchDate = Date()
        self.isCacheValid = true
        
        AppLog.notice("✅ ComputerInventoryCache: Updated cache with \(computers.count) computers")
    }
    
    /// Clear the cache (called on logout or manual refresh)
    func clearCache() {
        computers = []
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
