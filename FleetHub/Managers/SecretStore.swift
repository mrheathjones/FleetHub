//
//  SecretStore.swift
//  FleetHub
//
//  The ONLY home for integration secrets. Nothing secret is ever read from a
//  configuration profile or managed-preference domain: every value here is
//  kept in the Keychain through KeychainManager, which writes with a
//  restrictive accessibility class and prefers the data-protection keychain.
//
//  A secret gets here one of two ways:
//    · typed into the app (first-run onboarding or Settings → Credentials),
//      stored under the secret's plain Keychain account; or
//    · imported by a Jamf policy through `CredentialImporter`, stored under
//      an account that also names the API CLIENT ID it belongs to.
//
//  An imported secret is used only while the Core profile names that same
//  client ID, and it wins over a typed one. That is what makes rotation
//  safe: the new client's secret can arrive before the profile switches to
//  the new client ID, and each Mac changes over the moment it has both.
//
//  The non-secret identities these secrets pair with (server URL, client
//  IDs, key IDs, tenant ID) still come from the `core` managed domain.
//

import Foundation

/// Every secret FleetHub needs, keyed by the Keychain account it lives under.
enum FleetHubSecret: String, CaseIterable, Identifiable {
    /// OAuth `client_secret` for the master Jamf Pro API client
    /// (`core.jamfPro.masterClientID`). Required.
    case jamfMasterClientSecret

    /// OAuth `client_secret` of the Jamf Platform API integration
    /// (`core.platformAPI.clientID`). Optional.
    case platformClientSecret

    /// PEM-encoded ES256 private key for Apple Business Manager JWT signing
    /// (`core.appleBusinessManager.clientID` / `keyID`). Optional.
    case abmPrivateKey

    /// Jamf Protect API client password (`core.jamfProtect.clientID`). Optional.
    case jamfProtectPassword

    /// Entra app-only client secret for Return to Service cleanup
    /// (`core.entra.clientID`). Optional; the certificate is preferred.
    case entraClientSecret

    /// PEM containing the Entra app certificate followed by its RSA private
    /// key, for PS256 client-assertion auth. Optional; wins over the secret.
    case entraCertificatePEM

    var id: String { rawValue }

    /// Keychain account name. The Protect item keeps its historical account so
    /// a password saved by an earlier build is still found.
    var keychainKey: String {
        switch self {
        case .jamfMasterClientSecret: return "com.herojoneslabs.fleethub.jamfMasterClientSecret"
        case .platformClientSecret: return "com.herojoneslabs.fleethub.platformClientSecret"
        case .abmPrivateKey: return "com.herojoneslabs.fleethub.abmPrivateKey"
        case .jamfProtectPassword: return "com.herojoneslabs.fleethub.protect.password"
        case .entraClientSecret: return "com.herojoneslabs.fleethub.entraClientSecret"
        case .entraCertificatePEM: return "com.herojoneslabs.fleethub.entraCertificatePEM"
        }
    }

    var title: String {
        switch self {
        case .jamfMasterClientSecret: return "Jamf Pro API Client Secret"
        case .platformClientSecret: return "Jamf Platform API Client Secret"
        case .abmPrivateKey: return "Apple Business Manager Private Key"
        case .jamfProtectPassword: return "Jamf Protect API Password"
        case .entraClientSecret: return "Microsoft Entra Client Secret"
        case .entraCertificatePEM: return "Microsoft Entra Certificate (PEM)"
        }
    }

    var help: String {
        switch self {
        case .jamfMasterClientSecret:
            return "The client secret shown once when the master API client was created in Jamf Pro. Pairs with the client ID delivered by your configuration profile."
        case .platformClientSecret:
            return "The client secret shown once when the integration was created in Jamf Account. Pairs with the client ID delivered by your configuration profile. Integrations expire after six months."
        case .abmPrivateKey:
            return "The private key (.pem) downloaded from Apple Business Manager for the API key named in your configuration profile. Paste the whole file including the BEGIN/END lines."
        case .jamfProtectPassword:
            return "The password for the Jamf Protect API client named in your configuration profile."
        case .entraClientSecret:
            return "Client secret for the Entra app registration used for device cleanup. Used only when no certificate is saved."
        case .entraCertificatePEM:
            return "Certificate followed by its unencrypted RSA private key, both PEM. Preferred over the client secret."
        }
    }

    /// Multi-line PEM material rather than a single-line secret.
    var isMultiline: Bool {
        switch self {
        case .abmPrivateKey, .entraCertificatePEM: return true
        default: return false
        }
    }
}

/// Immutable snapshot of the secrets at the moment configuration was
/// composed. `MDMConfiguration` carries one of these so consumers keep their
/// existing flat accessors (`masterClientSecret`, `abmPrivateKey`, …).
struct ManagedSecrets {
    var masterClientSecret: String?
    var platformClientSecret: String?
    var abmPrivateKey: String?
    var protectPassword: String?
    var entraClientSecret: String?
    var entraCertPEM: String?

    static let empty = ManagedSecrets()

