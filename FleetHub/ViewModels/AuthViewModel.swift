//
//  AuthViewModel.swift
//  FleetHub
//
//  Authentication view model for managing user sessions
//

import SwiftUI
import AppKit
import Combine
import LocalAuthentication
import os.log

private let authLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.herojoneslabs.fleethub", category: "Auth")

class AuthViewModel: ObservableObject {
    @Published var isLoggedIn = false {
        didSet {
            if isLoggedIn { startIdleLockIfNeeded() } else { stopIdleLock() }
        }
    }
    @Published var currentUser: User?
    @Published var hasSeenWelcome: Bool {
        didSet {
            UserDefaults.standard.set(hasSeenWelcome, forKey: "hasSeenWelcome")
        }
    }
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var showBiometricPrompt = false
    /// True while a persisted Entra refresh token is being redeemed at
    /// launch — WelcomeLoginView shows a progress state instead of flashing
    /// the login form before the outcome is known.
    @Published var isRestoringEntraSession = false

    private let keychain = KeychainManager.shared
    let biometricManager = BiometricAuthManager()

    /// Entra refresh token parked while the biometric gate is up on a cold
    /// restore. Redeemed only after a successful unlock — an unlock alone is
    /// never a session in Entra mode (fail-closed).
    private var pendingEntraRefreshToken: String?

    // Idle lock (ui.authentication sessionTimeout)
    private var activityMonitor: Any?
    private var idleCheckTimer: Timer?
    private var lastActivityAt = Date()

    // MARK: - Managed configuration (ui.authentication; absent block = defaults)

    private var mdmConfiguration: MDMConfiguration {
        MDMConfigurationManager.shared.configuration
    }

    var signInMethod: MDMConfiguration.SignInMethod { mdmConfiguration.signInMethod }
    var isEntraSignInConfigured: Bool { mdmConfiguration.isEntraSignInConfigured }

    private var authenticationSettings: AuthenticationSettings? { mdmConfiguration.authentication }
    private var requireBiometric: Bool { authenticationSettings?.effectiveRequireBiometric ?? false }
    var isBiometricSetupAllowed: Bool { authenticationSettings?.effectiveAllowBiometricSetup ?? true }
    private var sessionTimeoutMinutes: Int { authenticationSettings?.effectiveSessionTimeoutMinutes ?? 0 }
    private var allowRememberMe: Bool { authenticationSettings?.effectiveAllowRememberMe ?? true }

    /// Whether restore / idle lock must pass through the biometric prompt.
    /// requireBiometric (managed) overrides the user's local opt-out, but
    /// missing hardware never locks an operator out — log and proceed.
    private var biometricGateActive: Bool {
        guard biometricManager.biometricType != .none else {
            if requireBiometric {
                AppLog.notice("⚠️ requireBiometric is set but no biometric hardware is available — proceeding without the gate")
            }
            return false
        }
        return biometricManager.isBiometricEnabled || requireBiometric
    }

    init() {
        self.hasSeenWelcome = UserDefaults.standard.bool(forKey: "hasSeenWelcome")
        restoreSession()
    }

