#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: uninstall_fleethub.sh
# Author: Heath Jones
# Date: 11-18-2026
# Purpose: Cleanly remove FleetHub, the FleetHubMenuBar companion and
#          FleetHub Setup from a managed Mac: quit the apps, delete the
#          bundles, forget the pkg receipts, and clear the console
#          user's local preferences, app data and Keychain items.
#          Intended as a Jamf Pro script payload (run as root).
#          NOTE: managed Configuration Profiles are removed by Jamf
#          (unscope/remove the profiles) — this script does not touch
#          them. The shared announcements folder under
#          /Library/Application Support/FleetHub is also left in place.
# Version: 1.0 - Initial Script
#
######################################################################
############## End Script Information Block ##########################
######################################################################

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

readonly MAIN_APP="/Applications/FleetHub.app"
readonly MENUBAR_APP="/Applications/FleetHubMenuBar.app"
readonly SETUP_APP="/Applications/FleetHubSetup.app"
readonly MAIN_BUNDLE_ID="com.herojoneslabs.fleethub"
readonly MENUBAR_BUNDLE_ID="com.herojoneslabs.fleethub.menubar"
readonly SETUP_BUNDLE_ID="com.herojoneslabs.fleethub.setup"

# Every Keychain account the apps create starts with this. That covers the
# sign-in items, the secrets typed in Settings, and the per-client secrets
# delivered by the credential policy (…<secret>.client.<client id>).
readonly KEYCHAIN_ACCOUNT_PREFIX="com.herojoneslabs.fleethub."

# Per-user folders the apps write to, relative to the user's home folder.
readonly USER_DATA_PATHS=(
    "Library/Application Support/FleetHub"
    "Library/Application Support/FleetHub Setup"
    "Library/Application Support/${MAIN_BUNDLE_ID}"
    "Library/Caches/${MAIN_BUNDLE_ID}"
    "Library/Caches/${MENUBAR_BUNDLE_ID}"
    "Library/Caches/${SETUP_BUNDLE_ID}"
    "Library/HTTPStorages/${MAIN_BUNDLE_ID}"
    "Library/HTTPStorages/${SETUP_BUNDLE_ID}"
)

info() { printf '==> %s\n' "$*"; }

# Resolve the currently logged-in console user (empty at the login window).
consoleUser=$(/usr/bin/stat -f%Su /dev/console 2>/dev/null)
[[ "${consoleUser}" == "root" ]] && consoleUser=""

# Processes are matched by the app's executable path: a bundle identifier
# does not appear in a process's command line.
quit_app() {
    local appPath="$1"
    /usr/bin/pkill -f "${appPath}/Contents/MacOS/" 2>/dev/null || true
}

remove_app() {
    local appPath="$1"
    if [[ -d "${appPath}" ]]
    then
        info "Removing ${appPath}"
        /bin/rm -rf "${appPath}"
    fi
}

forget_receipt() {
    local pkgID="$1"
    if /usr/sbin/pkgutil --pkgs | /usr/bin/grep -qx "${pkgID}"
    then
        info "Forgetting pkg receipt ${pkgID}"
        /usr/sbin/pkgutil --forget "${pkgID}" >/dev/null 2>&1 || true
    fi
}

run_as_user() {
    /bin/launchctl asuser "${consoleUID}" /usr/bin/sudo -H -u "${consoleUser}" "$@"
}

# ---------------------------------------------------------------------------
# 1. Quit running instances
# ---------------------------------------------------------------------------
info "Quitting FleetHub processes…"
quit_app "${MAIN_APP}"
quit_app "${MENUBAR_APP}"
quit_app "${SETUP_APP}"

# ---------------------------------------------------------------------------
# 2. Remove the app bundles
# ---------------------------------------------------------------------------
remove_app "${MAIN_APP}"
remove_app "${MENUBAR_APP}"
remove_app "${SETUP_APP}"

# ---------------------------------------------------------------------------
# 3. Forget pkg receipts
# ---------------------------------------------------------------------------
forget_receipt "${MAIN_BUNDLE_ID}"
forget_receipt "${MENUBAR_BUNDLE_ID}"
forget_receipt "${SETUP_BUNDLE_ID}"

# ---------------------------------------------------------------------------
# 4. Clear the console user's preferences, app data and Keychain items
#    (managed-profile values are removed by Jamf, not here)
# ---------------------------------------------------------------------------
if [[ -n "${consoleUser}" ]]
then
    consoleUID=$(/usr/bin/id -u "${consoleUser}" 2>/dev/null)
    consoleHome=$(/usr/bin/dscl . -read "/Users/${consoleUser}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
    [[ -z "${consoleHome}" ]] && consoleHome="/Users/${consoleUser}"

    info "Clearing local preferences for ${consoleUser}…"
    # The main bundle-ID domain doubles as the app<->menu bar IPC suite,
    # so deleting it also clears the suite plist.
    for prefsDomain in \
        "${MAIN_BUNDLE_ID}" \
        "${MENUBAR_BUNDLE_ID}" \
        "${SETUP_BUNDLE_ID}"
    do
        run_as_user /usr/bin/defaults delete "${prefsDomain}" >/dev/null 2>&1 || true

        # Stale UserDefaults plist (in case cfprefsd has flushed it to disk).
        userPlist="${consoleHome}/Library/Preferences/${prefsDomain}.plist"
        [[ -f "${userPlist}" ]] && /bin/rm -f "${userPlist}"
    done

    info "Removing app data for ${consoleUser}…"
    # Action log, saved SSH host keys, caches and Setup's saved form.
    for dataPath in "${USER_DATA_PATHS[@]}"
    do
        if [[ -e "${consoleHome}/${dataPath}" ]]
        then
            /bin/rm -rf "${consoleHome:?}/${dataPath}"
        fi
    done

    info "Removing FleetHub Keychain items…"
    # The apps store every item with an account name only (no service), so
    # items are found by account. List the accounts that carry the FleetHub
    # prefix, then delete each one by its exact name.
    keychainAccounts=$(run_as_user /usr/bin/security dump-keychain 2>/dev/null \
        | /usr/bin/awk -F'"' -v prefix="${KEYCHAIN_ACCOUNT_PREFIX}" \
            '$2 == "acct" && index($4, prefix) == 1 { print $4 }' \
        | /usr/bin/sort -u)
    while IFS= read -r keychainAccount
    do
        [[ -z "${keychainAccount}" ]] && continue
        run_as_user /usr/bin/security delete-generic-password -a "${keychainAccount}" >/dev/null 2>&1 || true
    done <<< "${keychainAccounts}"
else
    info "No console user logged in — skipping per-user cleanup."
fi

info "FleetHub removed."
exit 0
