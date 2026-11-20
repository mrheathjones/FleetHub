//
//  FleetHubMenuBarApp.swift
//  FleetHubMenuBar
//
//  A lightweight macOS menu bar companion app for FleetHub.
//  Provides quick device search by name or serial number.
//  Click a result to open the device record in the main FleetHub app.
//
//  Shared files required in this target's Compile Sources:
//    Models:    Computer.swift, MobileDevice.swift, MDMConfiguration.swift,
//               AppSettings.swift, User.swift, DeviceListItem.swift,
//               PlatformType.swift
//    Managers:  KeychainManager.swift, MDMConfigurationManager.swift
//    Services:  JamfAPIService.swift, UnifiedSearchService.swift,
//               UnifiedSearchResult+ModelIdentifier.swift,
//               ComputerSearchModels.swift, ComputerSearchService.swift,
//               MobileDeviceModels.swift, MobileDeviceInventoryCache.swift,
//               MobileDeviceInventoryService.swift, ComputerInventoryCache.swift
//    Utilities: DeviceIconProvider.swift
//    Views:     ThemeColors.swift
//

import SwiftUI
import AppKit
import os.log

private let logger = Logger(subsystem: "com.herojoneslabs.fleethub.menubar", category: "MenuBarApp")

// MARK: - App Entry Point

@main
struct FleetHubMenuBarApp: App {
    @NSApplicationDelegateAdaptor(MenuBarAppDelegate.self) var appDelegate

    init() {
        // Load configuration from shared UserDefaults / managed preferences
        MDMConfigurationManager.shared.reloadConfiguration()
        let config = MDMConfigurationManager.shared.configuration
        logger.info("FleetHubMenuBar initialized — Jamf URL: \(config.jamfURL)")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .frame(width: 420, height: 520)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App Delegate

final class MenuBarAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only. macOS and FleetHub can both start the companion;
        // the later one steps aside.
        if let bundleID = Bundle.main.bundleIdentifier {
            let me = NSRunningApplication.current
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != me.processIdentifier }
            let iAmLater = others.contains { other in
                guard let theirs = other.launchDate, let mine = me.launchDate else {
                    return other.processIdentifier < me.processIdentifier
                }
                return theirs < mine || (theirs == mine && other.processIdentifier < me.processIdentifier)
            }
            if iAmLater {
                logger.info("FleetHubMenuBar is already running; this copy is quitting")
                exit(0)
            }
        }
        // Pure menu-bar app — no Dock icon
        NSApp.setActivationPolicy(.accessory)
        logger.info("FleetHubMenuBar launched")
    }
}

// MARK: - Menu Bar Label (icon in the system menu bar)

private struct MenuBarLabel: View {
    var body: some View {
        Image(nsImage: menuBarIcon)
    }

    private var menuBarIcon: NSImage {
        if let icon = NSImage(named: "AppIcon") {
            let size = NSSize(width: 18, height: 18)
            let resized = NSImage(size: size)
            resized.lockFocus()
            icon.draw(
                in: NSRect(origin: .zero, size: size),
                from: NSRect(origin: .zero, size: icon.size),
                operation: .copy,
                fraction: 1.0
            )
            resized.unlockFocus()
            resized.isTemplate = false
            return resized
        }
        // Fallback SF Symbol
        return NSImage(
            systemSymbolName: "point.3.connected.trianglepath.dotted",
            accessibilityDescription: Branding.title
        ) ?? NSImage()
    }
}

// MARK: - Menu Bar Content View

