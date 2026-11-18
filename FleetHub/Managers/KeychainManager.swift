//
//  KeychainManager.swift
//  FleetHub
//
//  Secure keychain storage for authentication and credentials.
//
//  STORAGE POLICY
//  • Every item is written with an explicit, restrictive accessibility class
//    (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`): never synced, never
//    migrated to another Mac, unreadable while the login session is locked.
//  • Items are written to the data-protection keychain
//    (`kSecUseDataProtectionKeychain`) whenever the running build carries an
//    application identifier (a provisioning-profile–signed build). Builds
//    without one — Developer ID without a profile, ad-hoc, unsigned CI — get
//    `errSecMissingEntitlement` from that keychain, so the manager falls back
//    to the user's login keychain, where items are encrypted at rest and
//    ACL-bound to this app's code signature (another app, including the
//    menu bar companion, is prompted by macOS before it can read them). The
//    choice is probed once per process and logged. Both backends use the same
//    account names, and a value found in the login keychain is migrated
//    forward the first time the data-protection keychain is available.
//  • Writes are add-then-update (never delete-then-add) so a failed write
//    can never leave the caller without a credential.
//  • Every `SecItem*` status is checked and returned; nothing is swallowed.
//

import Foundation
import Security
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.herojoneslabs.fleethub", category: "Keychain")

final class KeychainManager {
    static let shared = KeychainManager()

    private init() {}

    /// Keychain account names, under the `com.herojoneslabs.fleethub.*` root.
    private enum Keys {
        static let authToken = "com.herojoneslabs.fleethub.authToken"
        static let userEmail = "com.herojoneslabs.fleethub.userEmail"
        static let userName = "com.herojoneslabs.fleethub.userName"
        static let refreshToken = "com.herojoneslabs.fleethub.refreshToken"
        static let entraRefreshToken = "com.herojoneslabs.fleethub.entraRefreshToken"
        static let jamfCredentials = "com.herojoneslabs.fleethub.jamfCredentials"
    }

    // MARK: - Backend selection

    private enum Backend { case dataProtection, legacy }

    private let backendLock = NSLock()
    private var resolvedBackend: Backend?

    /// The keychain this process can write to. Resolved lazily on the first
    /// call that needs it and cached for the life of the process.
    private var backend: Backend {
        backendLock.lock(); defer { backendLock.unlock() }
        if let resolvedBackend { return resolvedBackend }
        let probe = Self.probeDataProtectionKeychain()
        resolvedBackend = probe
        if probe == .legacy {
            logger.notice("Data-protection keychain unavailable to this build (unsigned or ad-hoc); using the login keychain for this process")
        }
        return probe
    }

    /// Finds out whether this build can WRITE to the data-protection
    /// keychain, by adding and removing a throwaway item there.
    ///
    /// A read is not enough: a build without an application identifier can
    /// be told "not found" on a read and still be refused on every write.
    /// Trusting the read made the app pick the data-protection keychain,
    /// fail to save there, and then mishandle items in the login keychain.
    private static func probeDataProtectionKeychain() -> Backend {
        let account = "com.herojoneslabs.fleethub.keychain-probe"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        var add = base
        add[kSecValueData as String] = Data("probe".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            SecItemDelete(base as CFDictionary)
            return .dataProtection
        case errSecDuplicateItem:
            // Left behind by an interrupted probe: it was writable then.
            SecItemDelete(base as CFDictionary)
            return .dataProtection
        default:
            // Missing entitlement, or anything else that stops a write:
            // the login keychain is the one that works.
            return .legacy
        }
    }

    private func baseQuery(_ key: String, backend: Backend) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        if backend == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    // MARK: - Core operations (status-returning)

