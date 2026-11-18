# Jamf Platform API

FleetHub can reach Jamf through the **Jamf Platform API gateway** instead of the Jamf Pro API.
The choice is the Core profile's `apiBackend` key:

| `apiBackend` | Base URL | Who the calls run as |
| --- | --- | --- |
| `jamfPro` (default) | `core → jamfPro → serverURL` | The signed-in operator's own Jamf Pro API client |
| `hybrid` | Reads: the gateway. Actions: `serverURL` | Reads: the Platform integration. Actions and secrets: the operator's own Jamf Pro API client |
| `platform` | `https://{region}.api.jamfcloud.com` | The one Platform integration in `core → platformAPI` |

**Hybrid.** The Platform API has no per-user API clients, so `platform` gives up Jamf's
per-person audit. `hybrid` keeps it where it matters. Each call carries a scope, and
`JamfAPIBackend.usesPlatform(for:)` decides the credential:

| Runs as the Platform integration (gateway) | Runs as the operator's own client (Jamf Pro API) |
| --- | --- |
| `inventory` — Overview counts, health | `mdmCommands` — restart, lock, Bluetooth, … |
| `deviceSearch` — search, device details, device history, My Devices | `returnToService` — wipe, Return to Service |
| `reports` — reports and scorecard | `sensitiveReads` — local admin password, FileVault key, Screen Share sign-in |
| Compliance Benchmarks (Platform-only) | `moveToSite`, `prestage`, `cleanup`, `declarativeStatus` |

The list on the left is an allow-list: a new scope is per-user until it is added. The request
is routed by the token it was built with, so a per-user token is never sent to the gateway and
the Platform token is never sent to Jamf Pro. Hybrid needs **both** credentials on each Mac
(the Platform secret and the master/provisioning secret). The operator's Jamf API role still
needs **Read Computers** / **Read Mobile Devices**, because action flows read the device
record as part of the action.

**How the switch works.** Every service is written once, against Jamf Pro API paths
(`{serverURL}/api/v2/…`). One function, `JamfTransport.prepare` in
[`FleetHub/Services/JamfBackend.swift`](../FleetHub/Services/JamfBackend.swift), rewrites those
requests for the gateway when `apiBackend` is `platform` and adds the scope header
(`X-Tenant-Id`). Requests to other hosts (Entra, Apple Business Manager, Jamf Protect) are never
touched. `serverURL` is still required on the Platform backend, because call sites build their
paths against it.

**The integration.** Create it in Jamf Account (`account.jamf.com` → **APIs** → **Create
Credential**), choosing the region, the API scope and the environment. Put the region, client
ID, tenant ID and environment ID in `core → platformAPI`; enter the client secret in the app
(Settings → Credentials, stored in the Keychain — never in a profile). Tokens last 15 minutes
and are re-minted automatically. **Integrations expire after six months** and must be renewed
in Jamf Account.

**No per-user clients on the Platform backend.** The gateway does not offer Jamf Pro's token
endpoint, API integrations or API roles, so FleetHub cannot provision a personal client for
each operator there. Every operator on the Mac acts as the one integration: Jamf's audit log
names the integration, and FleetHub's own action log (Logs) is what names the person. The
app's role gating (`access → roles`) still decides what each person can do. `jamfApiRoleName`
and `requiredRoleName` are not used on this backend.

**`platformAPI` without switching.** Filling in `platformAPI` while `apiBackend` stays
`jamfPro` enables **Compliance Benchmarks** only — they exist solely on the Platform API — and
leaves everything else on per-user Jamf Pro clients.

## Endpoint mapping

Path rule: `{serverURL}/api/v{n}/…` → `{gateway}/pro/v{n}/…`, and `{serverURL}/JSSResource/…` →
`{gateway}/proclassic/…`. The one version change is computer inventory, which is `v4` on the
gateway. Permissions use the Platform format `{capability}:{action}`; ones marked *(inferred)*
were not read from Jamf's reference and should be confirmed in Jamf Account.

