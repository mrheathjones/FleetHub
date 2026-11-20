//
//  SiteScopeManager.swift
//  FleetHub
//
//  Keeps the site scope in step with the signed-in person's roles and the
//  site they picked in the top bar.
//
//  The roles give the PERMITTED scope (see SiteScope.permitted). Inside it
//  the person may narrow the view to one site with the switcher; that
//  choice is remembered. Whatever results is written to SiteScopeStore,
//  and the inventory caches re-filter, so every screen that reads them
//  follows.
//

import Combine
import Foundation

@MainActor
final class SiteScopeManager: ObservableObject {

    static let shared = SiteScopeManager()

    /// One entry in the switcher.
    struct Choice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// True when the access profile turns site scoping on.
    @Published private(set) var isEnabled = false

    /// What the person's roles allow.
    @Published private(set) var permitted: SiteScope = .everything

    /// The sites the person may switch between, by name.
    @Published private(set) var choices: [Choice] = []

    /// The site picked in the switcher; nil shows every permitted site.
    @Published private(set) var selectedSiteID: String?

    /// Bumped whenever the scope in force changes. Views that copy
    /// inventory into their own state reload on it.
    @Published private(set) var revision = 0

    /// True while the view is limited to some sites, by role or by the
    /// switcher. Reads the scope in force; `revision` re-renders observers.
    var isLimitedNow: Bool { SiteScopeStore.current.isRestricted }

    /// True when the switcher has something to offer.
    var isSwitcherOffered: Bool { isEnabled && choices.count > 1 }

    /// The switcher's label: the picked site, or the all-sites wording.
    var selectionTitle: String {
        if let activeSelection { return name(for: activeSelection) }
        return permitted.isRestricted ? "All My Sites" : "All Sites"
    }

    /// The picked site while it is in force: scoping on and the site still
    /// permitted. A pick the roles no longer allow is ignored.
    var activeSelection: String? {
        guard isEnabled, let selectedSiteID, permitted.includes(siteID: selectedSiteID) else { return nil }
        return selectedSiteID
    }

    private static let selectionKey = "SiteScope_SelectedSiteID"

    private var visibleSites: Set<String> = []
    /// Site names Jamf returned, by id.
    private var jamfSiteNames: [String: String] = [:]
    /// Site names seen on computers in the inventory, by id.
    private var inventorySiteNames: [String: String] = [:]
    private var didFetchSites = false
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        selectedSiteID = UserDefaults.standard.string(forKey: Self.selectionKey)

        // @Published emits before the value is stored, so the new values
        // are taken from the publishers, never read back from the owners.
        UserSession.shared.$capabilities
            .map(\.visibleSites)
            .combineLatest(MDMConfigurationManager.shared.$configuration.map(\.siteScopingEnabled))
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] visibleSites, enabled in
                self?.rolesChanged(enabled: enabled, visibleSites: visibleSites)
            }
            .store(in: &cancellables)

        ComputerInventoryCache.shared.$knownSites
            .removeDuplicates()
            .sink { [weak self] names in
                self?.inventorySiteNames = names
                self?.rebuildChoices()
            }
            .store(in: &cancellables)

        #if DEBUG
        // Test aid (`-FleetHubDemoSiteSwitch <id>`): picks that site a few
        // seconds after launch, so a switch made while the app is running
        // can be checked without a person at the menu.
        if let target = UserDefaults.standard.string(forKey: "FleetHubDemoSiteSwitch") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                self?.select(target)
            }
        }
        #endif
    }

    /// Picks one site, or nil for every permitted site.
    func select(_ siteID: String?) {
        guard siteID != selectedSiteID else { return }
        if let siteID {
            guard choices.contains(where: { $0.id == siteID }) else { return }
            UserDefaults.standard.set(siteID, forKey: Self.selectionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.selectionKey)
        }
        selectedSiteID = siteID
        apply()
    }

    // MARK: - Private

    private func rolesChanged(enabled: Bool, visibleSites: Set<String>) {
        var enabled = enabled
        var visibleSites = visibleSites
        #if DEBUG
        // Development only: `-FleetHubDemoSiteScope 1,2` limits the demo
        // fleet to those sites so the scoped screens can be looked at.
        if let demo = UserDefaults.standard.string(forKey: "FleetHubDemoSiteScope") {
            enabled = true
            visibleSites = Set(demo.split(separator: ",").map { String($0) })
        }
        #endif

        isEnabled = enabled
        self.visibleSites = visibleSites
        permitted = SiteScope.permitted(enabled: enabled, visibleSites: visibleSites)
        // The companion gets what the roles allow, never the switcher's
        // narrower pick: its search is not tied to the main window's view.
        SiteScopeStore.publishForCompanion(visibleSites: enabled ? visibleSites : nil)
        rebuildChoices()
        apply()
        if enabled, !visibleSites.isEmpty { fetchSiteNames() }
    }

    /// Site names for the switcher. Fail-soft: without the Read Sites
    /// privilege the names come from the inventory, or fall back to the id.
    private func fetchSiteNames() {
        guard !didFetchSites else { return }
        didFetchSites = true
        Task { [weak self] in
            do {
                let sites = try await JamfSiteService.shared.fetchSites()
                self?.jamfSiteNames = Dictionary(sites.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                self?.rebuildChoices()
            } catch {
                AppLog.notice("Site names could not be read from Jamf Pro; using the names in the inventory: \(error.localizedDescription)")
                self?.didFetchSites = false
            }
        }
    }

    private func name(for id: String) -> String {
        if id == SiteScope.noSiteID { return "No Site" }
        if let name = jamfSiteNames[id], !name.isEmpty { return name }
        if let name = inventorySiteNames[id], !name.isEmpty { return name }
        return "Site \(id)"
    }

    private func rebuildChoices() {
        var ids: Set<String>
        if !isEnabled {
            ids = []
        } else if permitted.isRestricted {
            ids = permitted.siteIDs
        } else {
            ids = Set(jamfSiteNames.keys).union(inventorySiteNames.keys)
        }
        let rebuilt = ids
            .map { Choice(id: $0, name: name(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if rebuilt != choices { choices = rebuilt }
    }

    /// Writes the scope in force and has the caches re-filter.
    private func apply() {
        var effective = permitted
        if let activeSelection {
            effective = SiteScope(isRestricted: true, siteIDs: [activeSelection])
        }
        guard SiteScopeStore.current != effective else { return }
        SiteScopeStore.current = effective
        ComputerInventoryCache.shared.reapplyScope()
        MobileDeviceInventoryCache.shared.reapplyScope()
        revision += 1
    }
}
