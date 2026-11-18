//
//  DeviceCommandExecutor.swift
//  FleetHub
//
//  Executes device actions for one computer: Jamf token minting, MDM
//  command dispatch (restart/shutdown/Bluetooth/remote desktop/unlock/blank
//  push), LAPS + FileVault key reads, ABM unassign, Screen Share, and the
//  erase-acknowledgment state machine behind Erase Device / Return to
//  Service. Presentation-free: the device view renders the observable
//  result/progress state below and owns every dialog.
//

import SwiftUI
import Observation

@Observable
@MainActor
final class DeviceCommandExecutor {
    struct CommandResult {
        let success: Bool
        let title: String
        let message: String
    }

    /// The Return to Service plan the operator confirmed. Snapshotted when the
    /// confirmation dialog opens so the executed steps are exactly the steps
    /// that were shown, even if a profile re-push lands mid-dialog.
    struct ReturnToServicePlan {
        let options: AccessConfiguration.ReturnToServiceOptions
        let entraConfigured: Bool
    }

    /// The device commands target. Kept in sync by the view as full
    /// details load.
    var computer: Computer

    // MARK: - Observable command state

    var isExecutingCommand: Bool = false
    var commandResult: CommandResult?
    var showingCommandAlert: Bool = false
    /// Non-nil while a multi-stage flow (Return to Service / Erase Device) is
    /// processing; drives the progress modal and carries the current stage.
    var processingMessage: String? = nil
    /// Title shown on the processing overlay — set by whichever long-running
    /// flow is driving it (Return to Service vs. bare Erase Device).
    var processingTitle: String = "Return to Service"

    // Sensitive reads, shown until the operator dismisses them.

    /// What the SSH flow is showing: a step in progress, a changed host key
    /// waiting for a decision, or a failure. nil when nothing is shown.
    enum SSHPrompt: Equatable {
        case working(String)
        case hostKeyChanged
        case failed(title: String, message: String)
    }
    var sshPrompt: SSHPrompt?
    @ObservationIgnored private var sshTask: Task<Void, Never>?

    init(computer: Computer) {
        self.computer = computer
    }

    /// Read fresh on every execution path (strict fail-closed — see
    /// DeviceActionPolicy): the policy is a value type, so it must be rebuilt
    /// from the CURRENT configuration and capabilities.
    private var actionPolicy: DeviceActionPolicy {
        .currentForComputers
    }

    // MARK: - Action dispatch

    /// Runs a confirmed menu action. `returnToServicePlan` is the plan the
    /// operator confirmed (snapshotted when the dialog opened); sheet-owned
    /// actions are never routed here but stay exhaustive via `presentSheet`.
    func execute(
        _ action: DeviceAction,
        returnToServicePlan: ReturnToServicePlan?,
        openURL: OpenURLAction,
        presentSheet: (DeviceAction) -> Void
    ) async {
        // Defense in depth: the menu already filters by policy, but never
        // rely on UI alone — re-check the signed-in user's role capability
        // (the single gating layer) before any command fires, and audit-log
        // the denial.
        if let denial = actionPolicy.denialReason(for: action) {
            await reportActionDenial(denial, for: action)
            return
        }

        switch action {
        case .enableBluetooth:
            await sendBluetoothCommand(enable: true)
        case .disableBluetooth:
            await sendBluetoothCommand(enable: false)
        case .enableRemoteDesktop:
            await sendRemoteDesktopCommand(enable: true)
        case .disableRemoteDesktop:
            await sendRemoteDesktopCommand(enable: false)
        case .restart:
            await sendRestartCommand(notifyUser: true)
        case .restartSilent:
            await sendRestartCommand(notifyUser: false)
        case .shutdown:
            await sendShutdownCommand()
        case .wipe:
            await sendWipeCommand()
        case .returnToService:
            await sendEraseCommand(plan: returnToServicePlan)
        case .viewLocalAdminPassword:
            await fetchLocalAdminPassword()
        case .viewFileVaultKey:
            await fetchFileVaultKey()
        case .sendBlankPush:
            await sendBlankPushCommand()
        case .screenShare:
            await launchScreenShare(openURL: openURL)
            return // Screen Share handles its own logging
        case .ssh:
            startSSH()
            return // the SSH flow shows its own prompts and logs itself
        case .unlockUserAccount:
            // Never routed here (the action flow opens the sheet directly), but
            // keep the switch exhaustive and safe.
            presentSheet(.unlockUserAccount)
            return
        case .abmAssign:
            // Never routed here (the action flow opens the sheet, which owns the
            // flow and its own audit logging) — keep the switch exhaustive.
            presentSheet(.abmAssign)
            return
        case .abmUnassign:
            await executeABMUnassign()
            return // logs internally with ABM-specific detail
        case .assignPreStage:
            // Never routed here (the action flow opens the sheet, which owns the
            // flow and its own audit logging) — keep the switch exhaustive.
            presentSheet(.assignPreStage)
            return
        case .moveToSite:
            // Never routed here (the action flow opens the sheet, which owns the
            // flow and its own audit logging) — keep the switch exhaustive.
            presentSheet(.moveToSite)
            return
        }
        
        // Centralized logging for all MDM commands (except Screen Share which logs internally)
        if let result = commandResult {
            ActionLogService.shared.logAction(
                actionName: action.logName,
                actionCategory: action.logCategory,
                deviceName: computer.displayName,
                deviceSerialNumber: computer.serialNumber ?? "Unknown",
                deviceId: computer.id,
                success: result.success,
                errorMessage: result.success ? nil : result.message
            )
        }
    }

    /// Removes this device's MDM assignment in Apple Business Manager.
    /// The grant's allowedMdmServers governs which servers the operator may
    /// unassign FROM — checked against the device's CURRENT server.
    private func executeABMUnassign() async {
        guard let serial = computer.serialNumber, !serial.isEmpty else {
            showABMResult(success: false, title: "Unassign from MDM Server",
                                message: "This device has no serial number to look up in Apple Business Manager.")
            return
        }

        await MainActor.run { isExecutingCommand = true }

        do {
            let device = try await ABMAssignmentExecutor.resolveDevice(serial: serial)
            let servers = try await ABMAssignmentExecutor.loadServers()
            guard let current = try await ABMAssignmentExecutor.currentServer(for: device, servers: servers) else {
                showABMResult(success: false, title: "Unassign from MDM Server",
                                    message: "The device is not assigned to any MDM server in Apple Business Manager — there is nothing to unassign.")
                return
            }

            guard actionPolicy.canAssignToMdmServer(named: current.serverName) else {
                showABMResult(success: false, title: "Not Permitted",
                                    message: "Your role's grant does not permit unassigning devices from \(current.serverName).")
                logABMAction(.abmUnassign, serial: serial, success: false,
                             error: "Denied by allowedMdmServers for server \(current.serverName)")
                return
            }

            let outcome = try await ABMAPIService.shared.performAssignment(
                .unassignDevices, deviceId: device.id, mdmServerId: current.id
            )

            switch outcome {
            case .succeeded:
                await MainActor.run {
                    ABMDeviceCache.shared.applyAssignment(deviceId: device.id, serverId: nil)
                }
                showABMResult(success: true, title: "Unassigned from \(current.serverName)",
                                    message: "The device no longer has an MDM server assignment in Apple Business Manager. Until it is reassigned, it cannot enroll via Automated Device Enrollment.")
                logABMAction(.abmUnassign, serial: serial, success: true, error: nil)
            case .completedWithErrors(let detail):
                showABMResult(success: false, title: "Completed With Errors",
                                    message: "Apple accepted the request but reported errors:\n\n\(detail)")
                logABMAction(.abmUnassign, serial: serial, success: false, error: "COMPLETED_WITH_ERROR")
            case .failed(let status):
                showABMResult(success: false, title: "Unassign Failed",
                                    message: "Apple Business Manager reported the activity as \(status).")
                logABMAction(.abmUnassign, serial: serial, success: false, error: status)
            case .stillRunning(let activityId):
                showABMResult(success: false, title: "Still Processing",
                                    message: "Apple accepted the request but it had not completed when polling stopped (activity \(activityId)). Check the ABM Lookup tab shortly to confirm.")
                logABMAction(.abmUnassign, serial: serial, success: false, error: "Timed out polling activity \(activityId)")
            }
        } catch {
            showABMResult(success: false, title: "Unassign Failed", message: error.localizedDescription)
            logABMAction(.abmUnassign, serial: serial, success: false, error: error.localizedDescription)
        }
    }

