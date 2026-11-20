//
//  FleetHubApp.swift
//  FleetHub
//
//  Main application entry point
//

import SwiftUI
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.herojoneslabs.fleethub", category: "App")

/// Entry point. A Jamf policy can run the app's executable with
/// `--import-credential` to store an API client secret in the Keychain
/// (see CredentialImporter); that path never opens a window. Anything else
/// starts the app as usual.
@main
enum FleetHubMain {
    static func main() {
        // ssh starts this binary to supply an SSH password; that must be
        // answered before anything else in the app runs.
        if let exitCode = SSHSession.runAskPassIfRequested() {
            exit(exitCode)
        }
        if let exitCode = CredentialImporter.runIfRequested() {
            exit(exitCode)
        }
        LaunchContext.correct()
        #if DEBUG
        // Test aid (`-FleetHubSSHProbe host port user alias`, DEBUG builds
        // only): runs the reachability check and one sign-in attempt with a
        // throwaway password, prints what happened, and exits.
        if let index = CommandLine.arguments.firstIndex(of: "-FleetHubSSHProbe"),
           CommandLine.arguments.count > index + 4 {
            let arguments = CommandLine.arguments
            let host = arguments[index + 1], port = Int(arguments[index + 2]) ?? 22
            let target = SSHTarget(host: host, port: port, username: arguments[index + 3],
                                   hostKeyAlias: arguments[index + 4])
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                print("reachable: \(await SSHSession.isReachable(host: host, port: port, timeout: 3))")
                do {
                    let session = try SSHSession(target: target)
                    try await session.connect(password: "throwaway-test-value", timeout: 15)
                    print("connect: signed in")
                    session.close()
                } catch {
                    print("connect: \(error)")
                }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        // Test aid (`-FleetHubPrintConfig`, DEBUG builds only): prints what
        // was read from the managed domains — identifiers only, never a
        // secret — and exits. Used to check that delivered keys are seen.
        if CommandLine.arguments.contains("-FleetHubPrintConfig") {
            let config = MDMConfigurationManager.shared.configuration
            print("apiBackend: \(config.effectiveAPIBackend)")
            if let platform = config.platformAPI {
                print("platformAPI: region=\(platform.region) clientID=\(platform.clientID) tenantID=\(platform.tenantID) environmentID=\(platform.environmentID) protectTenantID=\(platform.protectTenantID)")
            } else {
                print("platformAPI: <not read>")
            }
            print("platformSecretPresent: \(config.isPlatformAPIReady)")
            print("signInMethod: \(config.signInMethod) entraUsable: \(config.isEntraSignInConfigured)")
            print("entraRedirectURI: \(config.entraSignInRedirectURI)")
            print("autoCreate: \(config.effectiveAutoCreateUserApiClient) configured: \(config.isConfigured) needsOwnClient: \(MDMConfigurationManager.shared.needsOwnAPIClient) setupScreen: \(MDMConfigurationManager.shared.needsCredentialOnboarding)")
            print("vpnIPExtensionAttribute: \(String(describing: config.effectiveVPNIPExtensionAttribute))")
            print("complianceAvailable: \(ComplianceBenchmarkService.isAvailable) reason: \(ComplianceBenchmarkService.unavailableReason ?? "none")")
            // Health cards as read, and how a sample device in each excluded
            // site / group resolves.
            let policy = HealthPolicy.current()
            print("healthPolicyConfigured: \(policy.isConfigured) cards: \(policy.cards.keys.sorted())")
            for metric in HealthMetricType.allCases {
                guard let card = policy.card(for: metric) else { continue }
                let carveOuts = card.effectiveExcept
                print("card \(metric.configID): excludes \(carveOuts.map { "\($0.type ?? "?"):\($0.effectiveID)" })")
                for selector in carveOuts {
                    let isMobile = selector.type == "mobileGroup"
                    let facts = DeviceScopeFacts(
                        deviceID: "probe", platform: isMobile ? "iOS" : "macOS",
                        siteID: selector.type == "site" ? selector.effectiveID : "999999", siteName: nil,
                        groupIDs: selector.type == "site" ? [] : [selector.effectiveID],
                        groupDataAvailable: true, isMobile: isMobile
                    )
                    print("   device in \(selector.type ?? "?") \(selector.effectiveID) -> \(policy.resolveScope(for: metric, facts: facts))")
                }
                let outside = DeviceScopeFacts(deviceID: "probe", platform: "macOS", siteID: "999999", siteName: nil,
                                               groupIDs: [], groupDataAvailable: true, isMobile: false)
                print("   device elsewhere -> \(policy.resolveScope(for: metric, facts: outside))")
            }
            exit(0)
        }
        #endif
        FleetHubApp.main()
    }
}

struct FleetHubApp: App {
    @StateObject private var deepLinkRouter = DeepLinkRouter()
    