    /// Which secrets are present (trimmed, non-empty).
    var presentSecrets: Set<FleetHubSecret> {
        var set: Set<FleetHubSecret> = []
        if Self.nonEmpty(masterClientSecret) { set.insert(.jamfMasterClientSecret) }
        if Self.nonEmpty(platformClientSecret) { set.insert(.platformClientSecret) }
        if Self.nonEmpty(abmPrivateKey) { set.insert(.abmPrivateKey) }
        if Self.nonEmpty(protectPassword) { set.insert(.jamfProtectPassword) }
        if Self.nonEmpty(entraClientSecret) { set.insert(.entraClientSecret) }
        if Self.nonEmpty(entraCertPEM) { set.insert(.entraCertificatePEM) }
        return set
    }

    private static func nonEmpty(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}

/// Keychain-backed secret storage with one accessor per secret.
final class SecretStore {
    static let shared = SecretStore()

    private let keychain = KeychainManager.shared

    private init() {}

    // MARK: Imported secrets, stored per API client ID

    private static func normalized(_ clientID: String?) -> String {
        (clientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Keychain account of the secret imported for `clientID`.
    private func importedKey(_ secret: FleetHubSecret, clientID: String) -> String {
        "\(secret.keychainKey).client.\(Self.normalized(clientID))"
    }

    /// UserDefaults key listing the client IDs an import exists for, so old
    /// ones can be pruned (the Keychain cannot be enumerated cheaply).
    private func importedIndexKey(_ secret: FleetHubSecret) -> String {
        "fleethub_imported_client_ids_\(secret.rawValue)"
    }

    /// The secret imported for exactly this client ID, if any.
    func importedValue(_ secret: FleetHubSecret, clientID: String?) -> String? {
        let id = Self.normalized(clientID)
        guard !id.isEmpty,
              let raw = keychain.loadString(forKey: importedKey(secret, clientID: id)) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func hasImported(_ secret: FleetHubSecret, clientID: String?) -> Bool {
        importedValue(secret, clientID: clientID) != nil
    }

    /// The secret to use with `clientID`: the one imported for that client,
    /// else the one typed into the app.
    func value(_ secret: FleetHubSecret, clientID: String?) -> String? {
        importedValue(secret, clientID: clientID) ?? value(secret)
    }

    /// Stores a secret for `clientID`, then drops imports for any client
    /// other than this one and `keep` (the client the profile names now),
    /// so superseded secrets do not accumulate.
    @discardableResult
    func setImported(_ secret: FleetHubSecret, clientID: String, to value: String, keep: String?) -> OSStatus {
        let id = Self.normalized(clientID)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return errSecParam }
        let status = keychain.saveStatus(key: importedKey(secret, clientID: id), data: data)
        guard status == errSecSuccess else { return status }

        let defaults = UserDefaults.standard
        var known = Set(defaults.stringArray(forKey: importedIndexKey(secret)) ?? [])
        known.insert(id)
        let keepers: Set<String> = [id, Self.normalized(keep)]
        for stale in known.subtracting(keepers) {
            _ = keychain.delete(key: importedKey(secret, clientID: stale))
            known.remove(stale)
        }
        defaults.set(Array(known).sorted(), forKey: importedIndexKey(secret))
        return status
    }

    // MARK: Typed secrets

    /// The stored value, trimmed; nil when absent or blank.
    func value(_ secret: FleetHubSecret) -> String? {
        guard let raw = keychain.loadString(forKey: secret.keychainKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func has(_ secret: FleetHubSecret) -> Bool {
        value(secret) != nil
    }

    /// Stores a value. A blank value removes the secret. Returns the
    /// Keychain status so the UI can report a failed write instead of
    /// pretending it saved.
    @discardableResult
    func set(_ secret: FleetHubSecret, to value: String) -> OSStatus {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return keychain.delete(key: secret.keychainKey) ? errSecSuccess : errSecIO
        }
        guard let data = trimmed.data(using: .utf8) else { return errSecParam }
        return keychain.saveStatus(key: secret.keychainKey, data: data)
    }

    @discardableResult
    func remove(_ secret: FleetHubSecret) -> Bool {
        keychain.delete(key: secret.keychainKey)
    }

    /// Removes every secret (used by the uninstall path and tests).
    func removeAll() {
        for secret in FleetHubSecret.allCases { _ = remove(secret) }
    }

    /// Snapshot used when composing `MDMConfiguration`. The two API client
    /// secrets are resolved for the client IDs the Core profile names, and
    /// the ABM private key for the ABM key ID it names.
    func snapshot(masterClientID: String? = nil, platformClientID: String? = nil, abmKeyID: String? = nil,
                  entraClientID: String? = nil) -> ManagedSecrets {
        ManagedSecrets(
            masterClientSecret: value(.jamfMasterClientSecret, clientID: masterClientID),
            platformClientSecret: value(.platformClientSecret, clientID: platformClientID),
            abmPrivateKey: value(.abmPrivateKey, clientID: abmKeyID),
            protectPassword: value(.jamfProtectPassword),
            entraClientSecret: value(.entraClientSecret, clientID: entraClientID),
            entraCertPEM: value(.entraCertificatePEM)
        )
    }

    /// Human-readable text for a failed write.
    static func describe(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return "\(message) (\(status))"
        }
        return "Keychain error \(status)"
    }
}
