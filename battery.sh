#!/bin/bash

## ###############
## Update management
## variables are used by this binary as well at the update script
## ###############
BATTERY_CLI_VERSION="v1.3.5"

# If a script may run as root:
#   - Reset PATH to safe defaults at the very beginning of the script.
#   - Never include user-owned directories in PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Ensure Ctrl+C stops the entire script, not just the current command
trap 'exit 130' INT

## ###############
## Variables
## ###############
visudo_folder=/private/etc/sudoers.d
visudo_file=${visudo_folder}/battery
configfolder=$HOME/.battery
pidfile=$configfolder/battery.pid
logfile=$configfolder/battery.log
maintain_percentage_tracker_file=$configfolder/maintain.percentage
maintain_voltage_tracker_file=$configfolder/maintain.voltage
daemon_path=$HOME/Library/LaunchAgents/battery.plist
calibrate_pidfile=$configfolder/calibrate.pid
path_configfile=/etc/paths.d/50-battery

# Voltage limits
voltage_min="10.5"
voltage_max="12.6"
voltage_hyst_min="0.1"
voltage_hyst_max="2"

# SECURITY NOTES:
# - ALWAYS hardcode and use the absolute path to the battery executables to avoid PATH-based spoofing.
#   Think of the scenario where 'battery update_silent' running as root invokes 'battery visudo' as a
#   PATH spoofing opportunity example.
# - Ensure this script, smc binary and their parent folders are root-owned and not writable by
#   the user or others.
# - Ensure that you are not sourcing any user-writable scripts within this script to avoid overrides of
#   security critical variables.
binfolder="/usr/local/co.palokaj.battery"
battery_binary="$binfolder/battery"
smc_binary="$binfolder/smc"

# GitHub URLs for setup and updates.
# Temporarily set to your username and branch to test update functionality with your fork.
# Security note: Do NOT allow github_user or github_branch to be injected via environment
#                variables or any other means. Keep them hardcoded.
github_user="actuallymentor"
github_branch="main"
github_url_setup_sh="https://raw.githubusercontent.com/${github_user}/battery/${github_branch}/setup.sh"
github_url_update_sh="https://raw.githubusercontent.com/${github_user}/battery/${github_branch}/update.sh"
github_url_battery_sh="https://raw.githubusercontent.com/${github_user}/battery/${github_branch}/battery.sh"

## ###############
## Housekeeping
## ###############

# Create config folder if needed
mkdir -p $configfolder

# create logfile if needed
touch $logfile

# Trim logfile if needed
logsize=$(stat -f%z "$logfile")
max_logsize_bytes=5000000
if ((logsize > max_logsize_bytes)); then
	tail -n 100 $logfile >$logfile
fi

# CLI help message
helpmessage="
Battery CLI utility $BATTERY_CLI_VERSION

Usage:

  battery status
    output battery SMC status, % and time remaining

  battery logs LINES[integer, optional]
    output logs of the battery CLI and GUI
    eg: battery logs 100

  battery maintain PERCENTAGE[1-100,stop] or RANGE[lower-upper]
    reboot-persistent battery level maintenance: turn off charging above, and on below a certain value
    it has the option of a --force-discharge flag that discharges even when plugged in (this does NOT work well with clamshell mode)
    eg: battery maintain 80           # maintain at 80%
    eg: battery maintain 70-80        # maintain between 70-80%
    eg: battery maintain stop

  battery maintain VOLTAGE[${voltage_min}V-${voltage_max}V,stop] (HYSTERESIS[${voltage_hyst_min}V-${voltage_hyst_max}V])
    reboot-persistent battery level maintenance: keep battery at a certain voltage
  default hysteresis: 0.1V
    eg: battery maintain 11.4V       # keeps battery between 11.3V and 11.5V
    eg: battery maintain 11.4V 0.3V  # keeps battery between 11.1V and 11.7V

  battery charging SETTING[on/off]
    manually set the battery to (not) charge
    eg: battery charging on

  battery adapter SETTING[on/off]
    manually set the adapter to (not) charge even when plugged in
    eg: battery adapter off

  battery calibrate
    calibrate the battery by discharging it to 15%, then recharging it to 100%, and keeping it there for 1 hour
    battery maintenance is restored upon completion
    menubar battery app execution and/or battery maintain command will interrupt calibration

  battery charge LEVEL[1-100]
    charge the battery to a certain percentage; battery maintenance is restored upon completion
    eg: battery charge 90

  battery discharge LEVEL[1-100]
    block adapter power until the battery reaches the specified level; battery maintenance is restored upon completion
    eg: battery discharge 90

  battery update
    update the battery utility to the latest version

  battery reinstall
    reinstall the battery utility to the latest version (reruns the installation script)

  battery uninstall
    enable charging, remove the smc tool, and the battery script

"

# Visudo instructions
# File location: /etc/sudoers.d/battery
# Purpose:
# - Allows this script to execute 'sudo smc -w' commands without requiring a user password.
# - Allows passwordless updates.
visudoconfig="
# Visudo settings for the battery utility installed from https://github.com/actuallymentor/battery
# intended to be placed in $visudo_file on a mac

# Allow passwordless update (All battery app executables are owned by root to prevent privilege escalation attacks)
ALL ALL = NOPASSWD: $battery_binary update_silent
ALL ALL = NOPASSWD: $battery_binary update_silent is_enabled

# Allow passwordless battery-charging–related SMC write commands
Cmnd_Alias    CHARGING_OFF = $smc_binary -k CH0B -w 02, $smc_binary -k CH0C -w 02, $smc_binary -k CHTE -w 01000000
Cmnd_Alias    CHARGING_ON = $smc_binary -k CH0B -w 00, $smc_binary -k CH0C -w 00, $smc_binary -k CHTE -w 00000000
Cmnd_Alias    FORCE_DISCHARGE_OFF = $smc_binary -k CH0I -w 00, $smc_binary -k CHIE -w 00, $smc_binary -k CH0J -w 00
Cmnd_Alias    FORCE_DISCHARGE_ON = $smc_binary -k CH0I -w 01, $smc_binary -k CHIE -w 08, $smc_binary -k CH0J -w 01
Cmnd_Alias    LED_CONTROL = $smc_binary -k ACLC -w 04, $smc_binary -k ACLC -w 03, $smc_binary -k ACLC -w 02, $smc_binary -k ACLC -w 01, $smc_binary -k ACLC -w 00
ALL ALL = NOPASSWD: CHARGING_OFF
ALL ALL = NOPASSWD: CHARGING_ON
ALL ALL = NOPASSWD: FORCE_DISCHARGE_OFF
ALL ALL = NOPASSWD: FORCE_DISCHARGE_ON
ALL ALL = NOPASSWD: LED_CONTROL

