#! /bin/bash

######################################################################
############## Begin Script Information Block ########################
######################################################################
# Name: Import-FleetHub-Credentials.sh
# Author: Heath Jones
# Date: 11-18-2026
# Purpose: Hands FleetHub's API client secrets to the FleetHub app, which stores them in the logged-in user's Keychain
# Version: 1.0 - Initial Script
#
# Requirements:
#   - Runs as root (Jamf policy), with a user logged in at the console
#   - FleetHub installed at /Applications/FleetHub.app (same policy, package before script)
#   - Jamf parameter $4: Jamf Pro provisioning (master) API client ID
#   - Jamf parameter $5: Jamf Pro provisioning (master) API client secret
#   - Jamf parameter $6: Jamf Platform API client ID
#   - Jamf parameter $7: Jamf Platform API client secret
#   - Jamf parameter $8: Apple Business Manager key ID
#   - Jamf parameter $9: Apple Business Manager private key (.pem), base64-encoded on one line
#   - Jamf parameter $10: Entra device cleanup app (client) ID
#   - Jamf parameter $11: Entra device cleanup client secret
#   - Give any of the pairs $4+$5, $6+$7, $8+$9, $10+$11. At least one pair is required.
#   - Policy frequency Ongoing, triggers Recurring Check-in and Login. Re-running
#     with unchanged values does nothing, so this is safe on every check-in.
#   - To rotate: put the NEW client ID and secret in the parameters first, then
#     change the client ID in the FleetHub Core profile, then delete the old client.
#     The ABM key rotates the same way, by its key ID.
#
######################################################################
############## End Script Information Block ##########################
######################################################################

####################################################################
############## Begin Define Variables Block ########################
####################################################################
##############################
### Core Defined Variables ###
### MODIFY AT YOUR OWN RISK ##
##############################

set -euo pipefail

# Ensure PATH is set so `which` resolves reliably in any execution context
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Binary paths (add task-specific binaries to User Defined Variables)
# `which` is preferred over `command -v` per the style guide, so the directive below is deliberate.
# shellcheck disable=SC2230
readonly AWK=$(which awk)
readonly BASENAME=$(which basename)
readonly DATE=$(which date)
readonly ID=$(which id)
readonly LOGGER=$(which logger)
readonly MKTEMP=$(which mktemp)
readonly RM=$(which rm)

# Org identity — REQUIRED, set per deployment.
# ORG_NAME_FRIENDLY: human-readable display name; MAY contain spaces. Use it for
#   user-facing text and swiftDialog banners. e.g. "Example Corp".
# ORG_NAME: path-safe — ORG_NAME_FRIENDLY with spaces removed — for filesystem
#   paths like /Library/Application Support/${ORG_NAME}/ and /Library/Logs/${ORG_NAME}/.
#   e.g. "ExampleCorp". (${var// /} is bash 3.2-safe; avoid '/' in the friendly name.)
# ORG_PLIST_DOMAIN: reverse-DNS — used for LOG_LABEL, LaunchDaemon/LaunchAgent
#   labels, and defaults preference domains. e.g. "com.example".
readonly ORG_NAME_FRIENDLY="Company Name"
# Part of the standard template; unused by this script.
# shellcheck disable=SC2034
readonly ORG_NAME="${ORG_NAME_FRIENDLY// /}"
readonly ORG_PLIST_DOMAIN="com.company"

# Script metadata
readonly SCRIPT_NAME=$("${BASENAME}" "$0")
readonly SCRIPT_VERSION="1.0"
readonly LOG_LABEL="${ORG_PLIST_DOMAIN}.${SCRIPT_NAME%.sh}"
# Part of the standard template; unused by this script.
# shellcheck disable=SC2034
readonly TIMESTAMP=$("${DATE}" +%Y%m%d_%H%M%S)
readonly JAMF_LOG="/var/log/jamf.log"

declare -a TEMP_FILES=()

##################################
### End Core Defined Variables ###
##################################

########################################
######## User Defined Variables ########
### Place your script variables here ###
########################################

# Task-specific binary paths
readonly SCUTIL=$(which scutil)
readonly LAUNCHCTL=$(which launchctl)
readonly SUDO=$(which sudo)

# The FleetHub executable. Its --import-credential mode stores a secret in the
# calling user's Keychain and exits without opening a window.
readonly FLEETHUB_BIN="/Applications/FleetHub.app/Contents/MacOS/FleetHub"