    private func showABMResult(success: Bool, title: String, message: String) {
        // Every executeABMUnassign path ends here, so the busy flag clears
        // before (never after) the result alert appears.
        isExecutingCommand = false
        commandResult = CommandResult(success: success, title: title, message: message)
        showingCommandAlert = true
    }

    func logABMAction(_ action: DeviceAction, serial: String, success: Bool, error: String?) {
        ActionLogService.shared.logAction(
            actionName: action.logName,
            actionCategory: action.logCategory,
            deviceName: computer.displayName,
            deviceSerialNumber: serial,
            deviceId: computer.id,
            success: success,
            errorMessage: error
        )
    }

    /// Shared denial handling for the defense-in-depth policy re-checks
    /// (executeAction and the Unlock Account sheet): surfaces the
    /// "Action Not Permitted" alert and audit-logs which layer denied.
    func reportActionDenial(_ denial: DeviceActionPolicy.DenialReason, for action: DeviceAction) async {
        // The operator-facing copy is the same either way — "not available for
        // your role" is true of both — but the AUDIT LOG distinguishes them,
        // because an emptyScope denial is a profile authoring mistake (the
        // action was granted, then scoped to nothing) and would otherwise be
        // indistinguishable from an intentional denial when someone asks why
        // a technician cannot see a button they were told they have.
        let auditDetail: String
        switch denial {
        case .roleCapability:
            auditDetail = "Blocked by role capability (no role held by this user grants '\(action.rawValue)' on computers; roles: \(signedInRolesDescription))"
        case .emptyScope:
            auditDetail = "Blocked by empty scope ('\(action.rawValue)' IS granted, but the role's target allow-list is empty — check allowedSites in the access profile; roles: \(signedInRolesDescription))"
        }

        await MainActor.run {
            commandResult = CommandResult(
                success: false,
                title: "Action Not Permitted",
                message: "\"\(action.logName)\" is not available for your role."
            )
            showingCommandAlert = true
        }
        ActionLogService.shared.logAction(
            actionName: action.logName,
            actionCategory: action.logCategory,
            deviceName: computer.displayName,
            deviceSerialNumber: computer.serialNumber ?? "Unknown",
            deviceId: computer.id,
            success: false,
            errorMessage: auditDetail
        )
    }

    /// The user's role names for audit copy — roles are arbitrary names
    /// defined by the profile, so the log records what they actually held.
    private var signedInRolesDescription: String {
        UserSession.shared.roles.isEmpty ? "none" : UserSession.shared.roles.joined(separator: ", ")
    }
    
    // MARK: - Remote access address

