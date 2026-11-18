# FleetHub — Managed Configuration

FleetHub is configured entirely by managed preferences: four preference domains, each
delivered as its own configuration profile, plus secrets that are entered in the app or
delivered by a Jamf policy and kept in the Keychain. Secrets are never read from a profile.

The schemas in `schemas/` are the authoritative list of keys, and FleetHub Setup generates
all four profiles from a guided form. This document explains how the domains fit together,
how to deploy and scope them, and how to check the result.

---

## 1. The four domains

| # | Preference domain | Tier | Schema file | Scope |
|---|---|---|---|---|
| 1 | `com.herojoneslabs.fleethub.core` | Connection & integrations (no secrets) | `schemas/FleetHub_Core_SCHEMA.json` | **All managed Macs** running FleetHub |
| 2 | `com.herojoneslabs.fleethub.access` | Role capabilities & destructive capability | `schemas/FleetHub_Access_SCHEMA.json` | **All managed Macs** running FleetHub |
| 3 | `com.herojoneslabs.fleethub.features` | Feature modules & tuning | `schemas/FleetHub_Features_SCHEMA.json` | **All managed Macs** running FleetHub |
| 4 | `com.herojoneslabs.fleethub.ui` | Branding & UX | `schemas/FleetHub_UI_SCHEMA.json` | **All managed Macs** running FleetHub |

Every domain also accepts an optional `configurationVersion` (string, default `"2.0"`,
informational — the loader logs it; nothing else reads it).

The app is **configured** once the core profile delivers `jamfPro.serverURL` and the
credential that Mac needs is in its Keychain. With automatic API client creation off (the
default), that is the signed-in person's own Jamf API client, which FleetHub asks for once.
With it on, it is the provisioning client's secret, paired with `jamfPro.masterClientID`.
Partial delivery → the app reports itself unconfigured and logs what is missing; there is no
silent placeholder fallback.

---

## 2. Sign-in and roles

### Interactive sign-in (`signIn` block)

The core domain configures **how users sign into FleetHub itself** — **identity only**. It
decides *who the user is* and *which role names they carry*; it grants **no** capabilities.
What each role name can do lives entirely in the access domain's `roles` block (next
section). This is separate from the `entra` cleanup pointer (app-only Graph credentials for
Return to Service): `signIn.entra` targets a **separate PUBLIC-client Entra app
registration** — a public client has no client secret, so no secret exists for it anywhere,
by design. An absent `signIn` block (or `method=email`) keeps the built-in email flow, in
which case the access domain's `role` key names the user's role instead.

| Key | Type | Default | Enforced where |
|---|---|---|---|
| `signIn.method` | string enum `email` / `entra` (case-insensitive) | `email` | Login flow — `entra` replaces the email form with Entra ID sign-in. Email sign-in is also turned off whenever `signIn.entra` carries a tenant ID and client ID, whatever this says |
| `signIn.entra.tenantId` | string (GUID) | — (required for Entra sign-in) | EntraAuthService — interactive token requests |
| `signIn.entra.clientId` | string (GUID; public client, never paired with a secret) | — (required for Entra sign-in) | EntraAuthService — interactive token requests |
| `signIn.entra.cloudInstance` | string enum `global` / `usgov` / `china` | `global` | EntraAuthService — token authority host (same mapping as `entra.cloudInstance`) |
| `signIn.entra.allowedGroupIds` | array of strings (group object ids) | `[]` = no group check | Optional extra client-side membership check via the token's groups claim |

