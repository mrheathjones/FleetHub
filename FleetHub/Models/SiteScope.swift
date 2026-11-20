//
//  SiteScope.swift
//  FleetHub
//
//  Which Jamf sites' devices the signed-in person may see.
//
//  Site scoping is opt-in: the access domain's `siteScoping` key turns it
//  on, and each role then lists the sites it may see in `visibleSites`.
//  With it off, nobody is limited and this type stays `.everything`.
//
//  ENFORCED BY THE APP, NOT BY JAMF. A Jamf API client cannot be limited to
//  a site, so the person's own API credential can still read every device.
//  The scope decides what FleetHub shows, searches and acts on.
//
//  Shared with the menu bar companion, which reads the scope the main app
//  last published (see SiteScopeStore).
//

import Foundation

struct SiteScope: Equatable, Sendable {

    /// False when every device is in scope.
    let isRestricted: Bool

    /// The site IDs in scope. Read only when `isRestricted` is true.
    let siteIDs: Set<String>

    /// No limit: site scoping is off, or the person's roles list `all`.
    static let everything = SiteScope(isRestricted: false, siteIDs: [])

    /// Fail-closed: scoping is on and the person's roles list no site.
    static let nothing = SiteScope(isRestricted: true, siteIDs: [])

    /// The id Jamf gives a device that belongs to no site.
    static let noSiteID = "-1"

    /// Whether a device in this site is in scope. A device with no site
    /// (or whose site was not returned) counts as site `-1`, so it is in
    /// scope only for a role that lists `-1` or `all`.
    func includes(siteID: String?) -> Bool {
        guard isRestricted else { return true }
        var id = (siteID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if id.isEmpty { id = Self.noSiteID }
        return siteIDs.contains(id)
    }

    /// The scope a person's roles allow. `visibleSites` is the union of
    /// their roles' lists, sentinel included.
    static func permitted(enabled: Bool, visibleSites: Set<String>) -> SiteScope {
        guard enabled else { return .everything }
        if AccessConfiguration.ABMAllowList.containsSentinel(visibleSites) { return .everything }
        let ids = Set(visibleSites
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        return SiteScope(isRestricted: true, siteIDs: ids)
    }
}

/// The scope in force right now, readable from any thread. The main app
/// sets it (SiteScopeManager); the inventory caches and the search services
/// read it.
enum SiteScopeStore {

    private static let lock = NSLock()
    private static var value: SiteScope = .everything

    static var current: SiteScope {
        get {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            value = newValue
        }
    }

    // MARK: - Device checks

    /// Whether a computer record is in the scope in force.
    static func includes(_ computer: Computer) -> Bool {
        current.includes(siteID: computer.general?.site?.id)
    }

    /// Whether a mobile device record is in the scope in force. A detail
    /// record that carries no site falls back to the inventory, which is
    /// already limited to the scope.
    static func includes(_ device: MobileDevice) -> Bool {
        let scope = current
        guard scope.isRestricted else { return true }
        if let id = device.site?.id, !id.isEmpty { return scope.includes(siteID: id) }
        return MobileDeviceInventoryCache.shared.devices.contains { $0.id == device.id }
    }

    /// The error a device-open path throws for a device outside the scope.
    /// Worded like a missing record: the app does not confirm that a device
    /// in someone else's site exists.
    static var outOfScopeError: NSError {
        NSError(domain: "SiteScope", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Device not found in your sites."])
    }

    // MARK: - Hand-off to the menu bar companion

    /// The main app's preferences domain, which the companion can read.
    private static let sharedSuite = "com.herojoneslabs.fleethub"
    private static let permittedKey = "SiteScope_VisibleSites"

    /// Main app: records the sites the signed-in person may see, so the
    /// companion's search is limited the same way. Nil removes the record
    /// (signed out), which leaves the companion showing nothing while
    /// scoping is on.
    static func publishForCompanion(visibleSites: Set<String>?) {
        let stores = [UserDefaults.standard, UserDefaults(suiteName: sharedSuite)].compactMap { $0 }
        for defaults in stores {
            if let visibleSites {
                defaults.set(visibleSites.sorted(), forKey: permittedKey)
            } else {
                defaults.removeObject(forKey: permittedKey)
            }
        }
    }

    /// Companion: loads the scope the main app last published. Fail-closed:
    /// scoping on with no record means nothing is in scope.
    static func loadForCompanion(enabled: Bool) {
        guard enabled else {
            current = .everything
            return
        }
        let stored = UserDefaults(suiteName: sharedSuite)?.stringArray(forKey: permittedKey)
        current = SiteScope.permitted(enabled: true, visibleSites: Set(stored ?? []))
    }
}
