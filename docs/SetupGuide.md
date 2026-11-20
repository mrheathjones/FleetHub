# FleetHub Setup Guide

This guide takes you from a fresh download to a working FleetHub in your own environment. It
is written for the Jamf administrator. Each step links to the document that holds the detail.

FleetHub has no server of its own and nothing is configured inside the app. You will:

1. Decide a few things up front.
2. Create credentials in Jamf Pro, and in any optional service you want to connect.
3. Build and sign the app.
4. Deliver four configuration profiles and the secrets.
5. Install, sign in and check.

Allow half a day for a first setup with Microsoft Entra ID sign-in, less without it.

---

## 1. What You Need

**Always**

| Need | Why |
| --- | --- |
| A Jamf Pro tenant, with rights to create API roles and API clients | FleetHub is a front end to Jamf Pro |
| A Mac with Xcode 16 or later | To build the three apps |
| An Apple Developer ID (Application certificate, and a notarization profile) | To sign and notarize the package you deploy |
| Macs running macOS 14.0 or later for your technicians | The minimum the app supports |

**Optional, by feature**

| Feature | Needs | Guide |
| --- | --- | --- |
| Sign-in with Microsoft accounts, with roles from Entra | An Entra app registration (public client) | [EntraAuthSetup.md](EntraAuthSetup.md) |
| Apple Business Manager lookup, AppleCare coverage, assign and unassign | An Apple Business Manager API account | [Integrations.md](Integrations.md#apple-business-manager) |
| Deleting the Entra device object during Return to Service | A second Entra app registration (app-only) | [Integrations.md](Integrations.md#microsoft-entra-device-cleanup) |
| Jamf Protect counts and record deletion in Cleanup | A Jamf Protect API client, or a Jamf Platform API integration | [Integrations.md](Integrations.md#jamf-protect) |
| Compliance Benchmarks, or running reads through the Platform API | A Jamf Platform API integration | [PlatformAPI.md](PlatformAPI.md) |
| Local Admin Password, SSH and Screen Share sign-in | Jamf LAPS turned on, and remote access enabled on the Macs | [Integrations.md](Integrations.md#jamf-laps-ssh-and-screen-share) |

You can start with Jamf Pro alone and add the rest later. Each optional service is switched on
by adding its block to the Core profile and entering its secret.

---

## 2. Decide Three Things First

These choices shape which credentials you create.

### How people sign in

| Method | Use it when | What decides a person's role |
| --- | --- | --- |
| **Microsoft Entra ID** (recommended) | More than one person uses FleetHub | The app roles on their Entra account |
| **Email address** | One operator, or a lab | The `role` key in the Access profile on that Mac |

Email sign-in accepts whatever address is typed, so it does not prove identity. Configuring
Entra sign-in turns email sign-in off.

### Who creates each person's Jamf API client

Every action in FleetHub runs as the signed-in person's own Jamf Pro API client, so that
Jamf's audit log names the person.

| Setting | What happens | Trade-off |
| --- | --- | --- |
| **Automatic creation off** (default) | You create an API client for each person in Jamf Pro. They enter its client ID and secret in FleetHub once. | More work per person. No powerful secret on technicians' Macs. |
| **Automatic creation on** | FleetHub creates and maintains each person's client at sign-in, using a provisioning ("master") client. | No work per person. The provisioning client's secret sits in each technician's Keychain, and it can create an API client with any API role. Needs Entra sign-in. |

The setting is `authentication.autoCreateUserApiClient` in the Core profile.

### Which Jamf API

| `apiBackend` | Use it when |
| --- | --- |
| `jamfPro` (default) | Almost always. Every call runs as the person. |
| `hybrid` | You want reads to go through the Jamf Platform API and actions to stay per person. |
| `platform` | You accept one shared integration for everything. Experimental; see [PlatformAPI.md](PlatformAPI.md). |

---

## 3. Build the Apps

```sh
git clone <this repository>
cd FleetHub
open FleetHub.xcodeproj
```

There are four schemes: `FleetHub`, `FleetHubMenuBar`, `FleetHubSetup` and `FleetHubPrompt` (the
optional Screen Share approval prompt, for the Macs being supported). Building `FleetHub`
also builds the menu bar companion and places it inside the app. The project carries
no development team, so set your own team for signing, or build unsigned to try it:

```sh
xcodebuild build -project FleetHub.xcodeproj -scheme FleetHub \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

To look around before connecting anything, start a Debug build of `FleetHub` with the launch
argument `-FleetHubDemo`. It shows generated sample data and cannot reach a real tenant.

For a package you can deploy, follow [`Deployment/README.md`](../Deployment/README.md). In
short: `Deployment/build-pkg.sh` builds, signs with your Developer ID, optionally notarizes, and
writes `dist/FleetHub-<version>-<build>.pkg`. Signing identity, notarization profile and other
machine-specific values go in an ignored `Deployment/build-pkg.local.sh` or in environment
variables, never in the repository.

**Bundle identifiers.** The apps ship as `com.herojoneslabs.fleethub`, `.menubar` and `.setup`,
and the four settings domains start with `com.herojoneslabs.fleethub.`. You can keep them. If
you change them, change them everywhere: the project, the schemas, the scripts and the
documents all name them.

---

## 4. Create the Jamf Pro Credentials

The fastest path is to run **FleetHub Setup** (build the `FleetHubSetup` scheme). Its *Jamf
Environment Setup* step lists, for the choices you made, every API role to create and the
exact privileges each one needs, with a button to copy each list. The same information is in
[JamfAPIPrivileges.md](JamfAPIPrivileges.md).

In **Jamf Pro → Settings → System → API Roles and Clients**:

1. **One API role per FleetHub role.** For example a Technician role and an Admin role. Give
   each only the privileges its FleetHub capabilities need. Note each role's exact name: it
   goes in the Access profile as that role's `jamfApiRoleName`.
2. **API clients for people**, depending on the choice in section 2:
   - *Automatic creation off:* create one API client per person, attach the API role for
     their FleetHub role, generate its secret, and give the person the client ID and secret.
   - *Automatic creation on:* create one provisioning client whose role has only **Read,
     Create and Update API Integrations** and **Read API Roles**. Its client ID goes in the
     Core profile as `jamfPro.masterClientID`.
3. **Optional, for FleetHub Setup's upload button:** a temporary client that can create
   configuration profiles and scripts. Setup lists its privileges under *For Setup*. Disable
   or delete it when you are done; FleetHub itself never uses it.

Jamf shows a client secret once. Keep each one in your password manager until it is
delivered.

---

## 5. Set Up the Optional Services

Do these now if you want them from day one, or skip to section 6 and come back.

| Service | What you create | Guide |
| --- | --- | --- |
| Microsoft Entra ID sign-in | A public-client app registration, app roles, and group assignments | [EntraAuthSetup.md](EntraAuthSetup.md) |
| Apple Business Manager | An API account, its private key, Client ID and Key ID | [Integrations.md](Integrations.md#apple-business-manager) |
| Entra device cleanup | An app-only app registration with a secret or certificate | [Integrations.md](Integrations.md#microsoft-entra-device-cleanup) |
| Jamf Protect | A Protect API client, or the Platform integration | [Integrations.md](Integrations.md#jamf-protect) |
| Jamf Platform API | An integration in Jamf Account | [PlatformAPI.md](PlatformAPI.md) |

Each guide ends with the same three things: which values go in the Core profile, which secret
goes in the Keychain, and how to check it works.

---

## 6. Write the Four Configuration Profiles

FleetHub reads four preference domains. Each is its own Jamf Pro configuration profile
(**Application & Custom Settings → External Applications → Custom Schema**).

| Domain | Holds | Schema |
| --- | --- | --- |
| `com.herojoneslabs.fleethub.core` | Jamf URL, sign-in method, API choices, and the non-secret identity of each optional service | `schemas/FleetHub_Core_SCHEMA.json` |
| `com.herojoneslabs.fleethub.access` | Roles: which tabs, actions, sites and servers each may use, and each role's Jamf API role name | `schemas/FleetHub_Access_SCHEMA.json` |
| `com.herojoneslabs.fleethub.features` | Feature switches and tuning: inventory sections, Health Scorecard, LAPS account, SSH, Screen Share, Cleanup | `schemas/FleetHub_Features_SCHEMA.json` |
| `com.herojoneslabs.fleethub.ui` | Branding, tab order and labels | `schemas/FleetHub_UI_SCHEMA.json` |

Two ways to produce them:

- **FleetHub Setup (recommended).** Its *Configure* step is a form for all four domains, and
  its *Deliver* step exports the profiles or uploads them to Jamf Pro unscoped, for you to
  scope.
- **By hand.** Paste each schema into Jamf's Custom Schema editor and fill in the form. The
  schemas describe every key. [Configuration.md](Configuration.md) explains the role model,
  scoping and the rules that make the app fail closed.

The smallest working Core profile, with automatic creation off and email sign-in:

```xml
<key>jamfPro</key>
<dict>
    <key>serverURL</key>
    <string>https://yourorg.jamfcloud.com</string>
</dict>
```

and the smallest Access profile that shows anything:

```xml
<key>role</key>
<string>Example.Technician</string>
<key>roles</key>
<array>
    <dict>
        <key>name</key>
        <string>Example.Technician</string>
        <key>jamfApiRoleName</key>
        <string>YOUR-API-ROLE</string>
        <key>modules</key>
        <array>
            <string>dashboard</string>
            <string>devices</string>
        </array>
    </dict>
</array>
```

[`Deployment/sample.mobileconfig`](../Deployment/sample.mobileconfig) holds a fuller example of
all four payloads in one file, for testing on a single Mac. In Jamf, keep them as four
profiles.

Things that catch people out:

- **A Mac with no Access profile shows an empty app.** That is deliberate. Scope the Access
  profile to every Mac that runs FleetHub.
- **Role names must match exactly,** including case: the Entra app role value (or the `role`
  key) against a `name` in `roles`.
- **Inventory sections matter.** `features.computers.inventorySections` must include the
  sections your health checks read. A missing section makes a check read Non-Compliant, and
  blanks that part of the device page.
- **Changes need a relaunch.** FleetHub reads its settings at launch.

---

## 7. Deliver the Secrets

No profile ever carries a secret. Each one is stored in the Keychain of the person using
FleetHub, and gets there one of two ways:

- **Typed in.** FleetHub asks on first launch for what it needs, and **Settings → Credentials**
  holds the rest.
- **By Jamf policy.** [`Deployment/Import-FleetHub-Credentials.sh`](../Deployment/Import-FleetHub-Credentials.sh)
  runs after the package installs and hands the secrets to the app. See
  [CredentialDelivery.md](CredentialDelivery.md).

| Secret | Needed when | Pairs with (Core profile) |
| --- | --- | --- |
| The person's own Jamf API client ID and secret | Automatic creation is off | Nothing: entered by the person |
| Jamf provisioning client secret | Automatic creation is on | `jamfPro.masterClientID` |
| Jamf Platform API client secret | A Platform integration is configured | `platformAPI.clientID` |
| Apple Business Manager private key | ABM is enabled | `appleBusinessManager.clientID` and `keyID` |
| Jamf Protect API password | Protect is enabled without a Platform integration | `jamfProtect.clientID` |
| Entra cleanup client secret or certificate | Return to Service deletes Entra objects | `entra.clientID` |

The policy script covers the provisioning client, the Platform integration, the ABM key and
the Entra cleanup secret. A person's own API client and the Jamf Protect password are typed in.

---

## 8. Install and Check

1. Deploy the package with a Jamf policy, and scope the four profiles to the same Macs.
2. Confirm the settings landed:

   ```sh
   ls "/Library/Managed Preferences/" | grep com.herojoneslabs.fleethub
   ```

   You should see `core`, `access`, `features` and `ui`.
3. Open FleetHub. It asks for whatever secret that Mac still needs, then offers sign-in.
4. Sign in. The tabs you see are the ones your role grants.
5. Check each piece you set up:

| Check | Expect |
| --- | --- |
| Overview loads device counts | The person's API role has Read Computers and Read Mobile Devices |
| Search finds a device and opens its page | Inventory sections are delivered |
| A harmless action (Send Blank Push) on a test Mac | A success message, and a line in Logs |
| Devices → ABM Lookup (if enabled) | Your Apple Business Manager devices and servers list |
| Local Admin Password on a test Mac (if enabled) | A panel with the password and a rotation countdown |
| Settings → Credentials | Each configured service shows its secret as saved |

[Configuration.md](Configuration.md) section 4 has the full checklist, including how to prove
that a role without a capability really cannot use it.

Test destructive actions (Erase, Return to Service, Cleanup deletes) against a test device
before you grant them to anyone.

### Limiting People to Their Jamf Sites

If your organization uses Jamf Pro sites, FleetHub can show each person only the devices in
their sites. It is off unless you turn it on.

1. In the Access profile, set **Limit Devices By Site** (`siteScoping`) to true.
2. On every role, fill in **Visible Sites** (`visibleSites`) with Jamf site IDs. Use `all` for
   roles that should see everything, and `-1` to include devices that belong to no site.
3. Push the profile and relaunch FleetHub.

A role with no Visible Sites sees no devices once the switch is on, so fill in every role
first. People with more than one site get a site switcher in the top bar.

**FleetHub applies this limit; Jamf Pro does not.** A Jamf Pro API client cannot be
restricted to a site, so each person's own API credential can still read every device in
Jamf Pro. Site scoping controls what FleetHub shows and acts on. It is not a security
boundary against someone who uses their API credential outside FleetHub.

The full rules, and what site scoping does not cover, are in
[Configuration.md](Configuration.md#site-scoping--limiting-people-to-their-jamf-sites).

### Menu Bar Search and the Login Item Profile

`FleetHub.app` carries a small companion, `FleetHubMenuBar.app`, inside itself at
`Contents/Library/LoginItems`. It puts a device search in the menu bar and opens results in
FleetHub. There is nothing separate to install.

It is on by default. The first time a person opens FleetHub, the app registers the companion
with macOS as a login item, so it starts then and at every login after that. It searches with
the Jamf credential of the person who signed in to FleetHub, so it finds nothing until they
have signed in once.

| Who | How to turn it off |
| --- | --- |
| One person | FleetHub → Settings → Preferences → Menu Bar Search. The choice is kept. |
| Everyone | Set `userExperience.menuBarSearch` to `false` in the Features profile. The companion is not started, a running copy is removed, and the Settings switch is hidden. |

**Stop macOS asking about it.** macOS tells the user when an app adds a login item, and lets
them switch it off in System Settings → General → Login Items. A Managed Login Items profile
approves the companion ahead of time. Apple describes the payload as one that "auto-enables and
auto-allows matched items".

In Jamf Pro: **Computers → Configuration Profiles → New**, level **Computer Level**, payload
**Managed Login Items**. Add one rule, and scope the profile to the same Macs as the package.
Deliver it before or with the package, so it is in place when FleetHub first opens.

| Field | Value |
| --- | --- |
| Rule Type | Bundle Identifier Prefix |
| Rule Value | `com.herojoneslabs.fleethub` |
| Comment | FleetHub menu bar search |

The prefix covers both FleetHub and the companion (`com.herojoneslabs.fleethub.menubar`). If you
changed the bundle identifiers, use your own prefix. If you would sooner approve everything your
organization signs, use Rule Type **Team Identifier** with the ten-character team ID of the
Developer ID you signed the package with.

The same payload as a profile, for another MDM or for checking what Jamf sends (payload type
`com.apple.servicemanagement`, macOS 13 or later, device channel only):

```xml
<dict>
    <key>PayloadType</key>
    <string>com.apple.servicemanagement</string>
    <key>PayloadIdentifier</key>
    <string>com.example.fleethub.loginitems</string>
    <key>PayloadUUID</key>
    <string>REPLACE-WITH-A-NEW-UUID</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
    <key>Rules</key>
    <array>
        <dict>
            <key>RuleType</key>
            <string>BundleIdentifierPrefix</string>
            <key>RuleValue</key>
            <string>com.herojoneslabs.fleethub</string>
            <key>Comment</key>
            <string>FleetHub menu bar search</string>
        </dict>
    </array>
</dict>
```

Check it on a Mac after FleetHub has been opened once:

```sh
sudo sfltool dumpbtm | grep -B2 -A12 -i fleethub
```

The companion should be listed as enabled and managed. With the profile in place the user
cannot switch the item off in System Settings; the FleetHub Settings switch is then the way to
stop it.

**Keychain.** The companion reads the Jamf credential FleetHub saved. Depending on how your
build is signed, macOS may ask the user once to let FleetHub Menu Bar use that Keychain item;
choosing Always Allow settles it. No profile can answer that prompt.

---

## 9. Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| The app opens empty, with no tabs | No Access profile on this Mac, or no `roles` entry whose `name` matches the person's role |
| "Enter your Jamf API client" appears when you expected sign-in | Automatic creation is off (the default). Turn it on in Core, or give the person a client |
| Email sign-in is refused | Entra sign-in is configured, or automatic creation is on |
| Entra sign-in fails with `AADSTS50011` | The redirect URI on the app registration is not the one FleetHub sends; see [EntraAuthSetup.md](EntraAuthSetup.md) section 8 |
| A button is shown but the action fails with a permission error | The person's Jamf API role lacks that privilege; compare with [JamfAPIPrivileges.md](JamfAPIPrivileges.md) |
| A health check reads Non-Compliant for everything | An inventory section that check needs is not in `inventorySections` |
| "Unable to Load" on the ABM tab | Wrong Client ID or Key ID, an expired key, or a proxy that inspects TLS to Apple |
| A setting you changed has no effect | Relaunch FleetHub; check the profile's preference domain is spelled exactly |

### Reading the log

FleetHub writes diagnostic messages to the macOS unified log under the subsystem
`com.herojoneslabs.fleethub` (the menu bar app uses `com.herojoneslabs.fleethub.menubar`).

```sh
log show --last 1h --predicate 'subsystem == "com.herojoneslabs.fleethub"'
```

Values in messages (device names, serial numbers, usernames, error text) are recorded as
private data and show as `‹…›` and `<private>`. To see them while you troubleshoot one Mac,
enable private data for the subsystem, relaunch FleetHub, reproduce the problem, then remove
the setting again. Either install a configuration profile with this payload:

```xml
<key>PayloadType</key>
<string>com.apple.system.logging</string>
<key>Subsystems</key>
<dict>
    <key>com.herojoneslabs.fleethub</key>
    <dict>
        <key>DEFAULT-OPTIONS</key>
        <dict>
            <key>Enable-Private-Data</key>
            <true/>
        </dict>
    </dict>
</dict>
```

or, on a single test Mac:

```sh
sudo mkdir -p /Library/Preferences/Logging/Subsystems
sudo defaults write /Library/Preferences/Logging/Subsystems/com.herojoneslabs.fleethub \
  DEFAULT-OPTIONS -dict Enable-Private-Data -bool true
```

Only messages logged after the setting is applied are revealed. Debug builds write every
message in full.

---

## 10. Keeping It Running

| Item | When | What to do |
| --- | --- | --- |
| Jamf Platform API integration | Expires every six months | Renew in Jamf Account, then deliver the new secret |
| Apple Business Manager key | When you revoke or replace it | Generate a new key, update `keyID` in Core, deliver the new key |
| Entra cleanup secret or certificate | At the expiry you set | Create a new one, deliver it |
| A person's Jamf API client | When they change role or leave | Change the API role on their client, or disable it (automatic creation does this at their next sign-in) |
| A new FleetHub build | When you update | Deploy the new package; profiles and Keychain items stay |

To remove FleetHub, run [`Deployment/OnDevice/Scripts/uninstall_fleethub.sh`](../Deployment/OnDevice/Scripts/uninstall_fleethub.sh)
by policy and unscope the four profiles.