    deinit {
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
        }
        idleCheckTimer?.invalidate()
    }

    // MARK: - Session restore

    private func restoreSession() {
        guard allowRememberMe else {
            // Managed policy: sessions never persist. Wipe anything left
            // over (incl. the Entra refresh token) — fresh sign-in required.
            clearSession()
            return
        }
        switch signInMethod {
        case .entra:
            restoreEntraSession()
        case .email:
            restoreEmailSession()
        }
    }

    private func restoreEmailSession() {
        guard let authToken = keychain.loadAuthToken(),
              !authToken.isEmpty else {
            return
        }

        let email = keychain.loadUserEmail() ?? ""
        let name = keychain.loadUserName() ?? ""
        let refreshToken = keychain.loadRefreshToken()

        guard !email.isEmpty else {
            clearSession()
            return
        }

        self.currentUser = User(
            email: email,
            name: name,
            authToken: authToken,
            refreshToken: refreshToken
        )

        if biometricGateActive {
            // Capabilities are established only after the unlock succeeds
            // (see authenticateWithBiometrics) — a pending prompt is not a
            // session.
            showBiometricPrompt = true
        } else {
            establishMDMSession(email: email, displayName: name)
            self.isLoggedIn = true
            syncJamfRolesAfterRestore(email: email)
        }
    }

    private func restoreEntraSession() {
        // The legacy authToken slot is NOT the session key in Entra mode;
        // only a redeemable refresh token constitutes a session.
        guard let refreshToken = keychain.loadEntraRefreshToken(),
              !refreshToken.isEmpty else {
            return
        }

        let email = keychain.loadUserEmail() ?? ""
        let name = keychain.loadUserName() ?? ""
        currentUser = User(email: email, name: name, authToken: "", refreshToken: nil)

        if biometricGateActive {
            pendingEntraRefreshToken = refreshToken
            showBiometricPrompt = true
        } else {
            redeemEntraRefreshToken(refreshToken)
        }
    }

    private func redeemEntraRefreshToken(_ refreshToken: String) {
        isRestoringEntraSession = true
        Task { @MainActor in
            defer { self.isRestoringEntraSession = false }

            guard let service = EntraAuthService(configuration: self.mdmConfiguration) else {
                AppLog.notice("⚠️ Entra session restore aborted: sign-in is no longer configured")
                self.failEntraRestore()
                return
            }
            do {
                // Fail-closed revalidation: the roles come from the FRESH
                // token — a role revoked since last sign-in ends the session.
                let identity = try await service.refreshSession(refreshToken: refreshToken)
                // A restored session normally finds the operator's Jamf
                // credential already in the Keychain, carrying the right Jamf
                // roles. Re-sync when it is missing, or when the roles in the
                // FRESH token (or the profile's mapping) now resolve to a
                // different set of Jamf API Roles — a promotion or a
                // revocation then reaches Jamf at this launch. A failure is
                // not fatal here: the session restores and Jamf calls fail
                // closed or run with the previous Jamf roles until the next
                // successful sync.
                if self.needsJamfCredentialSync(email: identity.email, fleetHubRoles: identity.roles) {
                    do {
                        _ = try await self.ensureUserJamfCredentials(email: identity.email, fleetHubRoles: identity.roles)
                    } catch {
                        AppLog.notice("⚠️ Could not sync the per-user Jamf credential on restore: \(error.localizedDescription)")
                    }
                }
                self.establishEntraSession(with: identity)
                AppLog.notice("✅ Entra session restored (roles: \(identity.roles.joined(separator: ", ")))")
            } catch {
                // Any refresh failure → signed out. No cached-capability fallback.
                AppLog.notice("⚠️ Entra session refresh failed (fail-closed): \(error.localizedDescription)")
                self.failEntraRestore()
            }
        }
    }

    @MainActor
    private func failEntraRestore() {
        currentUser = nil
        showBiometricPrompt = false
        clearSession()
        isLoggedIn = false
    }

    // MARK: - Biometrics

    func authenticateWithBiometrics(completion: ((Bool) -> Void)? = nil) {
        biometricManager.authenticate(reason: "Unlock \(Branding.productName)") { [weak self] success, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if success {
                    self.showBiometricPrompt = false
                    // Branch on the CONFIGURED method, never on whether a
                    // token happens to be parked: establishMDMSession
                    // resolves from the access `role` key, which is ignored
                    // outright under signIn.method=entra, so inferring the
                    // mode from a nil pendingEntraRefreshToken would resolve
                    // Entra capabilities from a key that has no authority.
                    if self.signInMethod == .entra {
                        guard let pendingToken = self.pendingEntraRefreshToken else {
                            // Entra mode with nothing parked: no token to
                            // revalidate, and no other admissible source of
                            // role names — only a full Microsoft sign-in may
                            // unlock (fail-closed).
                            AppLog.notice("⚠️ Biometric unlock in Entra mode with no parked refresh token — requiring full sign-in (fail-closed)")
                            self.currentUser = nil
                            self.clearSession()
                            self.isLoggedIn = false
                            self.errorMessage = "Please sign in with Microsoft to continue."
                            completion?(false)
                            return
                        }
                        // Cold restore in Entra mode: unlocking is not a
                        // session — the refresh token still has to be
                        // redeemed for freshly resolved capabilities
                        // (fail-closed).
                        self.pendingEntraRefreshToken = nil
                        self.redeemEntraRefreshToken(pendingToken)
                    } else {
                        // Email mode: re-resolve capabilities from the
                        // CURRENT profile on every unlock, so a role edit
                        // applies at idle-unlock as well as at launch.
                        let user = self.currentUser
                        self.establishMDMSession(
                            email: user?.email ?? "",
                            displayName: user?.name ?? ""
                        )
                        self.isLoggedIn = true
                        self.syncJamfRolesAfterRestore(email: user?.email ?? "")
                    }
                    completion?(true)
                } else {
                    if let error = error {
                        self.errorMessage = self.biometricManager.getErrorDescription(error)
                    }

                    if let laError = error as? LAError, laError.code == .userCancel {
                        self.clearSession()
                        self.currentUser = nil
                        self.showBiometricPrompt = false
                    }

                    completion?(false)
                }
            }
        }
    }

    // MARK: - Email sign-in

    func loginWithEmail(_ email: String, completion: ((Bool) -> Void)? = nil) {
        // Email sign-in is off whenever Entra sign-in is configured. The
        // login screen never offers it then; this refuses it for any other
        // caller as well.
        guard signInMethod == .email else {
            AppLog.notice("⚠️ Email sign-in refused: this Mac is configured for Microsoft Entra ID sign-in")
            errorMessage = "Email sign-in is turned off on this Mac. Sign in with Microsoft."
            completion?(false)
            return
        }
        // A typed address proves nothing. With automatic creation on, this
        // Mac's provisioning client would create or re-key an API client for
        // whatever address was typed, so anyone at this Mac could act as a
        // colleague. Email sign-in is therefore only for operators who hold
        // their own client's secret (automatic creation off), or for the
        // Platform backend, which has no per-user clients.
        if mdmConfiguration.effectiveAPIBackend.needsPerUserClients,
           mdmConfiguration.effectiveAutoCreateUserApiClient {
            AppLog.notice("⚠️ Email sign-in refused: automatic API client creation is on")
            errorMessage = "Email sign-in is not available while FleetHub creates API clients automatically. Ask your administrator to turn automatic creation off or to set up Microsoft sign-in."
            completion?(false)
            return
        }
        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                // The operator's own Jamf API client: reused when this Mac
                // already holds a working one, created with the master client
                // only when it does not.
                authLogger.info("Authenticating with Jamf Pro for \(email, privacy: .private)")

                // Platform backend: there are no per-user API clients. Prove
                // the integration credential works instead, and record the
                // session against it.
                let sessionClientID: String
                if self.mdmConfiguration.effectiveAPIBackend == .platform {
                    _ = try await JamfTokenProvider.token(for: .inventory)
                    sessionClientID = "platform"
                    AppLog.notice("✅ Platform API credential verified")
                } else {
                    let jamfCredentials = try await self.ensureUserJamfCredentials(
                        email: email,
                        fleetHubRoles: [self.mdmConfiguration.mdmRoleName]
                    )
                    sessionClientID = jamfCredentials.clientID
                    AppLog.notice("✅ Jamf credentials ready")
                    AppLog.notice("   Client ID: \(String(jamfCredentials.clientID.prefix(12)))...")
                }

                // ensureUserJamfCredentials only returns once the credential
                // is in the Keychain.
                let credentialsSaved = true

                // Extract name from email or use default
                let name = email.components(separatedBy: "@").first?.capitalized ?? "User"

                // Create user object
                let user = User(
                    email: email,
                    name: name,
                    authToken: sessionClientID,
                    refreshToken: nil
                )

                // Save user info to keychain
                let userSaved = saveUserToKeychain(user)

                if userSaved && credentialsSaved {
                    self.currentUser = user
                    self.hasSeenWelcome = true
                    // Capabilities BEFORE isLoggedIn — the UI reads them the
                    // moment it renders.
                    self.establishMDMSession(email: email, displayName: name)
                    self.isLoggedIn = true
                    self.isLoading = false
                    AppLog.notice("✅ Login successful")
                    completion?(true)
                } else {
                    self.errorMessage = "Failed to save credentials securely"
                    self.isLoading = false
                    completion?(false)
                }

            } catch let error as JamfAPIError {
                AppLog.error("❌ Jamf API error: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription
                self.isLoading = false
                completion?(false)

            } catch {
                AppLog.error("❌ Login error: \(error.localizedDescription)")
                self.errorMessage = "Authentication failed: \(error.localizedDescription)"
                self.isLoading = false
                completion?(false)
            }
        }
    }

    // MARK: - Entra sign-in

    func loginWithEntra(completion: ((Bool) -> Void)? = nil) {
        guard isEntraSignInConfigured,
              let service = EntraAuthService(configuration: mdmConfiguration) else {
            errorMessage = EntraAuthService.AuthError.notConfigured.errorDescription
            completion?(false)
            return
        }

        isLoading = true
        errorMessage = nil

        Task { @MainActor in
            do {
                let identity = try await service.signInInteractively()
                // Every app function runs as the operator's own Jamf API
                // client, so it must exist BEFORE the session opens: a
                // dashboard with no credential behind it can only show
                // errors. A failure here is a failed sign-in.
                do {
                    if self.mdmConfiguration.effectiveAPIBackend == .platform {
                        // No per-user client on the Platform API: confirm the
                        // integration credential works before opening the app.
                        _ = try await JamfTokenProvider.token(for: .inventory)
                    } else {
                        _ = try await self.ensureUserJamfCredentials(email: identity.email, fleetHubRoles: identity.roles)
                    }
                } catch {
                    self.errorMessage = "Microsoft sign-in succeeded, but your Jamf credential could not be set up: \(error.localizedDescription)"
                    self.isLoading = false
                    completion?(false)
                    return
                }
                self.establishEntraSession(with: identity)
                AppLog.notice("✅ Entra sign-in successful (roles: \(identity.roles.joined(separator: ", ")))")
                completion?(true)
            } catch EntraAuthService.AuthError.cancelled {
                // User closed the Microsoft window — not an error state.
                self.isLoading = false
                completion?(false)
            } catch let error as EntraAuthService.AuthError {
                // .notAuthorized already carries its role-assignment guidance.
                self.errorMessage = error.errorDescription
                self.isLoading = false
                completion?(false)
            } catch {
                self.errorMessage = "Sign-in failed: \(error.localizedDescription)"
                self.isLoading = false
                completion?(false)
            }
        }
    }

    /// UserDefaults key recording which Jamf API Roles the stored per-user
    /// credential was last provisioned with ("email|RoleA,RoleB"). Not a
    /// secret, and not trusted for access — it only decides whether the
    /// master client needs to re-sync the roles in Jamf.
    private static let provisionedJamfRolesKey = "fleethub_provisioned_jamf_roles"

    private func jamfRoleMarker(email: String, jamfRoles: [String]) -> String {
        "\(email.lowercased())|\(jamfRoles.joined(separator: ","))"
    }

    /// True when this Mac holds no per-user credential for `email`, or the
    /// one it holds was provisioned for a different set of Jamf API Roles
    /// than `fleetHubRoles` resolve to now.
    private func needsJamfCredentialSync(email: String, fleetHubRoles: [String]) -> Bool {
        // The Platform API has no per-user clients to provision or sync.
        if mdmConfiguration.effectiveAPIBackend == .platform { return false }
        // With automatic creation off, a Jamf administrator manages each
        // person's client and its roles; FleetHub changes nothing.
        if !mdmConfiguration.effectiveAutoCreateUserApiClient { return false }
        guard let stored = keychain.loadJamfCredentials(),
              stored.email.caseInsensitiveCompare(email) == .orderedSame else { return true }
        let desired = mdmConfiguration.jamfApiRoleNames(forRoleNames: fleetHubRoles)
        return UserDefaults.standard.string(forKey: Self.provisionedJamfRolesKey)
            != jamfRoleMarker(email: email, jamfRoles: desired)
    }

    /// The signed-in operator's own Jamf API client, which every app
    /// function authenticates as, carrying the Jamf API Role(s) their
    /// FleetHub roles map to (`MDMConfiguration.jamfApiRoleNames`).
    ///
    /// The master client is used ONLY to provision: when this Mac holds no
    /// working credential for `email`, or when the Jamf roles the operator
    /// should carry have changed since it was provisioned. A stored
    /// credential with the right roles that still mints a token is returned
    /// as-is, with no master call at all. A stored credential Jamf rejects
    /// (revoked, rotated or deleted) is replaced; a network failure is not
    /// treated as rejection, so an outage never triggers a re-create.
    ///
    /// Throws when no usable credential could be obtained and saved —
    /// callers treat that as a failed sign-in (fail-closed).
    @MainActor
    private func ensureUserJamfCredentials(email: String, fleetHubRoles: [String]) async throws -> JamfCredentials {
        if !mdmConfiguration.effectiveAutoCreateUserApiClient {
            return try await ownJamfCredentials(email: email)
        }
        let jamfRoles = mdmConfiguration.jamfApiRoleNames(forRoleNames: fleetHubRoles)

        if !needsJamfCredentialSync(email: email, fleetHubRoles: fleetHubRoles),
           let stored = keychain.loadJamfCredentials(), !stored.isExpired {
            JamfUserSession.shared.invalidate()
            do {
                _ = try await JamfUserSession.shared.bearerToken()
                return stored
            } catch JamfUserSessionError.authenticationFailed(let code, _) where (400...403).contains(code) {
                AppLog.notice("ℹ️ Stored per-user Jamf credential was rejected (\(code)) — provisioning a new one")
            }
        }

        AppLog.notice("🔐 Provisioning the per-user Jamf credential with the master client (Jamf roles: \(jamfRoles.joined(separator: ", ")))")
        let credentials = try await JamfAPIService.shared.authenticateWithEmail(email, roleNames: jamfRoles)
        guard keychain.saveJamfCredentials(credentials) else {
            throw JamfAPIError.serverError(
                statusCode: 0,
                message: "Your Jamf credential was created but could not be saved to this Mac's Keychain."
            )
        }
        UserDefaults.standard.set(
            jamfRoleMarker(email: email, jamfRoles: jamfRoles),
            forKey: Self.provisionedJamfRolesKey
        )
        // A token minted before the role change carries the OLD privileges,
        // and one minted for a previous operator must never be reused.
        JamfUserSession.shared.invalidate()
        return credentials
    }

    /// Automatic creation is off: use the API client this person entered
    /// themselves. Nothing is created or changed in Jamf, and no
    /// provisioning secret is involved.
    ///
    /// The client is tied to the first person who signs in with it. If
    /// someone else signs in on this Mac account, or Jamf stops accepting the
    /// client, it is forgotten and the setup screen asks for one again.
    private func ownJamfCredentials(email: String) async throws -> JamfCredentials {
        guard let stored = keychain.loadJamfCredentials() else {
            await OwnJamfAPIClient.forget(because: nil)
            throw JamfAPIError.ownClientRequired("Enter your Jamf API client to continue.")
        }
        if !stored.email.isEmpty, stored.email.caseInsensitiveCompare(email) != .orderedSame {
            let reason = "The Jamf API client saved on this Mac belongs to someone else. Enter your own to continue."
            await OwnJamfAPIClient.forget(because: reason)
            throw JamfAPIError.ownClientRequired(reason)
        }
        JamfUserSession.shared.invalidate()
        do {
            _ = try await JamfUserSession.shared.bearerToken()
        } catch JamfUserSessionError.authenticationFailed(let code, _) where (400...403).contains(code) {
            let reason = "Jamf no longer accepts the API client saved on this Mac (error \(code)). Enter your current client ID and secret."
            await OwnJamfAPIClient.forget(because: reason)
            throw JamfAPIError.ownClientRequired(reason)
        }
        guard stored.email.isEmpty else { return stored }
        let bound = JamfCredentials(clientID: stored.clientID, clientSecret: stored.clientSecret,
                                    email: email, expiresAt: stored.expiresAt)
        _ = keychain.saveJamfCredentials(bound)
        return bound
    }

    /// Email/MDM sessions restored from the Keychain (launch or biometric
    /// unlock) skip the sign-in call, so a profile push that changed the
    /// role's Jamf mapping would otherwise never reach Jamf. Re-sync in the
    /// background when the mapping no longer matches; non-fatal.
    private func syncJamfRolesAfterRestore(email: String) {
        let roles = [mdmConfiguration.mdmRoleName]
        Task { @MainActor in
            guard self.needsJamfCredentialSync(email: email, fleetHubRoles: roles) else { return }
            do {
                _ = try await self.ensureUserJamfCredentials(email: email, fleetHubRoles: roles)
            } catch {
                AppLog.notice("⚠️ Could not sync the per-user Jamf credential after restore: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Capability resolution
    //
    // Capabilities come from the CONFIG, always — never from the app. Both
    // sign-in modes resolve the identity's role NAMES against the access
    // domain's role definitions:
    //   • Entra: the id_token roles claim (re-resolved from the FRESH token
    //     on every restore/unlock, so a revocation applies at launch and at
    //     idle-unlock).
    //   • Email/MDM: the access domain's single `role` key.
    // A name matching no definition contributes nothing, and no match at all
    // means .none — the user is signed in but sees the empty state.

    /// Establishes the MDM-role session for the email flow. Deliberately
    /// NEVER refuses sign-in: an org whose profile is missing or whose
    /// `role` names nothing would otherwise be hard-locked out of the app
    /// with no way to see the error. They sign in to an empty state instead.
    ///
    /// Non-isolated, and synchronous on the main thread when possible, for
    /// the same reason as `clearSession()`: callers set `isLoggedIn = true`
    /// on the next line, and a deferred establish would leave the UI reading
    /// `.none` for a tick — flashing the empty state at a fully entitled
    /// user. (Also callable from `init` → `restoreEmailSession`, which is
    /// not MainActor-isolated.)
    private func establishMDMSession(email: String, displayName: String) {
        let roleName = mdmConfiguration.mdmRoleName
        let capabilities = mdmConfiguration.capabilities(forRoleNames: [roleName])

        // Diagnose the two failures separately — they need different fixes.
        // "No matching definition" is a NAME test, not a capability test: a
        // role that IS defined but lists nothing also resolves to .none, and
        // reporting that as a name mismatch sends the admin hunting a typo
        // that isn't there.
        if roleName.isEmpty {
            AppLog.notice("⚠️ No access-domain 'role' delivered — signing in with NO capabilities (fail-closed)")
        } else if mdmConfiguration.roleDefinitions[roleName] == nil {
            AppLog.notice("⚠️ Access-domain role '\(roleName)' matches no definition in the profile's roles block — signing in with NO capabilities (fail-closed; role names are case-sensitive)")
        } else if capabilities == .none {
            AppLog.notice("⚠️ Access-domain role '\(roleName)' IS defined in the profile's roles block but grants nothing — signing in with NO capabilities (add modules/actions to the definition)")
        }

        let roles = roleName.isEmpty ? [] : [roleName]
        let establish: @MainActor () -> Void = {
            UserSession.shared.establish(
                email: email,
                displayName: displayName,
                roles: roles,
                capabilities: capabilities
            )
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(establish)
        } else {
            Task { @MainActor in establish() }
        }
    }

    /// Shared tail of interactive Entra sign-in and refresh restore. The
    /// legacy authToken slot stays empty in Entra mode — the refresh token
    /// is the only session key.
    @MainActor
    private func establishEntraSession(with identity: EntraIdentity) {
        if !allowRememberMe {
            AppLog.notice("ℹ️ allowRememberMe is disabled by policy — Entra session will not persist")
        } else if let refreshToken = identity.refreshToken, !refreshToken.isEmpty {
            if !keychain.saveEntraRefreshToken(refreshToken) {
                AppLog.notice("⚠️ Failed to save the Entra refresh token — session won't survive relaunch")
            }
        } else {
            AppLog.notice("⚠️ Microsoft returned no refresh token — session won't survive relaunch")
        }
        _ = keychain.saveUserEmail(identity.email)
        _ = keychain.saveUserName(identity.displayName)

        // Resolved from the token's roles against the CURRENT config, so a
        // role revoked in Entra OR withdrawn from the profile takes effect
        // on the next restore/unlock. EntraAuthService's gate tested only
        // that a role NAME exists in the profile — it says nothing about
        // what that name grants — so .none here is not necessarily a
        // mid-session profile change: a defined role whose lists are all
        // empty resolves the same way. Either way the user lands on the
        // empty state, fail-closed.
        let capabilities = mdmConfiguration.capabilities(forRoleNames: identity.roles)
        UserSession.shared.establish(
            email: identity.email,
            displayName: identity.displayName,
            roles: identity.roles,
            capabilities: capabilities
        )
        currentUser = User(email: identity.email, name: identity.displayName, authToken: "", refreshToken: nil)
        hasSeenWelcome = true
        isLoggedIn = true
        isLoading = false

        fetchEntraProfilePhoto(refreshToken: identity.refreshToken, forEmail: identity.email)
    }

    /// Fail-soft directory-photo fetch, OFF the sign-in critical path: the
    /// photo needs a Graph User.Read token the sign-in scopes deliberately
    /// don't request, so it is redeemed separately here — a tenant that
    /// never consented to User.Read just gets the initials avatar
    /// (docs/EntraAuthSetup.md), and no failure in this path can touch the
    /// session itself.
    @MainActor
    private func fetchEntraProfilePhoto(refreshToken: String?, forEmail email: String) {
        guard let refreshToken, !refreshToken.isEmpty,
              let service = EntraAuthService(configuration: mdmConfiguration) else {
            return
        }
        Task { @MainActor in
            let result = await service.fetchProfilePhoto(refreshToken: refreshToken)
            // The session may have ended (logout, idle lock) or changed hands
            // while the fetch was in flight — a late photo must not attach to
            // it, and a late token must not resurrect cleared credentials.
            guard self.isLoggedIn, UserSession.shared.email == email else { return }
            if let data = result.photoData, let image = NSImage(data: data) {
                UserSession.shared.setProfilePhoto(image)
            }
            // Entra may rotate the refresh token during the redemption; keep
            // the freshest one or the next restore redeems a stale token.
            if self.allowRememberMe,
               let rotated = result.rotatedRefreshToken, !rotated.isEmpty,
               !self.keychain.saveEntraRefreshToken(rotated) {
                AppLog.notice("⚠️ Failed to save the rotated Entra refresh token")
            }
        }
    }

    func logout() {
        currentUser = nil
        errorMessage = nil
        clearSession()
        isLoggedIn = false
        showBiometricPrompt = false
    }

    func enableBiometricAuth() {
        biometricManager.setBiometricEnabled(true)
    }

    func disableBiometricAuth() {
        biometricManager.setBiometricEnabled(false)
    }

    private func saveUserToKeychain(_ user: User) -> Bool {
        var allSuccess = true

        allSuccess = keychain.saveAuthToken(user.authToken) && allSuccess
        allSuccess = keychain.saveUserEmail(user.email) && allSuccess
        allSuccess = keychain.saveUserName(user.name) && allSuccess

        if let refreshToken = user.refreshToken {
            allSuccess = keychain.saveRefreshToken(refreshToken) && allSuccess
        }

        return allSuccess
    }

    func clearSession() {
        pendingEntraRefreshToken = nil
        // A client the person entered themselves outlives sign-out: they may
        // not have the secret to hand again. It stays tied to their address.
        let ownClient = mdmConfiguration.effectiveAutoCreateUserApiClient ? nil : keychain.loadJamfCredentials()
        keychain.clearAllAuthData()
        if let ownClient { _ = keychain.saveJamfCredentials(ownClient) }
        // Drop every cached Jamf bearer token so the next operator never
        // inherits the previous one's attribution.
        JamfTokenProvider.invalidateAll()
        // Session-cached fleet data must not carry over to the next person.
        Task { @MainActor in ComplianceBenchmarkService.shared.reset() }
        clearUserSession()
    }

    /// Wipes the app-wide identity/capability holder WITHOUT touching the
    /// keychain — the idle-lock path needs exactly this, since the stored
    /// credentials must survive so biometric/re-login can restore them.
    ///
    /// Clears synchronously when possible: deferring the wipe past the
    /// caller's isLoggedIn=false would leave stale capabilities/roles
    /// readable for a tick, and a fast re-login's establish could be
    /// clobbered by the late clear.
    private func clearUserSession() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { UserSession.shared.clear() }
        } else {
            Task { @MainActor in
                UserSession.shared.clear()
            }
        }
    }

    func markWelcomeAsSeen() {
        hasSeenWelcome = true
    }

    func resetApp() {
        hasSeenWelcome = false
        currentUser = nil
        isLoggedIn = false
        errorMessage = nil
        showBiometricPrompt = false
        clearSession()
        biometricManager.setBiometricEnabled(false)
        UserDefaults.standard.removeObject(forKey: "hasSeenWelcome")
    }

    // MARK: - Idle lock (ui.authentication sessionTimeout)

    private func startIdleLockIfNeeded() {
        stopIdleLock()
        guard sessionTimeoutMinutes > 0 else { return }

        lastActivityAt = Date()
        activityMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            // Coalesce: the idle check runs on 30 s granularity, so
            // sub-second rewrites (scrollWheel fires per tick) are noise.
            if let self, Date().timeIntervalSince(self.lastActivityAt) > 1 {
                self.lastActivityAt = Date()
            }
            return event
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkIdleTimeout()
        }
        timer.tolerance = 5
        idleCheckTimer = timer
    }

    private func stopIdleLock() {
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
    }

    private func checkIdleTimeout() {
        guard isLoggedIn, sessionTimeoutMinutes > 0 else { return }
        let limit = TimeInterval(sessionTimeoutMinutes) * 60
        guard Date().timeIntervalSince(lastActivityAt) >= limit else { return }
        lockForIdleTimeout()
    }

    private func lockForIdleTimeout() {
        AppLog.notice("🔒 Session locked after \(sessionTimeoutMinutes) minutes of inactivity")
        isLoggedIn = false

        if biometricGateActive {
            if signInMethod == .entra {
                // Entra mode: an unlock is never a session — park the
                // refresh token so a successful unlock routes through
                // redeemEntraRefreshToken (fresh id_token → freshly resolved
                // capabilities, fail-closed), exactly like cold restore. A
                // role revoked since sign-in must not survive the unlock.
                guard let refreshToken = keychain.loadEntraRefreshToken(),
                      !refreshToken.isEmpty else {
                    // No redeemable token (e.g. allowRememberMe off) means
                    // revalidation is impossible — only a full Microsoft
                    // sign-in may unlock (fail-closed).
                    currentUser = nil
                    clearSession()
                    errorMessage = "Session locked due to inactivity. Please sign in again."
                    return
                }
                pendingEntraRefreshToken = refreshToken
            }
            // Cancel/failure falls back to full sign-in via clearSession
            // (existing prompt behavior).
            showBiometricPrompt = true
        } else if signInMethod == .entra {
            // No biometric gate in Entra mode: only a full Microsoft
            // sign-in may unlock — fail-closed.
            currentUser = nil
            clearSession()
            errorMessage = "Session locked due to inactivity. Please sign in again."
        } else {
            // Email mode: the keychain stays intact so the login screen (or
            // a later biometric unlock) can re-authenticate — but UserSession
            // must NOT keep serving the locked-out operator's identity and
            // capabilities to services and command handlers for the whole
            // locked window. Both restore paths re-establish it before
            // setting isLoggedIn.
            clearUserSession()
            errorMessage = "Session locked due to inactivity. Please sign in again."
        }
    }
}