struct MenuBarContentView: View {
    // The companion has no sign-in of its own. It searches as the operator
    // who signed in to the main app, using their per-user Jamf credential
    // from the Keychain, and fails closed when there is none — the master
    // client is never used for search.
    @StateObject private var searchService = UnifiedDeviceSearchService()
    @State private var searchText = ""
    /// Debounce timer: waits for typing to settle before kicking off a search.
    @State private var searchTask: Task<Void, Never>?
    /// The network search actually in flight. Tracked so a newer query (or a
    /// cleared field) cancels it instead of letting a slow response for "iph"
    /// overwrite the results for "iphone".
    @State private var inFlightSearch: Task<Void, Never>?

    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
            resultsList
            footer
        }
        .background(FleetHubTheme.surface)
        .onAppear {
            isSearchFocused = true
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            BrandMark(size: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(Branding.productName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text("Quick Device Search")
                    .font(.system(size: 11))
                    .foregroundStyle(FleetHubTheme.muted)
            }

            Spacer()

            connectionBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var connectionBadge: some View {
        // "Connected" means a Jamf Pro server is configured AND the operator
        // has signed in to the main app on this Mac, leaving their per-user
        // credential in the Keychain. Without it no search can run, so the
        // badge must not claim a connection.
        let config = MDMConfigurationManager.shared.configuration
        // On the Platform backend there is no per-user credential: the
        // companion is connected when the integration is fully set up.
        // Search is a read: it runs as the Platform integration on the
        // platform and hybrid backends, and as the operator otherwise.
        let onPlatform = config.effectiveAPIBackend.usesPlatform(for: .deviceSearch)
        let hasCredentials = !config.jamfURL.isEmpty
            && (onPlatform ? config.isPlatformAPIReady : JamfUserSession.shared.hasCredentials)
        return Text(hasCredentials ? "Connected" : (onPlatform ? "Platform API Not Set Up" : "Sign In to \(Branding.productName)"))
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(hasCredentials ? FleetHubTheme.goodText : FleetHubTheme.warnText)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hasCredentials ? FleetHubTheme.goodFill : FleetHubTheme.warnFill)
            )
    }

    // MARK: - Search Field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FleetHubTheme.muted)
                .font(.system(size: 13, weight: .medium))

            TextField("", text: $searchText, prompt: Text("Search by name or serial number…")
                .foregroundColor(FleetHubTheme.muted))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(FleetHubTheme.ink)
                .focused($isSearchFocused)
                .onSubmit {
                    performSearch()
                }
                .onChange(of: searchText) { _, newValue in
                    // Debounced live search — 400ms after typing stops. Any
                    // search already on the wire is for a query the operator
                    // has moved past, so it is cancelled too.
                    searchTask?.cancel()
                    cancelInFlightSearch()
                    if newValue.trimmingCharacters(in: .whitespaces).count >= 2 {
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard !Task.isCancelled else { return }
                            performSearch()
                        }
                    } else if newValue.isEmpty {
                        clearResults()
                    }
                }

            if !searchText.isEmpty {
                Button {
                    searchTask?.cancel()
                    cancelInFlightSearch()
                    searchText = ""
                    clearResults()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FleetHubTheme.muted)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            if searchService.isSearching {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .overlay(
            RoundedRectangle(cornerRadius: FleetHubTheme.controlRadius, style: .continuous)
                .stroke(isSearchFocused ? FleetHubTheme.accent : FleetHubTheme.border, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if searchService.searchResults.isEmpty && !searchService.isSearching {
                    emptyState
                } else {
                    ForEach(searchService.searchResults) { result in
                        MenuBarResultRow(result: result)
                        Rectangle().fill(FleetHubTheme.border.opacity(0.6)).frame(height: 1)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let error = searchService.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(FleetHubTheme.warnText)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
        } else if searchText.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(FleetHubTheme.muted)
                Text("Search for a Device")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                Text("Enter a device name or serial number.")
                    .font(.system(size: 12))
                    .foregroundStyle(FleetHubTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 50)
        } else if searchText.count < 2 {
            Text("Type at least 2 characters…")
                .font(.system(size: 12))
                .foregroundStyle(FleetHubTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    // MARK: - Footer

    private func footerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(FleetHubTheme.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(FleetHubTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(FleetHubTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            footerButton("Open \(Branding.productName)", icon: "macwindow") {
                openMainApp()
            }

            Spacer()

            Text("\(searchService.searchResults.count) result\(searchService.searchResults.count == 1 ? "" : "s")")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(FleetHubTheme.muted)
                .opacity(searchService.searchResults.isEmpty ? 0 : 1)

            Spacer()

            footerButton("Quit", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(FleetHubTheme.ground)
        .overlay(alignment: .top) {
            Rectangle().fill(FleetHubTheme.border).frame(height: 1)
        }
    }

    // MARK: - Actions

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else { return }
        // One search in flight at a time: a superseded one is cancelled and
        // the service guards cancellation before publishing, so it can never
        // overwrite the newer results.
        cancelInFlightSearch()
        inFlightSearch = Task {
            await searchService.searchDevices(query: query)
            guard !Task.isCancelled else { return }
            inFlightSearch = nil
        }
    }

    private func cancelInFlightSearch() {
        inFlightSearch?.cancel()
        inFlightSearch = nil
    }

    /// Empties the list for a cleared field. The in-flight search (if any)
    /// has already been cancelled, so nothing can repopulate it afterwards.
    private func clearResults() {
        searchService.searchResults = []
        searchService.errorMessage = nil
        searchService.isSearching = false
    }

    private func openMainApp() {
        activateOrLaunchMainApp()
    }
}

/// Activate the main FleetHub app if running, or launch it if not.
/// Never spawns a duplicate instance.
private func activateOrLaunchMainApp() {
    let bundleID = "com.herojoneslabs.fleethub"
    
    // Check if the main app is already running
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    
    if let app = runningApps.first {
        // Already running — just bring it to front
        AppLog.notice("🔗 MenuBar: Main app already running (pid \(app.processIdentifier)), activating")
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    } else {
        // Not running — launch it
        AppLog.notice("🔗 MenuBar: Main app not running, launching")
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } else {
            AppLog.error("❌ MenuBar: Could not find FleetHub app")
        }
    }
}

// MARK: - Result Row

private struct MenuBarResultRow: View {
    let result: UnifiedSearchResult
    @State private var isHovered = false

    var body: some View {
        Button {
            openDeviceInConsole()
        } label: {
            HStack(spacing: 10) {
                deviceIcon
                deviceInfo
                Spacer(minLength: 4)
                chevron
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isHovered ? FleetHubTheme.ground.opacity(0.7) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Device Icon

    @ViewBuilder
    private var deviceIcon: some View {
        DeviceIconView(
            modelIdentifier: result.modelIdentifier,
            modelName: result.model,
            platform: result.platform,
            size: 36
        )
    }

    // MARK: - Device Info

    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(result.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FleetHubTheme.ink)
                    .lineLimit(1)

                platformBadge
            }

            HStack(spacing: 6) {
                Text(result.serialNumber)
                    .font(.system(size: 11))
                    .foregroundStyle(FleetHubTheme.muted)

                if result.model != "Mac" && result.model != "Unknown" {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(FleetHubTheme.muted)
                    Text(result.model)
                        .font(.system(size: 11))
                        .foregroundStyle(FleetHubTheme.muted)
                        .lineLimit(1)
                }
            }

            if let user = result.assignedUser {
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.system(size: 9))
                    Text(user)
                        .font(.system(size: 11))
                }
                .foregroundStyle(FleetHubTheme.muted)
                .lineLimit(1)
            }
        }
    }

    private var platformBadge: some View {
        Text(result.platform.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(FleetHubTheme.control)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(FleetHubTheme.trough))
            .fixedSize()
    }

    private var chevron: some View {
        Image(systemName: "arrow.up.forward")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(FleetHubTheme.muted)
    }

    // MARK: - Action

    private func openDeviceInConsole() {
        let type: String
        let id: String

        switch result {
        case .computer(let computer):
            type = "computer"
            id = computer.id
        case .mobileDevice(let device):
            type = "mobiledevice"
            id = device.id
        }

        // Write deep link to shared UserDefaults so the main app picks it up on activation
        let suiteName = "com.herojoneslabs.fleethub"
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.set(type, forKey: "DeepLink_DeviceType")
            defaults.set(id, forKey: "DeepLink_DeviceID")
            defaults.synchronize()
            AppLog.notice("🔗 MenuBar: Wrote deep link — type: \(type), id: \(id)")
        }
        
        // Post a cross-process notification so the main app picks it up immediately
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.herojoneslabs.fleethub.deeplink"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        AppLog.notice("🔗 MenuBar: Posted distributed notification")
        
        // Activate or launch the main app
        activateOrLaunchMainApp()
    }
}
