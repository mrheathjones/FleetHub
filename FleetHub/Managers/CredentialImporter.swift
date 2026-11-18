//
//  CredentialImporter.swift
//  FleetHub
//
//  The command-line path a Jamf policy uses to put an API client secret
//  into this user's Keychain without anyone typing it:
//
//      FleetHub --import-credential jamfPro  --client-id <CLIENT-ID>
//      FleetHub --import-credential platform --client-id <CLIENT-ID>
//      FleetHub --import-credential abm      --client-id <ABM-KEY-ID> --base64
//      FleetHub --import-credential entra    --client-id <ENTRA-CLIENT-ID>
//
//  For `abm` the secret is the Apple Business Manager private key (PEM) and
//  the identifier is the ABM KEY ID from the Core profile. `--base64` says
//  standard input is base64 text to decode first — Jamf script parameters
//  are a single line, and a PEM is not. For `entra` the secret is the
//  client secret of the Entra app used for device cleanup, and the
//  identifier is that app's client ID (core entra.clientID).
//
//  The SECRET IS READ FROM STANDARD INPUT, never from an argument, so it
//  does not appear in the process list. It is never printed or logged.
//
//  FleetHub itself must do the write: an item created by another program
//  would belong to that program, and macOS would prompt the user every time
//  FleetHub read it.
//
//  The secret is stored for the given client ID (SecretStore.setImported)
//  and used only while the Core profile names that client. Running the
//  command again with the same values changes nothing, so the policy can
//  run on every check-in.
//
//  Exit codes: 0 stored or already current · 64 bad usage · 65 no usable
//  secret on standard input · 74 the Keychain refused the write.
//

import Foundation

enum CredentialImportNotification {
    /// Posted (cross-process) after a successful import so a running
    /// FleetHub reloads its configuration.
    static let name = Notification.Name("com.herojoneslabs.fleethub.credentialImported")
}

enum CredentialImporter {

    private static let flag = "--import-credential"

    /// Runs the import when the process was started with the flag and
    /// returns its exit code; returns nil for a normal app launch.
    static func runIfRequested(arguments: [String] = CommandLine.arguments) -> Int32? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }

        // A Jamf policy starts this as root and switches to the user, which
        // can leave HOME pointing at root's home. The Keychain is found
        // through the home folder, so with the wrong one macOS shows
        // "A keychain cannot be found to store…" instead of saving. Point
        // HOME at the real home of the user this process runs as, before
        // anything touches the Keychain.
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            setenv("HOME", home, 1)
            setenv("CFFIXED_USER_HOME", home, 1)
        }

        func fail(_ code: Int32, _ message: String) -> Int32 {
            FileHandle.standardError.write(Data("FleetHub: \(message)\n".utf8))
            return code
        }

        let kindIndex = arguments.index(after: flagIndex)
        guard kindIndex < arguments.count else {
            return fail(64, "usage: \(flag) jamfPro|platform|abm|entra --client-id <id> [--base64]   (secret on standard input)")
        }
        let secretKind: FleetHubSecret
        let profileBlock: String
        let profileKey: String
        switch arguments[kindIndex] {
        case "jamfPro":
            (secretKind, profileBlock, profileKey) = (.jamfMasterClientSecret, "jamfPro", "masterClientID")
        case "platform":
            (secretKind, profileBlock, profileKey) = (.platformClientSecret, "platformAPI", "clientID")
        case "abm":
            (secretKind, profileBlock, profileKey) = (.abmPrivateKey, "appleBusinessManager", "keyID")
        case "entra":
            (secretKind, profileBlock, profileKey) = (.entraClientSecret, "entra", "clientID")
        default:
            return fail(64, "unknown credential kind '\(arguments[kindIndex])'; use jamfPro, platform, abm or entra")
        }

        guard let idFlag = arguments.firstIndex(of: "--client-id"),
              arguments.index(after: idFlag) < arguments.count else {
            return fail(64, "--client-id <id> is required")
        }
        let clientID = arguments[arguments.index(after: idFlag)].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { return fail(64, "--client-id is empty") }

        let input = FileHandle.standardInput.readDataToEndOfFile()
        var secret = (String(data: input, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return fail(65, "no secret on standard input") }

        if arguments.contains("--base64") {
            guard let decoded = Data(base64Encoded: secret, options: .ignoreUnknownCharacters),
                  let text = String(data: decoded, encoding: .utf8) else {
                return fail(65, "standard input is not valid base64 text")
            }
            secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A wrong value here would only fail later, far from its cause, so
        // an ABM key must at least look like a PEM private key.
        if secretKind == .abmPrivateKey,
           !(secret.contains("-----BEGIN") && secret.contains("PRIVATE KEY-----")) {
            return fail(65, "the ABM key is not a PEM private key (expected BEGIN/END PRIVATE KEY lines)")
        }

        let store = SecretStore.shared
        if store.importedValue(secretKind, clientID: clientID) == secret {
            print("FleetHub: the \(arguments[kindIndex]) secret for this client is already current.")
            return 0
        }

        // The client the Core profile names right now keeps its secret, so
        // a new client's secret can be delivered ahead of the profile change.
        let core = CFPreferencesCopyAppValue(profileBlock as CFString, "com.herojoneslabs.fleethub.core" as CFString) as? [String: Any]
        let currentClientID = core?[profileKey] as? String

        let status = store.setImported(secretKind, clientID: clientID, to: secret, keep: currentClientID)
        guard status == errSecSuccess else {
            return fail(74, "the Keychain refused the secret: \(SecretStore.describe(status))")
        }

        DistributedNotificationCenter.default().postNotificationName(
            CredentialImportNotification.name, object: nil, userInfo: nil, deliverImmediately: true
        )
        print("FleetHub: stored the \(arguments[kindIndex]) secret for this client in the Keychain.")
        return 0
    }
}
