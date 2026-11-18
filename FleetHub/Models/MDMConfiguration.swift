//
//  MDMConfiguration.swift
//  FleetHub
//
//  Aggregated app-facing configuration, composed from the four managed
//  preference domains (com.herojoneslabs.fleethub.core / .access /
//  .features / .ui — see docs/Configuration.md) plus the secrets
//  held in the Keychain (SecretStore — never a profile). The flat fields
//  below are the stable consumer surface; the optional domain-model
//  properties expose the newer, not-yet-flattened surface (device actions,
//  feature modules, authentication, UI extras).
//

import Foundation

struct MDMConfiguration: Codable {
    /// API backend choice and the Platform integration's identity + secret.
    /// Optional `var`s (set after the memberwise init in the composing
    /// initializer) so the long designated init and Codable stay unchanged.
    var apiBackendRaw: String? = nil
    var platformAPI: PlatformAPIConnection? = nil
    var platformClientSecret: String? = nil

    /// The backend actually in effect. `platform` only when the profile
    /// asks for it AND delivers a usable Platform connection; an incomplete
    /// block never half-switches the app (calls would fail with a clear
    /// "not configured" error instead — see `JamfTransport.prepare`).
    var effectiveAPIBackend: JamfAPIBackend { JamfAPIBackend.parse(apiBackendRaw) }

