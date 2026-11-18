# FleetHub

## Project Overview
Native macOS MDM console for Jamf Pro environments. Provides fleet health dashboards, device inventory management, unified search, and compliance monitoring. Three targets: main app, menu bar companion, and FleetHub Setup (guided admin app that produces the configuration profiles).

## Build & Run
- Open `FleetHub.xcodeproj` in Xcode
- Three schemes: `FleetHub` (main app), `FleetHubMenuBar` (companion) and `FleetHubSetup` (admin setup app)
- Requires macOS deployment target (native Mac app, not Catalyst)
- Managed configuration needed for API connectivity — for development, `defaults write` the
  suite domains (e.g. `com.herojoneslabs.fleethub.core`) or start a Debug build with `-FleetHubDemo` for sample data (compiled out of Release); the Jamf master
  client secret (and other integration secrets) are entered in-app (first-run onboarding or
  Settings → Credentials) and stored in the Keychain — NEVER in a profile or `defaults`

## Architecture
- **UI Framework:** SwiftUI with selective AppKit bridging (NSImage, NSApp appearance)
- **Data Flow:** Services → Caches (disk+memory) → ObservableObject → Views
- **Auth:** Master API client (ID from the core profile, secret from the Keychain via SecretStore) creates per-user Jamf API clients and does nothing else; every Jamf token the app uses is the per-user one from `JamfTokenProvider`. That is opt-in (`authentication.autoCreateUserApiClient` = true, Entra sign-in only). With the default, false, there is no master client at all: each operator enters a pre-created client (`OwnJamfAPIClient`)
- **APIs:** Jamf Pro V1 (computers), V2 (mobile devices), ABM (AppleCare via ES256 JWT)
- **State:** Singleton services + @Published properties + Combine observers

## Key Conventions
- Async/await for all networking (no completion handlers)
- Diagnostics go through `AppLog.notice` / `AppLog.error` (Utilities/AppLog.swift), never `NSLog` or `print`: interpolated values are private in the unified log unless they are numbers, Booleans, or marked `privacy: .public`. `NSLog` is left only inside `#if DEBUG` test hooks that read stderr
- Session-based cache invalidation (UUID rotates on app launch)
- Site-based compliance rules, entirely profile-defined (`features.healthScorecard`); the app hardcodes no site or vendor names
- ThemeColors utility for all adaptive colors
- DeviceListItem as lightweight list representation (avoid passing full models to list views)
- PlatformType enum for all platform-specific logic (colors, icons, gradients)

## Important Gotchas
- Jamf sometimes reports iPads as iOS — detection uses model identifier fallback
- Computer model (Computer.swift) has ~30 nested types — read carefully before modifying
- `core.apiBackend` picks the API: `jamfPro` (default) or `platform` (Jamf Platform API gateway). Call sites always build Jamf Pro paths and send with `JamfTransport.data(for:)` (Services/JamfBackend.swift), which rewrites them to `/pro` / `/proclassic` on the gateway — never call `URLSession.shared.data(for:)` for a Jamf request. The Platform backend has NO per-user clients (one integration credential for everyone); Compliance Benchmarks are Platform-only and use `JamfTokenProvider.platformToken()` on either backend. Mapping table + unverified items: README "Jamf Platform API"
- `core.apiBackend`: `jamfPro` (default) / `hybrid` (reads → Platform integration, actions + secrets → per-user client; `JamfAPIBackend.usesPlatform(for:)` is an allow-list of read scopes, routed by the token the request carries) / `platform` (everything → integration)
- The master client ONLY provisions the per-user Jamf API client at sign-in; every app function (inventory, search, actions, Cleanup) runs as the per-user client via `JamfTokenProvider.token(for:)` and fails closed without it — no routing, no master fallback
- MDMConfiguration is composed from 4 managed preference domains (com.herojoneslabs.fleethub.core /
  .access / .features / .ui) plus Keychain secrets (SecretStore), each domain read via `UserDefaults(suiteName:)` — NEVER
  `persistentDomain(forName:)` — by ManagedDomainLoader (Managers/Configuration/). No
  flat-key fallback; profile changes take effect at relaunch; missing access profile fails
  closed to role=User (see docs/Configuration.md)
- MDMConfigurationManager is the only config manager
- HealthMetricsCalculator uses Combine debouncing — changes to cache structure require updating observers

## File Organization
```
Models/          — Data models (Computer, MobileDevice, User, etc.)
Services/        — API services, caches, search, health metrics
ViewModels/      — AuthViewModel (primary view model)
Managers/        — Keychain, biometric auth, MDM config
Utilities/       — Device icon provider
Views/           — All SwiftUI views organized by feature
  Authentication/  — Welcome, login, biometric flows
  Dashboard/       — Health scorecard, device counts, search
  Device/          — Device lists and detail views
  MyDevices/       — Read-only self-service view of the signed-in user's own devices
  Sidebar/         — Navigation sidebar
  Components/      — Shared UI components
  Announcement/    — Announcement feed
  Reports/         — Report builder
  Settings/        — App preferences
  Enrollments/     — DEP enrollment tracking
MenuBarApp/      — Menu bar companion target
Data/            — Mock data for previews
```
