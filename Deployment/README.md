# FleetHub — Deployment Guide

Sign, package, and deploy the FleetHub macOS app (and its menu bar companion) via Jamf Pro.
This folder is self-contained:

```
Deployment/
  build-pkg.sh                       channel-based sign + package workflow
  sample.mobileconfig                ready-to-edit example profile (all four domains, testing only)
  OnDevice/
    ExtensionAttributes/
      EA_FleetHub_Version.sh   reports installed version into inventory
    Scripts/
      uninstall_fleethub.sh    removes the app(s), receipts, and local prefs
```

The Jamf **Application & Custom Settings schemas** (managed config) live in the repo's
[`schemas/`](../schemas/) folder — one per preference domain (see section 3). The configuration
guide is [`docs/Configuration.md`](../docs/Configuration.md).

The built `.pkg`s land in the repo's `dist/` folder (gitignored).

---

## 1. Build a release package (channel-based)

Versions follow a channel scheme, composed from the project's **Version** (`MARKETING_VERSION`)
and **Build** (`CURRENT_PROJECT_VERSION`):

| Channel | Example version | Audience |
|---|---|---|
| `dev`   | `1.1.0-d.5` | Dev team machines (exclusion groups) |
| `alpha` | `1.1.0-a.5` | Alpha testers |
| `beta`  | `1.1.0-b.5` | Beta group |
| `uat`   | `1.1.0-u.5` | UAT |
| `ga`    | `1.1.0`   | GA to all (**current channel**) |

The project is on the **`ga`** channel at **Version `1.1.0`**. The **Build**
(`CURRENT_PROJECT_VERSION`) is a plain integer that `build-pkg.sh` increments after each
package; it is the `x` in `…-d.x` on the pre-release channels and is always the app's
`CFBundleVersion`. A GA package is named for the Version and the build number (`FleetHub-1.1.0-179.pkg`), so every build has its own file name. Raise
**Version** (`MARKETING_VERSION`) for each release.

**Build a pkg** with `Deployment/build-pkg.sh` — it derives the app name, bundle id, and built
path from the project; you only pick the channel. It's driven by a **CONFIG block at the top of the
script** (no command-line flags — runs straight from CodeRunner or by double-click):

| Toggle | Purpose |
|---|---|
| `CHANNEL` | `dev` / `alpha` / `beta` / `uat` / `ga` |
| `SCHEME` | Pre-set to `FleetHub` (the project has two schemes, so this must be explicit). |
| `APP_IDENTITY` | Developer ID Application identity → signs the app + hardened runtime. Empty = the project's own signing (fine for dev machines). Example: `Developer ID Application: Your Name (<TEAM_ID>)`. |
| `NOTARIZE` | `true` = notarize + staple the **app** (not the pkg); requires `APP_IDENTITY`. |
| `SIGN_PKG` | `true` = sign the pkg with your Developer ID Installer cert (auto-detected). |
| `BUMP` | `true` = increment the project's build number after a successful build. |
| `MIRROR_DIST` | If set, also copies the finished `.pkg` to this path (e.g. an iCloud archive folder). Empty = don't mirror. |

Set `CHANNEL`, run it → `dist/FleetHub-<version>.pkg`. The build is **universal**
(`arm64,x86_64`), so it installs natively on Apple Silicon and Intel. DerivedData is written to
`~/Library/Developer/FleetHub-build` — deliberately **outside iCloud**, because building inside
an iCloud-synced folder makes `codesign` fail on xattr detritus.

**Does the app need notarization?** Not for Jamf **policy** installs — `installer` runs locally and
the app lands with no quarantine flag, so a valid Developer ID signature is enough. Set
`NOTARIZE=true` only if the app may reach a Mac via download/AirDrop, or for MDM-command/manual
installs. Create the notary profile once:
`xcrun notarytool store-credentials "FleetHub-Notary" --apple-id … --team-id <TEAM_ID> --password <app-specific>`.

> Note: FleetHub's Xcode team is **<TEAM_ID>** (use a Developer ID under that team, or update
> `APP_IDENTITY`/`DEVELOPMENT_TEAM` if you sign under a different account).

---

## 2. Deploy via Jamf policy

**Jamf Pro → Settings → Packages** → upload the `.pkg`. Then a **Policy** with a **Packages**
payload (Install) scoped to the target Smart Group, trigger Recurring Check-in / Self Service as
appropriate. The companion **FleetHubMenuBar** is bundled in the same app build but is a separate
target — package/scope it separately only if you ship it.

---

## 3. Configure the app (four profiles, plus secrets)

FleetHub reads managed settings from **four preference domains**, each deployed as its own
configuration profile. **No profile carries a secret.** Secrets are typed into the app (first
launch or **Settings → Credentials**) or delivered by the policy script in
[`docs/CredentialDelivery.md`](../docs/CredentialDelivery.md), and are stored only in that
person's Keychain. The app's bundle id (`com.herojoneslabs.fleethub`) is **not** a settings
domain: a profile targeting it does nothing. Managed values take effect at **app relaunch**.

Create the profiles with **FleetHub Setup**, or by hand in **Jamf Pro → Configuration Profiles →
Application & Custom Settings → External Applications → Custom Schema**, pasting the matching
schema:

