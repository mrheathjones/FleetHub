# Feature Notes

Details behind a few features that need more than a line: health card scope, report filters, Screen Share and SSH.

## Health cards: leaving devices out, or measuring only some

Each `features.healthScorecard.cards[]` entry can leave devices out of that one metric with three optional string arrays: `excludeSiteIds`, `excludeComputerGroupIds` and `excludeMobileGroupIds` (Jamf ids, the same format as `siteIds` / `computerGroupIds` / `mobileGroupIds`). An excluded device counts neither as passing nor failing: it is absent from the card's percentage, the fleet score and the drill-down lists, and its own page shows the metric as Excluded. Exclusion wins over inclusion, so `allDevices: true` with one excluded group measures everything except that group. Excluding by computer group needs `GROUP_MEMBERSHIPS` in `computers.inventorySections`.

A card can also measure only the sites or groups you list: set `allDevices` to false and fill `siteIds`, `computerGroupIds` or `mobileGroupIds`. FleetHub Setup offers both as Leave Out and Only Include on each card. When a device is in both lists, it is left out.

## Report Filters: Site, Building and Department

In Report Builder these three filters list what is actually on the devices in the inventory, one per row, with a search field once a list passes eight entries. Each takes one or more values (a device matches when it is in any of them) and can be reversed (Member of / Not member of, In / Not in).

Jamf's inventory carries building and department as ids. FleetHub reads the names from `/api/v1/buildings` and `/api/v1/departments`, which need the API privileges **Read Buildings** and **Read Departments**. Without them the lists still work but show "Building ID 12" style labels, with a note saying why. Mobile devices carry only a site id; the site's name is shown when a computer in the same site supplies it.

## Screen Share Panel

Screen Share opens Apple's Screen Sharing app, which FleetHub cannot place inside its own window. FleetHub opens a small floating panel beside it instead, with the device, the session time, the password rotation countdown (when automatic sign-in used the management account's password), **Copy Password** (roles with `viewLocalAdminPassword` only) and **End Session**.

When your organization turns on the approval prompt, the person at the Mac must click **Allow** before the session opens, unless your role is exempt. FleetHub shows who it is waiting on and says why if the session is refused. [Integrations.md](Integrations.md#asking-before-screen-share) describes the setup and its limits.

End Session quits Apple's Screen Sharing app, so it closes every Screen Sharing session that app has open, not only this one. Closing the panel leaves the session running. The panel notices when Screen Sharing quits and records the session's length in the action log.

## SSH

The **SSH** computer action opens a terminal window signed in to the Mac as its Jamf management account (the LAPS `JMF` account). Grant it per role with the `ssh` computer action in the access profile; it is off for every role until granted.

What happens when an operator chooses SSH:

1. FleetHub picks the address: the VPN address from the extension attribute when that lookup is enabled and the device reports one, otherwise the address in the Jamf inventory record.
2. It checks that the SSH port answers at that address.
3. It reads the management account and its current password from Jamf with the operator's own API client. The password is never shown, logged or written to disk.
4. It signs in with the Mac's own `/usr/bin/ssh` and, only if that succeeds, opens the FleetHub SSH window.

Every step reports through FleetHub's own prompts, including each way it can fail.

| Needs | Detail |
|---|---|
| Role | `ssh` in the role's `computerActions` |
| Jamf API role | **View Local Admin Password**, and **View Local Admin Password Audit History** for the real rotation countdown (see Password Rotation Countdown below). |
| On the Mac | Remote Login on, and the management account allowed to use it. FleetHub cannot turn Remote Login on. |
| Features profile | `computers.sshPort` (default 22) and `computers.sshPasswordRotationMinutes` (default 60; match Jamf's LAPS Password Rotation Time). |

**Password rotation.** Jamf rotates the password some time after it is read. The window shows a countdown and brings itself forward five minutes before. An open session stays connected after rotation; `sudo` and new sign-ins need the new password.

**Copy Password.** The window has a Copy Password button for `sudo`, shown only when the operator's role also grants `viewLocalAdminPassword`. Each click reads the account's current password from Jamf, so it is right even after a rotation. The password is never drawn on screen, is marked so clipboard managers skip it, and is removed from the clipboard after 60 seconds. Each copy is logged.

**Host keys.** FleetHub keeps its own list in `~/Library/Application Support/FleetHub/ssh_known_hosts` and never reads or writes `~/.ssh`. A key is saved under the device's serial number, so a reused IP address is not mistaken for a changed Mac. The first connection to a Mac is accepted and saved. If a saved key later changes (normal after an erase), FleetHub stops and offers to delete the saved key and connect.

**Logging.** FleetHub records the password use, the session start and end with its length, and each failure. It does not record what is typed.

The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), pinned to an exact version.

## Password Rotation Countdown

The Local Admin Password panel, the Screen Share panel and the SSH window all count down to the
moment Jamf rotates the password.

Jamf rotates a LAPS password a set time after it is **first** viewed. A password someone viewed
30 minutes ago, with a 60-minute rotation time, has 30 minutes left, whoever views it next. To
show that, FleetHub reads the password's audit history from Jamf
(`/api/v2/local-admin-password/{id}/account/{username}/audit`), finds the entry for the password
it just read, and uses that entry's expiry and first view.

| Jamf API role holds | The countdown shows |
|---|---|
| **View Local Admin Password Audit History** | The real rotation time. |
| Not that privilege | An estimate that starts when FleetHub read the password, marked **Estimated**, with the reason. It is too long when someone viewed the password earlier. |

The rotation period comes from Jamf's LAPS settings when the role can read them (**Update Local
Admin Password Settings**, which operator roles normally do not hold). Otherwise FleetHub uses
`computers.sshPasswordRotationMinutes` from the Features profile (default 60): set it to Jamf's
**Password Rotation Time**.

The panel hides the password until **Show** is clicked, copies it with **Copy Password** (the
clipboard is cleared after a minute), and forgets it when the panel closes or the rotation is due.

## FileVault Recovery Key Panel

The FileVault Key action opens the same panel with the Mac's personal recovery key, the key's
status in Jamf, and the keys to press on the Mac: **Option-Shift-Return** at the FileVault login
screen shows the recovery key field (Apple silicon, macOS 12.0.1 or later). When no field appears,
the key is entered in macOS Recovery. There is no countdown, because a recovery key does not
rotate on a timer. Copy Recovery Key reads the key from Jamf again and is logged.