| FleetHub uses | Jamf Pro API call | Platform gateway call | Platform permission |
| --- | --- | --- | --- |
| Inventory, search, health, reports, My Devices | `GET /api/v1/computers-inventory` | `GET /pro/v4/computers-inventory` | `devices:read` |
| Cleanup stale listing | `GET /api/v3/computers-inventory` | `GET /pro/v4/computers-inventory` | `devices:read` |
| Device detail | `GET /api/v1/computers-inventory/{id}` | `GET /pro/v4/computers-inventory/{id}` | `devices:read` |
| Cleanup delete, Return to Service delete | `DELETE /api/v3/computers-inventory/{id}` | `DELETE /pro/v4/computers-inventory/{id}` | `destructive-device-actions:execute` *(inferred)* |
| Move to Site, Cleanup re-site (computers) | `PATCH /api/v3/computers-inventory-detail/{id}` | `PATCH /pro/v4/computers-inventory-detail/{id}` | `devices:update` *(inferred)* |
| FileVault recovery key | `GET /api/v3/computers-inventory/{id}/filevault` | `GET /pro/v4/computers-inventory/{id}/filevault` | not confirmed |
| Mobile inventory, search, reports, My Devices | `GET /api/v2/mobile-devices`, `GET /api/v2/mobile-devices/detail` | `GET /pro/v2/mobile-devices`, `GET /pro/v2/mobile-devices/detail` | `devices:read` |
| Mobile device detail | `GET /api/v2/mobile-devices/{id}/detail` | `GET /pro/v2/mobile-devices/{id}/detail` | `devices:read` |
| Move to Site (mobile) | `PATCH /api/v2/mobile-devices/{id}` | `PATCH /pro/v2/mobile-devices/{id}` | `devices:update` |
| MDM commands (restart, lock, erase, Bluetooth, …) | `POST /api/v2/mdm/commands` | `POST /pro/v2/mdm/commands` | `device-actions:execute` *(inferred)*; erase also `destructive-device-actions:execute` *(inferred)* |
| Command status, erase acknowledgment | `GET /api/v2/mdm/commands` | `GET /pro/v2/mdm/commands` | `device-actions:read` |
| Blank push | `POST /api/v2/mdm/blank-push` | `POST /pro/v2/mdm/blank-push` | `device-actions:execute` |
| LAPS accounts (Screen Share sign-in) | `GET /api/v2/local-admin-password/{mgmtId}/accounts` | `GET /pro/v2/local-admin-password/{mgmtId}/accounts` | `local-admin-passwords:read` |
| LAPS password | `GET /api/v2/local-admin-password/{mgmtId}/account/{user}/password` | `GET /pro/v2/local-admin-password/{mgmtId}/account/{user}/password` | `local-admin-passwords:read` *(inferred)* |
| Sites | `GET /api/v1/sites` | `GET /pro/v1/sites` | `sites:read` |
| PreStage list | `GET /api/v3/computer-prestages` | `GET /pro/v3/computer-prestages` | `prestage-enrollments:read` |
| PreStage scope read | `GET /api/v2/computer-prestages/scope`, `GET /api/v2/computer-prestages/{id}/scope` | `GET /pro/v2/computer-prestages/scope`, `GET /pro/v2/computer-prestages/{id}/scope` | `prestage-enrollments:read` |
| PreStage scope change | `POST /api/v2/computer-prestages/{id}/scope` (and delete-multiple) | `POST /pro/v2/computer-prestages/{id}/scope` | `prestage-enrollments:update` *(inferred)* |
| Inventory Preload | `GET/POST/PUT /api/v2/inventory-preload/records`, `csv-template`, `csv-validate` | `/pro/v2/inventory-preload/…` | not confirmed |
| My Devices identity match | `GET /api/v1/users` | `GET /pro/v1/users` | `users:read` |
| DDM status items | `GET /api/v1/ddm/{mgmtId}/status-items` | `GET /pro/v1/ddm/{mgmtId}/status-items` | `devices:read` *(inferred)* |
| Cleanup static groups | `GET /api/v3/computer-groups/static-groups` | `GET /pro/v3/computer-groups/static-groups` | `device-groups:read` |
| Cleanup unmanage | `POST /api/v1/computer-inventory/{id}/remove-mdm-profile` | `POST /pro/v1/computer-inventory/{id}/remove-mdm-profile` | not confirmed |
| Connection test | `GET /api/v1/jamf-pro-version` | `GET /pro/v1/jamf-pro-version` | none listed |
| Device enrollments (unused view) | `GET /api/v1/device-enrollments…` | `GET /pro/v1/device-enrollments…` | not confirmed |
| Device History | `GET /JSSResource/computerhistory/id/{id}` | `GET /proclassic/computerhistory/id/{id}` | `device-history:read` |
| Cleanup add to static group | `PUT /JSSResource/computergroups/id/{id}` | `PUT /proclassic/computergroups/id/{id}` | `device-groups:update` *(inferred)* |