# Allow passwordless SMC reads for runtime key probing and status checks.
Cmnd_Alias    SMC_READ = $smc_binary -k CHTE -r, $smc_binary -k CH0B -r, $smc_binary -k CH0C -r, $smc_binary -k CHIE -r, $smc_binary -k CH0J -r, $smc_binary -k CH0I -r, $smc_binary -k ACLC -r
ALL ALL = NOPASSWD: SMC_READ
"

# Get parameters
action=$1
setting=$2
subsetting=$3

## ###############
## Helpers
## ###############

function log() {
	echo -e "$(date +%D-%T) [$$]: $*"
}

function valid_percentage() {
	if ! [[ "$1" =~ ^[0-9]+$ ]] || [[ "$1" -lt 0 ]] || [[ "$1" -gt 100 ]]; then
		return 1
	else
		return 0
	fi
}

function valid_percentage_range() {
	# Check if input matches range format: NUMBER-NUMBER
	if ! [[ "$1" =~ ^[0-9]+-[0-9]+$ ]]; then
		return 1
	fi

	# Extract lower and upper bounds
	local lower="${1%-*}"
	local upper="${1#*-}"

	# Validate both numbers are valid percentages
	if ! valid_percentage "$lower" || ! valid_percentage "$upper"; then
		return 1
	fi

	# Check lower < upper
	if [[ "$lower" -ge "$upper" ]]; then
		return 1
	fi

	# Check bounds are reasonable (lower >= 10, upper <= 100)
	if [[ "$lower" -lt 10 ]] || [[ "$upper" -gt 100 ]]; then
		return 1
	fi

	return 0
}

function valid_voltage() {
	if [[ "$1" =~ ^[0-9]+(\.[0-9]+)?V$ ]]; then
		return 0
	fi
	return 1
}

charging_control_keys="CHTE CH0B CH0C"
adapter_control_keys="CHIE CH0J CH0I"

function smc_output_to_hex() {
	local line="$1"
	local value
	if [[ -z "$line" || "$line" =~ [Nn]o[[:space:]]data || "$line" =~ [Ee]rror || "$line" =~ [Pp]assword || "$line" =~ [Rr]equired || "$line" =~ [Nn]o[[:space:]]such[[:space:]]file || "$line" =~ [Nn]ot[[:space:]]found ]]; then
		echo
		return
	fi
	if [[ "$line" != *bytes* ]]; then
		echo
		return
	fi
	value="${line#*bytes}"
	echo "$value" | tr -cd '[:xdigit:]' | tr '[:lower:]' '[:upper:]'
}

function smc_read_hex_raw() {
	local key=$1
	local use_sudo=$2
	local line
	if [[ "$use_sudo" == "sudo" ]]; then
		line="$(sudo -n "$smc_binary" -k "$key" -r 2>&1)"
	else
		line="$("$smc_binary" -k "$key" -r 2>&1)"
	fi
	smc_output_to_hex "$line"
}

function smc_read_hex() {
	local key=$1
	local value
	value="$(smc_read_hex_raw "$key")"
	if [[ -n "$value" ]]; then
		echo "$value"
		return
	fi
	if [[ $EUID -ne 0 ]]; then
		smc_read_hex_raw "$key" sudo
	fi
}

function hex_values_match() {
	local observed="$1"
	local expected="$2"
	local observed_trim
	local expected_trim
	observed_trim="$(echo "$observed" | sed 's/^0*//')"
	expected_trim="$(echo "$expected" | sed 's/^0*//')"
	[[ -z "$observed_trim" ]] && observed_trim="0"
	[[ -z "$expected_trim" ]] && expected_trim="0"
	[[ "$observed_trim" == "$expected_trim" ]]
}

function smc_write_hex() {
	local key=$1
	local hex_value=$2
	if ! sudo "$smc_binary" -k "$key" -w "$hex_value" >/dev/null 2>&1; then
		log "⚠️ Failed to write $hex_value to $key"
		return 1
	fi
	return 0
}

function smc_write_hex_verified() {
	local key=$1
	local hex_value=$2
	local readback
	if ! smc_write_hex "$key" "$hex_value"; then
		return 1
	fi
	readback="$(smc_read_hex "$key")"
	if [[ -z "$readback" ]]; then
		log "⚠️ Unable to verify write $hex_value to $key: readback unavailable"
		return 1
	fi
	if ! hex_values_match "$readback" "$hex_value"; then
		log "⚠️ Failed to verify write $hex_value to $key: read back $readback"
		return 1
	fi
	return 0
}

function charging_control_value() {
	local key=$1
	local state=$2
	if [[ "$key" == "CHTE" && "$state" == "on" ]]; then echo "00000000"; return; fi
	if [[ "$key" == "CHTE" && "$state" == "off" ]]; then echo "01000000"; return; fi
	if [[ "$state" == "on" ]]; then echo "00"; return; fi
	echo "02"
}

function adapter_control_value() {
	local key=$1
	local state=$2
	if [[ "$state" == "off" ]]; then echo "00"; return; fi
	if [[ "$key" == "CHIE" ]]; then echo "08"; return; fi
	echo "01"
}

## #########################
## Detect supported SMC keys
## #########################
function smc_key_has_data() {
	[[ -n "$(smc_read_hex "$1")" ]]
}

smc_key_has_data CHTE && smc_supports_chte=true || smc_supports_chte=false;
smc_key_has_data CH0B && smc_supports_legacy_ch0b=true || smc_supports_legacy_ch0b=false;
smc_key_has_data CH0C && smc_supports_legacy_ch0c=true || smc_supports_legacy_ch0c=false;
[[ "$smc_supports_legacy_ch0b" == "true" || "$smc_supports_legacy_ch0c" == "true" ]] && smc_supports_legacy=true || smc_supports_legacy=false;
smc_key_has_data CHIE && smc_supports_adapter_chie=true || smc_supports_adapter_chie=false;
smc_key_has_data CH0I && smc_supports_adapter_ch0i=true || smc_supports_adapter_ch0i=false;
smc_key_has_data CH0J && smc_supports_adapter_ch0j=true || smc_supports_adapter_ch0j=false;