    init() {
        // Log final configuration state (loaded from the four managed
        // preference domains — dev config via `defaults write
        // com.herojoneslabs.fleethub.core …` etc.; see docs/Configuration.md)
        let config = MDMConfigurationManager.shared.configuration
        logger.info("App initialized with Jamf URL: \(config.jamfURL)")
        
        // Check ABM configuration
        if config.isABMConfigured {
            logger.info("ABM is configured - AppleCare lookups enabled")
        } else {
            logger.info("ABM is not configured - AppleCare lookups disabled")
        }

        // Menu bar search: on by default, unless the user or the
        // organization's profile turned it off.
        MenuBarCompanion.shared.applyPolicy()

        // Site scoping: starts following the signed-in person's roles
        // before any inventory is loaded.
        _ = SiteScopeManager.shared
    }
    
    var body: some Scene {
        WindowGroup {
            WelcomeLoginView()
                .frame(minWidth: 1200, minHeight: 800)
                .preferredColorScheme(AppSettings.shared.currentColorScheme)
                .environmentObject(AppSettings.shared)
                .environmentObject(deepLinkRouter)
                .environmentObject(UserSession.shared)
                .onOpenURL { url in
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    deepLinkRouter.handleURL(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    deepLinkRouter.checkForPendingDeepLink()
                }
                .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.herojoneslabs.fleethub.deeplink"))) { _ in
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    deepLinkRouter.checkForPendingDeepLink()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}


/// Puts the app in the signed-in person's context before anything reads the
/// Keychain.
///
/// A management tool can start the app as root, or as the user but with
/// root's home folder. Either way the app looks in the wrong Keychain,
/// finds no secrets, and shows Set Up FleetHub on a Mac that is fully set up.
enum LaunchContext {
    static func correct() {
        if getuid() == 0 {
            relaunchAsConsoleUser()
        }
        // The Keychain is found through the home folder.
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            let real = String(cString: home)
            if ProcessInfo.processInfo.environment["HOME"] != real {
                setenv("HOME", real, 1)
                setenv("CFFIXED_USER_HOME", real, 1)
            }
        }
    }

    /// Started as root: hand over to the person at the screen and quit. With
    /// nobody logged in there is no one to hand over to, so just quit.
    private static func relaunchAsConsoleUser() {
        var info = stat()
        guard stat("/dev/console", &info) == 0, info.st_uid != 0,
              let entry = getpwuid(info.st_uid) else {
            FileHandle.standardError.write(Data("FleetHub: started as root with no one logged in; quitting.\n".utf8))
            exit(0)
        }
        let user = String(cString: entry.pointee.pw_name)
        // Wait for this root copy to be gone first, so the launch starts a
        // new copy instead of bringing this one forward.
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/launchctl asuser "$2" /usr/bin/sudo -H -u "$3" /usr/bin/open -a "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(getpid()), String(info.st_uid), user, Bundle.main.bundlePath]
        try? process.run()
        FileHandle.standardError.write(Data("FleetHub: started as root; reopening as \(user).\n".utf8))
        exit(0)
    }
}