# Jamf parameters ($1-$3 are reserved by Jamf: mount point, computer name, username)
# SECURITY NOTICE: $5, $7, $9 and $11 are secrets. They are stored in Jamf Pro on the
# policy and can be read by anyone who can view that policy. This script never
# logs or prints them, and passes them to FleetHub on standard input so they do
# not appear in FleetHub's process arguments. $9 is the most sensitive: that
# key can assign and unassign devices across the whole ABM organization.
readonly PARAM_JAMF_CLIENT_ID="${4:-}"
readonly PARAM_JAMF_CLIENT_SECRET="${5:-}"
readonly PARAM_PLATFORM_CLIENT_ID="${6:-}"
readonly PARAM_PLATFORM_CLIENT_SECRET="${7:-}"
readonly PARAM_ABM_KEY_ID="${8:-}"
# Base64 of the whole .pem file, on one line (Jamf parameters cannot hold a
# multi-line value). FleetHub decodes it; this script never does.
readonly PARAM_ABM_PRIVATE_KEY_B64="${9:-}"
readonly PARAM_ENTRA_CLIENT_ID="${10:-}"
readonly PARAM_ENTRA_CLIENT_SECRET="${11:-}"

##################################
### End User Defined Variables ###
##################################
####################################################################
############## End Define Variables Block ##########################
####################################################################

###################################################################################
############## Begin Function Block ###############################################
###################################################################################
##############################
### Core Defined Functions ###
### MODIFY AT YOUR OWN RISK ##
##############################

# ── Logging ──────────────────────────────────────────────────────────────────
log_info() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [INFO] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.info "[INFO] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_warn() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [WARN] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.warning "[WARN] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_error() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [ERROR] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.err "[ERROR] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

log_debug() {
    local log_msg="$("${DATE}" '+%Y-%m-%d %H:%M:%S') ${SCRIPT_NAME}[$$]: [DEBUG] $*"
    "${LOGGER}" -t "${LOG_LABEL}" -p user.debug "[DEBUG] $*"
    echo -e "${log_msg}" | tee -ai "${JAMF_LOG}"
}