function log_smc_capabilities() {
	log "SMC capabilities: CHTE=$smc_supports_chte legacy=$smc_supports_legacy CH0B=$smc_supports_legacy_ch0b CH0C=$smc_supports_legacy_ch0c CHIE=$smc_supports_adapter_chie CH0I=$smc_supports_adapter_ch0i CH0J=$smc_supports_adapter_ch0j"
}

function supports_charging_control() {
	[[ "$smc_supports_chte" == "true" || "$smc_supports_legacy" == "true" ]]
}

function supports_adapter_control() {
	[[ "$smc_supports_adapter_chie" == "true" || "$smc_supports_adapter_ch0j" == "true" || "$smc_supports_adapter_ch0i" == "true" ]]
}

function write_charging_control() {
	local state=$1
	local key
	local value
	local wrote_legacy=false
	local legacy_failed=false

	if smc_key_has_data CHTE; then
		value="$(charging_control_value CHTE "$state")"
		if smc_write_hex_verified CHTE "$value"; then
			return 0
		fi
	fi

	for key in CH0B CH0C; do
		if smc_key_has_data "$key"; then
			wrote_legacy=true
			value="$(charging_control_value "$key" "$state")"
			if ! smc_write_hex_verified "$key" "$value"; then
				legacy_failed=true
			fi
		fi
	done

	[[ "$wrote_legacy" == "true" && "$legacy_failed" == "false" ]]
}

function write_adapter_control() {
	local state=$1
	local key
	local value
	for key in $adapter_control_keys; do
		if smc_key_has_data "$key"; then
			value="$(adapter_control_value "$key" "$state")"
			if smc_write_hex_verified "$key" "$value"; then
				return 0
			fi
		fi
	done
	return 1
}

## #################
## SMC Manipulation
## #################

# Change magsafe color
# see community sleuthing: https://github.com/actuallymentor/battery/issues/71
function change_magsafe_led_color() {
	local color=$1

	log "💡 Setting magsafe color to $color"

	if [[ "$color" == "green" ]]; then
		log "setting LED to green"
		sudo $smc_binary -k ACLC -w 03
	elif [[ "$color" == "orange" ]]; then
		log "setting LED to orange"
		sudo $smc_binary -k ACLC -w 04
	else
		# Default action: reset. Value 00 is a guess and needs confirmation
		log "resetting LED"
		sudo $smc_binary -k ACLC -w 00
	fi
}

# Re:discharging, we're using keys uncovered by @howie65: https://github.com/actuallymentor/battery/issues/20#issuecomment-1364540704
# CH0I seems to be the "disable the adapter" key
function enable_discharging() {
	log "🔽🪫 Enabling battery discharging"
	if ! write_adapter_control "on"; then
		log "⚠️ Unable to determine verified SMC key for enabling battery discharging"
		return 1
	fi
	sudo $smc_binary -k ACLC -w 01
	return 0
}

function disable_discharging() {
	log "🔼🪫 Disabling battery discharging"
	if ! write_adapter_control "off"; then
		log "⚠️ Unable to determine verified SMC key for disabling battery discharging"
	fi
	# Keep track of status
	is_charging=$(get_smc_charging_status)

	if ! valid_percentage "$setting"; then

		log "Disabling discharging: No valid maintain percentage set, enabling charging"
		# use direct commands since enable_charging also calls disable_discharging, and causes an eternal loop
		if ! write_charging_control "on"; then
			log "⚠️ Unable to reset charging state"
		fi
		change_magsafe_led_color "orange"

	elif [[ "$battery_percentage" -ge "$setting" && "$is_charging" == "enabled" ]]; then

		log "Disabling discharging: Charge above $setting, disabling charging"
		disable_charging
		change_magsafe_led_color "green"

	elif [[ "$battery_percentage" -lt "$setting" && "$is_charging" == "disabled" ]]; then

		log "Disabling discharging: Charge below $setting, enabling charging"
		# use direct commands since enable_charging also calls disable_discharging, and causes an eternal loop
		if ! write_charging_control "on"; then
			log "⚠️ Unable to reset charging state"
		fi
		change_magsafe_led_color "orange"

	fi

	battery_percentage=$(get_battery_percentage)
}

# Re:charging, Aldente uses CH0B https://github.com/davidwernhart/AlDente/blob/0abfeafbd2232d16116c0fe5a6fbd0acb6f9826b/AlDente/Helper.swift#L227
# but @joelucid uses CH0C https://github.com/davidwernhart/AlDente/issues/52#issuecomment-1019933570
# so I'm using both when available since with only CH0B I noticed sometimes during sleep it does trigger charging
function enable_charging() {
	log "🔌🔋 Enabling battery charging"
	local charging_control_ok=true
	if ! write_charging_control "on"; then
		log "⚠️ Unable to determine SMC keys for enabling charging"
		charging_control_ok=false
	fi
	disable_discharging
	[[ "$charging_control_ok" == "true" ]]
}

function disable_charging() {
	log "🔌🪫 Disabling battery charging"
	if ! write_charging_control "off"; then
		log "⚠️ Unable to determine SMC keys for disabling charging"
		return 1
	fi
	return 0
}

function get_smc_charging_status() {
	local key
	local hex_status
	for key in $charging_control_keys; do
		hex_status=$(smc_read_hex "$key")
		if [[ -z "$hex_status" ]]; then
			continue
		fi
		if hex_values_match "$hex_status" "$(charging_control_value "$key" "on")"; then
			echo "enabled"
			return
		fi
		echo "disabled"
		return
	done
	get_system_charging_status
}

function get_smc_discharging_status() {
	local key
	local hex_status
	for key in $adapter_control_keys; do
		hex_status=$(smc_read_hex "$key")
		if [[ -z "$hex_status" ]]; then
			continue
		fi
		if hex_values_match "$hex_status" "$(adapter_control_value "$key" "off")"; then
			echo "not discharging"
			return
		fi
		echo "discharging"
		return
	done
	get_system_discharging_status
}

