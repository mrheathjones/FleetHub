# Jamf API Privileges

Which Jamf Pro API privileges each FleetHub function needs. FleetHub Setup works the same lists out for you from the roles you define; this page is the reference behind it.

FleetHub authenticates to Jamf Pro with API Clients (OAuth 2.0 client credentials). Two identities
are involved, with strictly separate jobs:

- **Per-user client** — one per signed-in operator. **Every app function runs as this client**:
  search, inventory, reports, MDM commands, Cleanup, PreStage, Move to Site and sensitive reads.
  Jamf's own audit log therefore names the person for everything. Calls are **fail-closed**: if
  the operator's client is missing or its role lacks a privilege, the call errors — there is no
  fallback to the master client.
  - **Which Jamf API Role it carries** comes from the operator's FleetHub role: each entry in
    `access → roles` can name one with **`jamfApiRoleName`**. A role that names none uses the
    default `core → jamfPro → requiredRoleName`. Someone holding several roles gets every named
    Jamf role. So an admin role and a technician role can map to different Jamf API Roles from
    the same profiles.
  - Give each Jamf API Role **exactly the privileges below for the functions that FleetHub role
    grants**.
  - The mapping is re-checked at sign-in and at every launch/unlock. When it changes (a role is
    added, removed or re-mapped) the master client sets the operator's client to exactly the new
    set, so a demotion removes Jamf privileges as well as app features.
- **Master client** — ID from the `core` profile, secret from the Keychain (Settings →
  Credentials). It is used for **one thing only**: provisioning the operator's per-user client at
  sign-in when it does not exist yet (see "Provisioning per-user API clients" below). Its API role needs only those
  provisioning privileges and should hold nothing else.

> The OAuth token endpoints (`/api/v1/oauth/token`, `/api/v1/auth/invalidate-token`) need **no**
> privilege — only a valid API Client with a role attached.

Privileges are the exact strings from the Jamf Pro **API Roles and Clients** privilege picker.
Verified against the Jamf Pro API OpenAPI (`developer.jamf.com`) 2026-07.

| Function | Jamf Pro API privileges | Backing endpoints |
| --- | --- | --- |
| `mdmCommands` — restart, shut down, lock, unlock account, Bluetooth, remote desktop, blank push | **Send MDM command information in Jamf Pro API**, **View MDM command information in Jamf Pro API**, **Read Computers**, **plus one `Send Computer …` privilege per command** (table below) | `POST/GET /api/v2/mdm/commands`, `POST /api/v2/mdm/blank-push` |
| `returnToService` — erase + Jamf record delete | **Send MDM command information in Jamf Pro API**, **View MDM command information in Jamf Pro API**, **Send Computer Remote Wipe Command**, **Delete Computers**, **Read Computers** | `POST/GET /api/v2/mdm/commands` (`ERASE_DEVICE` + ack poll), `DELETE /api/v1/computers-inventory/{id}` |
| `sensitiveReads` — LAPS password + FileVault key, and Screen Share automatic sign-in (`features → computers → screenShareAutoSignIn`, off by default) | **View Local Admin Password**, **View Disk Encryption Recovery Key** | `GET /api/v2/local-admin-password/{mgmtId}/accounts` (finds the Jamf management account, `userSource` = `JMF`), `GET /api/v2/local-admin-password/{mgmtId}/account/{user}/password`, `GET /api/v3/computers-inventory/{id}/filevault` |
| `moveToSite` | **Read Sites**, **Read Computers**, **Update Computers** (computers); **Read Mobile Devices**, **Update Mobile Devices** (mobile) | `GET /api/v1/sites`, `PATCH /api/v3/computers-inventory-detail/{id}`, `PATCH /api/v2/mobile-devices/{id}` |
| Site scoping — site names in the top-bar switcher (`siteScoping`, off by default) | **Read Sites** (optional — without it the names come from the computer inventory) | `GET /api/v1/sites` |
| `prestage` — register/assign + Inventory Preload | **Read Computer PreStage Enrollments**, **Update Computer PreStage Enrollments**, **Read Inventory Preload Records**, **Create Inventory Preload Records**, **Update Inventory Preload Records** | `GET /api/v3/computer-prestages`, `GET/POST /api/v2/computer-prestages/{id}/scope`, `GET/POST/PUT /api/v2/inventory-preload/records`, `GET /api/v2/inventory-preload/csv-template`, `POST /api/v2/inventory-preload/csv-validate` |
| `cleanup` — stale listing + deletes | **Read Computers**, **Delete Computers**, **Read Sites**, **Read Static Computer Groups**, **Update Static Computer Groups** | `GET /api/v3/computers-inventory[-detail]`, `DELETE /api/v3/computers-inventory/{id}`, `GET /api/v1/sites`, `GET /api/v3/computer-groups/static-groups`, `PUT /JSSResource/computergroups/id/{id}` |
| `deviceSearch` — search + device detail + **My Devices** | **Read Computers**, **Read Mobile Devices**, plus **Read Users** for My Devices' identity match (optional — without it that module matches on the sign-in address alone) | `GET /api/v1/computers-inventory`, `GET /api/v2/mobile-devices`, `GET /api/v2/mobile-devices/detail`, `GET /api/v1/users` |
| `inventory` — dashboard counts + health | **Read Computers**, **Read Mobile Devices** | `GET /api/v1|v3/computers-inventory`, `GET /api/v2/mobile-devices/detail` |
| `reports` | **Read Computers**, **Read Mobile Devices** | `GET /api/v2/mobile-devices/detail` (+ inventory reads) |

