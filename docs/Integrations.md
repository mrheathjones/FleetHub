# Integrations

What each service FleetHub connects to needs: what to create there, which values go in the
Core profile, which secret goes in the Keychain, and how to check it works.

Only Jamf Pro is required. Everything else is optional and is switched on by adding its block
to the Core profile (`com.herojoneslabs.fleethub.core`) and entering its secret. FleetHub Setup
has a field for every value named here.

| Service | Used for | Guide |
| --- | --- | --- |
| Jamf Pro | Everything | [Jamf Pro](#jamf-pro) |
| Microsoft Entra ID (sign-in) | Signing in, and deciding each person's role | [EntraAuthSetup.md](EntraAuthSetup.md) |
| Apple Business Manager | Device lookup, AppleCare coverage, assign and unassign | [Apple Business Manager](#apple-business-manager) |
| Microsoft Entra ID (device cleanup) | Deleting a Mac's Entra device object in Return to Service | [Microsoft Entra Device Cleanup](#microsoft-entra-device-cleanup) |
| Jamf Protect | Protect counts and record deletion in Cleanup | [Jamf Protect](#jamf-protect) |
| Jamf Platform API | Compliance Benchmarks; optionally all reads | [PlatformAPI.md](PlatformAPI.md) |
| Jamf LAPS, SSH, Screen Share | Local admin passwords and remote sessions | [Jamf LAPS, SSH and Screen Share](#jamf-laps-ssh-and-screen-share) |

Secrets are never put in a profile. They are typed into FleetHub (first launch, or **Settings →
Credentials**) or delivered by the policy script in [CredentialDelivery.md](CredentialDelivery.md).

---

## Jamf Pro

**What to create** (Jamf Pro → Settings → System → API Roles and Clients)

- An **API role for each FleetHub role**, holding the privileges that role's capabilities
  need. [JamfAPIPrivileges.md](JamfAPIPrivileges.md) lists them by function, and FleetHub
  Setup lists them per role.
- **API clients.** Either one per person (automatic creation off, the default), or one
  provisioning client (automatic creation on). See [SetupGuide.md](SetupGuide.md) section 2.

**Core profile**

| Key | Value |
| --- | --- |
| `jamfPro.serverURL` | `https://yourorg.jamfcloud.com`, no trailing slash. Required. |
| `jamfPro.masterClientID` | The provisioning client's ID. Only with automatic creation on. |
| `jamfPro.requiredRoleName` | Fallback Jamf API role name for FleetHub roles that name none. |
| `authentication.autoCreateUserApiClient` | `true` to let FleetHub create each person's client. Default `false`. |

**Access profile:** each entry in `roles` names its Jamf API role in `jamfApiRoleName`.

**Secret:** the person's own client ID and secret (automatic creation off), or the
provisioning client's secret (on).

**Check:** sign in; Overview shows device counts. A function the person's FleetHub role grants
but their Jamf API role lacks fails with a permission message and nothing wider is tried.

---

## Apple Business Manager

Works with Apple Business Manager and Apple School Manager. It adds:

- The **ABM Lookup** tab under Devices: every device in your organization, its assigned
  device management service, and filters.
- **AppleCare coverage** on device pages and in reports.
- **Assign to MDM Server** and **Unassign**, for roles you allow.
- An optional **PreStage registration** step after an assignment.

### What to create

In Apple Business Manager (or Apple School Manager), signed in as an administrator:

1. Create an **API account**. Apple's guide:
   [Create an API account](https://support.apple.com/guide/business/axm33189f66a/web).
   Apple's menus have changed over time, so follow the guide for the current location.
2. Give the account a role that can read devices and, if you want FleetHub to assign and
   unassign, manage device assignments.
3. **Generate and download the private key.** It is a `.pem` file and can be downloaded once.
4. Copy the account's **Client ID** (it looks like `BUSINESSAPI.xxxxxxxx-…` or
   `SCHOOLAPI.…`) and **Key ID**.

### Core profile

```xml
<key>appleBusinessManager</key>
<dict>
    <key>enabled</key>
    <true/>
    <key>clientID</key>
    <string>BUSINESSAPI.00000000-0000-0000-0000-000000000000</string>
    <key>keyID</key>
    <string>00000000-0000-0000-0000-000000000000</string>
    <key>serviceType</key>
    <string>business</string>
</dict>
```

| Key | Value |
| --- | --- |
| `enabled` | `true`. Absent means off. |
| `clientID` | The API account's Client ID. |
| `keyID` | The Key ID of the private key. |
| `serviceType` | `business` (default) or `school`. It selects the API host and the token scope. |
| `defaultMdmServerName` | Optional. Preselects the server filter on the ABM Lookup tab, by name. |
| `defaultDeviceType` | Optional. `all`, `mac`, `iphone`, `ipad`, `appletv`, `watch` or `vision`. |

### Secret

The private key, the whole `.pem` file including its `BEGIN` and `END` lines. Enter it in
**Settings → Credentials → Apple Business Manager Private Key**, or deliver it by policy
(parameters 8 and 9 of the credential script; the key goes in base64-encoded, and FleetHub
Setup has an encoder for it).

FleetHub treats ABM as configured only when the Client ID, the Key ID and the key are all
present.

### Access profile

A role sees nothing of ABM until its entry in `roles` grants it:

| Key in the role | Grants |
| --- | --- |
| `deviceTabs` containing `abmLookup` | The ABM Lookup tab (the role also needs the `devices` module) |
| `computerActions` containing `abmAssign`, `abmUnassign` | The two actions on a device page and in ABM Lookup |
| `allowedMdmServers` | Which servers the role may assign to or unassign from. Names must match Apple's server names exactly; the literal `all` allows every server. Empty means none. |
| `allowPrestageOnAssign`, `allowedPrestages` | Whether a PreStage step is offered after an assignment, and which PreStages |

### Check

1. **Settings → Credentials** shows the key as saved.
2. **Devices → ABM Lookup** lists your devices and servers. The first load of a large
   organization takes a while; later loads use a cache on disk.
3. Search a serial number, open it, and compare its assigned server with Apple's site.
4. If you granted assignment, assign a test device and confirm the change at Apple.

### Notes

- **Network.** FleetHub calls `account.apple.com` for tokens and `api-business.apple.com` (or
  `api-school.apple.com`) for data. A proxy that inspects TLS to those hosts can break long
  loads; exempt them if the tab fails to load.
- **Assignment is asynchronous.** Apple accepts the request and completes it shortly after.
  FleetHub waits for the result and reports it, including Apple's per-device errors.
- **An unassigned device** is shown as "Not Assigned to Any MDM Server". FleetHub reads this
  from Apple's "not found" answer for the device's assigned server, which is an inference
  from how the API behaves rather than documented behaviour.
- **Rotation.** Generate a new key at Apple, update `keyID` in the Core profile, deliver the
  new key, then revoke the old one.

---

## Microsoft Entra Device Cleanup

Return to Service can delete the Mac's device object from Microsoft Entra after the erase is
acknowledged, so the Mac re-registers cleanly. This uses an app-only identity and is separate
from sign-in: do not reuse the sign-in app registration, which is a public client and has no
secret.

### What to create

In the Microsoft Entra admin center:

1. **App registrations → New registration.** Single tenant. No redirect URI.
2. **API permissions → Add → Microsoft Graph → Application permissions →
   `Device.ReadWrite.All`**, then **Grant admin consent**.
3. **Roles and administrators → Cloud Device Administrator → Add assignment**, and assign the
   app registration's service principal. Without this role Graph refuses the delete with a
   403 even though the permission is granted.
4. **Certificates & secrets.** Create either:
   - a **certificate** (preferred): upload the public certificate to the registration and
     keep the certificate and its private key as PEM, or
   - a **client secret**.
5. Note the **Directory (tenant) ID** and the **Application (client) ID**.

### Core profile

```xml
<key>entra</key>
<dict>
    <key>tenantID</key>
    <string>00000000-0000-0000-0000-000000000000</string>
    <key>clientID</key>
    <string>00000000-0000-0000-0000-000000000000</string>
</dict>
```

| Key | Value |
| --- | --- |
| `tenantID` | The Directory (tenant) ID. |
| `clientID` | The Application (client) ID of the cleanup registration. |
| `cloudInstance` | `global` (default), `usgov` or `china`. |

### Secret

One of, in **Settings → Credentials**:

- **Microsoft Entra Certificate (PEM):** the certificate followed by its unencrypted RSA
  private key, both in PEM. Used in preference to the secret when both are saved.
- **Microsoft Entra Client Secret.** The policy script can deliver this one (parameters 10
  and 11).

### Access profile

The role that may run Return to Service decides whether the Entra object is deleted:

```xml
<key>returnToServiceOptions</key>
<dict>
    <key>deleteJamfRecord</key>
    <true/>
    <key>deleteEntraObject</key>
    <true/>
</dict>
```

### How it behaves

- The erase always runs first. No cleanup step runs until the Mac acknowledges the erase
  command; if it never does, the Jamf record and the Entra object are left alone.
- FleetHub finds the Entra device by **display name**, matching the Mac's computer name, and
  deletes every match. If your Entra device names do not match your Jamf computer names,
  nothing is found and nothing is deleted.
- Cleanup is best effort: a failure is reported and logged, and does not undo the erase.

### Check

Run Return to Service on a test Mac that is registered in Entra. The result names how many
Entra objects were deleted. A 403 means the Cloud Device Administrator role is missing; "no
match" means the names differ.

---

## Jamf Protect

Adds Jamf Protect counts to Cleanup and lets roles with the `deleteFromProtect` cleanup action
remove a Mac's Protect record. There are two ways to connect; use one.

### Through the Jamf Platform API (preferred)

If you have a Platform integration (see [PlatformAPI.md](PlatformAPI.md)), FleetHub sends
Protect requests through it. No Protect URL, client or password is needed.

| Core key | Value |
| --- | --- |
| `jamfProtect.enabled` | `true` |
| `platformAPI.protectTenantID` | The Jamf **Protect** tenant's ID from Jamf Account. It is a different value from the Jamf Pro tenant ID. |

The integration needs `devices:read`, plus `devices:delete` if any role may delete Protect
records.

### With a Protect API client

In the Jamf Protect console, create an **API client** (under its administrative settings) with a
role that can read computers and, if you want deletion, delete them. Note its client ID and
password.

| Core key | Value |
| --- | --- |
| `jamfProtect.enabled` | `true` |
| `jamfProtect.url` | `https://yourorg.protect.jamfcloud.com` |
| `jamfProtect.clientID` | The API client's ID |

**Secret:** the API client's password, in **Settings → Credentials → Jamf Protect API
Password**. It is typed in; the policy script does not deliver it.

### Check

Open **Cleanup**. The Protect count appears, and the Protect device list loads.

---

## Jamf LAPS, SSH and Screen Share

These features have no credential of their own. They read passwords through the person's own
Jamf API client, so what they need is set up in Jamf Pro and on the managed Macs.

### In Jamf Pro

- **Turn on Local Administrator Password Solution** in Jamf Pro's Local Admin Password settings, and
  note the **Password Rotation Time** (how long after a view Jamf rotates the password).
- The person's **Jamf API role** needs **View Local Admin Password**. Add **View Local Admin
  Password Audit History** so the rotation countdown shows the real time; without it the
  countdown is an estimate and is labelled as one.
- For the FileVault Key action, the role needs the privilege to view FileVault recovery keys,
  and Macs must escrow their personal recovery key to Jamf.

### Features profile

| Key | Value |
| --- | --- |
| `localAdministration.enabled` | `true` to offer Local Admin Password. |
| `localAdministration.username` | Short name of the managed local administrator account whose password is looked up. |
| `computers.sshPort` | Port for the SSH action. Default 22. |
| `computers.sshPasswordRotationMinutes` | Match Jamf's Password Rotation Time. Used when the real time cannot be read. Default 60. |
| `computers.screenShareAutoSignIn` | `true` to sign Screen Share in with the management account. Default `false`, because it passes the password to macOS in a `vnc://` address. |
| `computers.vpnIPExtensionAttributeID` | If an extension attribute holds each Mac's VPN address, its numeric ID. FleetHub then connects to that address. |
| `computers.screenSharePrompt` | `true` to ask the person at the Mac before Screen Share opens. Default `false`. See *Asking before Screen Share* below. |
| `computers.screenSharePromptMethod` | What shows the prompt: `fleethubPrompt`, `swiftDialog` or `jamfHelper` (default). |
| `computers.screenSharePromptTitle`, `…Message`, `…IconPath` | The prompt's wording and image. In the message, `{technician}` and `{device}` are filled in. The icon path is a path on the Mac being supported. |
| `computers.screenSharePromptTimeoutSeconds` | Seconds to answer; no answer is a Deny. Default 60 (10 to 300). |
| `computers.screenSharePromptAllowWhenNoUser` | With nobody logged in, `true` (default) opens the session and `false` refuses it. |
| `computers.screenSharePromptExemptComputerGroupIds` | Jamf computer group IDs (smart or static) whose Macs are never prompted. |
| `computers.screenSharePromptExemptSiteIds` | Jamf site IDs whose Macs are never prompted. `-1` = Macs in no site. |

### Access profile

Grant the actions per role in `computerActions`: `viewLocalAdminPassword`, `viewFileVaultKey`,
`ssh`, `screenShare`. Screen Share's automatic sign-in and the Copy Password buttons also
need `viewLocalAdminPassword`.

While `computers.screenSharePrompt` is on, a role with `screenShareWithoutPrompt = true` opens
Screen Share without asking. Leave it unset on roles that must be allowed by the person at the
Mac. A person who holds any exempt role is not prompted.

### On the managed Macs

| Feature | Needs |
| --- | --- |
| SSH | **Remote Login** on, and the Jamf management account allowed to use it. FleetHub cannot turn it on. |
| Screen Share | **Remote Management** or Screen Sharing on. FleetHub's Enable Remote Desktop action can turn Remote Management on through Jamf. |
| Both | The technician's Mac must be able to reach the Mac's address: the VPN address when you collect one, otherwise the address in Jamf inventory. |
| Screen Share approval prompt | **Remote Login** on (the prompt is shown over SSH), the management account an administrator, and the prompt tool you chose: the **FleetHub Prompt** package, swiftDialog, or nothing extra for jamfHelper. |

### Asking before Screen Share

With `computers.screenSharePrompt` on, clicking Screen Share first shows an **Allow / Deny**
prompt on the Mac being supported, and the session opens only on Allow. Roles you exempt with
`screenShareWithoutPrompt` skip it.

**FleetHub applies this, not macOS.** The prompt is a step FleetHub runs before it opens
Screen Sharing. Someone who holds the management account's password can still connect with
Apple's Screen Sharing app directly, without FleetHub and without the prompt. Treat it as a
courtesy and an audit record, not as a security boundary.

How it works:

1. FleetHub signs in to the Mac over SSH with the Jamf management account (the same way the
   SSH action does), so the person's Jamf API role needs **View Local Admin Password**. The
   role does not need the `ssh` or `viewLocalAdminPassword` actions: no terminal opens and the
   password is not shown.
2. It starts the prompt in the logged-in person's session and waits for the answer.
3. Allow opens the session. Deny, no answer in time, or a prompt that could not be shown
   (Remote Login off, tool not installed, sign-in refused) all refuse it, and FleetHub says
   which. The request and its result are recorded in the action log.

Choosing what shows the prompt (`screenSharePromptMethod`):

| Value | Shows | Needs on the Macs being supported |
| --- | --- | --- |
| `fleethubPrompt` | A FleetHub-branded window with a countdown. | The **FleetHub Prompt** package (`FleetHubPrompt-<version>.pkg`), installed with a Jamf policy. It installs to `/Library/Application Support/FleetHub/` and does nothing until FleetHub starts it. |
| `swiftDialog` | A swiftDialog window with your title, message and icon. | swiftDialog at `/usr/local/bin/dialog`. |
| `jamfHelper` | A plain Jamf window with your title, message and icon. | Nothing: it is part of the Jamf framework. |

Macs that are never prompted. Kiosks, signage and other Macs with nobody at them cannot
answer. List their Jamf computer group in `screenSharePromptExemptComputerGroupIds`, or their
site in `screenSharePromptExemptSiteIds`, and Screen Share opens on them without the prompt
for every role. A smart group keeps the list current by itself. The action log records each
session that skipped the prompt this way. A Mac whose groups cannot be read is prompted.

Things to know:

- A locked or unattended Mac cannot answer, so the request times out and is refused.
- Cancelling in FleetHub stops waiting, but a prompt already on the Mac's screen stays until
  it is answered or times out. Its answer is then ignored.
- In the FleetHub Prompt app neither button is the default, so Return does not answer by
  accident; Escape and closing the window are a Deny.

### Check

On a test Mac: Local Admin Password opens a panel with a countdown; SSH opens a terminal
window signed in as the management account; Screen Share opens Apple's Screen Sharing with a
FleetHub panel beside it. [Features.md](Features.md) describes each in detail.