## ###############
## Statistics
## ###############

function get_battery_percentage() {
	battery_percentage=$(pmset -g batt | tail -n1 | awk '{print $3}' | sed s:\%\;::)
	echo "$battery_percentage"
}

function get_remaining_time() {
	time_remaining=$(pmset -g batt | tail -n1 | awk '{print $5}')
	echo "$time_remaining"
}

function get_pmset_output() {
	pmset -g batt 2>/dev/null
}

function get_pmset_battery_line() {
	get_pmset_output | tail -n1
}

function get_system_charging_status() {
	local battery_line
	local profiler_power
	battery_line="$(get_pmset_battery_line)"
	if [[ "$battery_line" =~ [Dd]ischarging ]]; then
		echo "disabled"
		return
	fi
	if [[ "$battery_line" =~ [Cc]harging || "$battery_line" =~ [Cc]harged ]]; then
		echo "enabled"
		return
	fi

	profiler_power="$(system_profiler SPPowerDataType 2>/dev/null)"
	if [[ "$profiler_power" =~ "Charging: Yes" ]]; then
		echo "enabled"
		return
	fi
	if [[ "$profiler_power" =~ "Charging: No" ]]; then
		echo "disabled"
		return
	fi
	echo "unknown"
}

function get_system_discharging_status() {
	local battery_line
	local profiler_power
	battery_line="$(get_pmset_battery_line)"
	if [[ "$battery_line" =~ [Dd]ischarging ]]; then
		echo "discharging"
		return
	fi
	if [[ "$battery_line" =~ [Cc]harging || "$battery_line" =~ [Cc]harged ]]; then
		echo "not discharging"
		return
	fi

	profiler_power="$(system_profiler SPPowerDataType 2>/dev/null)"
	if [[ "$profiler_power" =~ "Charging: No" ]]; then
		echo "discharging"
		return
	fi
	if [[ "$profiler_power" =~ "Charging: Yes" ]]; then
		echo "not discharging"
		return
	fi
	echo "unknown"
}

function get_charger_state() {
	ac_attached=$(get_pmset_output | awk 'NR == 1 { x=match($0, /AC Power/) > 0; print x; exit }')
	if [[ -z "$ac_attached" || "$ac_attached" == "0" ]]; then
		ac_attached=$(get_pmset_battery_line | awk '{ x=match($0, /AC attached/) > 0; print x }')
	fi
	echo "$ac_attached"
}

function get_maintain_percentage() {
	maintain_percentage=$(cat $maintain_percentage_tracker_file 2>/dev/null)
	echo "$maintain_percentage"
}

function get_voltage() {
	voltage=$(ioreg -l -n AppleSmartBattery -r | grep "\"Voltage\" =" | awk '{ print $3/1000 }' | tr ',' '.')
	echo "$voltage"
}

## ##################
## Miscellany helpers
## ##################