## Provisioning per-user API clients

When `core → authentication → autoCreateUserApiClient` is **true** (it is off by default), the master
client creates a Jamf API client for each operator who doesn't have one and assigns it the Jamf
API Role(s) their FleetHub role maps to (see above). That is a **master-role-only** capability and needs:

| Privilege | Why |
| --- | --- |
| **Read API Integrations** | Find an operator's existing client (`GET /api/v1/api-integrations`) |
| **Create API Integrations** | Create the client (`POST /api/v1/api-integrations`) |
| **Update API Integrations** | Enable it, assign/repair its role, rename it, and mint its secret (`PUT /api/v1/api-integrations/{id}`, `POST .../client-credentials`) |
| **Read API Roles** | Resolve the configured role name (`GET /api/v1/api-roles`) |

Clients are named **`<UPN> (<clientId>)`** — Jamf's audit log records the *client id* that ran a
command, so carrying the id in the name is what maps an audited action back to a person. A client whose name lacks the id is renamed on the operator's next sign-in. The UPN stays the name's
prefix, which is how FleetHub looks the client up.

### Without a provisioning client

With `autoCreateUserApiClient` left at **false** (the default), FleetHub never creates or changes
an API client, and needs no provisioning client ID or secret. Instead:

1. Create a Jamf API role for each FleetHub role, with the privileges in the table above.
2. Create an API client for each operator and attach the API role for their FleetHub role.
3. Give the operator the client ID and secret. FleetHub asks for them once (on its setup
   screen, or later under Settings → Credentials), checks them with Jamf, and keeps them in
   that person's Keychain.

The client is tied to the first person who signs in with it and survives sign-out. If someone
else signs in on the same Mac account, or Jamf stops accepting the client, FleetHub forgets it
and asks again. When an operator's role changes, change the API role on their client in Jamf
Pro; FleetHub does not sync it in this mode. Both sign-in methods work this way.

**Not part of these Jamf roles** (separate credentials): Apple Business Manager lookup (ABM API
client), Jamf Protect cleanup (Protect API client), and the Return-to-Service **Entra**
device-object delete (Microsoft Graph app registration — `Device.ReadWrite.All` + Cloud Device
Administrator).

## MDM commands: one privilege per command type

The `/api/v2/mdm/commands` OpenAPI lists only *View MDM command information in Jamf Pro API*, but
that is **not sufficient**. Jamf enforces three layers, and the role needs all of them:

1. **Send MDM command information in Jamf Pro API** — permission to POST a command at all.
2. **View MDM command information in Jamf Pro API** — read command status (the Return-to-Service
   flow polls for the erase acknowledgment).
3. **A `Send Computer …` privilege matching the specific command type.**

Missing #3 yields a 403 whose bracketed token names the command type — e.g. the Bluetooth toggle
is sent as a `SETTINGS` command:

```json
{ "httpStatus": 403, "errors": [ { "code": "INVALID_PRIVILEGE",
  "description": "User <clientId> not privileged for [SETTINGS]" } ] }
```

Command types FleetHub sends, and the privilege each needs (names verified against a Jamf Pro
instance's `GET /api/v1/api-role-privileges`, 2026-07):

| FleetHub action | MDM command type | Required privilege |
| --- | --- | --- |
| Enable/Disable Bluetooth | `SETTINGS` | **Send Computer Bluetooth Command** |
| Enable/Disable Remote Desktop | `ENABLE_/DISABLE_REMOTE_DESKTOP` | **Send Computer Remote Desktop Command** |
| Restart | `RESTART_DEVICE` | **Send Computer Restart Command** |
| Shut Down | `SHUT_DOWN_DEVICE` | **Send Computer Shut Down Command** |
| Wipe / Return-to-Service erase | `ERASE_DEVICE` | **Send Computer Remote Wipe Command** |
| Lock | `DEVICE_LOCK` | **Send Computer Remote Lock Command** (+ **View Computer Device Lock Pin** to display the PIN) |
| Unlock User Account | `UNLOCK_USER_ACCOUNT` | **Send Computer Unlock User Account Command** |
| Blank Push | `POST /api/v2/mdm/blank-push` | **Send MDM command information in Jamf Pro API** (the `Send Blank Pushes to Mobile Devices` privilege is mobile-only) |

Privilege strings vary by Jamf version — list the exact set your instance offers with:

```sh
curl -s "$JAMF_URL/api/v1/api-role-privileges" \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/json" \
  | jq -r '.privileges[]' | grep -iE "bluetooth|send computer|mdm command"
```

Role changes apply immediately, but FleetHub caches the per-user token for up to an hour — sign out
and back in to force a fresh one.

**Full per-user role**: the union of the table above — Read/Update/Delete Computers, Read/Update
Mobile Devices, Read Sites, Read/Update Static Computer Groups, Read/Update Computer PreStage
Enrollments, Read/Create/Update Inventory Preload Records, Send and View MDM command information
in Jamf Pro API (plus the per-command `Send Computer …` privileges), View Local Admin Password,
and View Disk Encryption Recovery Key. Trim it to the functions your access profile actually
grants; anything left out fails closed for that operator.