    /// The address Screen Share and SSH connect to: the VPN address when the
    /// profile enables the lookup and the device's extension attribute holds
    /// one, otherwise the address in the Jamf inventory record.
    private func remoteAccessAddress() -> (address: String, viaVPN: Bool) {
        let vpnIP = MDMConfigurationManager.shared.configuration.effectiveVPNIPExtensionAttribute
            .flatMap { computer.extensionAttributeValue($0) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let vpnIP, !vpnIP.isEmpty, vpnIP.uppercased() != "N/A" {
            return (vpnIP, true)
        }
        return (computer.ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", false)
    }

    // MARK: - SSH

    /// Starts the SSH flow: reachability, password, sign-in, window. Every
    /// step reports through `sshPrompt`, which the device view draws.
    func startSSH(forgettingSavedHostKey: Bool = false) {
        sshTask?.cancel()
        sshTask = Task { await runSSH(forgettingSavedHostKey: forgettingSavedHostKey) }
    }

    /// Stops a connection attempt the operator no longer wants.
    func cancelSSH() {
        sshTask?.cancel()
        sshTask = nil
        sshPrompt = nil
    }

    private func logSSH(_ name: String, category: String = "Device Actions", address: String? = nil,
                        success: Bool, error: String? = nil) {
        ActionLogService.shared.logAction(
            actionName: name,
            actionCategory: category,
            deviceName: computer.displayName,
            deviceSerialNumber: computer.serialNumber ?? "Unknown",
            deviceId: computer.id,
            ipAddressUsed: address,
            success: success,
            errorMessage: error
        )
    }

    private func runSSH(forgettingSavedHostKey: Bool) async {
        let name = computer.displayName
        let settings = MDMConfigurationManager.shared.configuration.features?.effectiveComputers
        let port = settings?.effectiveSSHPort ?? 22

        func fail(_ title: String, _ message: String, address: String? = nil) {
            guard !Task.isCancelled else { return }
            sshPrompt = .failed(title: title, message: message)
            logSSH("SSH Session", address: address, success: false, error: title)
        }

        // 1. Where to connect.
        let (address, viaVPN) = remoteAccessAddress()
        guard !address.isEmpty else {
            fail("No Address for This Device",
                 "Jamf has no IP address for \(name), and no VPN address was reported, so there is nothing to connect to.")
            return
        }
        let shownAddress = viaVPN ? "\(address) (VPN)" : address

        // 2. Can it be reached?
        sshPrompt = .working("Checking that \(name) can be reached at \(shownAddress)…")
        guard await SSHSession.isReachable(host: address, port: port) else {
            fail("Device Not Reachable",
                 "\(name) did not answer on port \(port) at \(shownAddress). The Mac may be off, asleep or off the network, the address Jamf holds may be out of date, or Remote Login may be turned off.",
                 address: address)
            return
        }
        guard !Task.isCancelled else { return }

        // 3. The management account and its current password.
        sshPrompt = .working("Getting the management account password from Jamf…")
        let credential: (username: String, password: String)
        do {
            credential = try await fetchManagementAccountCredential()
            logSSH("Used management account password for SSH", category: "Security", success: true)
        } catch {
            logSSH("Used management account password for SSH", category: "Security", success: false,
                   error: error.localizedDescription)
            fail("Password Not Available",
                 "FleetHub could not get the management account password for \(name): \(error.localizedDescription).",
                 address: address)
            return
        }
        let fetchedAt = Date()
        guard !Task.isCancelled else { return }

        // 4. Sign in.
        let alias = Self.hostKeyAlias(serial: computer.serialNumber, fallback: address)
        if forgettingSavedHostKey {
            SSHSession.removeSavedHostKey(alias: alias)
            logSSH("Removed saved SSH host key", category: "Security", address: address, success: true)
        }
        sshPrompt = .working("Signing in to \(name) as \(credential.username)…")
        let session: SSHSession
        do {
            session = try SSHSession(target: SSHTarget(host: address, port: port,
                                                       username: credential.username, hostKeyAlias: alias))
        } catch {
            fail("SSH Could Not Start", "FleetHub could not prepare the connection: \(error.localizedDescription)", address: address)
            return
        }
        do {
            try await session.connect(password: credential.password)
        } catch {
            session.close()
            guard !Task.isCancelled else { return }
            switch error as? SSHFailure {
            case .hostKeyChanged:
                sshPrompt = .hostKeyChanged
                logSSH("SSH Session", address: address, success: false, error: "Host key changed")
            case .permissionDenied:
                fail("Sign-In Refused",
                     "\(name) refused the management account's password. The password Jamf holds may not match the Mac yet, or \(credential.username) may not be allowed to use Remote Login.",
                     address: address)
            case .connectionRefused:
                fail("Connection Refused",
                     "\(name) refused the connection on port \(port). Remote Login is probably turned off.",
                     address: address)
            case .timedOut:
                fail("Connection Timed Out",
                     "\(name) stopped answering at \(shownAddress) before the sign-in finished.",
                     address: address)
            case .other(let detail):
                fail("SSH Failed", "ssh reported: \(detail)", address: address)
            case nil:
                fail("SSH Failed", error.localizedDescription, address: address)
            }
            return
        }
        guard !Task.isCancelled else {
            session.close()
            return
        }

        // 5. When does the password rotate? Jamf's own figure when the role
        // can read it, otherwise the configured rotation period.
        let rotation = await passwordRotation(username: credential.username, password: credential.password,
                                              fetchedAt: fetchedAt)

        SSHWindowManager.shared.open(
            session: session,
            info: SSHSessionInfo(
                deviceName: name,
                serialNumber: computer.serialNumber ?? "Unknown",
                deviceID: computer.id,
                username: credential.username,
                host: address,
                viaVPN: viaVPN,
                startedAt: Date(),
                rotatesAt: rotation.rotatesAt,
                rotationIsEstimate: rotation.isEstimate,
                rotationNote: rotation.note
            ),
            fetchPassword: passwordFetcher(account: .management,
                                           logName: "Copied management account password (SSH window)")
        )
        sshPrompt = nil
        logSSH("SSH Session Started", address: address, success: true)
    }

    /// Which LAPS account a panel's Copy Password reads.
    private enum PasswordAccount {
        /// The Jamf management framework account (SSH, Screen Share).
        case management
        /// The account named in the profile (the Local Admin Password action).
        case localAdmin
    }

    /// A window or panel's Copy Password and Show actions, or nil when the
    /// role may not view the local admin password. Each call reads the
    /// current password from Jamf (Jamf audits it as a view), works out its
    /// rotation time again, and is logged here.
    private func passwordFetcher(account: PasswordAccount, logName: String)
        -> (() async throws -> FetchedPassword)? {
        guard actionPolicy.isAllowed(.viewLocalAdminPassword) else { return nil }
        return { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.actionPolicy.isAllowed(.viewLocalAdminPassword) else {
                throw NSError(domain: "SSH", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "your role no longer allows viewing the local admin password"])
            }
            do {
                let credential: (username: String, password: String)
                switch account {
                case .management: credential = try await self.fetchManagementAccountCredential()
                case .localAdmin: credential = try await self.fetchLocalAdminCredential()
                }
                let rotation = await self.passwordRotation(username: credential.username,
                                                           password: credential.password, fetchedAt: Date())
                self.logSSH(logName, category: "Security", success: true)
                return FetchedPassword(username: credential.username, password: credential.password,
                                       rotatesAt: rotation.rotatesAt, rotationIsEstimate: rotation.isEstimate,
                                       rotationNote: rotation.note)
            } catch {
                self.logSSH(logName, category: "Security",
                            success: false, error: error.localizedDescription)
                throw error
            }
        }
    }

    /// Letters and digits of the serial number; the address when there is none.
    private static func hostKeyAlias(serial: String?, fallback: String) -> String {
        let cleaned = (serial ?? "").filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? fallback : "fleethub-\(cleaned.lowercased())"
    }

    /// When Jamf is due to rotate the password just read. Jamf starts the
    /// clock at the password's FIRST view, so this reads the LAPS audit
    /// history (API role privilege "View Local Admin Password Audit
    /// History") and finds the entry for this password. Without that
    /// privilege the time is estimated from now and marked as such.
    private func passwordRotation(username: String, password: String, fetchedAt: Date) async -> LAPSRotation.Result {
        let configured = Double(MDMConfigurationManager.shared.configuration.features?
            .effectiveComputers.effectiveSSHPasswordRotationMinutes ?? 60) * 60
        let jamfURL = MDMConfigurationManager.shared.configuration.jamfURL

        var auditData: Data?
        var auditStatus: Int?
        var jamfPeriod: TimeInterval?
        if let managementId = computer.general?.managementId, !managementId.isEmpty,
           let token = try? await getBearerToken(scope: .sensitiveReads) {
            func get(_ path: String) async -> (Data, Int)? {
                guard let url = URL(string: "\(jamfURL)\(path)") else { return nil }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = NetworkTuning.connectionTimeout
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                guard let (data, response) = try? await JamfTransport.data(for: request),
                      let http = response as? HTTPURLResponse else { return nil }
                return (data, http.statusCode)
            }
            let encodedName = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
            if let (data, status) = await get("/api/v2/local-admin-password/\(managementId)/account/\(encodedName)/audit") {
                auditStatus = status
                // The response lists passwords; it is used for the match and
                // the dates only, and never stored or logged.
                if status == 200 { auditData = data }
            }
            // Jamf's own rotation period. Most operator roles cannot read the
            // LAPS settings; the profile's figure is used then.
            if auditData != nil {
                if let known = Self.jamfRotationPeriod[jamfURL] {
                    jamfPeriod = known
                } else if let (data, status) = await get("/api/v2/local-admin-password/settings"), status == 200 {
                    struct Settings: Decodable { let passwordRotationTime: Double? }
                    let period = (try? JSONDecoder().decode(Settings.self, from: data))?.passwordRotationTime
                    Self.jamfRotationPeriod[jamfURL] = period.flatMap { $0 > 0 ? $0 : nil }
                    jamfPeriod = Self.jamfRotationPeriod[jamfURL] ?? nil
                } else {
                    Self.jamfRotationPeriod[jamfURL] = .some(nil)
                }
            }
        }
        return LAPSRotation.resolve(auditJSON: auditData, auditStatus: auditStatus, password: password,
                                    fetchedAt: fetchedAt, jamfPeriod: jamfPeriod, configuredPeriod: configured)
    }

    /// Jamf's `passwordRotationTime` per server, once asked for. A stored nil
    /// means the role could not read it, so it is not asked for again.
    private static var jamfRotationPeriod: [String: TimeInterval?] = [:]

    // MARK: - Screen Share
    
    private func launchScreenShare(openURL: OpenURLAction) async {
        // The VPN address when the profile names the extension attribute that
        // carries it and the device reports one; otherwise the inventory address.
        let (targetIP, hasVPN) = remoteAccessAddress()
        
        guard !targetIP.isEmpty else {
            commandResult = CommandResult(
                success: false,
                title: "Screen Share Failed",
                message: "No IP address available for this device."
            )
            showingCommandAlert = true
            ActionLogService.shared.logAction(
                actionName: "Screen Share",
                actionCategory: "Device Actions",
                deviceName: computer.displayName,
                deviceSerialNumber: computer.serialNumber ?? "Unknown",
                deviceId: computer.id,
                success: false,
                errorMessage: "No IP address available"
            )
            return
        }
        
        guard URL(string: "vnc://\(targetIP)") != nil else {
            commandResult = CommandResult(
                success: false,
                title: "Screen Share Failed",
                message: "Invalid IP address: \(targetIP)"
            )
            showingCommandAlert = true
            ActionLogService.shared.logAction(
                actionName: "Screen Share",
                actionCategory: "Device Actions",
                deviceName: computer.displayName,
                deviceSerialNumber: computer.serialNumber ?? "Unknown",
                deviceId: computer.id,
                ipAddressUsed: targetIP,
                success: false,
                errorMessage: "Invalid IP address"
            )
            return
        }

        // Optional automatic sign-in (features computers.screenShareAutoSignIn,
        // default off). It discloses a LAPS password, so it ALSO needs the
        // role's viewLocalAdminPassword grant — the Screen Share grant alone
        // never fetches a credential. Any failure falls back to the plain
        // prompt: the session still opens, the operator just types the
        // credential as before.
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = targetIP
        var signedInAs: String?
        var signedInPassword: String?
        var passwordFetchedAt: Date?
        var autoSignInNote = ""

        let autoSignInEnabled = MDMConfigurationManager.shared.configuration
            .features?.effectiveComputers.effectiveScreenShareAutoSignIn ?? false
        if autoSignInEnabled, actionPolicy.isAllowed(.viewLocalAdminPassword) {
            await MainActor.run { isExecutingCommand = true }
            do {
                let credential = try await fetchManagementAccountCredential()
                // Percent-encode with unreserved characters only, so a
                // password containing ':', '@' or '/' cannot be read as part
                // of the URL's structure.
                components.percentEncodedUser = Self.urlCredentialEncode(credential.username)
                components.percentEncodedPassword = Self.urlCredentialEncode(credential.password)
                signedInAs = credential.username
                signedInPassword = credential.password
                passwordFetchedAt = Date()
                ActionLogService.shared.logAction(
                    actionName: "Used management account password for Screen Share",
                    actionCategory: "Security",
                    deviceName: computer.displayName,
                    deviceSerialNumber: computer.serialNumber ?? "Unknown",
                    deviceId: computer.id,
                    success: true
                )
            } catch {
                // Never include the credential or the URL in a message or log.
                autoSignInNote = "\n\nAutomatic sign-in was not available (\(error.localizedDescription)), so Screen Sharing will ask for a name and password."
                ActionLogService.shared.logAction(
                    actionName: "Used management account password for Screen Share",
                    actionCategory: "Security",
                    deviceName: computer.displayName,
                    deviceSerialNumber: computer.serialNumber ?? "Unknown",
                    deviceId: computer.id,
                    success: false,
                    errorMessage: error.localizedDescription
                )
            }
            await MainActor.run { isExecutingCommand = false }
        }

        guard let url = components.url else {
            commandResult = CommandResult(
                success: false,
                title: "Screen Share Failed",
                message: "Could not build the Screen Sharing address for \(targetIP)."
            )
            showingCommandAlert = true
            return
        }

        // The URL may carry a credential: hand it straight to the system and
        // let it go out of scope. It is never logged, shown or copied.
        //
        // A session is only reported once the system accepted the address
        // and the app that handles it (Apple's Screen Sharing unless another
        // viewer is the default) is running. Whether that app then reaches
        // the Mac and signs in is its own business: it shows its own errors.
        let viewerID = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "vnc://localhost") ?? url)
            .flatMap { Bundle(url: $0)?.bundleIdentifier } ?? SSHWindowManager.screenSharingBundleID
        let accepted = await withCheckedContinuation { continuation in
            openURL(url) { continuation.resume(returning: $0) }
        }
        var viewerRunning = false
        if accepted {
            for _ in 0..<24 {
                if !NSRunningApplication.runningApplications(withBundleIdentifier: viewerID).isEmpty {
                    viewerRunning = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        ActionLogService.shared.logAction(
            actionName: "Screen Share",
            actionCategory: "Device Actions",
            deviceName: computer.displayName,
            deviceSerialNumber: computer.serialNumber ?? "Unknown",
            deviceId: computer.id,
            ipAddressUsed: targetIP,
            success: viewerRunning,
            errorMessage: viewerRunning ? nil : "Screen Sharing did not open"
        )
        guard viewerRunning else {
            commandResult = CommandResult(
                success: false,
                title: "Screen Share Failed",
                message: "Screen Sharing did not open for \(targetIP). Check that an app is set to open vnc:// addresses on this Mac."
            )
            showingCommandAlert = true
            return
        }

        // The FleetHub panel beside Apple's Screen Sharing window. When the
        // management account's password signed the session in, the panel
        // counts down to its rotation.
        var rotation: LAPSRotation.Result?
        if let signedInAs, let signedInPassword, let passwordFetchedAt {
            rotation = await passwordRotation(username: signedInAs, password: signedInPassword,
                                              fetchedAt: passwordFetchedAt)
        }
        SSHWindowManager.shared.openScreenSharePanel(
            info: SSHSessionInfo(
                deviceName: computer.displayName,
                serialNumber: computer.serialNumber ?? "Unknown",
                deviceID: computer.id,
                username: signedInAs ?? "",
                host: targetIP,
                viaVPN: hasVPN,
                startedAt: Date(),
                rotatesAt: rotation?.rotatesAt,
                rotationIsEstimate: rotation?.isEstimate ?? false,
                kind: .screenShare,
                rotationNote: rotation?.note
            ),
            fetchPassword: passwordFetcher(account: .management,
                                           logName: "Copied management account password (Screen Share panel)")
        )

        // The panel says the session is open; a dialog is only needed when
        // automatic sign-in was expected and did not happen.
        if !autoSignInNote.isEmpty {
            commandResult = CommandResult(
                success: true,
                title: "Screen Share Launched",
                message: "Opening Screen Sharing to \(targetIP)\(hasVPN ? " (VPN)" : "")." + autoSignInNote
            )
            showingCommandAlert = true
        }
    }

    /// Unreserved characters only (RFC 3986), for the user and password
    /// parts of a URL.
    private static func urlCredentialEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// The device's Jamf management account (LAPS `userSource` "JMF") and its
    /// current password, read with the operator's own API client (the
    /// `sensitiveReads` scope, fail-closed). Jamf audits the view against the
    /// operator and rotates the password afterwards per the LAPS settings.
    ///
    /// Both calls need the API role privilege "View Local Admin Password".
    private func fetchManagementAccountCredential() async throws -> (username: String, password: String) {
        func failure(_ message: String, code: Int = 0) -> NSError {
            NSError(domain: "ScreenShare", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }

        guard let managementId = computer.general?.managementId, !managementId.isEmpty else {
            throw failure("the device has no management ID")
        }
        let jamfURL = MDMConfigurationManager.shared.configuration.jamfURL
        let token = try await getBearerToken(scope: .sensitiveReads)

        func get(_ path: String) async throws -> Data {
            guard let url = URL(string: "\(jamfURL)\(path)") else { throw failure("invalid Jamf Pro URL") }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = NetworkTuning.connectionTimeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await JamfTransport.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw failure("no response from Jamf Pro") }
            switch http.statusCode {
            case 200...299: return data
            case 403: throw failure("your Jamf API role lacks View Local Admin Password", code: 403)
            case 404: throw failure("no LAPS account was found for this device", code: 404)
            // The body of a failed call is never surfaced: keep the message generic.
            default: throw failure("Jamf Pro returned \(http.statusCode)", code: http.statusCode)
            }
        }

        struct Accounts: Decodable {
            struct Account: Decodable { let username: String; let userSource: String? }
            let results: [Account]
        }
        let accounts = try JSONDecoder().decode(
            Accounts.self,
            from: try await get("/api/v2/local-admin-password/\(managementId)/accounts")
        )
        // "JMF" = the Jamf management framework account; "MDM" = the
        // PreStage-created admin. Only the former is used here.
        let managementAccounts = accounts.results.filter { $0.userSource?.uppercased() == "JMF" }
        guard let account = managementAccounts.first else {
            throw failure("this device has no Jamf management account under LAPS")
        }
        guard managementAccounts.count == 1 else {
            throw failure("this device reports more than one Jamf management account")
        }

        let encodedName = account.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account.username
        struct PasswordResponse: Decodable { let password: String }
        let password = try JSONDecoder().decode(
            PasswordResponse.self,
            from: try await get("/api/v2/local-admin-password/\(managementId)/account/\(encodedName)/password")
        ).password
        guard !password.isEmpty else { throw failure("Jamf Pro returned an empty password") }
        return (account.username, password)
    }

    // MARK: - MDM Commands
    
    private func sendBluetoothCommand(enable: Bool) async {
        guard let managementId = computer.general?.managementId else {
            await MainActor.run {
                commandResult = CommandResult(
                    success: false,
                    title: "Error",
                    message: "Device management ID not available"
                )
                showingCommandAlert = true
            }
            return
        }
        
        await MainActor.run { isExecutingCommand = true }
        
        do {
            let config = MDMConfigurationManager.shared.configuration
            let jamfURL = config.jamfURL
            
            // Get bearer token
            let token = try await getBearerToken()
            
            // Build the command payload
            let parameters: [String: Any] = [
                "clientData": [["managementId": managementId]],
                "commandData": [
                    "commandType": "SETTINGS",
                    "bluetooth": enable
                ]
            ]
            
            let postData = try JSONSerialization.data(withJSONObject: parameters, options: [])
            
            guard let url = URL(string: "\(jamfURL)/api/v2/mdm/commands") else {
                throw NSError(domain: "DeviceView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = NetworkTuning.connectionTimeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = postData
            
            AppLog.notice("📤 Sending Bluetooth command (enable: \(enable)) to device: \(computer.displayName)")
            
            let (data, response) = try await JamfTransport.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "DeviceView", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }
            
            AppLog.notice("📥 Bluetooth command response status: \(httpResponse.statusCode)")
            
            if (200...299).contains(httpResponse.statusCode) {
                await MainActor.run {
                    isExecutingCommand = false
                    commandResult = CommandResult(
                        success: true,
                        title: "Command Sent",
                        message: "Bluetooth \(enable ? "enable" : "disable") command has been sent to \(computer.displayName). The device will process this command shortly."
                    )
                    showingCommandAlert = true
                }
            } else {
                AppLog.error("❌ Bluetooth command failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
                throw NSError(
                    domain: "DeviceView",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: JamfErrorFormatter.message(
                        status: httpResponse.statusCode,
                        body: data,
                        fallbackAction: "change Bluetooth"
                    )]
                )
            }
            
        } catch {
            AppLog.error("❌ Bluetooth command error: \(error.localizedDescription)")
            await MainActor.run {
                isExecutingCommand = false
                commandResult = CommandResult(
                    success: false,
                    title: "Command Failed",
                    message: error.localizedDescription
                )
                showingCommandAlert = true
            }
        }
    }
    
    /// Fetches the Jamf token for a device operation. `scope` selects which
    /// routing category applies — MDM commands, the Return-to-Service legs,
    /// or the sensitive password/key reads — so each can be independently
    /// attributed to the operator (per-user, fail-closed) or the master client.
    /// `JamfTokenProvider` owns the routing and the cache.
    private func getBearerToken(scope: CredentialScope = .mdmCommands) async throws -> String {
        try await JamfTokenProvider.token(for: scope)
    }
    
    // MARK: - Remote Desktop Commands
    
    private func sendRemoteDesktopCommand(enable: Bool) async {
        await sendSimpleCommand(
            commandType: enable ? "ENABLE_REMOTE_DESKTOP" : "DISABLE_REMOTE_DESKTOP",
            successMessage: "Remote Desktop \(enable ? "enable" : "disable") command has been sent to \(computer.displayName)."
        )
    }
    
    // MARK: - Restart Command
    
    private func sendRestartCommand(notifyUser: Bool) async {
        guard let managementId = computer.general?.managementId else {
            await showError("Device management ID not available")
            return
        }
        
        await MainActor.run { isExecutingCommand = true }
        
        do {
            let token = try await getBearerToken()
            let config = MDMConfigurationManager.shared.configuration
            
            var commandData: [String: Any] = ["commandType": "RESTART_DEVICE"]
            if notifyUser {
                commandData["notifyUser"] = true
            }
            
            let parameters: [String: Any] = [
                "clientData": [["managementId": managementId]],
                "commandData": commandData
            ]
            
            try await executeCommand(parameters: parameters, token: token, jamfURL: config.jamfURL)
            
            await MainActor.run {
                isExecutingCommand = false
                commandResult = CommandResult(
                    success: true,
                    title: "Command Sent",
                    message: "Restart command has been sent to \(computer.displayName).\(notifyUser ? " The user will be notified." : "")"
                )
                showingCommandAlert = true
            }
        } catch {
            await showError(error.localizedDescription)
        }
    }
    
    // MARK: - Shutdown Command
    
    private func sendShutdownCommand() async {
        await sendSimpleCommand(
            commandType: "SHUT_DOWN_DEVICE",
            successMessage: "Shutdown command has been sent to \(computer.displayName)."
        )
    }
    
    // MARK: - Erase Device (bare erase — Jamf record and Entra object kept)

    /// Bare erase: queue the ERASE_DEVICE command (with recovery PIN), WAIT for
    /// the device to acknowledge it, and stop there — the Jamf computer record
    /// and Entra device object are intentionally left in place. An erase is
    /// never fire-and-forget, so an unacknowledged command surfaces as a
    /// failure the operator must follow up on manually.
    private func sendWipeCommand() async {
        guard let managementId = computer.general?.managementId else {
            await showError("Device management ID not available — cannot erase this device.")
            return
        }

        let config = MDMConfigurationManager.shared.configuration
        let deviceName = computer.displayName
        let serial = computer.serialNumber ?? "Unknown"
        let deviceId = computer.id

        await MainActor.run {
            isExecutingCommand = true
            processingTitle = "Erase Device"
            processingMessage = "Sending erase command to \(deviceName)…"
        }

        do {
            let token = try await getBearerToken()

            let erase = try await performEraseAndAwaitAck(
                managementId: managementId, deviceName: deviceName,
                serial: serial, deviceId: deviceId, token: token, config: config
            )

            var summaryLines = erase.summaryLines
            if erase.acked {
                summaryLines.append("• Erase acknowledged. Jamf record and Entra object intentionally left in place.")
            } else {
                summaryLines.append("• Erase was NOT acknowledged in time — the command remains queued for delivery and the device record is untouched. Follow up manually.")
            }

            await MainActor.run {
                isExecutingCommand = false
                processingMessage = nil
                commandResult = CommandResult(
                    success: erase.acked,
                    title: erase.acked ? "Erase Acknowledged" : "Erase Not Acknowledged",
                    message: "\(deviceName):\n" + summaryLines.joined(separator: "\n")
                )
                showingCommandAlert = true
            }

        } catch {
            AppLog.error("❌ Erase Device error: \(error.localizedDescription)")
            await MainActor.run { processingMessage = nil }
            await showError(error.localizedDescription)
        }
    }

    // MARK: - Return to Service (Erase → configurable Jamf/Entra cleanup)

    /// Orchestrates the decommission: queue the ERASE_DEVICE command, WAIT for
    /// the device to acknowledge it, then run the cleanup steps the profile
    /// enables (options on the returnToService allow-list entry; both default
    /// ON, preserving the full decommission for already-deployed profiles).
    /// Ports the `after-ack` behavior of Erase_and_Delete_Devices.sh — and
    /// hardens it: NO cleanup step (Jamf delete OR Entra delete) may run until
    /// the erase is acknowledged, because deleting the Jamf record removes the
    /// MDM profile and unmanages the Mac — an unacknowledged command would then
    /// never be delivered. Each stage logs independently; Entra is best-effort.
    private func sendEraseCommand(plan: ReturnToServicePlan?) async {
        guard let managementId = computer.general?.managementId else {
            await showError("Device management ID not available — cannot erase this device.")
            return
        }

        let config = MDMConfigurationManager.shared.configuration
        // Execute exactly the plan the operator confirmed (snapshotted when
        // the dialog opened); fall back to the live policy defensively.
        let options = plan?.options ?? actionPolicy.returnToServiceOptions()
        let entraConfiguredAtConfirm = plan?.entraConfigured ?? config.isEntraConfigured
        let deviceName = computer.displayName
        let serial = computer.serialNumber ?? "Unknown"
        let deviceId = computer.id
        let category = "Device Actions"

        await MainActor.run {
            isExecutingCommand = true
            processingTitle = "Return to Service"
            processingMessage = "Sending erase command to \(deviceName)…"
        }

        var summaryLines: [String] = []
        var overallSuccess = true

        do {
            let token = try await getBearerToken(scope: .returnToService)

            // 1) Erase phase: queue the command (with PIN) and wait for the
            // device to acknowledge it.
            let erase = try await performEraseAndAwaitAck(
                managementId: managementId, deviceName: deviceName,
                serial: serial, deviceId: deviceId, token: token, config: config
            )
            summaryLines.append(contentsOf: erase.summaryLines)
            let acked = erase.acked

            // The ack wait can outlive the original bearer token — cleanup
            // uses a fresh one (falling back to the original if the refresh
            // fails; the delete then surfaces its own auth error).
            let cleanupToken = acked ? ((try? await getBearerToken(scope: .returnToService)) ?? token) : token

            // 2) Delete the Jamf record only after the erase is acknowledged,
            // and only when the profile hasn't disabled the step.
            if acked && options.effectiveDeleteJamfRecord {
                await MainActor.run { processingMessage = "Erase acknowledged. Removing Jamf record…" }
                do {
                    try await deleteJamfRecord(computerId: deviceId, token: cleanupToken, jamfURL: config.jamfURL)
                    summaryLines.append("• Erase acknowledged; Jamf record removed.")
                    ActionLogService.shared.logAction(
                        actionName: "Delete Jamf Record", actionCategory: category,
                        deviceName: deviceName, deviceSerialNumber: serial, deviceId: deviceId,
                        success: true, errorMessage: nil
                    )
                } catch {
                    overallSuccess = false
                    summaryLines.append("• Jamf record NOT removed: \(error.localizedDescription)")
                    ActionLogService.shared.logAction(
                        actionName: "Delete Jamf Record", actionCategory: category,
                        deviceName: deviceName, deviceSerialNumber: serial, deviceId: deviceId,
                        success: false, errorMessage: error.localizedDescription
                    )
                }
            } else if acked {
                // Policy-disabled skip — not a failure.
                summaryLines.append("• Jamf record kept (disabled by policy).")
            } else {
                overallSuccess = false
                // Compose the timeout line from the confirmed plan — never
                // invite the operator to manually run a step the profile
                // deliberately disabled.
                var notAckedLine = "• Erase was NOT acknowledged in time — the command remains queued for delivery"
                var skipped: [String] = []
                if options.effectiveDeleteJamfRecord {
                    skipped.append("the Jamf record was intentionally left in place (deleting it now would unmanage the Mac)")
                }
                if options.effectiveDeleteEntraObject && entraConfiguredAtConfirm {
                    skipped.append("Entra cleanup was skipped")
                }
                if !skipped.isEmpty { notAckedLine += "; " + skipped.joined(separator: " and ") }
                notAckedLine += ". Follow up manually."
                summaryLines.append(notAckedLine)
                // Audit the withheld delete only when one was actually
                // planned — a policy-disabled step was never going to run.
                if options.effectiveDeleteJamfRecord {
                    ActionLogService.shared.logAction(
                        actionName: "Delete Jamf Record", actionCategory: category,
                        deviceName: deviceName, deviceSerialNumber: serial, deviceId: deviceId,
                        success: false, errorMessage: "Erase not acknowledged; record intentionally not deleted (would unmanage the Mac)."
                    )
                }
            }

            // 3) Entra cleanup — HARD-gated on acknowledgment like every other
            // cleanup step, then on the profile option. Best effort, only when
            // configured. Never fatal.
            if acked && options.effectiveDeleteEntraObject && entraConfiguredAtConfirm {
                if let entra = EntraGraphService(configuration: config) {
                    let entraName = computer.general?.name ?? deviceName
                    await MainActor.run { processingMessage = "Removing '\(entraName)' from Microsoft Entra…" }
                    let result = await entra.deleteDevices(displayName: entraName)
                    var entraSuccess = true
                    switch result.outcome {
                    case .completed:
                        entraSuccess = result.failed == 0
                        summaryLines.append("• Entra: \(result.deleted) object(s) removed" + (result.failed > 0 ? ", \(result.failed) failed." : "."))
                    case .noMatch:
                        summaryLines.append("• Entra: no matching device object.")
                    case .authFailed, .lookupFailed, .notConfigured:
                        entraSuccess = false
                        summaryLines.append("• Entra cleanup did not complete: \(result.message)")
                    }
                    ActionLogService.shared.logAction(
                        actionName: "Entra Device Cleanup", actionCategory: category,
                        deviceName: entraName, deviceSerialNumber: serial, deviceId: deviceId,
                        success: entraSuccess, errorMessage: entraSuccess ? nil : result.message
                    )
                } else {
                    summaryLines.append("• Entra cleanup not configured — skipped.")
                }
            } else if acked && options.effectiveDeleteEntraObject {
                // Option on, but Entra wasn't configured when the operator
                // confirmed — nothing was promised, nothing runs.
                summaryLines.append("• Entra cleanup not configured — skipped.")
            } else if acked {
                // Policy-disabled skip — not a failure.
                summaryLines.append("• Entra cleanup disabled by policy — skipped.")
            }
            // Not acked: the step-2 summary line already covers the skipped
            // Entra cleanup — no cleanup runs on an unacknowledged erase.

            await MainActor.run {
                isExecutingCommand = false
                processingMessage = nil
                commandResult = CommandResult(
                    success: overallSuccess,
                    title: overallSuccess ? "Return to Service Complete" : "Return to Service — Attention Needed",
                    message: "\(deviceName):\n" + summaryLines.joined(separator: "\n")
                )
                showingCommandAlert = true
            }

        } catch {
            AppLog.error("❌ Return to Service error: \(error.localizedDescription)")
            await MainActor.run { processingMessage = nil }
            await showError(error.localizedDescription)
        }
    }

    // MARK: - Shared erase phase

    /// Result of the shared erase phase: whether the device acknowledged the
    /// erase, plus the summary lines accumulated so far.
    private struct ErasePhaseResult { let acked: Bool; let summaryLines: [String] }

    /// Issues ERASE_DEVICE (with recovery PIN) and ALWAYS waits for the device
    /// to acknowledge — an erase is never fire-and-forget, and callers must
    /// treat acked == false as "no further destructive steps may run".
    private func performEraseAndAwaitAck(managementId: String, deviceName: String, serial: String, deviceId: String, token: String, config: MDMConfiguration) async throws -> ErasePhaseResult {
        let category = "Device Actions"
        var summaryLines: [String] = []

        // EraseDevice always requires a 6-digit PIN in the API call, but the PIN
        // only MATTERS on Intel/T2 Macs — there it becomes the recovery PIN
        // needed to unlock the Mac after the wipe. Apple Silicon ignores it, so
        // the PIN is only surfaced/logged for non-Apple-Silicon hardware. When
        // the architecture is unknown, `isAppleSilicon` is false, so the PIN is
        // shown (safe default).
        let erasePIN = String(format: "%06d", Int.random(in: 0...999999))
        let showPIN = !computer.isAppleSilicon

        // 1) Queue the erase command (with PIN) and capture its UUID.
        let commandUUID = try await issueEraseCommand(managementId: managementId, pin: erasePIN, token: token, jamfURL: config.jamfURL)
        if showPIN {
            summaryLines.append("• Erase command queued. Recovery PIN: \(erasePIN) (needed to unlock this Intel/T2 Mac).")
        } else {
            summaryLines.append("• Erase command queued.")
        }
        ActionLogService.shared.logAction(
            actionName: showPIN ? "Erase Command Queued (recovery PIN \(erasePIN))" : "Erase Command Queued",
            actionCategory: category,
            deviceName: deviceName, deviceSerialNumber: serial, deviceId: deviceId,
            success: true, errorMessage: nil
        )

        // 2) WAIT until the device ACKNOWLEDGES the erase. Destructive
        // follow-up (e.g. deleting the Jamf record, which unmanages the Mac by
        // removing MDM) must not happen until the wipe is acknowledged/underway
        // or the command never processes.
        await MainActor.run { processingMessage = "Waiting for \(deviceName) to acknowledge the erase…" }
        let acked = await waitForAcknowledgment(uuid: commandUUID, deviceName: deviceName, token: token, jamfURL: config.jamfURL)

        return ErasePhaseResult(acked: acked, summaryLines: summaryLines)
    }

    /// POST an ERASE_DEVICE MDM command (with the required 6-digit PIN) and
    /// return its command UUID.
    private func issueEraseCommand(managementId: String, pin: String, token: String, jamfURL: String) async throws -> String {
        let parameters: [String: Any] = [
            "clientData": [["managementId": managementId]],
            "commandData": [
                "commandType": "ERASE_DEVICE",
                "pin": pin
            ]
        ]
        let postData = try JSONSerialization.data(withJSONObject: parameters, options: [])

        guard let url = URL(string: "\(jamfURL)/api/v2/mdm/commands") else {
            throw NSError(domain: "DeviceView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = postData

        AppLog.notice("📤 Sending Erase command to \(computer.displayName) (managementId: \(managementId))")

        let (data, response) = try await JamfTransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "DeviceView", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            AppLog.error("❌ Erase command rejected: \(errorMessage)")
            throw NSError(
                domain: "DeviceView",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: JamfErrorFormatter.message(
                    status: httpResponse.statusCode,
                    body: data,
                    fallbackAction: "send the erase command"
                )]
            )
        }

        let uuid = Self.extractCommandUUID(from: data) ?? ""
        AppLog.notice("✅ Erase queued (command uuid: \(uuid.isEmpty ? "unknown" : uuid))")
        return uuid
    }

    /// Poll the erase command until the device ACKNOWLEDGES it (or it reports
    /// COMPLETED), so destructive follow-up steps only run once the wipe is
    /// actually underway. Returns false on NOT_NOW / ERROR / FAILED or on
    /// timeout — in which case the caller must NOT run any cleanup step
    /// (deleting the record would unmanage the Mac before the command is
    /// delivered). Timeout and poll interval come from the core domain
    /// (jamfPro.eraseAckTimeoutSeconds / jamfPro.eraseAckPollIntervalSeconds;
    /// the defaults mirror wait_for_ack in the script: 180s, 15s).
    private func waitForAcknowledgment(uuid: String, deviceName: String, token: String, jamfURL: String) async -> Bool {
        guard !uuid.isEmpty else {
            AppLog.notice("⚠️ No command UUID to poll — cannot confirm acknowledgment")
            return false
        }

        let config = MDMConfigurationManager.shared.configuration
        let timeoutSeconds = config.eraseAckTimeoutSeconds
        let pollIntervalSeconds = config.eraseAckPollIntervalSeconds
        var waited = 0
        // The configurable wait (up to 30 min) can outlive the bearer token,
        // so the poll refreshes it on a 401 instead of silently retrying
        // with a dead token until timeout.
        var token = token

        while true {
            await MainActor.run {
                processingMessage = "Waiting for \(deviceName) to acknowledge the erase…  (\(waited)s)"
            }

            var components = URLComponents(string: "\(jamfURL)/api/v2/mdm/commands")
            components?.queryItems = [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "page-size", value: "1"),
                URLQueryItem(name: "filter", value: "uuid==\"\(uuid)\"")
            ]

            if let url = components?.url {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = NetworkTuning.connectionTimeout
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                do {
                    let (data, response) = try await JamfTransport.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        let state = Self.extractCommandState(from: data)
                        let normalized = state.uppercased()
                            .replacingOccurrences(of: "_", with: "")
                            .replacingOccurrences(of: " ", with: "")
                        AppLog.notice("🔎 Erase \(uuid) state=\(state.isEmpty ? "<none>" : state) (waited \(waited)s)")
                        switch normalized {
                        case "ACKNOWLEDGED", "COMPLETED":
                            return true
                        case "ERROR", "FAILED", "NOTNOW":
                            AppLog.error("❌ Erase \(uuid) returned \(state) — not deleting the record")
                            return false
                        default:
                            break // PENDING / empty — keep waiting
                        }
                    } else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                        AppLog.notice("⚠️ Ack poll failed (HTTP \(code))")
                        if code == 401 {
                            // The provider caches tokens; drop them so the
                            // refresh below actually re-mints.
                            JamfTokenProvider.invalidateAll()
                        }
                        if code == 401, let fresh = try? await getBearerToken(scope: .returnToService) {
                            token = fresh
                            AppLog.notice("🔑 Bearer token refreshed for ack polling")
                        }
                    }
                } catch {
                    AppLog.notice("⚠️ Ack poll error for \(uuid): \(error.localizedDescription)")
                }
            }

            // Exit only after a poll AT the timeout boundary: sleep exactly
            // the remaining window (never past it), then poll once more —
            // an ack landing during the final sleep is not missed, and a
            // poll interval larger than the timeout cannot overshoot it.
            if waited >= timeoutSeconds { break }
            let sleepSeconds = min(pollIntervalSeconds, timeoutSeconds - waited)
            try? await Task.sleep(nanoseconds: UInt64(sleepSeconds) * 1_000_000_000)
            waited += sleepSeconds
        }

        AppLog.notice("⏱️ Timed out after \(timeoutSeconds)s waiting for ack of \(uuid)")
        return false
    }