## Platform-only services

These exist only on the Platform API, so FleetHub reaches them with the Platform integration on
**either** backend. All take the `X-Environment-Id` header.

| Service | Call | Permission | Status |
| --- | --- | --- | --- |
| Compliance Benchmarks | `GET /compliance-benchmarks/v1/benchmarks`, `…/{id}/compliance-percentage`, `…/{id}/rules`, `…/{id}/devices?rule-id=` | `compliance-benchmarks:read` | Used |
| Device lookup (serial → platform device ID) | `GET /devices/v1/devices?filter=serialNumber=="…"` | `devices:read` | Used |
| Declaration reports | `GET /ddm/report/v1/devices/{deviceId}/declarations` | `declarations:read` | Documented as available; not yet used |

## Not available on the gateway

| Jamf Pro API call | Used for | Consequence |
| --- | --- | --- |
| `POST /api/v1/oauth/token`, `/api/v1/auth/…` | Minting and invalidating Jamf Pro tokens | The gateway issues its own token (`POST {gateway}/auth/token`) |
| `/api/v1/api-integrations` | Creating and updating per-user API clients | No per-user clients on the Platform backend |
| `/api/v1/api-roles` | Resolving the Jamf API Role | `jamfApiRoleName` / `requiredRoleName` are unused there |

`JamfTransport` throws a clear "not available through the Jamf Platform API" error if one of
these is ever requested on the Platform backend, rather than sending it.

## Unverified

**None of the gateway mapping has been run against a live tenant.** In particular, the
computer-inventory calls move from `v1`/`v3` to `v4`, and the app's decoders are assumed — not
confirmed — to accept the `v4` response shape. The exact `v4` FileVault path and the rows marked
*(inferred)* or *not confirmed* above should be checked against
[developer.jamf.com/platform-api](https://developer.jamf.com/platform-api/reference) before
relying on the Platform backend.

## Jamf Protect through the Platform API

When a Platform API integration is configured (on any backend), FleetHub sends its Jamf Protect requests (list computers, delete a record) to `POST https://{region}.api.jamfcloud.com/protect` as that integration. The scope header is `X-Tenant-Id` carrying `platformAPI.protectTenantID` — the Jamf **Protect** tenant's UUID, which is a different value from the Jamf Pro `tenantID` (a tenant ID names one product instance; the Jamf Pro one is never sent to Protect). If it is empty, `X-Environment-Id` is used instead, which Jamf may refuse for Protect. No Protect tenant URL, client ID or password is needed; Core needs `jamfProtect.enabled` and that tenant ID. The integration needs `devices:read`, plus `devices:delete` for roles that may delete Protect records. Without a Platform integration, FleetHub falls back to the Protect tenant's own API client.
