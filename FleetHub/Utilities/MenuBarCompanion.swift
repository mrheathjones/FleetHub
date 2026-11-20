//
//  MenuBarCompanion.swift
//  FleetHub
//
//  Turns the menu bar companion on and off.
//
//  The companion (FleetHubMenuBar.app) ships inside this app at
//  Contents/Library/LoginItems. Turning it on registers it with macOS as a
//  login item, so it starts now and at every login; turning it off removes
//  the registration and quits it. macOS lists it under System Settings >
//  General > Login Items.
//
//  It is on by default: FleetHub registers it at launch. Two things stop
//  that. The user can turn it off in Settings, and that choice is kept. An
//  administrator can remove it for everyone with the features key
//  userExperience.menuBarSearch = false.
//

import AppKit
import ServiceManagement

@MainActor
final class MenuBarCompanion: ObservableObject {
    static let shared = MenuBarCompanion()

    /// The companion's bundle identifier: this app's, plus ".menubar".
    static let bundleIdentifier = (Bundle.main.bundleIdentifier ?? "com.herojoneslabs.fleethub") + ".menubar"

    /// True when macOS has the companion registered to start at login.
    @Published private(set) var isEnabled = false
    /// True when macOS is waiting for the user to allow it in System Settings.
    @Published private(set) var needsApproval = false
    /// Why the last change failed, if it did.
    @Published private(set) var errorMessage: String?

    private var service: SMAppService { SMAppService.loginItem(identifier: Self.bundleIdentifier) }

    /// Where the companion sits inside this app, if this build carries it.
    private var embeddedURL: URL? {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LoginItems/FleetHubMenuBar.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// False for a build that does not carry the companion.
    var isAvailable: Bool { embeddedURL != nil }

    private init() {
        refresh()
    }

    /// UserDefaults key: true once the user has turned the companion off.
    private static let turnedOffByUserKey = "menuBarSearchTurnedOffByUser"

    /// False when the organization's profile removes the companion.
    var isAllowed: Bool {
        MDMConfigurationManager.shared.configuration.features?
            .effectiveUserExperience.effectiveMenuBarSearch ?? true
    }

    /// True when Settings should show the switch.
    var isOffered: Bool { isAvailable && isAllowed }

    /// Brings the registration in line with the profile and the user's
    /// choice. Called once at launch.
    func applyPolicy() {
        guard isAvailable else { return }
        refresh()
        if !isAllowed {
            if isEnabled || needsApproval || !runningCopies.isEmpty {
                try? service.unregister()
                quitRunningCopies()
                AppLog.notice("Menu bar companion removed by the organization's profile")
                refresh()
            }
            return
        }
        #if DEBUG
        // A development build never registers itself by default: that would
        // leave a login item pointing into a build folder.
        return
        #else
        guard !UserDefaults.standard.bool(forKey: Self.turnedOffByUserKey) else { return }
        if isEnabled {
            launchIfNeeded()
        } else if !needsApproval {
            register(byUser: false)
        }
        #endif
    }

    /// Reads the current state from macOS.
    func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    /// The Settings switch. The user's choice is remembered, so an
    /// automatic turn-on never overrides a deliberate off.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(!enabled, forKey: Self.turnedOffByUserKey)
        if enabled {
            register(byUser: true)
        } else {
            errorMessage = nil
            do {
                try service.unregister()
                quitRunningCopies()
                AppLog.notice("Menu bar companion turned off")
            } catch {
                AppLog.error("Menu bar companion could not be turned off: \(error.localizedDescription)")
                errorMessage = "The menu bar app could not be turned off. \(error.localizedDescription)"
            }
            refresh()
        }
    }

    private func register(byUser: Bool) {
        errorMessage = nil
        do {
            try service.register()
            // macOS starts a newly registered login item by itself, a
            // moment later. Starting it here as well made two copies, so
            // only step in if it has still not appeared.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.launchIfNeeded()
            }
            AppLog.notice("Menu bar companion turned on (by user: \(byUser))")
        } catch {
            AppLog.error("Menu bar companion could not be turned on: \(error.localizedDescription)")
            if byUser {
                errorMessage = "The menu bar app could not be turned on. \(error.localizedDescription)"
            }
        }
        refresh()
    }

    /// Opens System Settings at Login Items, where the user can allow it.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var runningCopies: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
    }

    /// Starts the companion when no copy is running: after a registration
    /// that did not start it, or when it was quit by hand.
    private func launchIfNeeded() {
        guard runningCopies.isEmpty, let url = embeddedURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                AppLog.error("Menu bar companion did not start: \(error.localizedDescription)")
            }
        }
    }

    private func quitRunningCopies() {
        for app in runningCopies {
            app.terminate()
        }
    }
}