function determine_unprivileged_user() {
	local username="$1"
	if [[ "$username" == "root" ]]; then
		log "⚠️ 'battery $action $setting $subsetting': argument user is root, trying to recover" >&2
		username=""
	fi
	if [[ -z "$username" && -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
		username="$SUDO_USER"
	fi
	if [[ -z "$username" && -n "$USER" && "$USER" != "root" ]]; then
		username="$USER"
	fi
	if [[ -z "$username" && "$HOME" == /Users/* ]]; then
		username="$(basename "$HOME")";
	fi
	if [[ -z "$username" ]]; then
		log "⚠️ 'battery $action $setting $subsetting': unable to determine unprivileged user; falling back to 'logname'" >&2
		username="$(logname 2>/dev/null || true)"
	fi
	echo "$username"
}

function assert_unprivileged_user() {
	local username="$1"
	if [[ -z "$username" || "$username" == "root" ]]; then
		log "❌ 'battery $action $setting $subsetting': failed to determine unprivileged user"
		exit 11
	fi
}

function assert_not_running_as_root() {
	if [[ $EUID -eq 0 ]]; then
		echo " ❌ The following command should not be executed with root privileges:"
		echo "        battery $action $setting $subsetting"
		echo "    Please, try running without 'sudo'"
		exit 1
	fi
}

function assert_running_as_root() {
	if [[ $EUID -ne 0 ]]; then
		log "❌ battery $action $setting $subsetting: must be executed with root privileges"
		exit 1
	fi
}

function ensure_owner() {
	local owner="$1" group="$2" path="$3"
	[[ -e $path ]] || { return 1; }
	local cur_owner=$(stat -f '%Su' "$path")
	local cur_group=$(stat -f '%Sg' "$path")
	if [[ $cur_owner != "$owner" || $cur_group != "$group" ]]; then
		sudo chown -h "${owner}:${group}" "$path"
	fi
}

function ensure_owner_mode() {
	local owner="$1" group="$2" mode="$3" path="$4"
	ensure_owner "$owner" "$group" "$path" || return
	local cur_mode=$(stat -f '%Lp' "$path")
	if [[ $cur_mode != "${mode#0}" ]]; then
		sudo chmod -h "$mode" "$path"
	fi
}

# Use the following function to apply any setup related fixes which require root permissions.
# This function is executed by 'update_silent' action with EUID==0.
function fixup_installation_owner_mode() {
	local username=$1

	ensure_owner_mode $username staff 755 "$(dirname "$daemon_path")"
	ensure_owner_mode $username staff 644 "$daemon_path"

	ensure_owner_mode $username staff 755 "$configfolder"
	ensure_owner_mode $username staff 644 "$pidfile"
	ensure_owner_mode $username staff 644 "$logfile"
	ensure_owner_mode $username staff 644 "$maintain_percentage_tracker_file"
	ensure_owner_mode $username staff 644 "$maintain_voltage_tracker_file"
	ensure_owner_mode $username staff 644 "$calibrate_pidfile"

	ensure_owner_mode root wheel 755 "$visudo_folder"
	ensure_owner_mode root wheel 440 "$visudo_file"

	ensure_owner_mode root wheel 755 "$binfolder"
	ensure_owner_mode root wheel 755 "$battery_binary"
	ensure_owner_mode root wheel 755 "$smc_binary"

	# Do some cleanup after previous versions
	sudo rm -f "$configfolder/visudo.tmp"
}

function is_latest_version_installed() {
	# Check if content is reachable first with HEAD request
	curl -sSI "$github_url_battery_sh" &>/dev/null || return 0

	# Download the remote script then check if our version string is present.
	# Note: piping curl directly into grep -q causes a broken-pipe error (curl error 56)
	# because grep -q exits on first match while curl is still writing.
	local remote_script
	remote_script="$(curl -sS "$github_url_battery_sh" 2>/dev/null)"
	echo "$remote_script" | grep -q "$BATTERY_CLI_VERSION"
}

## ###############
## Actions
## ###############

# If the config folder or log file were just created by the code above while
# running as root, set the correct ownership and permissions.
if [[ $EUID -eq 0 ]]; then
	username="$(determine_unprivileged_user "$SUDO_USER")"
	if [[ -n "$username" && "$username" != "root" ]]; then
		fixup_installation_owner_mode "$username"
	fi
fi

# Version message
if [[ "$action" == "version" ]] || [[ "$action" == "--version" ]]; then
	echo "$BATTERY_CLI_VERSION"
	exit 0
fi

# Help message
if [ -z "$action" ] || [[ "$action" == "help" ]] || [[ "$action" == "--help" ]]; then
	echo -e "$helpmessage"
	exit 0
fi

# Update '/etc/sudoers.d/battery' config if needed
if [[ "$action" == "visudo" ]]; then

	# Allocate temp folder
	tempfolder="$(mktemp -d)"
	function cleanup() { rm -rf "$tempfolder"; }
	trap cleanup EXIT

	# Write the visudo file to a tempfile
	visudo_tmpfile="$tempfolder/visudo.tmp"
	echo -e "$visudoconfig" >$visudo_tmpfile

	# If the visudo folder does not exist, make it
	if ! test -d "$visudo_folder"; then
		sudo mkdir -p "$visudo_folder"
	fi
	ensure_owner_mode root wheel 755 "$visudo_folder"

	# If the visudo file is the same (no error, exit code 0), set the permissions just
	if sudo cmp $visudo_file $visudo_tmpfile &>/dev/null; then

		echo "☑️  The existing battery visudo file is what it should be for version $BATTERY_CLI_VERSION"

		# Check if file permissions are correct, if not, set them
		ensure_owner_mode root wheel 440 "$visudo_file"

		# Delete tempfolder
		rm -rf "$tempfolder"

		# exit because no changes are needed
		exit 0

	fi

	# Validate that the visudo tempfile is valid
	if sudo visudo -c -f $visudo_tmpfile &>/dev/null; then

		# Copy the visudo file from tempfile to live location
		sudo cp $visudo_tmpfile $visudo_file

		# Set correct permissions on visudo file
		ensure_owner_mode root wheel 440 "$visudo_file"

		# Delete tempfolder
		rm -rf "$tempfolder"

		echo "✅ Visudo file updated successfully"

	else
		echo "❌ Error validating visudo file, this should never happen:"
		sudo visudo -c -f $visudo_tmpfile
	fi

	exit 0
fi

# Reinstall helper
if [[ "$action" == "reinstall" ]]; then
	echo "This will run curl -sS ${github_url_setup_sh} | bash"
	if [[ ! "$setting" == "silent" ]]; then
		echo "Press any key to continue"
		read
	fi
	curl -sS "$github_url_setup_sh" | bash
	exit 0
fi

# Update helper for GUI app
if [[ "$action" == "update_silent" ]]; then

	assert_running_as_root

	# Exit with success when the GUI app just checks if passwordless updates are enabled
	if [[ "$setting" == "is_enabled" ]]; then
		exit 0
	fi

	# Try updating
	if ! is_latest_version_installed; then
		curl -sS "$github_url_update_sh" | bash
		echo "✅ battery background script was updated to the latest version."
	else
		echo "☑️  No updates found"
	fi

	# Update the visudo configuration on each update ensuring that the latest version
	# is always installed.
	# Note: this will overwrite the visudo configuration file only if it is outdated.
	$battery_binary visudo

	# Determine the name of unprivileged user
	username="$(determine_unprivileged_user "")"
	assert_unprivileged_user "$username"

	# Use opportunity to fixup installation
	fixup_installation_owner_mode "$username"

	exit 0
fi

# Update helper for Terminal users
if [[ "$action" == "update" ]]; then

	assert_not_running_as_root

	# The older GUI versions 1_3_2 and below can not run silent passwordless update and
	# will complain with alert. Just exit with success and let them update themselves.
	# Remove this condition in future versions when you believe the old UI is not used anymore.
	if [[ "$setting" == "silent" ]]; then
		exit 0
	fi

	if ! curl -fsI "$github_url_battery_sh" &>/dev/null; then
		echo "❌ Can't check for updates: no internet connection (or GitHub unreachable)."
		exit 1
	fi

	# The code below repeats integrity checks from GUI app, specifically from
	# app/modules/battery.js: 'initialize_battery'. Try keeping it consistent.

	function check_installation_integrity() (
		function not_link_and_root_owned() {
			[[ ! -L "$1" ]] && [[ $(stat -f '%u' "$1") -eq 0 ]]
		}

		not_link_and_root_owned "$binfolder" && \
		not_link_and_root_owned "$battery_binary" && \
		not_link_and_root_owned "$smc_binary" && \
		sudo -n "$battery_binary" update_silent is_enabled >/dev/null 2>&1
	)

	if ! check_installation_integrity; then
		version_before="0" # Force restart maintenance process
		echo -e "‼️ The battery installation seems to be broken. Forcing reinstall...\n"
		$battery_binary reinstall silent
	else
		version_before="$($battery_binary version)"
		sudo $battery_binary update_silent
	fi

	# Restart background maintenance process if update was installed
	if [[ -x $battery_binary ]] && [[ "$($battery_binary version)" != "$version_before" ]]; then
		printf "\n%s\n" "🛠️  Restarting 'battery maintain' ..."
		$battery_binary maintain recover
	fi

	exit 0
fi

# Uninstall helper
if [[ "$action" == "uninstall" ]]; then

	if [[ ! "$setting" == "silent" ]]; then
		echo "This will enable charging, and remove the smc tool and battery script"
		echo "Press any key to continue"
		read
	fi

	$battery_binary maintain stop
	$battery_binary remove_daemon

	enable_charging
	disable_discharging

	sudo rm -fv /usr/local/bin/battery
	sudo rm -fv /usr/local/bin/smc

	sudo rm -fv "$visudo_file"
	sudo rm -frv "$binfolder"
	sudo rm -frv "$configfolder"
	sudo rm -fv "$path_configfile"

	# Ensure no dangling battery processes are left running
	pkill -f "/usr/local/bin/battery.*|/usr/local/co\.palokaj\.battery/battery.*"

	exit 0
fi

# Charging on/off controller
if [[ "$action" == "charging" ]]; then

	log "Setting $action to $setting"

	# Disable running daemon
	$battery_binary maintain stop

	# Set charging to on and off
	if [[ "$setting" == "on" ]]; then
		enable_charging
	elif [[ "$setting" == "off" ]]; then
		disable_charging
	else
		log "Error: $setting is not \"on\" or \"off\"."
		exit 1
	fi

	exit 0

fi

# Discharge on/off controller
if [[ "$action" == "adapter" ]]; then

	log "Setting $action to $setting"

	# Disable running daemon
	$battery_binary maintain stop

	# Set charging to on and off
	if [[ "$setting" == "on" ]]; then
		disable_discharging
	elif [[ "$setting" == "off" ]]; then
		enable_discharging
	else
		log "Error: $setting is not \"on\" or \"off\"."
		exit 1
	fi

	exit 0

fi

# Charging on/off controller
if [[ "$action" == "charge" ]]; then

	if ! valid_percentage "$setting"; then
		log "Error: $setting is not a valid setting for battery charge. Please use a number between 0 and 100"
		exit 1
	fi

	# Stop battery maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain stop
	fi

	# Start charging
	battery_percentage=$(get_battery_percentage)
	log "Charging to $setting% from $battery_percentage%"
	enable_charging # also disables discharging

	# Loop until battery charging level is reached
	while [[ "$battery_percentage" -lt "$setting" ]]; do

		if [[ "$battery_percentage" -ge "$((setting - 3))" ]]; then
			sleep 20
		else
			caffeinate -is sleep 60
		fi

		battery_percentage=$(get_battery_percentage)

	done

	disable_charging
	log "Charging completed at $battery_percentage%"

	# Try restoring maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain recover
	fi

	exit 0

fi

# Discharging on/off controller
if [[ "$action" == "discharge" ]]; then

	if ! valid_percentage "$setting"; then
		log "Error: $setting is not a valid setting for battery discharge. Please use a number between 0 and 100"
		exit 1
	fi

	# Stop battery maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain stop
	fi

	# Start discharging
	battery_percentage=$(get_battery_percentage)
	log "Discharging to $setting% from $battery_percentage%"
	enable_discharging

	# Loop until battery charging level is reached
	while [[ "$battery_percentage" -gt "$setting" ]]; do

		log "Battery at $battery_percentage% (target $setting%)"
		caffeinate -is sleep 60
		battery_percentage=$(get_battery_percentage)

	done

	disable_discharging
	log "Discharging completed at $battery_percentage%"

	# Try restoring maintenance if invoked by user from Terminal
	if [[ "$BATTERY_HELPER_MODE" != "1" ]]; then
		$battery_binary maintain recover
	fi

	exit 0

fi

# Maintain at level
if [[ "$action" == "maintain_synchronous" ]]; then

	log_smc_capabilities

	# Checking if the calibration process is running
	if test -f "$calibrate_pidfile"; then
		pid=$(cat "$calibrate_pidfile" 2>/dev/null)
		kill $pid &>/dev/null
		log "🚨 Calibration process have been stopped"
	fi

	# Recover old maintain status if old setting is found
	if [[ "$setting" == "recover" ]]; then

		# Before doing anything, log out environment details as a debugging trail
		log "Debug trail. User: $USER, config folder: $configfolder, logfile: $logfile, file called with 1: $1, 2: $2"

		maintain_percentage=$(cat $maintain_percentage_tracker_file 2>/dev/null)
		if [[ $maintain_percentage ]]; then
			log "Recovering maintenance percentage $maintain_percentage"
			setting=$(echo $maintain_percentage)
		else
			log "No setting to recover, exiting"
			exit 0
		fi
	fi

	# Parse setting - could be single value or range
	lower_bound=""
	upper_bound=""
	is_range=false

	if valid_percentage_range "$setting"; then
		# Range format: lower-upper
		is_range=true
		lower_bound="${setting%-*}"
		upper_bound="${setting#*-}"
	elif valid_percentage "$setting"; then
		# Single value format (backward compatible)
		is_range=false
		lower_bound="$setting"
		upper_bound="$setting"
	else
		log "Error: $setting is not a valid setting for battery maintain. Please use a number between 0 and 100, or a range like 70-80"
		exit 1
	fi

	# Check if the user requested that the battery maintenance first discharge to the desired level
	if [[ "$subsetting" == "--force-discharge" ]]; then
		# Before we start maintaining the battery level, first discharge to the target level
		discharge_target="$lower_bound"
		log "Triggering discharge to $discharge_target before enabling charging limiter"
		BATTERY_HELPER_MODE=1 $battery_binary discharge "$discharge_target"
		log "Discharge pre battery-maintenance complete, continuing to battery maintenance loop"
	else
		log "Not triggering discharge as it is not requested"
	fi

	# Start charging
	battery_percentage=$(get_battery_percentage)

	if [[ "$is_range" == true ]]; then
		log "Maintaining battery between $lower_bound% and $upper_bound% from $battery_percentage%"
	else
		log "Charging to and maintaining at $setting% from $battery_percentage%"
	fi

	# Loop until battery percent is exceeded
	while true; do

		# Keep track of status
		is_charging=$(get_smc_charging_status)
		ac_attached=$(get_charger_state)

		is_discharging=$(get_smc_discharging_status)

		if [[ "$battery_percentage" -ge "$upper_bound" && ("$is_charging" == "enabled" || "$ac_attached" == "1" || "$is_discharging" == "not discharging") ]]; then

			log "Charge at or above $upper_bound%"
			if supports_charging_control && [[ "$is_charging" != "disabled" ]]; then
				if ! disable_charging && supports_adapter_control && [[ "$is_discharging" != "discharging" ]]; then
					log "Charging control failed verification, forcing adapter discharge"
					enable_discharging
				fi
			elif supports_adapter_control && [[ "$is_discharging" != "discharging" ]]; then
				log "Charging control unavailable, forcing adapter discharge"
				enable_discharging
			elif ! supports_charging_control && ! supports_adapter_control; then
				log "⚠️ Unable to determine SMC keys for limiting battery level"
			fi
			change_magsafe_led_color "green"

		elif [[ "$battery_percentage" -lt "$lower_bound" && ("$is_charging" != "enabled" || "$is_discharging" == "discharging") ]]; then

			log "Charge below $lower_bound%"
			if supports_charging_control; then
				if ! enable_charging && supports_adapter_control; then
					log "Charging control failed verification, restoring adapter power"
					disable_discharging
				fi
			elif supports_adapter_control; then
				log "Charging control unavailable, restoring adapter power"
				disable_discharging
			else
				log "⚠️ Unable to determine SMC keys for restoring charging"
			fi
			change_magsafe_led_color "orange"

		fi

		sleep 60

		battery_percentage=$(get_battery_percentage)

	done

	exit 0

fi

# Maintain at voltage
if [[ "$action" == "maintain_voltage_synchronous" ]]; then

	log_smc_capabilities

	# Recover old maintain status if old setting is found
	if [[ "$setting" == "recover" ]]; then

		# Before doing anything, log out environment details as a debugging trail
		log "Debug trail. User: $USER, config folder: $configfolder, logfile: $logfile, file called with 1: $1, 2: $2"

		maintain_voltage=$(cat $maintain_voltage_tracker_file 2>/dev/null)
		if [[ $maintain_voltage ]]; then
			log "Recovering maintenance voltage $maintain_voltage"
			setting=$(echo $maintain_voltage | awk '{print $1}')
			subsetting=$(echo $maintain_voltage | awk '{print $2}')
		else
			log "No setting to recover, exiting"
			exit 0
		fi
	fi

	voltage=$(get_voltage)
	lower_voltage=$(echo "$setting - $subsetting" | bc -l)
	upper_voltage=$(echo "$setting + $subsetting" | bc -l)
	log "Keeping voltage between ${lower_voltage}V and ${upper_voltage}V"

	# Loop
	while true; do
		is_charging=$(get_smc_charging_status)
		is_discharging=$(get_smc_discharging_status)

		if (($(echo "$voltage < $lower_voltage" | bc -l))) && [[ "$is_charging" != "enabled" || "$is_discharging" == "discharging" ]]; then
			log "Battery at ${voltage}V"
			if supports_charging_control; then
				if ! enable_charging && supports_adapter_control; then
					log "Charging control failed verification, restoring adapter power"
					disable_discharging
				fi
			elif supports_adapter_control; then
				log "Charging control unavailable, restoring adapter power"
				disable_discharging
			else
				log "⚠️ Unable to determine SMC keys for restoring charging"
			fi
		fi
		if (($(echo "$voltage >= $upper_voltage" | bc -l))) && [[ "$is_charging" != "disabled" || "$is_discharging" == "not discharging" ]]; then
			log "Battery at ${voltage}V"
			if supports_charging_control; then
				if ! disable_charging && supports_adapter_control; then
					log "Charging control failed verification, forcing adapter discharge"
					enable_discharging
				fi
			elif supports_adapter_control; then
				log "Charging control unavailable, forcing adapter discharge"
				enable_discharging
			else
				log "⚠️ Unable to determine SMC keys for limiting battery voltage"
			fi
		fi

		sleep 60

		voltage=$(get_voltage)

	done

	exit 0

fi

# Asynchronous battery level maintenance
if [[ "$action" == "maintain" ]]; then

	assert_not_running_as_root

	disable_discharging

	# Kill old process silently
	if test -f "$pidfile"; then
		log "Killing old maintain process at $(cat $pidfile)"
		pid=$(cat "$pidfile" 2>/dev/null)
		kill $pid &>/dev/null
	fi

	if test -f "$calibrate_pidfile"; then
		pid=$(cat "$calibrate_pidfile" 2>/dev/null)
		kill $pid &>/dev/null
		log "🚨 Calibration process have been stopped"
	fi

	if [[ "$setting" == "stop" ]]; then
		log "Killing running maintain daemons & enabling charging as default state"
		rm $pidfile 2>/dev/null
		$battery_binary disable_daemon
		enable_charging
		$battery_binary status
		exit 0
	fi

	# Check if setting is a voltage
	is_voltage=false
	if valid_voltage "$setting"; then
		setting="${setting//V/}"

		if valid_voltage "$subsetting"; then
			subsetting="${subsetting//V/}"
		else
			subsetting="0.1"
		fi

		if (($(echo "$setting < $voltage_min" | bc -l) || $(echo "$setting > $voltage_max" | bc -l))); then
			log "Error: ${setting}V is not a valid setting. Please use a value between ${voltage_min}V and ${voltage_max}V"
			exit 1
		fi
		if (($(echo "$subsetting < $voltage_hyst_min" | bc -l) || $(echo "$subsetting > $voltage_hyst_max" | bc -l))); then
			log "Error: ${subsetting}V is not a valid setting. Please use a value between ${voltage_hyst_min}V and ${voltage_hyst_max}V"
			exit 1
		fi

		is_voltage=true

	# Check if setting is a percentage range or single value
	elif ! valid_percentage "$setting" && ! valid_percentage_range "$setting"; then
		log "Called with $setting $action"
		# If setting is not a valid percentage/range and not a special keyword, exit with an error.
		if ! { [[ "$setting" == "stop" ]] || [[ "$setting" == "recover" ]]; }; then
			log "Error: $setting is not a valid setting for battery maintain. Please use a number between 0 and 100, a range like 70-80, or an action keyword like 'stop' or 'recover'."
			exit 1
		fi

	fi

	# Start maintenance script
	if [ "$is_voltage" = true ]; then
		log "Starting battery maintenance at ${setting}V ±${subsetting}V"
		nohup $battery_binary maintain_voltage_synchronous $setting $subsetting >>$logfile &
	else
		if valid_percentage_range "$setting"; then
			log "Starting battery maintenance between ${setting/-/% and }%"
		else
			log "Starting battery maintenance at $setting% $subsetting"
		fi
		nohup $battery_binary maintain_synchronous $setting $subsetting >>$logfile &
	fi

	# Store pid of maintenance process and setting
	echo $! >$pidfile
	pid=$(cat "$pidfile" 2>/dev/null)

	if ! [[ "$setting" == "recover" ]]; then

		rm "$maintain_percentage_tracker_file" "$maintain_voltage_tracker_file" 2>/dev/null

		if [[ "$is_voltage" = true ]]; then
			log "Writing new setting $setting $subsetting to $maintain_voltage_tracker_file"
			echo "$setting $subsetting" >$maintain_voltage_tracker_file
			log "Maintaining battery at ${setting}V ±${subsetting}V"

		else
			log "Writing new setting $setting to $maintain_percentage_tracker_file"
			echo $setting >$maintain_percentage_tracker_file
			if valid_percentage_range "$setting"; then
				log "Maintaining battery between ${setting/-/% and }%"
			else
				log "Maintaining battery at $setting%"
			fi
		fi

	fi

	# Enable the daemon that continues maintaining after reboot
	$battery_binary create_daemon

	exit 0

fi

# Battery calibration
if [[ "$action" == "calibrate" ]]; then

	# Stop the maintaining
	$battery_binary maintain stop &>/dev/null

	# Kill old process silently
	if test -f "$calibrate_pidfile"; then
		pid=$(cat "$calibrate_pidfile" 2>/dev/null)
		kill $pid &>/dev/null
	fi
	echo $$ >$calibrate_pidfile

	echo -e "Starting battery calibration\n"

	echo "[ 1 ] Discharging battery to 15%"
	BATTERY_HELPER_MODE=1 $battery_binary discharge 15 &>/dev/null

	echo "[ 2 ] Charging to 100%"
	BATTERY_HELPER_MODE=1 $battery_binary charge 100 &>/dev/null

	echo "[ 3 ] Reached 100%, waiting for 1 hour"
	enable_charging &>/dev/null
	sleep 3600

	echo "[ 4 ] Discharging battery to 80%"
	BATTERY_HELPER_MODE=1 $battery_binary discharge 80 &>/dev/null

	# Remove pidfile
	rm -f $calibrate_pidfile

	# Recover old maintain status
	echo "[ 5 ] Restarting battery maintenance"
	$battery_binary maintain recover &>/dev/null

	echo -e "\n✅ Done\n"
	exit 0

fi

# Status logger
if [[ "$action" == "status" ]]; then

	smc_charging_status=$(get_smc_charging_status)
	smc_discharging_status=$(get_smc_discharging_status)
	log "Battery at $(get_battery_percentage)% ($(get_remaining_time) remaining), $(get_voltage)V, smc charging $smc_charging_status, adapter $smc_discharging_status"
	if test -f $pidfile; then
		maintain_percentage=$(cat $maintain_percentage_tracker_file 2>/dev/null)
		if [[ $maintain_percentage ]]; then
			if valid_percentage_range "$maintain_percentage"; then
				maintain_level="${maintain_percentage/-/% - }%"
			else
				maintain_level="$maintain_percentage%"
			fi
		else
			maintain_level=$(cat $maintain_voltage_tracker_file 2>/dev/null)
			maintain_level=$(echo "$maintain_level" | awk '{print $1 "V ±" $2 "V"}')
		fi
		log "Your battery is currently being maintained at $maintain_level"
	fi
	exit 0

fi

# Status logger in csv format
if [[ "$action" == "status_csv" ]]; then

	echo "$(get_battery_percentage),$(get_remaining_time),$(get_smc_charging_status),$(get_smc_discharging_status),$(get_maintain_percentage)"

fi

# launchd daemon creator, inspiration: https://www.launchd.info/
if [[ "$action" == "create_daemon" ]]; then

	assert_not_running_as_root

	call_action="maintain_synchronous"
	if test -f "$maintain_voltage_tracker_file"; then
		call_action="maintain_voltage_synchronous"
	fi

	daemon_definition="
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
	<dict>
		<key>Label</key>
		<string>com.battery.app</string>
		<key>ProgramArguments</key>
		<array>
			<string>$battery_binary</string>
			<string>$call_action</string>
			<string>recover</string>
		</array>
		<key>StandardOutPath</key>
		<string>$logfile</string>
		<key>StandardErrorPath</key>
		<string>$logfile</string>
		<key>RunAtLoad</key>
		<true/>
	</dict>
</plist>
"

	mkdir -p "${daemon_path%/*}"

	# check if daemon already exists
	if test -f "$daemon_path"; then

		log "Daemon already exists, checking for differences"
		daemon_definition_difference=$(diff --brief --ignore-space-change --strip-trailing-cr --ignore-blank-lines <(cat "$daemon_path" 2>/dev/null) <(echo "$daemon_definition"))

		# remove leading and trailing whitespaces
		daemon_definition_difference=$(echo "$daemon_definition_difference" | xargs)
		if [[ "$daemon_definition_difference" != "" ]]; then

			log "daemon_definition changed: replace with new definitions"
			echo "$daemon_definition" >"$daemon_path"

		fi
	else

		# daemon not available, create new launch deamon
		log "Daemon does not yet exist, creating daemon file at $daemon_path"
		echo "$daemon_definition" >"$daemon_path"

	fi

	# enable daemon
	launchctl enable "gui/$(id -u $USER)/com.battery.app"
	exit 0

fi

# Disable daemon
if [[ "$action" == "disable_daemon" ]]; then

	log "Disabling daemon at gui/$(id -u $USER)/com.battery.app"
	launchctl disable "gui/$(id -u $USER)/com.battery.app"
	exit 0

fi

# Remove daemon
if [[ "$action" == "remove_daemon" ]]; then

	rm $daemon_path 2>/dev/null
	exit 0

fi

# Display logs
if [[ "$action" == "logs" ]]; then

	amount="${2:-100}"

	echo -e "👾 Battery CLI logs:\n"
	tail -n $amount $logfile

	echo -e "\n🖥️	Battery GUI logs:\n"
	tail -n $amount "$configfolder/gui.log"

	echo -e "\n📁 Config folder details:\n"
	ls -lah $configfolder

	echo -e "\n⚙️	Battery data:\n"
	$battery_binary status
	$battery_binary | grep -E "v\d.*"

	exit 0

fi