| # | Preference domain | Schema (in `schemas/`) | Contents | Scope |
|---|---|---|---|---|
| 1 | `com.herojoneslabs.fleethub.core` | `FleetHub_Core_SCHEMA.json` | Jamf Pro connection, sign-in method, and the IDs (never secrets) of ABM, Jamf Protect, Entra and the Platform API | Every Mac running FleetHub |
| 2 | `com.herojoneslabs.fleethub.access` | `FleetHub_Access_SCHEMA.json` | The `roles` list: tabs, actions, sites and servers per role, and each role's Jamf API role name | Every Mac running FleetHub |
| 3 | `com.herojoneslabs.fleethub.features` | `FleetHub_Features_SCHEMA.json` | Inventory, Health Scorecard, LAPS account, SSH, Screen Share, Cleanup tuning, reports | Every Mac running FleetHub |
| 4 | `com.herojoneslabs.fleethub.ui` | `FleetHub_UI_SCHEMA.json` | Branding, tab order and labels | Every Mac running FleetHub |

The only value the app cannot start without is **core** `jamfPro.serverURL`. What else is
needed depends on your choices, which [`docs/SetupGuide.md`](../docs/SetupGuide.md) walks
through. `Deployment/sample.mobileconfig` bundles all four payloads into one profile **for
testing on a single Mac only**; in Jamf they are four profiles.

### Access is fail closed

A Mac with no access profile, or a person whose role matches no entry in `roles`, gets an
empty app: no tabs, no actions, no export. Scope the access profile to every Mac that runs
FleetHub and express differences between people as roles, not by withholding the profile.
The role model is described in [`docs/Configuration.md`](../docs/Configuration.md) section 2.

**A profile is readable by anyone on the Mac, so role lists are a convenience, not a security
boundary.** The boundary is the Jamf API role on each person's own API client (section 4).

### Optional services

Apple Business Manager, Entra device cleanup, Jamf Protect and the Jamf Platform API are each
enabled by a block in the core profile plus a secret in the Keychain.
[`docs/Integrations.md`](../docs/Integrations.md) covers what to create for each.

---

## 4. Create the Jamf API roles and clients

**Jamf Pro → Settings → API Roles and Clients.** FleetHub Setup's *Jamf Environment Setup* step
lists the exact privileges for your configuration; [`docs/JamfAPIPrivileges.md`](../docs/JamfAPIPrivileges.md)
has the same lists by function.

- **One API role per FleetHub role**, with only the privileges that role's capabilities need.
  Name it in the access profile as that role's `jamfApiRoleName`.
- **Each person acts as their own API client**, so Jamf's audit log names them:
  - *Automatic creation off (default):* create an API client per person, attach the API role
    for their FleetHub role, and give them the client ID and secret. They enter it in FleetHub
    once.
  - *Automatic creation on* (`authentication.autoCreateUserApiClient` = true, Entra sign-in
    only): create one provisioning client with **Read, Create and Update API Integrations**
    and **Read API Roles**, name it in core as `jamfPro.masterClientID`, and deliver its
    secret. FleetHub creates and maintains each person's client at sign-in. That secret can
    create a client with any API role, so weigh it before turning this on.

**Keep the two layers aligned.** A capability a FleetHub role grants but the person's Jamf API
role lacks shows a button that fails with a permission error. A privilege the Jamf API role
holds but the FleetHub role does not grant is simply not offered in the app, but is still
usable by that person outside FleetHub with the same client.

Rotation: create the new secret in Jamf and deliver it (typed into **Settings → Credentials**,
or by the policy script). Profiles do not change unless a client ID changes.

---

## 5. Create the version Extension Attribute (optional, recommended)

**Jamf Pro → Settings → Computer Management → Extension Attributes → New**

- Name: **FleetHub Version** (or your preference).
- Data Type: **String**, Input Type: **Script**.
- Paste `OnDevice/ExtensionAttributes/EA_FleetHub_Version.sh`.

Populates at the next inventory collection (`jamf recon`). Use it to build Smart Groups for update
targeting (e.g. "FleetHub < 1.0").

---

## 6. Uninstall

Add `OnDevice/Scripts/uninstall_fleethub.sh` as a **Jamf script** and run it via a policy to
remove the app(s), forget pkg receipts, and clear the console user's local prefs + FleetHub Keychain
items (every integration secret entered in Settings → Credentials plus the auth/Jamf sign-in
accounts). Separately **unscope/remove ALL FOUR Configuration
Profiles** in Jamf — core, access, features, ui — (the script does not touch managed profiles).
If a Mac was ever configured with the developer `defaults write` story (see
`docs/Configuration.md` §6), user-level
`~/Library/Preferences/com.herojoneslabs.fleethub.{core,access,features,ui}.plist` files may
remain — remove them with `defaults delete <domain>`.

---

## 7. End-to-end verification

1. Build a package, install it on a test Mac, and confirm `/Applications/FleetHub.app` opens.
2. Push all four profiles and confirm the settings landed:
   `ls /Library/Managed\ Preferences/com.herojoneslabs.fleethub.{core,access,features,ui}.plist`
3. Launch FleetHub. It asks for whatever secret that Mac still needs (the person's own API
   client, or the provisioning secret when automatic creation is on), then offers sign-in.
4. Sign in as a person with a limited role: only that role's tabs and actions appear. Remove
   the access profile from the Mac and relaunch: the app is empty (fail closed).
5. `sudo jamf recon` and confirm the **FleetHub Version** extension attribute populates.
6. Against a **test** device, run one harmless action (Send Blank Push) and confirm the line in
   Logs, before trusting any destructive action.
7. Run the uninstall policy and confirm the app and its Keychain items are gone; unscope the
   four profiles.

The full checklist, including relaunch behaviour and partial delivery, is in
[`docs/Configuration.md`](../docs/Configuration.md) section 4. The whole setup from scratch is
in [`docs/SetupGuide.md`](../docs/SetupGuide.md).