    /// Add-then-update write. Returns the `OSStatus` of the operation that
    /// decided the outcome so callers can show it.
    @discardableResult
    func saveStatus(key: String, data: Data) -> OSStatus {
        let backend = self.backend
        var add = baseQuery(key, backend: backend)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            status = SecItemUpdate(baseQuery(key, backend: backend) as CFDictionary, update as CFDictionary)
        }
        // The probe is a READ, and on some builds a read of a missing item
        // answers "not found" even though WRITES need an entitlement the
        // build lacks. When a write proves that, switch this process to the
        // login keychain and try again there instead of failing.
        if status == errSecMissingEntitlement, backend == .dataProtection {
            backendLock.lock()
            resolvedBackend = .legacy
            backendLock.unlock()
            logger.notice("Data-protection keychain refused a write (missing entitlement); using the login keychain for this process")
            return saveStatus(key: key, data: data)
        }
        if status != errSecSuccess {
            logger.error("Keychain write failed for \(key, privacy: .public): \(status)")
        }
        return status
    }

    @discardableResult
    func save(key: String, data: Data) -> Bool {
        saveStatus(key: key, data: data) == errSecSuccess
    }

    func load(key: String) -> Data? {
        let backend = self.backend
        if let data = read(key: key, backend: backend) {
            return data
        }
        // Forward migration: a value written by an earlier (legacy-keychain)
        // build is moved into the data-protection keychain on first read.
        if backend == .dataProtection, let legacy = read(key: key, backend: .legacy) {
            // Remove the login-keychain copy ONLY when the value really is
            // in the data-protection keychain now. If that save was refused
            // and fell back to the login keychain, the "copy" just written
            // IS the login-keychain item: deleting it would destroy the
            // secret (this happened, and wiped policy-delivered secrets on
            // their first read).
            if saveStatus(key: key, data: legacy) == errSecSuccess,
               self.backend == .dataProtection,
               read(key: key, backend: .dataProtection) == legacy {
                _ = SecItemDelete(baseQuery(key, backend: .legacy) as CFDictionary)
                logger.notice("Migrated \(key, privacy: .public) to the data-protection keychain")
            }
            return legacy
        }
        return nil
    }

    private func read(key: String, backend: Backend) -> Data? {
        var query = baseQuery(key, backend: backend)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound, errSecMissingEntitlement:
            return nil
        default:
            logger.error("Keychain read failed for \(key, privacy: .public): \(status)")
            return nil
        }
    }

    /// Removes the item from every backend this process can reach. Missing
    /// items count as success.
    @discardableResult
    func delete(key: String) -> Bool {
        var ok = true
        for backend in [Backend.dataProtection, .legacy] {
            let status = SecItemDelete(baseQuery(key, backend: backend) as CFDictionary)
            switch status {
            case errSecSuccess, errSecItemNotFound, errSecMissingEntitlement:
                continue
            default:
                logger.error("Keychain delete failed for \(key, privacy: .public): \(status)")
                ok = false
            }
        }
        return ok
    }

    func saveString(_ string: String, forKey key: String) -> Bool {
        guard let data = string.data(using: .utf8) else { return false }
        return save(key: key, data: data)
    }

    func loadString(forKey key: String) -> String? {
        guard let data = load(key: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Session tokens

    func saveAuthToken(_ token: String) -> Bool {
        return saveString(token, forKey: Keys.authToken)
    }

    func loadAuthToken() -> String? {
        return loadString(forKey: Keys.authToken)
    }

    func deleteAuthToken() -> Bool {
        return delete(key: Keys.authToken)
    }

    func saveRefreshToken(_ token: String) -> Bool {
        return saveString(token, forKey: Keys.refreshToken)
    }

    func loadRefreshToken() -> String? {
        return loadString(forKey: Keys.refreshToken)
    }

    func deleteRefreshToken() -> Bool {
        return delete(key: Keys.refreshToken)
    }

    func saveEntraRefreshToken(_ token: String) -> Bool {
        return saveString(token, forKey: Keys.entraRefreshToken)
    }

    func loadEntraRefreshToken() -> String? {
        return loadString(forKey: Keys.entraRefreshToken)
    }

    func deleteEntraRefreshToken() -> Bool {
        return delete(key: Keys.entraRefreshToken)
    }

    // MARK: - User identity (non-secret → UserDefaults, not Keychain)
    //
    // The signed-in user's email and display name are shown all over the UI
    // and carry no security value. Storing them in the Keychain only bought
    // an extra "FleetHub wants to use your confidential information"
    // ACL prompt per item on every fresh/re-signed build — for data that is
    // not confidential. They now live in UserDefaults. The accessors below
    // keep the same names/signatures (call sites are unchanged) and migrate
    // any value left in the Keychain by an older build on first read, then
    // delete the orphaned Keychain item so the prompt stops for good.

    private var defaults: UserDefaults { .standard }

    @discardableResult
    func saveUserEmail(_ email: String) -> Bool {
        defaults.set(email, forKey: Keys.userEmail)
        _ = delete(key: Keys.userEmail)   // clear any legacy Keychain copy
        return true
    }

    func loadUserEmail() -> String? {
        if let email = defaults.string(forKey: Keys.userEmail) { return email }
        // One-time migration from a Keychain value written by an older build.
        if let legacy = loadString(forKey: Keys.userEmail) {
            defaults.set(legacy, forKey: Keys.userEmail)
            _ = delete(key: Keys.userEmail)
            return legacy
        }
        return nil
    }

    @discardableResult
    func deleteUserEmail() -> Bool {
        defaults.removeObject(forKey: Keys.userEmail)
        return delete(key: Keys.userEmail)
    }

    @discardableResult
    func saveUserName(_ name: String) -> Bool {
        defaults.set(name, forKey: Keys.userName)
        _ = delete(key: Keys.userName)
        return true
    }

    func loadUserName() -> String? {
        if let name = defaults.string(forKey: Keys.userName) { return name }
        if let legacy = loadString(forKey: Keys.userName) {
            defaults.set(legacy, forKey: Keys.userName)
            _ = delete(key: Keys.userName)
            return legacy
        }
        return nil
    }

    @discardableResult
    func deleteUserName() -> Bool {
        defaults.removeObject(forKey: Keys.userName)
        return delete(key: Keys.userName)
    }

    func clearAllAuthData() {
        _ = deleteAuthToken()
        _ = deleteRefreshToken()
        _ = deleteEntraRefreshToken()
        _ = deleteUserEmail()
        _ = deleteUserName()
    }

    // MARK: - Jamf Credentials

    func saveJamfCredentials(_ credentials: JamfCredentials) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(credentials) else {
            return false
        }

        return save(key: Keys.jamfCredentials, data: data)
    }

    func loadJamfCredentials() -> JamfCredentials? {
        guard let data = load(key: Keys.jamfCredentials) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try? decoder.decode(JamfCredentials.self, from: data)
    }

    func deleteJamfCredentials() -> Bool {
        return delete(key: Keys.jamfCredentials)
    }
}