# ── Cleanup (trapped on EXIT/INT/TERM) ───────────────────────────────────────
cleanup() {
    local exit_code=$?
    local f
    for f in "${TEMP_FILES[@]:-}"
    do
        if [[ -f "${f}" ]]
        then
            "${RM}" -f "${f}"
        fi
    done
    log_info "${SCRIPT_NAME} exiting with code ${exit_code}"
    exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# ── Preflight ────────────────────────────────────────────────────────────────
require_root() {
    if [[ "$("${ID}" -u)" -ne 0 ]]
    then
        log_error "Must run as root"
        exit 1
    fi
}

##################################
### End Core Defined Functions ###
##################################

########################################
######## User Defined Functions ########
### Place your script functions here ###
########################################

# FleetHub must already be installed: it is the only program that may write
# its own Keychain items without the user being prompted afterwards.
require_fleethub() {
    if [[ ! -x "${FLEETHUB_BIN}" ]]
    then
        log_error "FleetHub not found at ${FLEETHUB_BIN}. Install the package before this script runs."
        exit 1
    fi
}

# A client ID and its secret travel together. Fails when only one of a pair
# was given, and when neither pair was given at all.
require_credential_pairs() {
    if [[ -n "${PARAM_JAMF_CLIENT_ID}" && -z "${PARAM_JAMF_CLIENT_SECRET}" ]]
    then
        log_error "Parameter 4 (Jamf Pro client ID) is set but parameter 5 (its secret) is empty"
        exit 1
    fi

    if [[ -z "${PARAM_JAMF_CLIENT_ID}" && -n "${PARAM_JAMF_CLIENT_SECRET}" ]]
    then
        log_error "Parameter 5 (Jamf Pro client secret) is set but parameter 4 (its client ID) is empty"
        exit 1
    fi

    if [[ -n "${PARAM_PLATFORM_CLIENT_ID}" && -z "${PARAM_PLATFORM_CLIENT_SECRET}" ]]
    then
        log_error "Parameter 6 (Platform client ID) is set but parameter 7 (its secret) is empty"
        exit 1
    fi

    if [[ -z "${PARAM_PLATFORM_CLIENT_ID}" && -n "${PARAM_PLATFORM_CLIENT_SECRET}" ]]
    then
        log_error "Parameter 7 (Platform client secret) is set but parameter 6 (its client ID) is empty"
        exit 1
    fi

    if [[ -n "${PARAM_ABM_KEY_ID}" && -z "${PARAM_ABM_PRIVATE_KEY_B64}" ]]
    then
        log_error "Parameter 8 (ABM key ID) is set but parameter 9 (the base64 private key) is empty"
        exit 1
    fi

    if [[ -z "${PARAM_ABM_KEY_ID}" && -n "${PARAM_ABM_PRIVATE_KEY_B64}" ]]
    then
        log_error "Parameter 9 (ABM private key) is set but parameter 8 (its key ID) is empty"
        exit 1
    fi

    if [[ -n "${PARAM_ENTRA_CLIENT_ID}" && -z "${PARAM_ENTRA_CLIENT_SECRET}" ]]
    then
        log_error "Parameter 10 (Entra client ID) is set but parameter 11 (its secret) is empty"
        exit 1
    fi

    if [[ -z "${PARAM_ENTRA_CLIENT_ID}" && -n "${PARAM_ENTRA_CLIENT_SECRET}" ]]
    then
        log_error "Parameter 11 (Entra client secret) is set but parameter 10 (its client ID) is empty"
        exit 1
    fi

    if [[ -z "${PARAM_JAMF_CLIENT_ID}" && -z "${PARAM_PLATFORM_CLIENT_ID}" && -z "${PARAM_ABM_KEY_ID}" && -z "${PARAM_ENTRA_CLIENT_ID}" ]]
    then
        log_error "No credentials given. Set parameters 4 and 5, 6 and 7, 8 and 9, or 10 and 11."
        exit 1
    fi
}

# Prints the console user's short name. Returns 1 when nobody is logged in
# (login window, Setup Assistant, or a system account at the console).
get_current_user() {
    local console_user
    # The $3 below is awk's field, not a shell variable.
    # shellcheck disable=SC2016
    console_user=$("${SCUTIL}" <<< "show State:/Users/ConsoleUser" | "${AWK}" '/Name :/ && ! /loginwindow/ { print $3 }')

    if [[ -z "${console_user}" || "${console_user}" == "root" || "${console_user}" == "_mbsetupuser" ]]
    then
        return 1
    fi

    printf '%s\n' "${console_user}"
}

# Hands one secret to FleetHub, running FleetHub as the console user so the
# item lands in that user's Keychain. The secret goes in on standard input.
#   $1 kind (jamfPro | platform | abm | entra)   $2 client ID or ABM key ID   $3 secret
#   $4 console user                      $5 console user's UID
#   $6 optional: "--base64" when $3 is base64 text for FleetHub to decode
import_credential() {
    local kind="$1"
    local client_id="$2"
    local client_secret="$3"
    local console_user="$4"
    local console_uid="$5"
    local encoding_flag="${6:-}"
    local -a import_args=(--import-credential "${kind}" --client-id "${client_id}")

    if [[ -n "${encoding_flag}" ]]
    then
        import_args+=("${encoding_flag}")
    fi

    log_info "Importing the ${kind} secret for client ${client_id} as ${console_user}"

    # -H sets HOME to the user's home. Without it HOME stays root's, the
    # login Keychain is not found, and macOS shows a "Keychain Not Found"
    # dialog instead of saving.
    if ! printf '%s' "${client_secret}" | "${LAUNCHCTL}" asuser "${console_uid}" "${SUDO}" -H -u "${console_user}" \
        "${FLEETHUB_BIN}" "${import_args[@]}"
    then
        log_error "FleetHub did not store the ${kind} secret (see its message above)"
        return 1
    fi

    log_info "FleetHub holds the ${kind} secret for client ${client_id}"
}

##################################
### End User Defined Functions ###
##################################
###################################################################################
############## End Function Block #################################################
###################################################################################

#####################################################
################## Run Script Block #################
#####################################################

log_info "${SCRIPT_NAME} v${SCRIPT_VERSION} starting"

require_root
require_fleethub
require_credential_pairs

# The Keychain belongs to a user, so there is nothing to do until one is
# logged in. Exit 0: the policy runs again at the next check-in or login.
if ! current_user=$(get_current_user)
then
    log_warn "No user is logged in. Nothing imported; the policy will try again at the next login or check-in."
    exit 0
fi

current_uid=$("${ID}" -u "${current_user}")
failures=0

if [[ -n "${PARAM_JAMF_CLIENT_ID}" ]]
then
    if ! import_credential "jamfPro" "${PARAM_JAMF_CLIENT_ID}" "${PARAM_JAMF_CLIENT_SECRET}" "${current_user}" "${current_uid}"
    then
        failures=$((failures + 1))
    fi
fi

if [[ -n "${PARAM_PLATFORM_CLIENT_ID}" ]]
then
    if ! import_credential "platform" "${PARAM_PLATFORM_CLIENT_ID}" "${PARAM_PLATFORM_CLIENT_SECRET}" "${current_user}" "${current_uid}"
    then
        failures=$((failures + 1))
    fi
fi

if [[ -n "${PARAM_ABM_KEY_ID}" ]]
then
    if ! import_credential "abm" "${PARAM_ABM_KEY_ID}" "${PARAM_ABM_PRIVATE_KEY_B64}" "${current_user}" "${current_uid}" "--base64"
    then
        failures=$((failures + 1))
    fi
fi

if [[ -n "${PARAM_ENTRA_CLIENT_ID}" ]]
then
    if ! import_credential "entra" "${PARAM_ENTRA_CLIENT_ID}" "${PARAM_ENTRA_CLIENT_SECRET}" "${current_user}" "${current_uid}"
    then
        failures=$((failures + 1))
    fi
fi

if [[ "${failures}" -gt 0 ]]
then
    log_error "${failures} credential import(s) failed"
    exit 1
fi

log_info "${SCRIPT_NAME} completed successfully"

###########################################################
################## End Script Block #######################
###########################################################