    /// DELETE the Jamf computer-inventory record. Treats 200/204 as success.
    private func deleteJamfRecord(computerId: String, token: String, jamfURL: String) async throws {
        guard let url = URL(string: "\(jamfURL)/api/v1/computers-inventory/\(computerId)") else {
            throw NSError(domain: "DeviceView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await JamfTransport.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "DeviceView", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            AppLog.error("❌ Jamf record delete failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
            throw NSError(
                domain: "DeviceView",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: JamfErrorFormatter.message(
                    status: httpResponse.statusCode,
                    body: data,
                    fallbackAction: "delete the Jamf record"
                )]
            )
        }
        AppLog.notice("🗑️ Deleted Jamf record id \(computerId)")
    }

    /// Pull a command UUID from the POST /api/v2/mdm/commands response. Shape
    /// varies by Jamf version (array of objects, or a single object).
    private static func extractCommandUUID(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        func uuid(_ dict: [String: Any]) -> String? {
            (dict["id"] as? String) ?? (dict["commandUuid"] as? String)
        }
        if let array = json as? [[String: Any]], let first = array.first {
            return uuid(first)
        }
        if let dict = json as? [String: Any] {
            if let results = dict["results"] as? [[String: Any]], let first = results.first {
                return uuid(first)
            }
            return uuid(dict)
        }
        return nil
    }