**Fail-closed rules (deliberate — mirror the access domain's `role` gate):**

- `method=entra` with a missing/blank `tenantId` or `clientId` → sign-in is **blocked with a
  configuration-error state**. The app **never falls back to the email flow** — a
  misconfigured profile must not silently downgrade to the weaker sign-in path. (In code:
  `signInMethod` stays `.entra` while `isEntraSignInConfigured` is `false`.)
- A token whose `roles` claim matches **no entry `name`** in the access domain's `roles` array →
  **sign-in refused**. Roles absent means denied, never defaulted up. There is no built-in
  role name to fall back to.
- Enforce the restriction **Entra-side too**: enable *Assignment required* on the enterprise
  application and assign only the intended users/groups — the client-side checks here are a
  UX gate, not a security boundary on their own.
- Prefer app roles over `allowedGroupIds`: the groups claim is subject to Entra's overage
  limit and can arrive **empty** for users in many groups, which the group check then fails.
  The roles claim is never subject to overage.
- `allowedGroupIds` is a **sign-in** gate only — it never grants capabilities. Group
  membership maps to nothing; only role names do.

### Role-capability model

**Nothing about access is hardcoded in the app any more.** There are no built-in tiers, no
built-in role names, and no built-in capability defaults. The app reads the access domain's
`roles` block and renders exactly what it finds. Roles are **arbitrary, admin-named
capability sets**.

#### Identity precedence — where the role names come from

Resolved in this order; the first configured source wins outright (no merging across
sources):

1. **Entra sign-in** — core `signIn.method=entra`. The role names are the values in the ID
   token's `roles` claim. The access `role` key is **ignored entirely** in this mode.
2. **Access domain `role`** — when Entra sign-in is not configured. A single free-form
   string naming one `roles` entry's `name`. This is the machine-scoped identity: every user of
   that Mac holds that one role.
3. **User-level plist (dev/unmanaged only)** — the loader reads each domain via
   `UserDefaults(suiteName:)`, so standard CFPreferences precedence applies: the MDM-forced
   `/Library/Managed Preferences/<domain>.plist` **wins**, and a user-level
   `~/Library/Preferences/com.herojoneslabs.fleethub.access.plist` is consulted only
   where the managed profile delivers nothing. This is the §6 developer story, not a
   deployment mechanism — on a managed Mac the profile always wins.

#### The `roles` block

An **ARRAY of role objects**, each carrying its own name in `name`:

```
roles = (
  {
    name                = "<RoleName>";  // the role's name — REQUIRED
    modules             = [ ids ];   // sidebar / route ids
    computerActions     = [ ids ];   // DeviceAction ids, intersected with deviceActions
    mobileDeviceActions = [ ids ];   // same, mobile side
    cleanupActions      = [ ids ];   // cleanup sub-actions
    allowExport         = <bool>;    // every export surface (Reports, Cleanup, Logs)
  },
  // ...more role objects
)
```

> **Why an array and not a dictionary keyed by role name?** Role names are admin-chosen, so
> a dictionary can only be expressed in JSON Schema as `additionalProperties` — which
> **Jamf Pro's Application & Custom Settings form generator cannot render**, forcing admins
> to hand-edit profile XML. A list of objects renders as a form in the Jamf schema editor.
> Same idiom as `deviceActions.computer.actions` (`{id, enabled, displayName}`), which
> already renders there.

| Key | Type | Absent = | Valid ids |
|---|---|---|---|
| `name` | string | **entry SKIPPED** (see below) | **Admin-chosen.** Must equal an Entra app-role **Value** (Entra mode) or the `role` key (MDM mode), **exactly, case-sensitively** |
| `modules` | array of string | no modules | `dashboard`, `devices`, `myDevices`, `announcements`, `logs`, `reports`, `cleanup`, `settings`. **Array order = sidebar order** — see *Sidebar order* below |
| `computerActions` | array of string | no computer actions | the `deviceActions.computer.actions[].id` set (`sendBlankPush`, `restart`, `restartSilent`, `shutdown`, `returnToService`, `enableRemoteDesktop`, `disableRemoteDesktop`, `enableBluetooth`, `disableBluetooth`, `viewFileVaultKey`, `viewLocalAdminPassword`, `screenShare`, `unlockUserAccount`, `wipe`; the reserved ids render nothing) |
| `mobileDeviceActions` | array of string | no mobile actions | the `deviceActions.mobileDevice.actions[].id` set — forward-looking, no mobile actions menu exists yet |
| `cleanupActions` | array of string | no cleanup actions | `unmanage`, `addToGroup`, `moveToSite`, `deleteFromProtect`, `deleteRecord` |
| `allowExport` | bool | `false` | — (a single switch over **every** export surface — see below) |

**`allowExport` is app-wide, not Reports-only.** It gates every path that moves data out of
the app, and each control is simply **not rendered** without it:

| Surface | Control | Hosting module |
|---|---|---|
| Reports | the Export menu (CSV / Excel / PDF / Markdown), both the toolbar menu and the prominent Run-Report button | `reports` |
| Cleanup | the Export menus on the **stale-device** and **protected-device** lists (CSV / Markdown / PDF) | `cleanup` |
| Logs | **Export CSV** — copies the whole audit trail to the pasteboard | `logs` |

So a role's `modules` decide which export surfaces the user can *reach*, and `allowExport`
decides whether any of them work. The sample profile's `FleetHub.CleanupTech` role omits
`allowExport`, so its holders get the Cleanup module **with no export control** — add
`allowExport = 1` to that entry (or hold another role that sets it, since it is OR'd across
matched roles) if cleanup technicians should be able to export their device lists.

#### `myDevices` — the self-service module

`myDevices` is a **read-only** view of the devices assigned to the person signed in: their Macs, iPhones,
iPads and Vision Pros, each with serial, OS version, last check-in, free space, encryption
state and battery. It renders **no action control of its own** — opening a device pushes the
same detail views the Devices module uses, and those gate every action on `computerActions` /
`mobileDeviceActions`, so a role granting `myDevices` and no actions is information-only.
That makes it the one module that is safe to give to everybody.

- **Granting `myDevices` does NOT grant `devices`.** A user with only `myDevices` can see
  their own devices and cannot search the fleet.

**How a user is matched to their devices.** FleetHub knows the operator by email (the Entra UPN,
or the address used at sign-in); Jamf inventory records are keyed by
`userAndLocation.username`, which in most tenants is a directory short name. FleetHub does not
guess the mapping — it asks Jamf: `GET /api/v1/users?filter=email=="<sign-in address>"`
returns the user record(s) for that address, and inventory is then searched for **every**
username those records carry (one person routinely holds both an `hea08299`-style record and
a UPN-style one). Tune this in `features.myDevices`:

| Key | Default | Effect |
|---|---|---|
| `enabled` | `true` | Machine-layer kill switch for the module |
| `resolveDirectoryUsers` | `true` | Use `/api/v1/users` to learn the tenant's username(s) for the sign-in address. **Needs the Read Users privilege** — a denial is non-fatal and the app falls back to the switches below, with a note in the view |
| `matchEmail` | `true` | Match `userAndLocation.email` / mobile `emailAddress` against the sign-in address |
| `matchUsernameFromEmail` | `true` | Match a username equal to the full sign-in address |
| `matchUsernameLocalPart` | `false` | Also try the part before the `@`. Off by default: it matches nothing in short-name tenants and is the one candidate that could match a *different* person where mailboxes are shared |
| `matchRealName` | `false` | Match real name against the display name. Off by default — Jamf's formatting (`Doe, Jane A.`) rarely equals the token's |
| `showLocalDeviceFallback` | `true` | When nothing matches, show the Mac FleetHub is running on (matched by hardware serial), **labelled as this Mac**, not as an assignment |
| `maxDevices` | `50` | Cap, so a mis-scoped match cannot pull in the fleet |

**API role privileges:** `Read Computers`, `Read Mobile Devices`, and — for the accurate
identity match — `Read Users`. Reads use the `deviceSearch` credential scope.

#### Sidebar order

**A role's `modules` array order IS its sidebar order.** The first id is the topmost row;
the rest follow in listed order. There is no `order` key anywhere — when you set a module,
you set its position in the same edit, in the same place, and each role gets its own
ordering for free:

```
roles = (
  {
    name    = "FleetHub.Support";
    modules = ( devices, dashboard, logs, settings );   // Devices renders FIRST
  },
  {
    name    = "FleetHub.Admin";
    modules = ( dashboard, devices, cleanup, settings ); // Dashboard renders first
  },
)
```

Rules:

- **`settings` is pinned** below the sidebar divider wherever you list it. Listing it grants
  it; its position is ignored. (Sign Out sits below it and is never gated.)
- **Unknown / not-yet-implemented ids are skipped** with no error and no gap. Ordering
  around a pre-staged id is safe — that is what lets a newer profile deploy to an older
  build.
- **The machine layer still prunes.** A module a role grants but this Mac disables — via
  `ui.sidebarItems[].isEnabled`, `ui.userInterface.showAnnouncements` /
  `showSettings`, `features.reports.enabled`, or `features.myDevices.enabled` — renders
  **no row**, and the rows after it simply close up. Order never widens access; the two
  layers still intersect.
- **`ui.sidebarItems` does not set order.** It supplies presence (`isEnabled`), label and
  icon for an id; its own list position is meaningless.

**Union order (multi-role users).** One merged list, resolved deterministically:

1. Walk the `roles` **array in the order it is authored in the profile** — *not* the order
   the Entra token's `roles` claim lists them. The claim's order is Entra's to choose and can
   change between sign-ins; the profile is the admin's version-controlled statement of
   intent, so it is the one that decides layout.
2. Within each matched role, append its `modules` in listed order.
3. **First appearance wins.** A module an earlier role already contributed keeps its earlier
   position — a later role listing it again is ignored. Never re-ordered, never duplicated.

So for a user holding both roles in the example above, `FleetHub.Support` is authored first and
its order leads: **devices, dashboard, logs**, then `FleetHub.Admin` contributes only what is
new — **cleanup** — and `settings` stays pinned. To change that, reorder the `roles` array
itself.

#### Naming and union semantics

- **Exact, case-sensitive matching.** An Entra app-role `Value` must equal a `roles` entry's
  `name` character-for-character; likewise the access `role` string. `fleethub.admin` does not
  match `FleetHub.Admin`. There is no fuzzy match, no aliasing, no normalization to lean on.
  (The `name` is whitespace-trimmed before matching, so a stray trailing space is forgiven —
  nothing else is.)
- **Multiple roles → UNION.** A user whose token carries several matching role values
  receives the union of every matched role's lists; `allowExport` is **OR**'d (one role
  granting it is enough). MDM mode resolves exactly one role name, so union across
  *different* names only ever matters under Entra sign-in.
- **A nameless entry is SKIPPED** (and logged). An entry whose `name` is missing, blank, or
  malformed is unreachable — no role name could ever match it — so it is dropped rather
  than indexed under the empty string, where a blank `role` key could otherwise resolve to
  real capabilities. Fail-closed.
- **Duplicate `name`s UNION together** — they do **not** replace one another. Every entry
  carrying a name contributes to that name, so splitting one role across two entries is
  equivalent to writing one merged entry, and a duplicate can only ever **widen** what the
  name grants. Last-wins was rejected deliberately: it would make an admin's grant vanish
  silently based on array order. This applies in **both** modes — unlike the multi-role
  union above, a single MDM `role` string hitting two same-named entries unions them too.
- **Cleanup is not special-cased.** It is simply the `cleanup` id in a role's `modules`
  list, with its sub-actions in `cleanupActions`. A **cleanup-only role** (e.g.
  `FleetHub.CleanupTech` with `modules = (cleanup)`) is a supported, ordinary pattern: assign
  it in Entra *alongside* another role and the union gives that user their normal surface
  plus Cleanup.
- **Sign-out is safe to omit `settings` around.** Sign Out lives in the sidebar, not inside
  Settings, so a role without the `settings` module is not stranded.

#### Two layers — device actions only

| Layer | Scope | Source | Decides |
|---|---|---|---|
| 1 | **Machine** — which Mac the operator sits at | access `deviceActions.{computer,mobileDevice}.actions` (+ features `enableAPIActions` kill switch) | which actions **exist** on this Mac: `enabled` state, menu `displayName`, Return-to-Service `options` |
| 2 | **User** — who is signed in | the union of matched roles' `computerActions` / `mobileDeviceActions` | which of those existing actions **this role may see and run** |

An action renders and executes **only when both layers allow it** — a fail-closed
intersection; neither layer can expand what the other denies. An id a role lists but the
machine allow-list omits (or sets `enabled=false`) stays hidden and blocked; an id the
allow-list grants that no matched role lists likewise stays hidden and blocked.

**`modules`, `cleanupActions`, and `allowExport` have no machine layer — they are
role-driven only.** (The `cleanup` block in the access domain is *tunables only*:
`staleDays`, `defaultStaticGroupID`, `defaultSiteID`. It grants nothing.)

#### Fail-closed rules

- **No `roles` block → no capabilities.** Nothing is defaulted on, ever.
- **Role name matches no entry `name` → no capabilities.** In **Entra mode** that user is
  **refused sign-in** outright. In **MDM mode** the user still **signs in but sees an empty
  app** — no modules, no actions, no export.
- That MDM asymmetry is **deliberate**: a missing, mis-scoped, or malformed access profile
  must not hard-lock an org out of its own app. An empty app is diagnosable from the
  inside; a refused sign-in on every Mac is not.
- Unknown ids inside a role's lists are ignored, not fatal — forward compatibility.
- There is deliberately **no default** for `roles`, and none for `role`. A default would be
  a hardcoded capability, which is exactly what this model removes.

---

## 3. Jamf Pro deployment steps

> **Two Jamf Custom Schema limits, both confirmed by probing. Design within them —
> a plist upload is not an acceptable fallback for this app.**
>
> 1. **Array nesting stops at two levels.** `array of objects → array of strings` and
>    `array of objects → array of objects` both render. A third level gives **no editable
>    field** for the innermost value, so the key is unauthorable even though the schema is
>    valid and the app decodes it fine. This is why `healthScorecard.cards[]` carries its
>    `siteIds` / `requiredApps` / `checks` directly rather than nesting them under a
>    `targets[]` list.
> 2. **The root `title` must be ASCII.** A non-ASCII character there — an em-dash, across
>    all eight schemas — makes Jamf render its generic property editor: a `root` label with
>    an `object` type dropdown and a type picker beside every property, instead of a clean
>    form. `description` may contain any characters; only `title` matters. A bare
>    reverse-DNS `$id` (not a URI) is fine, so the domain-as-`$id` convention below stands.

Create **four** configuration profiles, one per domain. For each:

1. **Jamf Pro → Configuration Profiles → New**.
2. Add an **Application & Custom Settings → External Applications** payload, source
   **Custom Schema**.
3. Set **Preference Domain** to the exact domain string from the table in §1
   (e.g. `com.herojoneslabs.fleethub.core` — a typo here silently delivers nothing).
4. Paste the matching schema file from `schemas/` (e.g. `FleetHub_Core_SCHEMA.json`) into the
   Custom Schema editor and fill in the values. Replace every `REPLACE-WITH-…` placeholder
   with the real value **in Jamf** — never commit real values to the repo.
5. Scope per the matrix below.

### Scoping matrix

| Profile (domain) | Scope |
|---|---|
| `com.herojoneslabs.fleethub.core` | All managed Macs running FleetHub |
| `com.herojoneslabs.fleethub.access` | **All managed Macs running FleetHub — per variant** (see below) |
| `com.herojoneslabs.fleethub.features` | All managed Macs running FleetHub |
| `com.herojoneslabs.fleethub.ui` | All managed Macs running FleetHub |

### Access-profile scoping

The access profile carries **every capability**, so a Mac without it runs an **empty app**. Scope it to **all Macs running
FleetHub**, and differentiate populations with **per-variant values**, not by withholding:

- **Entra sign-in mode** — one variant is usually enough: the same `roles` block everywhere
  (the token decides who is who), with `deviceActions` narrowed on any Mac population that
  should not be able to run destructive actions *at all*, regardless of who signs in.
- **MDM mode** — one variant per population, identical `roles` block, differing `role`:
  `role = "FleetHub.Admin"` on admin Macs, `role = "FleetHub.Support"` on support Macs, and so
  on. The `role` key is the machine-scoped identity.
- Under-scoping is **safe** (an empty app, never an over-privileged one), just not useful.
  Over-scoping is the dangerous direction.

### Paired rule (access ⟷ per-user API role)

Role capabilities are a UI gate; the API client's permissions are the real boundary. Keep
them aligned:

- Every app function runs as the signed-in operator's own Jamf API client. The Jamf API Role it
  carries is named per FleetHub role by `access → roles[] → jamfApiRoleName` (falling back to
  `core.jamfPro.requiredRoleName`). Give each of those Jamf roles only the privileges that
  FleetHub role's capabilities need — a read-only Jamf role for a role that grants no
  destructive capability.
- Never grant destructive capabilities (`wipe` / `returnToService` in `computerActions`, or
  `unmanage` / `deleteRecord` in `cleanupActions`) on Macs whose per-user role is read-only:
  the buttons would appear and every one would fail closed.
- The master client named by `core.jamfPro.masterClientID` exists only when automatic API
  client creation is on (it is off by default). Its secret is kept in each Mac's Keychain,
  never in a profile, and it only provisions per-user clients. Give its role the API Integrations
  and API Roles privileges listed in `docs/JamfAPIPrivileges.md` and nothing else.

### Security notes

- Managed-preference plists are written **world-readable** to
  `/Library/Managed Preferences/<domain>.plist` — any local user or process can read them.
  That is exactly why **no profile carries a secret**: secrets live in each Mac's Keychain
  (entered in-app). Rotating a secret = create the new one in Jamf/ABM/Protect/Entra and
  paste it into Settings → Credentials on each operator Mac; profiles are untouched.
- The access profile is **fail-closed**: a Mac that never receives it grants **nothing** —
  no modules, no device actions, no cleanup, no export. Under-scoping is safe;
  over-scoping is not.
- Every role name and capability list is delivered in that world-readable plist, so the
  `roles` block is **public knowledge on every Mac that receives it**. Treat it as
  documentation of your access model, not as a secret — the real boundary is the Jamf API
  role behind the provisioned credentials.

### Relaunch required

FleetHub reads the domains at launch and on explicit reload; there are **no live profile
observers**. After pushing or changing any of the four profiles, **relaunch the app**
(both the main app and the menu bar app) for the new values to take effect.

---

## 4. Verification checklist (multi-profile)

Run on a test Mac after deploying the four profiles:

1. **Profiles landed** — confirm all four plists exist (and that NO credentials plist does):
   ```sh
   ls /Library/Managed\ Preferences/com.herojoneslabs.fleethub.{core,access,features,ui}.plist
   ```
   (The access plist should exist on **every** Mac running FleetHub — a Mac without it runs
   an empty app.)
2. **Domain values readable** — spot-check each domain the way the app reads it:
   ```sh
   defaults read com.herojoneslabs.fleethub.core jamfPro
   defaults read com.herojoneslabs.fleethub.access role
   defaults read com.herojoneslabs.fleethub.access roles
   ```
3. **App configured** — launch FleetHub; on a fresh Mac the first-run onboarding asks for the
   master client secret, then the login flow reaches Jamf. If unconfigured, check the app
   log: it names the **missing domain or secret**.
4. **Missing-secret check** — remove the master secret (Settings → Credentials → Clear),
   relaunch: the app must show onboarding again and log that the Keychain secret is missing
   (core alone is not enough). Re-enter it afterwards.
5. **Role gate** — MDM mode: with `role` set to a `roles` entry whose `modules` include
   `cleanup`, the **Cleanup** sidebar item appears; point `role` at an entry without it (or
   at a name matching **no** entry, or remove the access profile) and the app renders
   **empty**.
   Entra mode: sign in as a user assigned an app role whose **Value** equals a `roles`
   entry's `name`
   and confirm exactly that role's modules render; a user assigned to the app with **no**
   matching role must be **refused sign-in**.
   - **Union check (Entra mode)** — assign one test user two roles (e.g. a support role and
     a cleanup-only role) and confirm they see the union of both, and that `allowExport` is
     granted if **either** role grants it.
   - **Two-layer check** — pick an id that a role lists but `deviceActions` sets
     `enabled=false` (the sample ships `wipe`, `returnToService`, and `screenShare` that
     way): it must stay **hidden** even for the fullest role. Then flip `enabled` to
     `true`, re-push, relaunch, and confirm it appears only for roles listing it.
   - **Case-sensitivity check** — deliberately mis-case one role name (`fleethub.admin` vs
     `FleetHub.Admin`) and confirm it matches **nothing**. This is the single most likely
     production misconfiguration.
6. **Managed vs. overridable fields** — connection identities (`jamfPro.*`, `entra.*`)
   have no editable in-app fields and are profile-only; every secret is in-app only
   (Settings → Credentials) and no profile can lock or override it. The Cleanup tunables (`cleanup.staleDays`, `jamfProtect.enabled`/`url`/
   `clientID`) are MDM **defaults**: an in-app Settings edit stores a local override
   (`Cleanup.StaleDays` etc. in `com.herojoneslabs.fleethub`) that silently **wins over the
   profile** until cleared with `defaults delete com.herojoneslabs.fleethub <key>`.
7. **Version EA** — `sudo jamf recon` → the *FleetHub Version* EA populates.
8. **Relaunch behavior** — change a value in one profile (e.g. `cleanup.staleDays`),
   re-push, relaunch the app, confirm the new value; confirm it did NOT change while the
   app stayed running. If you use `cleanup.staleDays` (or any other locally overridable
   Cleanup tunable — see step 6), **first clear any local override** or the profile value
   will never surface: `defaults delete com.herojoneslabs.fleethub Cleanup.StaleDays` (likewise
   `Cleanup.ProtectEnabled` / `Cleanup.ProtectURL` / `Cleanup.ProtectClientID`).
9. **(Admin)** Against a **test** Jamf instance, exercise a safe Cleanup action
   (move-to-site) on a throwaway record before trusting the delete path.

---

## 5. Jamf Protect password — Keychain only

The Protect API password is entered in-app (Settings → Credentials, or the Cleanup
section) and stored in the Keychain item `com.herojoneslabs.fleethub.protect.password`.
It is never delivered by a profile.

---

## 6. Developer / unmanaged configuration

The loader reads each domain via `UserDefaults(suiteName:)`, which surfaces **both**
`/Library/Managed Preferences/<domain>.plist` (forced, wins) **and**
`~/Library/Preferences/<domain>.plist`. So on a dev Mac, plain `defaults write` against the
**suite domains** is the supported dev story — no profile needed:

This is also the third rung of the identity precedence chain (Entra → managed access `role`
→ user-level access `role`): standard CFPreferences precedence means the managed plist wins
wherever it delivers a value, so a user-level write only surfaces on a Mac where the profile
delivers nothing. It is a **dev story, not a deployment mechanism**.

```sh
defaults write com.herojoneslabs.fleethub.core jamfPro -dict \
  serverURL "https://yourorg.jamfcloud.com" masterClientID "REPLACE-WITH-MASTER-CLIENT-ID"
# The master client SECRET is never written with defaults: launch the app and enter it
# in the first-run onboarding (or Settings → Credentials). It goes straight to the Keychain.

# A role NAME alone grants nothing — you must also define what it means.
defaults write com.herojoneslabs.fleethub.access role "Dev.Admin"
# `roles` is an ARRAY of role objects, each naming itself — write the whole list at once.
defaults write com.herojoneslabs.fleethub.access roles '(
  {
    name = "Dev.Admin";
    modules = (dashboard, devices, announcements, logs, reports, cleanup, settings);
    computerActions = (sendBlankPush, restart, restartSilent, shutdown, enableBluetooth, disableBluetooth);
    cleanupActions = (addToGroup, moveToSite);
    allowExport = 1;
  }
)'

# Layer 1 must ALSO grant the ids above, or nothing renders:
defaults write com.herojoneslabs.fleethub.access deviceActions -dict-add computer '{
  actions = (
    { id = sendBlankPush; enabled = 1; },
    { id = restart; enabled = 1; },
    { id = restartSilent; enabled = 1; },
    { id = shutdown; enabled = 1; },
    { id = enableBluetooth; enabled = 1; },
    { id = disableBluetooth; enabled = 1; }
  );
}'
```

Notes:

- The app seeds **no placeholder values** at launch, and `MDMConfiguration.default` uses
  empty strings — an unconfigured dev Mac is genuinely unconfigured.
- **No role names are built into the app**, in any build configuration — a dev Mac with no
  `roles` block renders an empty app in every build configuration. Define the block above
  once and it persists.
- Remember the **two-layer** rule when a dev-Mac action stubbornly refuses to appear: it
  must be granted in **both** the role's `computerActions` and `deviceActions.computer.actions`
  (with `enabled = 1`). Forgetting layer 1 is the usual cause.
- Writing to `com.herojoneslabs.fleethub` (the bundle id) does nothing for managed config anymore.

## 7. Uninstall residue

`Deployment/OnDevice/Scripts/uninstall_fleethub.sh` removes the apps, receipts, and
the `com.herojoneslabs.fleethub` / `com.herojoneslabs.fleethub.menubar` local prefs. Two things it does
not cover:

- **Managed profiles** — unscope/remove all four configuration profiles in Jamf (the
  script never touches profiles).
- **Dev-written suite plists** — if anyone used the §6 dev story on that Mac, user-level
  `~/Library/Preferences/com.herojoneslabs.fleethub.{core,access,features,ui}.plist`
  files may remain. Remove with `defaults delete <domain>` per domain. (Secrets are in the
  Keychain; the uninstall script removes every FleetHub Keychain item.)