    /// True when a Platform integration is fully usable (identity from the
    /// profile + secret in the Keychain).
    var isPlatformAPIReady: Bool {
        platformAPI != nil
            && !(platformClientSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    let jamfURL: String
    let masterClientID: String
    let masterClientSecret: String
    let appTitle: String
    let appSubtitle: String
    let sidebarItems: [SidebarItemConfig]
    let requiredRoleName: String
    let supportURL: String?
    let localAdminUsername: String

    // Network tuning (core domain jamfPro.connectionTimeout /
    // jamfPro.requestTimeout) — consumed via NetworkTuning at every
    // URLRequest/URLSession construction site.
    let connectionTimeoutSeconds: Int
    let requestTimeoutSeconds: Int

    // Erase-acknowledgment tuning (core domain jamfPro.eraseAckTimeoutSeconds /
    // jamfPro.eraseAckPollIntervalSeconds) — applied to EVERY erase (Erase
    // Device and Return to Service). The ack wait is mandatory by design;
    // no cleanup step runs without acknowledgment.
    let eraseAckTimeoutSeconds: Int
    let eraseAckPollIntervalSeconds: Int

    /// The Jamf extension attribute holding a device's VPN IP, from the
    /// Features profile (computers.vpnIPExtensionAttributeID). nil = the org
    /// does not collect one; Screen Share, SSH and the IP tile then use the
    /// address in the inventory record.
    var effectiveVPNIPExtensionAttribute: VPNIPExtensionAttributeRef? {
        features?.effectiveComputers.effectiveVPNIPExtensionAttribute
    }

    /// Lifetime (days) for per-user Jamf API credentials provisioned by the
    /// app (core jamfPro.userCredentialLifetimeDays, default 90).
    let userCredentialLifetimeDays: Int

    /// AxM API base URL (core appleBusinessManager.serviceType:
    /// business → api-business.apple.com, school → api-school.apple.com).
    let abmAPIBaseURL: String

    /// OAuth scope matching abmAPIBaseURL (business.api / school.api).
    let abmOAuthScope: String

    /// Azure endpoints for the Entra cleanup flow (core entra.cloudInstance:
    /// global / usgov / china).
    let entraAuthorityHost: String
    let entraGraphHost: String
    
    // Apple Business Manager API (optional)
    let abmClientId: String?
    let abmKeyId: String?
    let abmPrivateKey: String?

    /// ABM Lookup default filters (core appleBusinessManager.defaultMdmServerName
    /// / defaultDeviceType). Starting-point filter state, operator-overridable.
    /// Server is named (resolved to id in the view); device type is a raw token
    /// parsed via ABMDeviceType.from (fail-safe to all).
    let abmDefaultMdmServerName: String?
    let abmDefaultDeviceType: String?

    // MARK: - Role-based access + Cleanup feature (Jamf stale-device cleanup)
    /// This Mac's role name, delivered by MDM in the access domain's `role`
    /// key. A FREE-FORM string naming a key in `roleDefinitions` — the app
    /// defines no roles of its own. Read it through `mdmRoleName` (trimmed);
    /// a value matching no definition grants nothing (fail-closed).
    let role: String?

    /// The access domain's `roles` array AS DELIVERED — profile order intact.
    /// This is the ordered source of truth: a role's `modules` array position
    /// is its sidebar order, and across roles the union walks THIS array (see
    /// `capabilities(forRoleNames:)` and `UserCapabilities.union(_:)`), so the
    /// order must survive composition. `roleDefinitions` below is only a
    /// lookup index derived from it — a dictionary has no stable order and
    /// could never carry this.
    let orderedRoleDefinitions: [AccessConfiguration.RoleDefinition]

    /// NAME INDEX over `orderedRoleDefinitions`, derived once in `init` by
    /// `roleIndex(from:)` so membership lookup stays O(1). The value is a
    /// LIST because duplicate names are legal and UNION together — see
    /// `roleIndex(from:)` for why. `[:]` when the domain or the block is
    /// absent — in which case EVERY user resolves to `UserCapabilities.none`.
    ///
    /// UNORDERED BY NATURE — for membership tests (`hasAnyDefinedRole(in:)`)
    /// and diagnostics only. Anything order-sensitive must read
    /// `orderedRoleDefinitions`. Resolve capabilities through
    /// `capabilities(forRoleNames:)`, never by hand.
    let roleDefinitions: [String: [AccessConfiguration.RoleDefinition]]
    /// Stale threshold (days without check-in) used by Cleanup.
    let cleanupStaleDays: Int
    let cleanupDefaultStaticGroupID: String?
    let cleanupDefaultSiteID: String?

    // Jamf Protect (optional, gated)
    let protectEnabled: Bool
    let protectURL: String?
    let protectClientID: String?
    /// Jamf Protect API password — from the Keychain (SecretStore), never a
    /// profile.
    let protectPassword: String?

    // MARK: - Microsoft Entra (Graph) cleanup for Return to Service
    /// Microsoft Entra tenant id (core `entra.tenantID`).
    let entraTenantId: String?
    /// Entra app registration client id (core `entra.clientID`).
    let entraClientId: String?
    /// Entra app client secret — from the Keychain (SecretStore); fallback
    /// auth when no certificate is present.
    let entraClientSecret: String?
    /// PEM (certificate + private key) for PS256 client-assertion auth
    /// (preferred) — from the Keychain (SecretStore).
    let entraCertPEM: String?

    // MARK: - New (not-yet-flattened) domain surface
    // Parsed and exposed by the config layer; per-view enforcement status is
    // tracked in docs/Configuration.md. All optional — absent when
    // the delivering domain/profile is absent.

    /// Per-action device-command allow-list (access domain).

    /// Feature modules & tuning (features domain, whole model).
    let features: FeaturesConfiguration?

    /// Sign-in behavior preferences — core domain `authentication` only. It
    /// moved from the ui domain in the schema-3.0 cleanup and the transitional
    /// read of the ui copy has been REMOVED.
    let authentication: AuthenticationSettings?

    /// Whether the Announcements area may render (features domain
    /// `userExperience.showAnnouncements`; ui domain legacy fallback).
    /// INTERSECTED with the role grant — never a substitute for it.
    let showAnnouncements: Bool

    /// Whether the Settings area may render (features domain
    /// `userExperience.showSettings`; ui domain legacy fallback).
    /// INTERSECTED with the role grant — never a substitute for it.
    let showSettings: Bool

    /// Full branding/UX section (ui domain) — companyName, logoURL,
    /// accentColor, defaultColorScheme, show* switches beyond the flattened
    /// appTitle/appSubtitle/supportURL.
    let userInterfaceExtras: UserInterfaceSettings?

    /// Cosmetic Devices-tab rename overrides (ui domain `deviceTabs`).
    /// Read via `deviceTabLabelOverride(id:)`. Empty when none delivered.
    let uiDeviceTabs: [DeviceTabLabelSetting]

    /// Cosmetic device-action label/icon overrides (ui domain
    /// `deviceActionLabels`). Read via `deviceActionLabelOverride(id:)`.
    /// Empty when none delivered.
    let uiDeviceActionLabels: [DeviceActionLabelSetting]

    /// Cosmetic scorecard card label overrides (ui domain `healthCardLabels`).
    /// Read via `healthCardLabelOverride(id:)`. Empty when none delivered.
    let uiHealthCardLabels: [HealthCardLabelSetting]

    /// Interactive sign-in configuration (core domain `signIn` block) —
    /// how users sign into the app itself: built-in email flow (default)
    /// or Microsoft Entra ID via a separate PUBLIC-client app registration.
    /// Distinct from the app-only `entra*` cleanup credentials above.
    /// Consumed via the `signInMethod` / `entraSignIn*` accessors below.
    let signIn: CoreConfiguration.SignInSettings?

    /// Whether Entra device cleanup can run: tenant + client id must be present
    /// along with at least one credential (certificate PEM or client secret).
    var isEntraConfigured: Bool {
        guard let tenant = entraTenantId, !tenant.isEmpty,
              let client = entraClientId, !client.isEmpty else {
            return false
        }
        let hasCert = (entraCertPEM?.isEmpty == false)
        let hasSecret = (entraClientSecret?.isEmpty == false)
        return hasCert || hasSecret
    }

    /// Whether the app can talk to Jamf. On the Jamf Pro backend:
    /// core-domain serverURL + masterClientID non-empty AND the master
    /// client secret present in the Keychain. On the Platform backend: the
    /// serverURL (call sites still address Jamf Pro paths) plus a usable
    /// Platform integration and its secret. The manager logs exactly what
    /// is missing when this is false.
    var isConfigured: Bool {
        guard !jamfURL.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let backend = effectiveAPIBackend
        // Hybrid needs BOTH halves: the integration for reads and the
        // master client to provision each operator's own client for actions.
        if backend.needsPlatformIntegration,
           !(isPlatformAPIReady && (platformAPI?.canProxyJamfPro ?? false)) {
            return false
        }
        // With automatic creation off, each operator brings their own
        // pre-created API client and no provisioning client is involved.
        if backend.needsPerUserClients, effectiveAutoCreateUserApiClient {
            return !masterClientID.trimmingCharacters(in: .whitespaces).isEmpty
                && !masterClientSecret.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    var isABMConfigured: Bool {
        guard let clientId = abmClientId, !clientId.isEmpty,
              let keyId = abmKeyId, !keyId.isEmpty,
              let privateKey = abmPrivateKey, !privateKey.isEmpty else {
            return false
        }
        return true
    }

    // MARK: - Roles & capabilities (profile-defined; strict fail-closed)

    /// This Mac's role name from the access domain's `role` key, trimmed.
    /// `""` when absent. Used as the identity's role name ONLY when Entra
    /// sign-in is not configured — the Entra roles claim wins when it is.
    var mdmRoleName: String {
        role?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Resolves capabilities for a set of role names — the Entra roles claim
    /// under Entra sign-in, or `[mdmRoleName]` otherwise.
    ///
    /// Matching is EXACT and CASE-SENSITIVE: "FleetHub.Admin" and
    /// "fleethub.admin" are different roles. Names matching no definition
    /// contribute nothing (they are not an error — an Entra tenant may
    /// assign roles this app has never heard of). When no name matches, the
    /// result is `.none` — fail-closed, by construction of `union([])`.
    ///
    /// A user holding several defined roles gets the UNION of their
    /// capabilities — as does a user holding ONE name that the profile
    /// defines more than once (see `roleIndex(from:)`).
    ///
    /// ORDER: matched definitions are handed to `UserCapabilities.union(_:)`
    /// in the order they appear in the PROFILE's `roles` array — NOT in
    /// `names` order. That matters because module order is sidebar order:
    /// `names` is the token's roles claim, whose order Entra chooses and may
    /// vary between sign-ins, so ordering by it would make a user's sidebar
    /// shuffle for no reason the admin can see or control. Filtering the
    /// ordered array (rather than looking each name up in the dictionary
    /// index, which has no order) is what pins the result to the profile.
    /// Duplicate names still union: every entry carrying a matched name is
    /// kept, each in its own array position.
    ///
    /// Nameless entries can never match — the same rule `roleIndex(from:)`
    /// applies — which also stops an empty `role` key resolving to anything.
    func capabilities(forRoleNames names: [String]) -> UserCapabilities {
        let requested = Set(names)
        let matched = orderedRoleDefinitions.filter { definition in
            let name = definition.effectiveName
            return !name.isEmpty && requested.contains(name)
        }
        return UserCapabilities.union(matched)
    }

    /// The Jamf Pro API Role names to attach to the per-user API client of
    /// someone holding `names` — the roles that bound them in Jamf itself.
    ///
    /// Each matched role definition contributes its `jamfApiRoleName`; a
    /// matched definition that names none contributes the Core default
    /// (`jamfPro.requiredRoleName`). Names matching no definition contribute
    /// nothing. When that leaves nothing at all — no role matched, or none
    /// named a Jamf role — the Core default alone is returned, which is the
    /// behaviour before per-role Jamf roles existed.
    ///
    /// Sorted and de-duplicated so two sign-ins with the same roles always
    /// compare equal. An EMPTY result means the profiles name no Jamf role
    /// for this person; provisioning then fails closed.
    func jamfApiRoleNames(forRoleNames names: [String]) -> [String] {
        let requested = Set(names)
        let fallback = requiredRoleName.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolved = Set<String>()
        for definition in orderedRoleDefinitions {
            let name = definition.effectiveName
            guard !name.isEmpty, requested.contains(name) else { continue }
            let jamfRole = definition.effectiveJamfApiRoleName
            if !jamfRole.isEmpty {
                resolved.insert(jamfRole)
            } else if !fallback.isEmpty {
                resolved.insert(fallback)
            }
        }
        if resolved.isEmpty, !fallback.isEmpty {
            resolved.insert(fallback)
        }
        return resolved.sorted()
    }

    /// True when at least one name matches a defined role — i.e. the
    /// identity has some FleetHub role at all. THE Entra sign-in eligibility
    /// gate (EntraAuthService calls it through a closure — see the overload
    /// below); this rule exists nowhere else. Same exact, case-sensitive
    /// matching as `capabilities(forRoleNames:)`.
    ///
    /// Note what it does NOT test: only that a name is DEFINED, never what
    /// that definition grants. A role defined as `{name = "Auditor";}` is
    /// eligible and resolves to `.none` — signed in, empty app.
    func hasAnyDefinedRole(in names: [String]) -> Bool {
        Self.hasAnyDefinedRole(in: names, definitions: roleDefinitions)
    }

    /// The rule itself, over the role index alone, so a caller that must not
    /// retain the whole configuration can still share this exact
    /// implementation rather than re-deriving it — EntraAuthService holds a
    /// closure over this, because the configuration carries Jamf/Entra
    /// secrets an auth service has no business retaining.
    static func hasAnyDefinedRole(
        in names: [String],
        definitions: [String: [AccessConfiguration.RoleDefinition]]
    ) -> Bool {
        names.contains { definitions[$0] != nil }
    }

    /// Indexes the access domain's `roles` ARRAY by role name, once, so
    /// `capabilities(forRoleNames:)` and `hasAnyDefinedRole(in:)` stay O(1)
    /// per name.
    ///
    /// Two edge cases the array shape introduces, both resolved fail-closed:
    ///
    /// • NAMELESS ENTRY (`name` missing, blank, or malformed) → SKIPPED and
    ///   logged. No role name can ever match it, so indexing it under `""`
    ///   would only risk an empty/whitespace `role` key accidentally
    ///   resolving to real capabilities.
    ///
    /// • DUPLICATE NAMES → UNIONED, not replaced. Later entries append rather
    ///   than overwrite, so `roleDefinitions[name]` holds every definition
    ///   carrying that name and `UserCapabilities.union` sums them. Union is
    ///   the direction that matches multi-role semantics (holding a name
    ///   grants everything that name is defined to grant) and it is the
    ///   predictable one: last-wins would make an admin's grant silently
    ///   vanish based on array order.
    static func roleIndex(
        from definitions: [AccessConfiguration.RoleDefinition]
    ) -> [String: [AccessConfiguration.RoleDefinition]] {
        var index: [String: [AccessConfiguration.RoleDefinition]] = [:]
        for definition in definitions {
            let name = definition.effectiveName
            guard !name.isEmpty else {
                AppLog.notice("⚠️ access.roles: role entry with a missing or blank 'name' — SKIPPED (an unnamed role is unreachable; no role name can match it)")
                continue
            }
            index[name, default: []].append(definition)
        }
        return index
    }

    // MARK: - Interactive sign-in (core signIn block; strict fail-closed)

    /// How users sign into the app.
    enum SignInMethod: String {
        case email
        case entra
    }

    /// Resolved sign-in method. Entra whenever the profile says "entra"
    /// (case-insensitive) OR delivers a usable Entra registration (tenant
    /// and client ids). Email sign-in is therefore only available when no
    /// Entra sign-in is configured at all: a profile that carries the
    /// registration but omits or mistypes `method` must not quietly fall
    /// back to the weaker email flow.
    var signInMethod: SignInMethod {
        let raw = signIn?.method?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if raw == SignInMethod.entra.rawValue { return .entra }
        if !entraSignInTenantId.isEmpty, !entraSignInClientId.isEmpty { return .entra }
        return .email
    }

    /// Whether the Entra sign-in flow is selected AND usable: method is
    /// "entra" with non-empty tenantId and clientId. FAIL-CLOSED: when
    /// `signInMethod == .entra` but this is false, the login UI must show
    /// a configuration-error state — NEVER the email form (see
    /// `entraSignInRequired`); a misconfigured profile must not silently
    /// downgrade to the weaker email flow.
    var isEntraSignInConfigured: Bool {
        signInMethod == .entra
            && !entraSignInTenantId.isEmpty
            && !entraSignInClientId.isEmpty
    }

    /// Entra tenant id for interactive sign-in ("" when absent).
    var entraSignInTenantId: String {
        signIn?.entra?.tenantId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Application (client) id of the PUBLIC-client app registration for
    /// interactive sign-in ("" when absent). Not secret — and no secret
    /// is ever paired with it.
    var entraSignInClientId: String {
        signIn?.entra?.clientId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// OAuth token authority host for interactive sign-in, resolved from
    /// signIn.entra.cloudInstance via the shared CloudInstance mapping
    /// (default global → login.microsoftonline.com).
    var entraSignInAuthorityHost: String {
        (signIn?.entra?.effectiveCloudInstance ?? .global).authorityHost
    }

    /// Entra group OBJECT ids the signed-in user must be a member of
    /// (verified via the token's groups claim). Default [] = no group
    /// check. Prefer app roles — the groups claim is overage-limited.
    /// Redirect URI for interactive sign-in: the profile's
    /// signIn.entra.redirectURI, or the built-in default.
    var entraSignInRedirectURI: String {
        signIn?.entra?.effectiveRedirectURI ?? CoreConfiguration.EntraSignInSettings.defaultRedirectURI
    }

    var effectiveEntraAllowedGroupIds: [String] {
        signIn?.entra?.effectiveAllowedGroupIds ?? []
    }

    /// Whether the master client may create a per-user Jamf API client for an
    /// operator who doesn't have one yet (assigning `requiredRoleName`, named
    /// `<UPN> (<clientId>)`). Default false. See `AuthenticationSettings`.
    var effectiveAutoCreateUserApiClient: Bool {
        authentication?.effectiveAutoCreateUserApiClient ?? false
    }

    /// Whether the Entra sign-in flow is REQUIRED: true whenever the
    /// method is "entra", even when misconfigured
    /// (`isEntraSignInConfigured == false`). The email path must be
    /// hidden in that case — the login UI shows a configuration error
    /// instead of falling back to the weaker email flow.
    var entraSignInRequired: Bool { signInMethod == .entra }

    // MARK: - Device action policies (strict fail-closed)

    /// Policy for the computer (macOS) Actions menu: access-domain
    /// allow-list + features-domain enableAPIActions kill switch,
    /// intersected with the signed-in user's role capabilities. No
    /// allow-list delivered → DeviceActionPolicy denies everything and the
    /// Actions menu is hidden; so does `.none` capabilities. NOTE: once an
    /// allow-list is delivered it is authoritative for Screen Share too —
    /// the legacy core-domain `jamfPro.screenShareEnabled` key is deprecated
    /// and ignored.
    ///
    /// Pass the CURRENT capabilities (UserSession.shared.capabilities) —
    /// the policy is a value, so it must be rebuilt when they change.
    func computerActionPolicy(capabilities: UserCapabilities) -> DeviceActionPolicy {
        DeviceActionPolicy(capabilities: capabilities, platform: .computer)
    }

    /// Policy for mobile-device actions. No mobile actions menu exists yet
    /// (MobileDeviceView's "More" button is a stub); any future menu must be
    /// built from this policy from day one.
    func mobileDeviceActionPolicy(capabilities: UserCapabilities) -> DeviceActionPolicy {
        DeviceActionPolicy(capabilities: capabilities, platform: .mobileDevice)
    }

    // MARK: - UI cosmetic overrides (ui domain; label/icon only)

    /// The Devices-tab rename for `id`, or nil to use the tab's built-in
    /// title. Last non-empty entry for a duplicate id wins.
    func deviceTabLabelOverride(id: String) -> String? {
        var result: String?
        for item in uiDeviceTabs where item.effectiveID == id {
            if !item.effectiveDisplayName.isEmpty { result = item.effectiveDisplayName }
        }
        return result
    }

    /// The display-name override for scorecard card `id`, or nil when none was
    /// delivered or it is blank. Cosmetic only — which cards exist and what they
    /// measure is the features domain's `healthScorecard.cards`.
    func healthCardLabelOverride(id: String) -> String? {
        var name: String?
        for item in uiHealthCardLabels where item.effectiveID == id {
            if !item.effectiveDisplayName.isEmpty { name = item.effectiveDisplayName }
        }
        return name
    }

    /// The label/icon override for device-action `id`, or nil when none was
    /// delivered. Either field may still be nil (blank → app default). Last
    /// entry carrying a non-empty field for a duplicate id wins per field.
    func deviceActionLabelOverride(id: String) -> (displayName: String?, icon: String?)? {
        var displayName: String?
        var icon: String?
        var matched = false
        for item in uiDeviceActionLabels where item.effectiveID == id {
            matched = true
            if !item.effectiveDisplayName.isEmpty { displayName = item.effectiveDisplayName }
            if !item.effectiveIcon.isEmpty { icon = item.effectiveIcon }
        }
        return matched ? (displayName: displayName, icon: icon) : nil
    }

    init(
        jamfURL: String,
        masterClientID: String,
        masterClientSecret: String,
        appTitle: String,
        appSubtitle: String,
        sidebarItems: [SidebarItemConfig],
        requiredRoleName: String,
        supportURL: String?,
        localAdminUsername: String,
        connectionTimeoutSeconds: Int = 30,
        requestTimeoutSeconds: Int = 60,
        eraseAckTimeoutSeconds: Int = 180,
        eraseAckPollIntervalSeconds: Int = 15,
        userCredentialLifetimeDays: Int = 90,
        abmAPIBaseURL: String = "https://api-business.apple.com/v1",
        abmOAuthScope: String = "business.api",
        entraAuthorityHost: String = "login.microsoftonline.com",
        entraGraphHost: String = "graph.microsoft.com",
        abmClientId: String?,
        abmKeyId: String?,
        abmPrivateKey: String?,
        abmDefaultMdmServerName: String? = nil,
        abmDefaultDeviceType: String? = nil,
        role: String? = nil,
        roles: [AccessConfiguration.RoleDefinition] = [],
        cleanupStaleDays: Int = 90,
        cleanupDefaultStaticGroupID: String? = nil,
        cleanupDefaultSiteID: String? = nil,
        protectEnabled: Bool = false,
        protectURL: String? = nil,
        protectClientID: String? = nil,
        protectPassword: String? = nil,
        entraTenantId: String? = nil,
        entraClientId: String? = nil,
        entraClientSecret: String? = nil,
        entraCertPEM: String? = nil,
        features: FeaturesConfiguration? = nil,
        authentication: AuthenticationSettings? = nil,
        showAnnouncements: Bool = true,
        showSettings: Bool = true,
        userInterfaceExtras: UserInterfaceSettings? = nil,
        uiDeviceTabs: [DeviceTabLabelSetting] = [],
        uiDeviceActionLabels: [DeviceActionLabelSetting] = [],
        uiHealthCardLabels: [HealthCardLabelSetting] = [],
        signIn: CoreConfiguration.SignInSettings? = nil
    ) {
        self.jamfURL = jamfURL
        self.masterClientID = masterClientID
        self.masterClientSecret = masterClientSecret
        self.appTitle = appTitle
        self.appSubtitle = appSubtitle
        self.sidebarItems = sidebarItems
        self.requiredRoleName = requiredRoleName
        self.supportURL = supportURL
        self.localAdminUsername = localAdminUsername
        self.connectionTimeoutSeconds = connectionTimeoutSeconds
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.eraseAckTimeoutSeconds = eraseAckTimeoutSeconds
        self.eraseAckPollIntervalSeconds = eraseAckPollIntervalSeconds
        self.userCredentialLifetimeDays = userCredentialLifetimeDays
        self.abmAPIBaseURL = abmAPIBaseURL
        self.abmOAuthScope = abmOAuthScope
        self.entraAuthorityHost = entraAuthorityHost
        self.entraGraphHost = entraGraphHost
        self.abmClientId = abmClientId
        self.abmKeyId = abmKeyId
        self.abmPrivateKey = abmPrivateKey
        self.abmDefaultMdmServerName = abmDefaultMdmServerName
        self.abmDefaultDeviceType = abmDefaultDeviceType
        self.role = role
        // The index is DERIVED here rather than passed in, so the ordered
        // array and its name index cannot drift apart at any call site.
        self.orderedRoleDefinitions = roles
        self.roleDefinitions = MDMConfiguration.roleIndex(from: roles)
        self.cleanupStaleDays = cleanupStaleDays
        self.cleanupDefaultStaticGroupID = cleanupDefaultStaticGroupID
        self.cleanupDefaultSiteID = cleanupDefaultSiteID
        self.protectEnabled = protectEnabled
        self.protectURL = protectURL
        self.protectClientID = protectClientID
        self.protectPassword = protectPassword
        self.entraTenantId = entraTenantId
        self.entraClientId = entraClientId
        self.entraClientSecret = entraClientSecret
        self.entraCertPEM = entraCertPEM
        self.features = features
        self.authentication = authentication
        self.showAnnouncements = showAnnouncements
        self.showSettings = showSettings
        self.userInterfaceExtras = userInterfaceExtras
        self.uiDeviceTabs = uiDeviceTabs
        self.uiDeviceActionLabels = uiDeviceActionLabels
        self.uiHealthCardLabels = uiHealthCardLabels
        self.signIn = signIn
    }

    // MARK: - Composition from the four managed domains

    /// Composes the flat consumer surface from the four domain models plus
    /// the Keychain-held secrets. Any absent domain contributes its documented
    /// defaults; validity (isConfigured) is judged by the aggregation layer,
    /// never here.
    init(
        core: CoreConfiguration?,
        secrets: ManagedSecrets,
        access: AccessConfiguration?,
        features: FeaturesConfiguration?,
        ui: UserInterfaceConfiguration?
    ) {
        let jamfPro = core?.jamfPro
        let uiSettings = ui?.userInterface

        // ABM identity is only surfaced when the block is delivered AND
        // enabled; the private key rides along from the Keychain.
        var abmClientId: String? = nil
        var abmKeyId: String? = nil
        var abmPrivateKey: String? = nil
        if let abm = core?.appleBusinessManager, abm.effectiveEnabled {
            abmClientId = abm.clientID
            abmKeyId = abm.keyID
            abmPrivateKey = secrets.abmPrivateKey
        }

        // Managed sidebar override: usable ui-domain items win; otherwise
        // keep the built-in default sidebar.
        let deliveredSidebar = ui?.effectiveSidebarItems ?? []
        let managedSidebar = deliveredSidebar
            .filter { $0.isUsable }
            .map {
                SidebarItemConfig(
                    id: $0.effectiveID,
                    icon: $0.effectiveIcon,
                    title: $0.effectiveDisplayName
                )
            }
        // Falling back to the built-in sidebar silently discards a delivered
        // label/icon — say so, or an admin sees built-in rows with no clue why.
        if !deliveredSidebar.isEmpty && managedSidebar.isEmpty {
            print("⚠️ ui.sidebarItems: \(deliveredSidebar.count) item(s) delivered but none usable "
                  + "(each needs a non-empty id) — using the built-in sidebar, "
                  + "so any delivered label/icon is IGNORED")
        } else if deliveredSidebar.count != managedSidebar.count {
            let dropped = deliveredSidebar.filter { !$0.isUsable }.map { $0.effectiveID.isEmpty ? "(no id)" : $0.effectiveID }
            print("⚠️ ui.sidebarItems: skipped \(dropped.count) unusable item(s): \(dropped.joined(separator: ", "))")
        }
        let sidebarItems = managedSidebar.isEmpty
            ? MDMConfiguration.defaultSidebarItems
            : managedSidebar

        // Each of these five settings moved domains in the schema cleanup and
        // is now read ONLY from its current home — the transitional reads of
        // the old locations were removed once every deployed profile carried
        // the new layout. An undelivered key falls to its documented default,
        // exactly like any other key in its domain.
        //
        //   core.authentication              (was ui.authentication)
        //   features.userExperience.show*    (was ui.userInterface.show*)
        //   features.cleanup                 (was access.cleanup)
        //   features.localAdministration     (was core.localAdministration)

        let resolvedShowAnnouncements = features?.effectiveUserExperience.effectiveShowAnnouncements ?? true
        let resolvedShowSettings = features?.effectiveUserExperience.effectiveShowSettings ?? true
        let resolvedCleanup = features?.effectiveCleanup ?? ManagedCleanupSettings()
        let resolvedLocalAdmin = features?.effectiveLocalAdministration ?? ManagedLocalAdminSettings()

        self.init(
            jamfURL: jamfPro?.serverURL ?? "",
            masterClientID: jamfPro?.masterClientID ?? "",
            masterClientSecret: secrets.masterClientSecret ?? "",
            appTitle: uiSettings?.effectiveAppTitle ?? "FleetHub",
            appSubtitle: uiSettings?.effectiveAppSubtitle ?? "",
            sidebarItems: sidebarItems,
            requiredRoleName: jamfPro?.effectiveRequiredRoleName ?? "",
            supportURL: uiSettings?.effectiveSupportURL,
            localAdminUsername: resolvedLocalAdmin.effectiveUsername,
            connectionTimeoutSeconds: jamfPro?.effectiveConnectionTimeout ?? 30,
            requestTimeoutSeconds: jamfPro?.effectiveRequestTimeout ?? 60,
            eraseAckTimeoutSeconds: jamfPro?.effectiveEraseAckTimeoutSeconds ?? 180,
            eraseAckPollIntervalSeconds: jamfPro?.effectiveEraseAckPollIntervalSeconds ?? 15,
            userCredentialLifetimeDays: jamfPro?.effectiveUserCredentialLifetimeDays ?? 90,
            abmAPIBaseURL: (core?.appleBusinessManager?.effectiveServiceType ?? .business).apiBaseURL,
            abmOAuthScope: (core?.appleBusinessManager?.effectiveServiceType ?? .business).oauthScope,
            entraAuthorityHost: (core?.entra?.effectiveCloudInstance ?? .global).authorityHost,
            entraGraphHost: (core?.entra?.effectiveCloudInstance ?? .global).graphHost,
            abmClientId: abmClientId,
            abmKeyId: abmKeyId,
            abmPrivateKey: abmPrivateKey,
            abmDefaultMdmServerName: core?.appleBusinessManager?.effectiveDefaultMdmServerName,
            abmDefaultDeviceType: core?.appleBusinessManager?.defaultDeviceType,
            // Fail-closed: absent access domain → nil role name and no role
            // definitions → every user resolves to UserCapabilities.none.
            role: access?.role,
            // Passed as the DELIVERED ARRAY, not a pre-built index: profile
            // order is load-bearing (module order = sidebar order).
            roles: access?.effectiveRoles ?? [],
            cleanupStaleDays: resolvedCleanup.effectiveStaleDays,
            cleanupDefaultStaticGroupID: resolvedCleanup.defaultStaticGroupID,
            cleanupDefaultSiteID: resolvedCleanup.defaultSiteID,
            protectEnabled: core?.jamfProtect?.effectiveEnabled ?? false,
            protectURL: core?.jamfProtect?.url,
            protectClientID: core?.jamfProtect?.clientID,
            protectPassword: secrets.protectPassword,
            entraTenantId: core?.entra?.effectiveTenantID,
            entraClientId: core?.entra?.effectiveClientID,
            entraClientSecret: secrets.entraClientSecret,
            entraCertPEM: secrets.entraCertPEM,
            features: features,
            authentication: core?.authentication,
            showAnnouncements: resolvedShowAnnouncements,
            showSettings: resolvedShowSettings,
            userInterfaceExtras: uiSettings,
            uiDeviceTabs: ui?.deviceTabs ?? [],
            uiDeviceActionLabels: ui?.deviceActionLabels ?? [],
            uiHealthCardLabels: ui?.healthCardLabels ?? [],
            // Interactive sign-in passthrough. Absent core domain (or an
            // absent signIn block) → nil → signInMethod resolves to .email,
            // so undelivered profiles keep the email flow unchanged.
            signIn: core?.signIn
        )
        self.apiBackendRaw = core?.apiBackend
        self.platformAPI = core?.platformAPI?.connection
        self.platformClientSecret = secrets.platformClientSecret
    }
    
    /// One resolved sidebar item: a COSMETIC PRESENTATION override only —
    /// `title`/`icon` empty means "use the destination's built-in". Carries
    /// neither presence (that is the role's `modules` grant, access domain)
    /// nor order (a row's position is where its id sits in that `modules`
    /// array), so the ui domain has no say in either.
    struct SidebarItemConfig: Codable, Identifiable {
        let id: String
        let icon: String
        let title: String

        init(id: String, icon: String, title: String) {
            self.id = id
            self.icon = icon
            self.title = title
        }
    }
    
    /// The app's built-in sidebar, used when no usable managed override is
    /// delivered by the ui domain. Ids MUST be NavigationDestination raw
    /// values — unknown ids are skipped by SidebarView. (The previous list
    /// referenced routes that never existed in this app.)
    ///
    /// INVARIANT: this list MUST enumerate EVERY module id a role can grant.
    /// SidebarView renders (the user's ordered role `modules`) ∩ (this list,
    /// or the ui domain's sidebarItems override), so an id missing here can
    /// NEVER appear on a Mac that gets no sidebarItems override — the
    /// presentation layer would silently swallow a grant the admin made.
    /// This list is presentation only; it grants nothing on its own.
    ///
    /// The ORDER of this array is not meaningful — row order comes from each
    /// role's `modules` array (access domain). These entries exist to supply
    /// presence plus the built-in label/icon.
    static let defaultSidebarItems: [SidebarItemConfig] = [
        SidebarItemConfig(id: "dashboard", icon: "square.grid.2x2", title: "Overview"),
        SidebarItemConfig(id: "devices", icon: "desktopcomputer", title: "Devices"),
        SidebarItemConfig(id: "myDevices", icon: "person.crop.square", title: "My Devices"),
        SidebarItemConfig(id: "announcements", icon: "megaphone", title: "Announcements"),
        SidebarItemConfig(id: "logs", icon: "doc.text.magnifyingglass", title: "Logs"),
        SidebarItemConfig(id: "reports", icon: "chart.bar.doc.horizontal", title: "Reports"),
        SidebarItemConfig(id: "cleanup", icon: "wand.and.sparkles", title: "Cleanup"),
        SidebarItemConfig(id: "settings", icon: "gearshape", title: "Settings")
    ]

    // Default configuration (fallback when no managed domain is delivered).
    // Deliberately EMPTY connection strings — no placeholder values that a
    // consumer could mistake for real configuration; validity checks are
    // plain non-empty tests.
    static let `default` = MDMConfiguration(
        jamfURL: "",
        masterClientID: "",
        masterClientSecret: "",
        appTitle: "FleetHub",
        appSubtitle: "",
        sidebarItems: defaultSidebarItems,
        requiredRoleName: "",
        supportURL: nil,
        localAdminUsername: "macadmin",
        abmClientId: nil,
        abmKeyId: nil,
        abmPrivateKey: nil
        // No role name and no role definitions: with nothing delivered,
        // every user resolves to UserCapabilities.none. The old DEBUG
        // `role: "Admin"` shim is gone — it named a role the app invented,
        // and roles are now defined ONLY by the profile, so it could not
        // grant anything anyway. For local dev, deliver a roles ARRAY (each
        // entry names itself) plus the `role` key that selects one of them:
        //   defaults write com.herojoneslabs.fleethub.access roles '(
        //     {
        //       name = "Dev";
        //       modules = (dashboard, devices);
        //       allowExport = 1;
        //     }
        //   )'
        //   defaults write com.herojoneslabs.fleethub.access role "Dev"
    )
}