    /// Pull the command state from GET /api/v2/mdm/commands. Prefers
    /// `commandState`, falls back to `status`. Handles array / results / object.
    private static func extractCommandState(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return "" }
        func state(_ dict: [String: Any]) -> String {
            (dict["commandState"] as? String) ?? (dict["status"] as? String) ?? ""
        }
        if let array = json as? [[String: Any]], let first = array.first {
            return state(first)
        }
        if let dict = json as? [String: Any] {
            if let results = dict["results"] as? [[String: Any]], let first = results.first {
                return state(first)
            }
            return state(dict)
        }
        return ""
    }
    
    // MARK: - Unlock User Account Command
    
    func sendUnlockAccountCommand(username: String) async {
        // Defense in depth (same invariant as executeAction): the sheet is
        // only reachable via the policy-filtered menu, but enforcement must
        // never live only in the UI — re-check both layers and audit-log
        // which one denied.
        if let denial = actionPolicy.denialReason(for: .unlockUserAccount) {
            await reportActionDenial(denial, for: .unlockUserAccount)
            return
        }

        guard let managementId = computer.general?.managementId else {
            await showError("Device management ID not available")
            return
        }
        
        guard !username.isEmpty else {
            await showError("Username is required")
            return
        }
        
        await MainActor.run { isExecutingCommand = true }
        
        do {
            let token = try await getBearerToken()
            let config = MDMConfigurationManager.shared.configuration
            
            let parameters: [String: Any] = [
                "clientData": [["managementId": managementId]],
                "commandData": [
                    "commandType": "UNLOCK_USER_ACCOUNT",
                    "userName": username
                ]
            ]
            
            try await executeCommand(parameters: parameters, token: token, jamfURL: config.jamfURL)
            
            await MainActor.run {
                isExecutingCommand = false
                commandResult = CommandResult(
                    success: true,
                    title: "Command Sent",
                    message: "Unlock account command for user '\(username)' has been sent to \(computer.displayName)."
                )
                showingCommandAlert = true
            }
        } catch {
            await showError(error.localizedDescription)
        }
    }
    
    // MARK: - Helper Functions
    
    private func sendSimpleCommand(commandType: String, successMessage: String) async {
        guard let managementId = computer.general?.managementId else {
            await showError("Device management ID not available")
            return
        }
        
        await MainActor.run { isExecutingCommand = true }
        
        do {
            let token = try await getBearerToken()
            let config = MDMConfigurationManager.shared.configuration
            
            let parameters: [String: Any] = [
                "clientData": [["managementId": managementId]],
                "commandData": ["commandType": commandType]
            ]
            
            try await executeCommand(parameters: parameters, token: token, jamfURL: config.jamfURL)
            
            await MainActor.run {
                isExecutingCommand = false
                commandResult = CommandResult(
                    success: true,
                    title: "Command Sent",
                    message: successMessage
                )
                showingCommandAlert = true
            }
        } catch {
            await showError(error.localizedDescription)
        }
    }
    
    private func executeCommand(parameters: [String: Any], token: String, jamfURL: String) async throws {
        let postData = try JSONSerialization.data(withJSONObject: parameters, options: [])
        
        guard let url = URL(string: "\(jamfURL)/api/v2/mdm/commands") else {
            throw NSError(domain: "DeviceView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = postData
        
        let (data, response) = try await JamfTransport.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "DeviceView", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if !(200...299).contains(httpResponse.statusCode) {
            AppLog.error("❌ MDM command failed: \(String(data: data, encoding: .utf8) ?? "Unknown error")")
            throw NSError(
                domain: "DeviceView",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: JamfErrorFormatter.message(
                    status: httpResponse.statusCode,
                    body: data,
                    fallbackAction: "send this command"
                )]
            )
        }
    }
    
    private func showError(_ message: String) async {
        await MainActor.run {
            isExecutingCommand = false
            commandResult = CommandResult(
                success: false,
                title: "Command Failed",
                message: message
            )
            showingCommandAlert = true
        }
    }
    
    // MARK: - Local Admin Password (LAPS)
    
    /// The Local Admin Password action: reads the password and opens the
    /// FleetHub companion panel, which counts down to its rotation and
    /// offers Copy Password.
    private func fetchLocalAdminPassword() async {
        await MainActor.run { isExecutingCommand = true }
        do {
            let credential = try await fetchLocalAdminCredential()
            let fetchedAt = Date()
            // The panel now holds the password, so the view is recorded here.
            // A failure is recorded by the dispatcher, from the error shown.
            logSSH(DeviceAction.viewLocalAdminPassword.logName,
                   category: DeviceAction.viewLocalAdminPassword.logCategory, success: true)
            let rotation = await passwordRotation(username: credential.username, password: credential.password,
                                                  fetchedAt: fetchedAt)
            let (address, viaVPN) = remoteAccessAddress()
            await MainActor.run {
                isExecutingCommand = false
                SSHWindowManager.shared.openPasswordPanel(
                    info: SSHSessionInfo(
                        deviceName: computer.displayName,
                        serialNumber: computer.serialNumber ?? "Unknown",
                        deviceID: computer.id,
                        username: credential.username,
                        host: address,
                        viaVPN: viaVPN,
                        startedAt: fetchedAt,
                        rotatesAt: rotation.rotatesAt,
                        rotationIsEstimate: rotation.isEstimate,
                        kind: .localAdminPassword,
                        rotationNote: rotation.note
                    ),
                    password: credential.password,
                    fetchPassword: passwordFetcher(account: .localAdmin,
                                                   logName: "Copied local admin password (password panel)")
                )
            }
        } catch {
            AppLog.error("❌ LAPS fetch error: \(error.localizedDescription)")
            await showError(error.localizedDescription)
        }
    }

    /// The current password of the local admin account the profile names.
    private func fetchLocalAdminCredential() async throws -> (username: String, password: String) {
        guard let managementId = computer.general?.managementId, !managementId.isEmpty else {
            throw NSError(domain: "DeviceView", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Device management ID not available"])
        }
        let config = MDMConfigurationManager.shared.configuration
        let username = config.localAdminUsername
        let token = try await getBearerToken(scope: .sensitiveReads)
        let encodedName = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        guard let url = URL(string: "\(config.jamfURL)/api/v2/local-admin-password/\(managementId)/account/\(encodedName)/password") else {
            throw NSError(domain: "DeviceView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await JamfTransport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "DeviceView", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        AppLog.notice("📥 LAPS response status: \(http.statusCode)")
        guard (200...299).contains(http.statusCode) else {
            // The body of a failed call is never surfaced or logged.
            var message = "Failed to retrieve password."
            if http.statusCode == 404 {
                message = "Local admin password not found for user '\(username)' on this device. LAPS may not be configured."
            } else if http.statusCode == 403 {
                message = "Access denied. Insufficient privileges to view local admin passwords."
            }
            throw NSError(domain: "DeviceView", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        struct LAPSResponse: Decodable { let password: String }
        let password = try JSONDecoder().decode(LAPSResponse.self, from: data).password
        return (username, password)
    }

    // MARK: - FileVault Key
    
    /// The FileVault Key action: reads the personal recovery key and opens
    /// the FleetHub companion panel, which holds it (hidden until asked
    /// for), offers Copy Recovery Key, and shows how to enter it on the Mac.
    private func fetchFileVaultKey() async {
        await MainActor.run { isExecutingCommand = true }
        do {
            let key = try await readFileVaultKey()
            // The panel now holds the key, so the view is recorded here.
            // A failure is recorded by the dispatcher, from the error shown.
            logSSH(DeviceAction.viewFileVaultKey.logName,
                   category: DeviceAction.viewFileVaultKey.logCategory, success: true)
            var details = [SSHSessionInfo.Detail(label: "Key Status", value: key.status.capitalized,
                                                 isGood: key.status == "VALID")]
            if !key.encryptionState.isEmpty {
                details.append(.init(label: "Encryption", value: Self.encryptionStateText(key.encryptionState),
                                     isGood: nil))
            }
            let (address, viaVPN) = remoteAccessAddress()
            await MainActor.run {
                isExecutingCommand = false
                SSHWindowManager.shared.openPasswordPanel(
                    info: SSHSessionInfo(
                        deviceName: computer.displayName,
                        serialNumber: computer.serialNumber ?? "Unknown",
                        deviceID: computer.id,
                        username: "",
                        host: address,
                        viaVPN: viaVPN,
                        startedAt: Date(),
                        rotatesAt: nil,
                        rotationIsEstimate: false,
                        kind: .fileVaultKey,
                        details: details
                    ),
                    password: key.recoveryKey,
                    fetchPassword: fileVaultKeyFetcher()
                )
            }
        } catch {
            AppLog.error("❌ FileVault fetch error: \(error.localizedDescription)")
            await showError(error.localizedDescription)
        }
    }

    /// The key panel's Copy and Show actions: each reads the current key from
    /// Jamf again and is logged. nil when the role may not view the key.
    private func fileVaultKeyFetcher() -> (() async throws -> FetchedPassword)? {
        guard actionPolicy.isAllowed(.viewFileVaultKey) else { return nil }
        return { [weak self] in
            guard let self else { throw CancellationError() }
            guard self.actionPolicy.isAllowed(.viewFileVaultKey) else {
                throw NSError(domain: "DeviceView", code: 403,
                              userInfo: [NSLocalizedDescriptionKey: "your role no longer allows viewing the FileVault key"])
            }
            let name = "Copied FileVault recovery key (key panel)"
            do {
                let key = try await self.readFileVaultKey()
                self.logSSH(name, category: "Security", success: true)
                return FetchedPassword(username: "", password: key.recoveryKey, rotatesAt: nil,
                                       rotationIsEstimate: false, rotationNote: nil)
            } catch {
                self.logSSH(name, category: "Security", success: false, error: error.localizedDescription)
                throw error
            }
        }
    }

    private static func encryptionStateText(_ state: String) -> String {
        switch state {
        case "ENCRYPTED": return "Encrypted"
        case "ENCRYPTING": return "Encrypting"
        case "DECRYPTING": return "Decrypting"
        case "NOT_ENCRYPTED": return "Not Encrypted"
        default: return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The device's personal recovery key, with what Jamf says about it.
    private func readFileVaultKey() async throws
        -> (recoveryKey: String, status: String, encryptionState: String) {
        func failure(_ message: String, code: Int) -> NSError {
            NSError(domain: "DeviceView", code: code, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let token = try await getBearerToken(scope: .sensitiveReads)
        let jamfURL = MDMConfigurationManager.shared.configuration.jamfURL
        guard let url = URL(string: "\(jamfURL)/api/v3/computers-inventory/\(computer.id)/filevault") else {
            throw failure("Invalid URL", code: 400)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = NetworkTuning.connectionTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await JamfTransport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw failure("Invalid response", code: 500) }
        AppLog.notice("📥 FileVault response status: \(http.statusCode)")
        guard (200...299).contains(http.statusCode) else {
            // The body of a failed call is never surfaced or logged.
            switch http.statusCode {
            case 404: throw failure("FileVault information not found for this device. The device may not be encrypted or escrowed.", code: 404)
            case 403: throw failure("Access denied. Insufficient privileges to view FileVault recovery keys.", code: 403)
            default: throw failure("Failed to retrieve FileVault key.", code: http.statusCode)
            }
        }

        struct FileVaultResponse: Decodable {
            let personalRecoveryKey: String?
            let bootPartitionEncryptionDetails: BootPartitionDetails?
            let individualRecoveryKeyValidityStatus: String?
            struct BootPartitionDetails: Decodable { let partitionFileVault2State: String? }
        }
        let decoded = try JSONDecoder().decode(FileVaultResponse.self, from: data)
        let state = decoded.bootPartitionEncryptionDetails?.partitionFileVault2State ?? ""
        guard let recoveryKey = decoded.personalRecoveryKey, !recoveryKey.isEmpty else {
            switch state {
            case "NOT_ENCRYPTED": throw failure("This device is not encrypted with FileVault.", code: 404)
            case "ENCRYPTING": throw failure("FileVault encryption is in progress. Recovery key may not be available yet.", code: 404)
            case "DECRYPTING": throw failure("FileVault is being decrypted. Recovery key is no longer valid.", code: 404)
            default: throw failure("No personal recovery key found for this device.", code: 404)
            }
        }
        return (recoveryKey, decoded.individualRecoveryKeyValidityStatus ?? "UNKNOWN", state)
    }

    // MARK: - Send Blank Push
    
    private func sendBlankPushCommand() async {
        guard let managementId = computer.general?.managementId else {
            await showError("Device management ID not available")
            return
        }
        
        await MainActor.run { isExecutingCommand = true }
        
        do {
            let token = try await getBearerToken()
            let config = MDMConfigurationManager.shared.configuration
            let jamfURL = config.jamfURL
            
            // Build the blank push payload
            let parameters: [String: Any] = [
                "clientManagementIds": [managementId]
            ]
            
            let postData = try JSONSerialization.data(withJSONObject: parameters, options: [])
            
            guard let url = URL(string: "\(jamfURL)/api/v2/mdm/blank-push") else {
                throw NSError(domain: "DeviceView", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = NetworkTuning.connectionTimeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = postData
            
            AppLog.notice("📤 Sending Blank Push to device: \(computer.displayName) (managementId: \(managementId))")
            
            let (data, response) = try await JamfTransport.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "DeviceView", code: 500, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }
            
            AppLog.notice("📥 Blank Push response status: \(httpResponse.statusCode)")
            
            if (200...299).contains(httpResponse.statusCode) {
                await MainActor.run {
                    isExecutingCommand = false
                    commandResult = CommandResult(
                        success: true,
                        title: "Blank Push Sent",
                        message: "An APNs notification has been sent to \(computer.displayName). The device should check in shortly if it's online and reachable."
                    )
                    showingCommandAlert = true
                }
            } else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                AppLog.error("❌ Blank Push failed: \(errorMessage)")
                
                var userMessage = "Failed to send blank push."
                if httpResponse.statusCode == 404 {
                    userMessage = "Device not found or not enrolled in MDM."
                } else if httpResponse.statusCode == 403 {
                    userMessage = "Access denied. Insufficient privileges to send push notifications."
                }
                
                throw NSError(domain: "DeviceView", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: userMessage])
            }
            
        } catch {
            AppLog.error("❌ Blank Push error: \(error.localizedDescription)")
            await showError(error.localizedDescription)
        }
    }
}

// MARK: - Current Policy

extension DeviceActionPolicy {
    /// The computer Actions policy for the signed-in user, built from the
    /// CURRENT configuration and role capabilities (strict fail-closed).
    @MainActor
    static var currentForComputers: DeviceActionPolicy {
        MDMConfigurationManager.shared.configuration
            .computerActionPolicy(capabilities: UserSession.shared.capabilities)
    }
}
