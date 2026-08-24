#!/usr/bin/env bash

# Dependencies: Linux kernel, yq, bash >= 5.1
# Bash 5.1 or later is required to support 'wait -p'

# Also these common core utilities are required: cat mkdir readlink rm setsid sleep tail

# Source: https://github.com/casperklein/supervisor.sh/

# shellcheck disable=2178,2128 # Bug: https://github.com/koalaman/shellcheck/issues/1309

# Shell options
set   -o errexit         # Exit immediately if a command exits with a non-zero status
set   -o nounset         # Treat unset variables as an error when substituting
shopt -s inherit_errexit # Exit on errors - also in sub-shells
shopt -s nullglob        # Return nothing if '*' does not expand

# Global variables
APP="supervisor.sh"
APP_PATH=$(readlink -f "$0")
VER=0.16

: "${PID_DIR:=/run/$APP}" # Allow PID_DIR override via ENV
PID_FILE="$PID_DIR/$APP.pid"
LOCK_DIR="$PID_DIR/.lock"

CONFIG_FILE_BASH=0
FOREGROUND=0
HERTZ=$(getconf CLK_TCK 2>/dev/null || echo "100") # CLK_TCK --> Ticks per second (usually 100)
NO_COLOR=0
PIDS=()
PIDS_STARTTIME=()
TIME_FORMAT="%F %T" # Default value for CLI commands where config is not read, e.g. 'supervisor.sh stop'

# Set default config path
if hash yq 2>/dev/null; then
	CONFIG_FILE="/etc/supervisor.yaml"
else
	CONFIG_FILE="/etc/supervisor.yaml.sh"
fi

# Enable Bash builtins if available
# mkdir builtin behaves differently when using '-m'
for i in rm sleep; do
	enable "$i" &>/dev/null || true
done

# Begin shared part (client & server)

# Show usage and exit
_usage() {
	cat <<-USAGE
		$APP $VER

		Usage:
		  $APP [OPTION] [COMMAND]

		Configuration file:
		  By default, the configuration is read from '/etc/supervisor.yaml'.
		  If 'yq' is not available, '/etc/supervisor.yaml.sh' will be used instead.
		  Provide '--config' to specify a custom configuration file.

		Options:
		  -c, --config     Specify configuration file, e.g. '$APP -c /path/config.yaml'.
		  -h, --help       Show this help.
		  -n, --no-color   Disable color usage.
		  -v, --version    Show version.

		Commands:
		  start            Start $APP as daemon.
		  start <job>      Start job.
		  stop             Stop $APP.
		  stop  <job>      Stop job.
		  restart          Restart daemon.
		  restart <job>    Restart job.
		  status           Show process status table.
		  fix              Fix unclean shutdown.
		  lint             Validate and display the full configuration, including implicit default values.
		  log              Show continuously the $APP log.
		  logs             Show continuously the $APP log + job logs.
		  convert          Convert the YAML configuration file to Bash.
		                   This allows the usage without the 'yq' dependency.

		If no command is provided, $APP will start in foreground.

	USAGE
	exit 0
}

_read_config_file() {
	local marker output i j=0

	if [ ! -f "$CONFIG_FILE" ]; then
		echo "Error: Configuration file '$CONFIG_FILE' not found."
		echo
		exit 1
	fi >&2

	if [ ! -r "$CONFIG_FILE" ]; then
		echo "Error: Configuration file '$CONFIG_FILE' is not accessible."
		echo
		exit 1
	fi >&2

	# Is the config file a Bash script (converted from YAML)?
	read -r -N 7 marker < "$CONFIG_FILE" || true # 'read' may fail if the file is empty or smaller than 7 bytes
	if [ "$marker" == "declare" ]; then
		CONFIG_FILE_BASH=1
		# shellcheck disable=1090
		source "$CONFIG_FILE"
	else
		# Check if 'yq' binary is available
		if ! hash yq 2>/dev/null; then
			echo "Error: 'yq' binary is not available. Get it from: https://github.com/mikefarah/yq"
			echo
			exit 1
		fi >&2

		# Check if the correct 'yq' program is used
		if [[ "$(yq --version 2>&1)" != "yq (https://github.com/mikefarah/yq/)"* ]]; then
			echo "Error: Wrong 'yq' program detected."
			echo
			echo "There are at least two, that have the same name:"
			echo
			echo "  - $APP depends on 'yq' from: https://github.com/mikefarah/yq"
			echo "  - The Debian repository, for example, provides 'yq' from: https://github.com/kislyuk/yq"
			echo
			exit 1
		fi >&2

		# Validate config file
		if ! output=$(yq . "$CONFIG_FILE" 2>&1); then
			echo "Error: The configuration file is invalid."
			echo "$output"
			echo
			exit 1
		fi >&2

		# Read config from file

		# mapfile -t --> Remove a trailing DELIM from each line read (default newline)
		# yq -r      --> unwrap scalar, print the value with no quotes, colors or comments

		# supervisor config                       Key                  Default value instead of 'null'
		LOG_FILE=$(            yq -r '.supervisor.logfile              // "/dev/stdout"'   "$CONFIG_FILE")
		SIGTERM_GRACE_PERIOD=$(yq -r '.supervisor.sigterm_grace_period // "10"'            "$CONFIG_FILE")
		KEEP_RUNNING=$(        yq -r '.supervisor.keep_running         // "off"'           "$CONFIG_FILE")
		COLOR=$(               yq -r '.supervisor.color                // ""'              "$CONFIG_FILE")
		COLOR_ERROR=$(         yq -r '.supervisor.color_error          // "'$'\e[1;31m''"' "$CONFIG_FILE")
		TIME_FORMAT=$(         yq -r '.supervisor.time_format          // "%F %T"'         "$CONFIG_FILE") # See 'man strftime'

		# Job config                                    Key            Default value instead of 'null'
		mapfile -t JOB_NAME          < <(yq -r '.jobs[].name           // ""'              "$CONFIG_FILE")
		mapfile -t JOB_COMMAND       < <(yq -r '.jobs[].command        // ""'              "$CONFIG_FILE")
		mapfile -t JOB_AUTOSTART     < <(yq -r '.jobs[].autostart      // "on"'            "$CONFIG_FILE")
		mapfile -t JOB_LOGFILE       < <(yq -r '.jobs[].logfile        // "/dev/stdout"'   "$CONFIG_FILE")
		mapfile -t JOB_REQUIRED      < <(yq -r '.jobs[].required       // "no"'            "$CONFIG_FILE")
		mapfile -t JOB_RESTART       < <(yq -r '.jobs[].restart        // "error"'         "$CONFIG_FILE")
		mapfile -t JOB_RESTART_LIMIT < <(yq -r '.jobs[].restart_limit  // "3"'             "$CONFIG_FILE")
		declare -A JOB_RESTART_COUNT
	fi

	# Validate config

	__show_error_and_exit() {
		echo "Error: $1"
		echo "Check: $CONFIG_FILE"
		echo
		_show_config
		echo
		exit 1
	} >&2

	# Any jobs configured?
	if [[ "${#JOB_NAME[@]}" -eq 1 && -z "${JOB_NAME[0]}" ]]; then
		__show_error_and_exit "No jobs configured."
	fi

	# Validate job names and commands
	for i in "${!JOB_NAME[@]}"; do
		# Job name and command cannot be empty/missing
		if [[ -z "${JOB_NAME[i]}" || -z "${JOB_COMMAND[i]}" ]]; then
			__show_error_and_exit "Parsing job #$((++i)) configuration failed. The 'name' or 'command' value cannot be empty/missing."
		fi

		# Prevent problematic job (file) names
		# 1. Dotfiles are excluded from globbing (*.pid)
		# 2. A filename cannot contain a slash
		# 3. Whitespaces in job names do not work with bash completion
		if [[ ! "${JOB_NAME[i]}" =~ ^[^./[:space:]][^/[:space:]]*$ ]]; then
			__show_error_and_exit "Parsing job #$((++i)) configuration failed. The job name must not start with a dot and must not contain whitespace or slashes."
		fi
	done

	# The job name must be uniq
	declare -A job_name_uniq
	for i in "${JOB_NAME[@]}"; do
		((++j))
		if [ -n "${job_name_uniq[$i]:-}" ]; then
			__show_error_and_exit "Invalid job #$j name. Job #${job_name_uniq[$i]} is already named '$i'."
		else
			job_name_uniq[$i]=$j
		fi
	done

	# Validate optional settings

	# COLOR / COLOR_ERROR can be empty or must contain an escape sequence
	if [[ -n "$COLOR"       && "$COLOR"       != *$'\e'* ]]; then
		__show_error_and_exit "supervisor.color does not contain an ansi color escape sequence. Current value is: $COLOR"
	fi
	if [[ -n "$COLOR_ERROR" && "$COLOR_ERROR" != *$'\e'* ]]; then
		__show_error_and_exit "supervisor.color_error does not contain an ansi color escape sequence. Current value is: $COLOR_ERROR"
	fi

	__is_integer() {
		# $1   Description
		# $2   Value

		if ! [[ "$2" =~ ^[0-9]+$ ]]; then
			__show_error_and_exit "$1 must be an integer >= 0. Current value is: $2"
		fi
	}

	__is_integer "supervisor.sigterm_grace_period" "$SIGTERM_GRACE_PERIOD"

	for i in "${!JOB_RESTART_LIMIT[@]}"; do
		__is_integer "Job #$(( i + 1 )) 'restart_limit'" "${JOB_RESTART_LIMIT[i]}"
	done

	__has_valid_value() {
		local description value allowed

		description=$1
		value=$2
		shift 2
		allowed=("$@")

		for i in "${allowed[@]}"; do
			[ "$value" == "$i" ] && return 0
		done

		__show_error_and_exit "$description has an invalid value '$value'. Possible values: $*"
	}

	__has_valid_value "supervisor.keep_running" "$KEEP_RUNNING" on off

	for i in "${!JOB_AUTOSTART[@]}"; do
		__has_valid_value "Job #$(( i + 1 )) 'autostart'" "${JOB_AUTOSTART[i]}" on off
	done

	for i in "${!JOB_RESTART[@]}"; do
		__has_valid_value "Job #$(( i + 1 )) 'restart'" "${JOB_RESTART[i]}" error on off
	done

	for i in "${!JOB_REQUIRED[@]}"; do
		__has_valid_value "Job #$(( i + 1 )) 'required'" "${JOB_REQUIRED[i]}" yes no
	done
}

_show_config() {
	local color="" color_error=""

	# Escape ANSI colors
	[ -n "$COLOR"       ] && color=${COLOR@Q}
	[ -n "$COLOR_ERROR" ] && color_error=${COLOR_ERROR@Q}

	# @Q above returns the escape character as \E
	# YAML however requires \e
	# Replace \E --> \e
	color=${color//\\E/\\e}
	color_error=${color_error//\\E/\\e}

	# Remove surrounding $'' if present
	[[ "$color"       == '$'\'*\' ]] && color=${color:2:-1}
	[[ "$color_error" == '$'\'*\' ]] && color_error=${color_error:2:-1}

	cat <<-CONFIG
		supervisor:
		  logfile: "$LOG_FILE"
		  sigterm_grace_period: "$SIGTERM_GRACE_PERIOD"
		  keep_running: "$KEEP_RUNNING"
		  color: "$color"
		  color_error: "$color_error"
		  time_format: "$TIME_FORMAT"

		jobs:
	CONFIG

	for i in "${!JOB_NAME[@]}"; do
		cat <<-CONFIG
		  # Job $(( i + 1 ))
		  - name: "${JOB_NAME[i]}"
		    command: ${JOB_COMMAND[i]}
		    autostart: "${JOB_AUTOSTART[i]}"
		    logfile: "${JOB_LOGFILE[i]}"
		    restart: "${JOB_RESTART[i]}"
		    restart_limit: "${JOB_RESTART_LIMIT[i]}"
		    required: "${JOB_REQUIRED[i]}"

		CONFIG
	done
}

_status() {
	# $1   Status message
	# $2   Treat message as an error if set
	local color=""

	# Use colors only when running in foreground
	if (( FOREGROUND == 1 )); then
		if [[ -z "${2:-}" && -n "$COLOR" ]]; then
			# Use configured color for status message
			color=$COLOR
		elif [[ -n "${2:-}" && -n "$COLOR_ERROR" ]]; then
			# Use configured color for error message
			color=$COLOR_ERROR
		fi
	fi

	# Print the current date/time + status message
	# Don't use multiple 'printf' statements (separate color and status message 'printf').
	# This can lead to a race condition, where $color is set and then output from a job starts.
	if [ -n "$color" ]; then
		printf "%s%($TIME_FORMAT)T %s%s\n" "$color" -1 "$1" $'\e[0m'
	else
		printf "%($TIME_FORMAT)T %s\n" -1 "$1"
	fi

	return 0
}

_release_lock() {
	rm -rf "$LOCK_DIR"
}

# Acquire lock for exclusive (start) operations
_acquire_lock() {
	if ! mkdir "$LOCK_DIR" 2>/dev/null; then
		return 1
	fi

	# Release lock on termination
	# shellcheck disable=2064
	trap "_release_lock" EXIT

	return 0
}

_get_starttime_from_pid() {
	local pid=$1 stat

	# Non bash alternative
	# stat -c %Y /proc/$pid

	# man proc_pid_stat
	# Field 22 starttime: The time the process started after system boot. The value is expressed in clock ticks (divide by sysconf(_SC_CLK_TCK))
	IFS= read -r stat < "/proc/$pid/stat"

	# Remove the first two fields, because the second field (the filename of the executable, in parentheses) can contain whitespaces.
	stat=${stat#*)}
	read -r -a stat <<<"$stat"

	# Output field 20 (starttime) in seconds
	echo "$(( stat[19] / HERTZ ))"
}

# After a process terminates, the OS may assign its PID to a different process.
# Verify the saved process start time to ensure the PID still belongs to the expected process.
_check_process_starttime() {
	local pid_file=$1 starttime_app starttime_pid

	if [ -f "$pid_file.starttime" ]; then
		starttime_app=$(<"$pid_file.starttime")
		starttime_pid=$(_get_starttime_from_pid "$(<"$pid_file")")

		if [ "$starttime_app" == "$starttime_pid" ]; then
			return 0
		fi
	fi

	return 1
}

_is_process_running() {
	local pid_file=$1

	# supervisor
	if [ "$pid_file" == "$PID_FILE" ]; then
		if kill -0 "$(<"$pid_file")" 2>/dev/null; then
			if _check_process_starttime "$pid_file"; then
				# supervisor is runnning
				return 0
			fi
		fi

		# supervisor is not running --> process not running or wrong start time
		return 1
	fi

	__is_process_group_running() {
		local pid_file=$1

		if kill -0 -"$(<"$pid_file")" 2>/dev/null; then
			return 0
		fi

		return 1
	}

	# Job
	if kill -0 "$(<"$pid_file")" 2>/dev/null; then
		if _check_process_starttime "$pid_file"; then
			# Job is running
			return 0
		fi

		if __is_process_group_running "$pid_file"; then
			# Only child processes are running
			return 2
		fi

		# Job is not running --> wrong start time
		return 1
	fi

	if __is_process_group_running "$pid_file"; then
		# Only child processes are running
		return 2
	fi

	# Job is not running
	return 1
}

_is_app_running() {
	if [ -f "$PID_FILE" ]; then
		if _is_process_running "$PID_FILE"; then
			return 0
		fi
	fi
	return 1
}

_exit_if_app_is_not_running() {
	if ! _is_app_running; then
		echo "Error: $APP is not running."
		echo
		exit 1
	fi >&2
}

_exit_if_app_is_already_running() {
	if _is_app_running; then
		echo "Error: $APP is already running."
		echo
		exit 1
	fi >&2
}

# Check if supervisor was gracefully stopped (Is PID_DIR clean?)
# Test: kill -9 $(</run/supervisor.sh/supervisor.sh.pid)
_check_clean_shutdown() {
	local i skip_lock=${1:-}

	if ! _is_app_running; then
		for i in "$PID_DIR/.sigterm"* "$PID_DIR/"*.pid*; do
			return 1
		done

		if [ -z "$skip_lock" ]; then
			for i in "$LOCK_DIR"*/; do
				return 1
			done
		fi
	fi

	return 0
}

_exit_if_unclean_shutdown() {
	if ! _check_clean_shutdown "${1:-}"; then
		echo "Error: $APP was not stopped gracefully."
		echo
		_show_process_status_table || true
		echo "Run '$APP fix' to terminate leftover job processes and clean up runtime data."
		echo
		exit 1
	fi >&2
}

_delete_runtime_data() {
	rm -f "$PID_DIR/.sigterm" \
	      "$PID_DIR/"*.pid*

	_release_lock
}

# Stop any running jobs and delete runtime data
_fix_unclean_shutdown() {
	local i name pid signal ec wait_grace_period=0

	if _check_clean_shutdown; then
		echo "Everything is fine, no action required."
		echo
		exit 0
	fi

	# Send SIGTERM to running jobs, later SIGKILL if necessary
	for signal in "SIGTERM" "SIGKILL"; do
		for i in "$PID_DIR"/*.pid; do
			if [ ! -f "$i.stopped" ]; then
				name=${i##*/}
				name=${name:0:-4}
				pid=$(<"$i")

				if kill -0 -"$pid" 2>/dev/null; then
					# Process group is running
					_status "Sending $signal: $name ($pid)"
					kill -"$signal" -"$pid" 2>/dev/null || true
					if [ "$signal" == "SIGTERM" ]; then
						wait_grace_period=1
					else
						# Wait until process group got killed
						SECONDS=0 # Increments automatically
						while kill -0 -"$pid" 2>/dev/null; do
							if (( SECONDS >= 10 )); then
								_status "Error: Process group ($pid) is still running after 10 seconds."
								echo
								exit 1
							fi
							sleep 0.2
						done
					fi
				fi
			fi
		done
		if (( wait_grace_period == 1 )); then
			wait_grace_period=0
			_status "Waiting for a grace period of ${SIGTERM_GRACE_PERIOD} seconds before sending SIGKILL to any jobs that are still running."
			sleep "$SIGTERM_GRACE_PERIOD"
		else
			break
		fi
	done

	_delete_runtime_data
	_status "Fix was successful."
	echo
}

_stop_app_cli() {
	_exit_if_app_is_not_running

	local app_pid
	app_pid=$(<"$PID_FILE")

	if [ -f "$PID_DIR/.sigterm" ]; then
		_status "Termination is already in progress. Waiting.."
	else
		_status "Stopping $APP ($app_pid)"
		kill -SIGTERM "$app_pid" 2>/dev/null || true
	fi

	while kill -0 "$app_pid" 2>/dev/null; do
		sleep 0.5
	done

	_status "$APP ($app_pid) terminated"
}

_stop_app() {
	# Create marker file to indicate that a shutdown is in progress
	: >"$PID_DIR/.sigterm"

	_status "Stopping $APP ($$)"

	if (( ${#PIDS[@]} > 0 )); then
		# Send SIGTERM to all job process groups
		kill -SIGTERM "${PIDS[@]/#/-}" 2>/dev/null || true
	fi
}

# Calculate total runtime
_get_runtime() {
	local total=${1:-$SECONDS}
	local days=$((   total / 86400         ))
	local hours=$(( (total % 86400) / 3600 ))
	local mins=$((  (total %  3600) /   60 ))
	local secs=$((   total %    60         ))
	local output

	# Ensure a width of 2
	printf -v hours "%2d" "$hours"
	printf -v  mins "%2d" "$mins"
	printf -v  secs "%2d" "$secs"

	if (( days > 0 )); then
		output="${days}d ${hours}h ${mins}m ${secs}s"
	elif (( hours > 0 )); then
		output="${hours}h ${mins}m ${secs}s"
	elif (( mins > 0 )); then
		output="${mins}m ${secs}s"
	else
		output="${secs}s"
	fi

	# Trim white spaces
	read -r -d "" output <<<"$output" || true

	echo "$output"
}

_show_process_status_table() {
	local name=("Name") state=("State") pid=("PGID") runtime=("Runtime") logfile=("Logfile")
	local line boot_time i basename ec starttime current_time orphaned=()

	# Get boot time
	while read -r line; do
		if [[ $line =~ ^btime\ (.+) ]]; then
			boot_time=${BASH_REMATCH[1]}
			break
		fi
	done < /proc/stat

	# Get process states
	for i in "$PID_DIR"/*.pid; do
		basename=${i##*/}
		name+=("${basename:0:-4}")

		_is_process_running "$i" && ec=$? || ec=$?

		# Check exit code
		case "$ec" in
			0)
				  state+=( "running"                                        )
				    pid+=( "$(<"$i")"                                       )
				logfile+=( "$(readlink -f "/proc/${pid[-1]}/fd/1" || true)" )

				starttime=$(<"$i.starttime")
				printf -v current_time '%(%s)T' -1
				runtime+=( "$(_get_runtime "$(( current_time - (boot_time + starttime) ))")" )
				;;

			1)
				  state+=( "stopped" )
				    pid+=( ""        )
				logfile+=( ""        )

				if [ -f "$i.runtime" ]; then
					runtime+=( "$(<"$i.runtime")" )
				else
					runtime+=( "" )
				fi
				;;

			2)
				   state+=( "running*" )
				     pid+=( "$(<"$i")" )
				 logfile+=( ""         )
				 runtime+=( ""         )
				orphaned+=( "$(<"$i")" )
				;;
		esac
	done

	if (( ${#name[@]} == 1 )); then
		# No PID files in $PID_DIR
		echo "Error: $APP is not running."
		echo
		return 1
	fi >&2

	__get_max_element_length_from_array() {
		local i max_len=0
		for i in "$@"; do
			if (( ${#i} > max_len )); then
				max_len=${#i}
			fi
		done
		echo "$max_len"
	}

	# Set column padding
	local padding_name padding_state padding_pid padding_runtime padding_logfile
	padding_name=$(    __get_max_element_length_from_array "${name[@]}"    )
	padding_state=$(   __get_max_element_length_from_array "${state[@]}"   )
	padding_pid=$(     __get_max_element_length_from_array "${pid[@]}"     )
	padding_runtime=$( __get_max_element_length_from_array "${runtime[@]}" )
	padding_logfile=$( __get_max_element_length_from_array "${logfile[@]}" )

	# Add padding to GPID lines to right align them
	for i in "${!pid[@]}"; do
		(( i == 0 )) && continue
		if (( ${#pid[i]} < padding_pid )); then
			printf -v "pid[i]" "%*s" "$padding_pid" "${pid[i]}"
		fi
	done

	# Add padding to runtime lines to right align them
	for i in "${!runtime[@]}"; do
		(( i == 0 )) && continue
		if (( ${#runtime[i]} < padding_runtime )); then
			printf -v "runtime[i]" "%*s" "$padding_runtime" "${runtime[i]}"
		fi
	done

	# Repeat $1 "$2"-times
	__str_repeat(){
		local char=$1 count=$2 output
		printf -v output -- "%${count}s"
		printf "%s" "${output// /$char}"
	}

	__print_table_line() {
		# $1   Filler
		# $2   Start character
		# $3   Separator
		# $4   End character

		# Start character
		printf "%s" "$2"

		# 1st column
		__str_repeat "$1" $(( padding_name  + 2 ))

		# Separator
		printf "%s" "$3"

		# 2nd column
		__str_repeat "$1" $(( padding_state  + 2 ))

		# Separator
		printf "%s" "$3"

		# 3rd column
		__str_repeat "$1" $(( padding_pid  + 2 ))

		# Separator
		printf "%s" "$3"

		# 4th column
		__str_repeat "$1" $(( padding_runtime  + 2 ))

		# Separator
		printf "%s" "$3"

		# 5th column
		__str_repeat "$1" $(( padding_logfile  + 2 ))

		# End character
		printf "%s\n" "$4"
	}

	# Top border
	__print_table_line "─" "┌" "┬" "┐"

	# Print table
	local    red=$'\e[1;31m'
	local  green=$'\e[0;32m'
	local yellow=$'\e[0;33m'
	local  white=$'\e[1;37m'
	local  reset=$'\e[0m'

	for i in "${!name[@]}"; do
		if (( NO_COLOR == 0 )); then
			# The '%-*s' printf (dynamic) padding does not handle "colored" strings properly
			# Manual padding is required instead

			# 1st column (Name)
			echo -n "│ "
			if (( i == 0 )); then
				# Print header row in bright white
				printf "%s" "$white${name[i]}$reset"
			else
				printf "%s"       "${name[i]}"
			fi
			__str_repeat " " $(( padding_name - ${#name[i]} + 1 ))

			# 2nd column (State)
			echo -n "│ "
			case "${state[i]}" in
				   State) printf "%s"  "$white${state[i]}$reset" ;; # Print header row in bright white
				 running) printf "%s"  "$green${state[i]}$reset" ;; # Print "running"  jobs in green
				 stopped) printf "%s"    "$red${state[i]}$reset" ;; # Print "stopped"  jobs in red
				running*) printf "%s" "$yellow${state[i]}$reset" ;; # Print "running*" jobs in yellow
			esac
			__str_repeat " " $(( padding_state - ${#state[i]} + 1 ))

			# 3rd column (PID)
			echo -n "│ "
			case "${pid[i]}" in
				PGID) printf "%s" "$white${pid[i]}$reset" ;;
				   *) printf "%s"       "${pid[i]}"       ;;
			esac
			__str_repeat " " $(( padding_pid - ${#pid[i]} + 1 ))

			# 4th colum (Runtime)
			echo -n "│ "
			case "${runtime[i]}" in
				Runtime) printf "%s" "$white${runtime[i]}$reset" ;;
				      *) printf "%s"       "${runtime[i]}"       ;;
			esac
			__str_repeat " " $(( padding_runtime - ${#runtime[i]} + 1 ))

			# 5th column (Logfile)
			echo -n "│ "
			case "${logfile[i]}" in
				Logfile) printf "%s" "$white${logfile[i]}$reset" ;;
				      *) printf "%s"       "${logfile[i]}"       ;;
			esac
			__str_repeat " " $(( padding_logfile - ${#logfile[i]} + 1 ))
		else
			# Colorless table
			# 1st column (Name)
			printf "│ %-*s " "$padding_name"    "${name[i]}"

			# 2nd column (State)
			printf "│ %-*s " "$padding_state"   "${state[i]}"

			# 3rd column (PID)
			printf "│ %-*s " "$padding_pid"     "${pid[i]}"

			# 4th column (Runtime)
			printf "│ %-*s " "$padding_runtime" "${runtime[i]}"

			# 5th column (Logfile)
			printf "│ %-*s " "$padding_logfile" "${logfile[i]}"
		fi

		# End character
		echo "│"

		# Separate header row from table body
		if (( i == 0 )); then
			__print_table_line "═" "╞" "╪" "╡"
		fi
	done

	# Bottom border
	__print_table_line "─" "└" "┴" "┘"
	echo

	if (( ${#orphaned[@]} > 0 )); then
		echo "State: ${yellow}running*$reset --> Main process exited, but child processes are still running."
		echo "The child processes are not necessarily part of the job anymore."
		echo
		echo "To inspect the orphaned child processes, run: ps -o pid,pgid,cmd ${orphaned[*]/#/-g }"
		echo
	fi
}

_start_job_cli() {
	_exit_if_app_is_not_running

	local name=$1 pid
	local pid_file="$PID_DIR/$name.pid"

	# Ensure that only one job starts at a time
	SECONDS=0 # Increments automatically
	until _acquire_lock; do
		if (( SECONDS >= 10 )); then
			echo "Error: Could not acquire lock within 10 seconds."
			echo
			return 1
		fi >&2
		sleep 0.2
	done >&2

	if [ -f "$pid_file" ]; then
		if [ -f "$pid_file.stopped" ]; then
			if [ -f "$PID_DIR/.sigterm" ]; then
				echo "Error: $APP termination is in progress."
				echo
				return 1
			fi >&2

			# Create marker file
			_set_job_state "start" "$PID_DIR/$name"

			# Send USR1 signal to supervisor to trigger the job start
			# start_job_trap() will then start the job
			if ! kill -SIGUSR1 "$(<"$PID_FILE")"; then
				# Delete marker file
				rm -f "$pid_file.start"

				echo "Error: Triggering job start failed."
				echo
				return 1
			fi >&2

			_status "Starting job: $name"

			# Wait until job has started
			SECONDS=0 # Increments automatically
			while [ -f "$pid_file.start" ]; do
				if (( SECONDS >= 10 )); then
					# Delete marker file
					rm -f "$pid_file.start"

					_status "Error: Job was not started within 10 seconds. Check $APP log."
					return 1
				fi
				sleep 0.2
			done

			pid=$(<"$pid_file")
			if [ -z "$pid" ]; then
				# $name.pid.start file was deleted, but PID file is empty.
				# This happens when a job fails to start because its log file is not writable.
				_status "Error: Job failed to start."
				return 1
			fi

			_status "Job started: $name ($pid)"
			return 0
		else
			echo "Error: $name is already running." >&2
			echo >&2
			return 1
		fi
	else
		echo "Error: Job '$name' not found." >&2
		echo >&2
		return 1
	fi
}

_stop_job_cli() {
	_exit_if_app_is_not_running

	local name=$1 pid
	local pid_file="$PID_DIR/$name.pid"

	if [ -f "$pid_file" ]; then
		if [ ! -f "$pid_file.stopped" ]; then
			if [ -f "$PID_DIR/.sigterm" ]; then
				echo "Error: $APP termination is in progress."
				echo
				return 1
			fi >&2

			# Send SIGTERM to job process group
			pid=$(<"$pid_file")
			_status "Stopping job: $name ($pid)"
			_set_job_state "stop" "$PID_DIR/$name"
			kill -SIGTERM -"$pid" 2>/dev/null || true

			_status "Waiting for a grace period of ${SIGTERM_GRACE_PERIOD} seconds before sending SIGKILL."

			# Wait until job has terminated
			local grace_period_start=$SECONDS
			while kill -0 -"$pid" 2>/dev/null; do
				if (( SECONDS - grace_period_start >= SIGTERM_GRACE_PERIOD )); then
					_status "Job is still running, sending SIGKILL: $name ($pid)"
					kill -SIGKILL -"$pid" 2>/dev/null || true
				fi
				sleep 0.2
			done

			SECONDS=0 # Increments automatically
			until [[ -f "$pid_file.stopped" || ! -f "$pid_file" ]]; do
				if (( SECONDS >= 10 )); then
					_status "Job terminated: $name ($pid)"
					_status "Error: Runtime files were not cleaned up by $APP within 10 seconds."
					return 1
				fi
				if _is_process_running "$pid_file"; then
					# Job was restarted by another CLI instance (really fast!)
					break;
				fi
				sleep 0.2
			done

			_status "Job terminated: $name ($pid)"
			return 0
		else
			echo "Error: $name is not running." >&2
			echo >&2
			return 1
		fi
	else
		echo "Error: Job '$name' not found." >&2
		echo >&2
		return 1
	fi
}

_set_job_state() {
	local state=$1 name=$2

	case "$state" in
		start)
			# Job start triggered via CLI
			: >"$name.pid.start"
			;;

		stop)
			# Let supervisor know, that the job is stopped on purpose (via CLI)
			# This is important
			# - if a job terminates and is configured with 'required: yes'
			# - if a job terminates and is configured with 'restart: on'
			# The marker below ensures that supervisor takes no action in these cases.
			: >"$name.pid.stop"
			;;

		stopped)
			# Job stopped
			: >"$name.pid"
			rm -f "$name.pid."{start,starttime}
			: >"$name.pid.stopped"
			;;

		started)
			# Job started
			rm -f "$name.pid."{start,stop,stopped,runtime}
			;;
	esac
	return 0
}

# Parse options
while [[ "${1:-}" == -* ]]; do
	case "${1:-}" in
		-h|--help)
			_usage
			;;

		-c|--config)
			# Use config file from argument
			if [ -z "${2:-}" ]; then
				echo "Error: No configuration file provided."
				echo
				exit 1
			fi >&2
			# Get absolute CONFIG_FILE path. A relative path will not work in daemon mode (Daemon's work directory is /)
			CONFIG_FILE=$(readlink -f "$2")
			shift 2
			;;

		-n|--no-color)
			NO_COLOR=1
			shift
			;;

		-v|--version)
			echo "$APP $VER"
			echo
			exit 0
			;;

		--)
			shift
			break
			;;

		--daemon)
			break
			;;

		*)
			echo "Error: Unknown option '$1'" >&2
			echo >&2
			exit 1
	esac
done

# Read config
if ! [[
	# Some commands don’t require the config file, e.g. status / start <job> / stop / lint
	"${1:-}" == "status"                ||
	"${1:-}" == "start"  && -n "${2:-}" ||
	"${1:-}" == "stop"   && -z "${2:-}" ||
	"${1:-}" == "lint"
]]; then
	_read_config_file
fi

# CLI option > config file
if (( NO_COLOR == 1 )); then
	COLOR=""
	COLOR_ERROR=""
fi

_create_pid_directory() {
	# shellcheck disable=2174
	if ! mkdir -m 700 -p "$PID_DIR" 2>/dev/null; then
		echo "Error: PID directory '$PID_DIR' could not be created. Check permissions."
		echo
		exit 1
	fi >&2
}

# Get command
case "${1:-}" in
	""|*start)
		# Ensure PID directory exists for start operations
		_create_pid_directory
		;;&

	lint)
		# Check and print config
		_read_config_file
		echo "Configuration is valid."
		echo
		_show_config
		exit 0
		;;

	fix)    _fix_unclean_shutdown; exit ;;

	status) _exit_if_unclean_shutdown; _show_process_status_table; exit ;;

	start)
		# Start daemon or job?
		if [ -n "${2:-}" ]; then
			_start_job_cli "$2"
			exit 0
		fi
		;;

	stop)
		# Stop supervisor or job?
		if [ -z "${2:-}" ]; then
			# Stop supervisor
			_stop_app_cli
		else
			# Stop job if running
			_stop_job_cli "$2"
		fi
		exit 0
		;;

	restart)
		# Restart supervisor or job?
		if [ -z "${2:-}" ]; then
			_exit_if_app_is_not_running

			# Check if supervisor runs as daemon (required for restart)
			mapfile -t -d $'\0' SV_ARGS < "/proc/$(<"$PID_FILE")/cmdline"
			if [ "${SV_ARGS[-1]}" != "--daemon" ]; then
				echo "Error: $APP is not running as daemon."
				echo
				exit 1
			fi >&2

			_stop_app_cli # Continue from here after the supervisor was stopped to start again
		else
			_stop_job_cli "$2"
			_start_job_cli "$2"
			exit 0
		fi
		;;

	convert)
		if (( CONFIG_FILE_BASH == 1 )); then
			echo "Error: Configuration file '$CONFIG_FILE' is already converted to Bash."
			echo
			exit 1
		fi >&2

		echo "Converting '$CONFIG_FILE' to Bash --> '$CONFIG_FILE.sh'"
		echo

		# Get the attributes and value of each variable
		VARS=$(declare -p            \
			LOG_FILE             \
			SIGTERM_GRACE_PERIOD \
			KEEP_RUNNING         \
			COLOR                \
			COLOR_ERROR          \
			TIME_FORMAT          \
			JOB_NAME             \
			JOB_COMMAND          \
			JOB_AUTOSTART        \
			JOB_LOGFILE          \
			JOB_REQUIRED         \
			JOB_RESTART          \
			JOB_RESTART_LIMIT
		)

		# Declare variables as global and write config file
		echo "${VARS//declare/& -g}" >"$CONFIG_FILE.sh"
		exit 0
		;;

	log)
		if [[ "$LOG_FILE" != "/dev/stdout" && -f "$LOG_FILE" ]]; then
			# Show the last 10 log lines, then output appended data as the file grows
			exec tail -n 10 -F "$LOG_FILE"
		else
			echo "Error: No log file configured in '$CONFIG_FILE'" >&2
			echo >&2
			exit 1
		fi
		;;

	logs)
		LOGS=()

		for i in "${JOB_LOGFILE[@]}"; do
			if [ "$i" != "/dev/stdout" ]; then
				LOGS+=("$i")
			fi
		done

		if [[ "$LOG_FILE" != "/dev/stdout" && -f "$LOG_FILE" ]]; then
			LOGS+=("$LOG_FILE")
		fi

		if (( ${#LOGS[@]} > 0 )); then
			# Show the last 10 log lines, then output appended data as the files grow
			exec tail -n 10 -F "${LOGS[@]}"
		else
			echo "Error: No log files configured in '$CONFIG_FILE'" >&2
			echo >&2
			exit 1
		fi
		;;

	--daemon) : ;; # Already in daemon mode --> Don't start again

	# No command? Start supervisor in foreground.
	"")
		set -- "--daemon" # Pretend to be already in daemon mode --> Don't start as daemon
		FOREGROUND=1      # Run in foreground, not as daemon
		;;

	*)
		echo "Error: Unknown command '$1'" >&2
		echo >&2
		exit 1
		;;
esac

# Begin server only part

# Bash version >= 5.1 ?
if ! (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
	echo "Error: Bash 5.1 or later is required to run $APP"
	echo
	exit 1
fi >&2

if _acquire_lock; then
	_exit_if_unclean_shutdown skip-lock-check
	_exit_if_app_is_already_running
else
	if [[ $FOREGROUND == 1 || $1 != "--daemon" ]]; then
		echo "Error: Could not acquire lock. $APP is already being started by another process."
		echo
		exit 1
	fi >&2

	# FOREGROUND == 0 && $1 == "--daemon" --> log already acquired by parent process, see blow.
fi

# Run as daemon
if [ "$1" != "--daemon" ]; then
	if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
		echo "Error: $APP log file '$LOG_FILE' is not writeable."
		echo
		exit 1
	fi >&2

	_status "Starting $APP"

	cd /
	setsid bash "$APP_PATH" --config "$CONFIG_FILE" "--daemon" &
	echo "$!" >"$PID_FILE"
	_get_starttime_from_pid "$!" >"$PID_FILE.starttime"

	# Do not release lock. This will be handled by the new daemon process started above.
	trap "" EXIT

	_status "$APP $VER started ($!)"
	exit 0
fi

_terminate() {
	# Termination is now in progress. Disable traps to prevent loops and race conditions (SIGUSR1).
	trap "" SIGHUP SIGINT SIGTERM SIGUSR1 EXIT

	local signal=${1:-} i

	# Unexpected termination (unknown signal or error)
	# 'kill -0' does not work reliably after receiving a signal without a trap handler, e.g. SIGSEGV.
	# After _stop_app() sends SIGTERM to the child process it turns into a zombie: grep State /proc/PID/status --> State:  Z (zombie)
	# That's because 'wait' have to be called on that process.
	# Therefore stop supervisor and jobs in a generic way without job monitoring.
	# This will mostly take longer, because the full grace period is used
	# and supervisor will not exit early if the jobs terminate faster.
	if [ -z "$signal" ]; then
		_status "Error: Unexpected termination" ERROR

		# Send SIGTERM to all jobs
		_stop_app

		_status "Waiting $SIGTERM_GRACE_PERIOD seconds for job termination"
		sleep "$SIGTERM_GRACE_PERIOD"

		# Send SIGKILL to all jobs
		kill -SIGKILL "${PIDS[@]/#/-}" 2>/dev/null || true

		_delete_runtime_data
		_status "$APP ($$) terminated after $(_get_runtime)"
		exit 1
	fi

	[ "$signal" != "NO_SIGNAL" ] && _status "$signal received."

	# Send SIGTERM to all jobs
	_stop_app

	local grace_period_start=$SECONDS last_wait_info=$SECONDS

	__wait_info() {
		local i wait_jobs seconds_until_sigkill
		for i in "${!PIDS[@]}"; do
			wait_jobs+="${JOB_NAME[i]}, "
		done
		if [ -n "${wait_jobs:-}" ]; then
			seconds_until_sigkill=$(( SIGTERM_GRACE_PERIOD + grace_period_start - SECONDS ))
			(( seconds_until_sigkill > 0 )) && _status "Waiting $seconds_until_sigkill seconds for job termination: ${wait_jobs:0:-2}"
		fi
		return 0
	}
	__wait_info

	# Wait until all jobs have terminated
	while :; do
		for i in "${!PIDS[@]}"; do
			# Is job still running?
			if ! kill -0 -"${PIDS[i]}" 2>/dev/null; then
				_status "Job terminated: ${JOB_NAME[i]} (${PIDS[i]})"
				unset "PIDS[$i]"
				_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
			else
				# Kill job after grace period
				if (( SECONDS - grace_period_start >= SIGTERM_GRACE_PERIOD )); then
					_status "Job is still running, sending SIGKILL: ${JOB_NAME[i]} (${PIDS[i]})"
					kill -SIGKILL -"${PIDS[i]}" 2>/dev/null || true
				fi
			fi
		done

		# Are all jobs terminated?
		if (( ${#PIDS[@]} == 0 )); then
			break
		fi

		# Show remaining running jobs every 5 seconds
		if (( SECONDS - last_wait_info > 4 )); then
			last_wait_info=$SECONDS
			__wait_info
		fi

		sleep 0.2
	done

	_delete_runtime_data

	_status "$APP ($$) terminated after $(_get_runtime)"
	exit 0
}

# Set signal handlers
trap "      _terminate        " EXIT    # Unexpected signals and errors
trap "      _terminate SIGHUP " SIGHUP  # Stop supervisor when receiving SIGHUP
trap "echo; _terminate SIGINT " SIGINT  # Stop supervisor when receiving SIGINT
trap "      _terminate SIGTERM" SIGTERM # Stop supervisor when receiving SIGTERM

# Running as daemon?
if (( FOREGROUND == 0 )); then
	# Ignore SIGHUP
	trap "" SIGHUP

	# Close STDIN file descriptor
	exec 0>&-

	# Redirect STDOUT and STDERR to /dev/null or a log file if configured
	if [ "$LOG_FILE" == "/dev/stdout" ]; then
		exec &>  /dev/null
	else
		exec &>> "$LOG_FILE"
	fi
else
	echo "$$" >"$PID_FILE"
	_get_starttime_from_pid "$$" >"$PID_FILE.starttime"
fi

_status "$APP $VER started ($$)"
_release_lock

_exit_app_if_job_is_required() {
	local i=$1

	# Stop supervisor if a required job has terminated
	if [ "${JOB_REQUIRED[i]}" == "yes" ]; then
		# Keep running, if the job was stopped on purpose (via the 'stop' command)
		if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
			_status "Required job terminated: ${JOB_NAME[i]}" ERROR
			_terminate NO_SIGNAL
		fi
	fi
}

_start_job() {
	local i=$1

	# Prevent restart loop if log file is not writeable
	if ! { : >> "${JOB_LOGFILE[i]}"; } 2>/dev/null; then
		_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
		_status "Error: Job '${JOB_NAME[i]}' could not be started. Log file '${JOB_LOGFILE[i]}' is not writeable." ERROR
		_exit_app_if_job_is_required "$i"

		# Explicit return code 0 is mandatory. Any 'return' executed within a trap handler, returns the exit status of the last command
		# executed before the handler was invoked. In this case, 130 (128 + 10 [SIGUSR1]).
		return 0
	fi

	# setsid --> run each job in his own process group
	setsid bash -c "${JOB_COMMAND[i]}" &>>"${JOB_LOGFILE[i]}" &

	# Save PID
	PIDS[i]=$!
	echo "${PIDS[i]}" >"$PID_DIR/${JOB_NAME[i]}.pid"

	# Save start time
	PIDS_STARTTIME[i]=$(_get_starttime_from_pid "${PIDS[i]}")
	echo "${PIDS_STARTTIME[i]}" >"$PID_DIR/${JOB_NAME[i]}.pid.starttime"

	_set_job_state "started" "$PID_DIR/${JOB_NAME[i]}"
	_status "Job started: ${JOB_NAME[i]} (${PIDS[i]})"
}

# Create jobs first, where autostart is disabled.
# This avoids a race condition, when a job starts another job that might not exist yet.
for i in "${!JOB_NAME[@]}"; do
	if [ "${JOB_AUTOSTART[i]}" == "off" ]; then
		_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
	fi
done

# Start a job, when SIGUSR1 is received
_start_job_trap() {
	local i name

	# For the job that has to be started, a JOB.pid.start file exists.
	for name in "$PID_DIR"/*.pid.start; do
		name=${name##*/}
		name=${name:0:-10}

		# Search and start job
		for i in "${!JOB_NAME[@]}"; do
			if [ "${JOB_NAME[i]}" == "$name" ]; then
				if [ -n "${PIDS[i]:-}" ]; then
					# This should never happen, when using "supervisor.sh start <job>"
					_status "Error: '$name' job start was requested, but the job is already running." ERROR
					break
				fi

				# (Re)set restart count
				JOB_RESTART_COUNT[i]=0
				_start_job "$i"
				break
			fi
		done
	done
}

# Set signal handler for SIGUSR1
trap "_start_job_trap" SIGUSR1

# Start jobs
for i in "${!JOB_NAME[@]}"; do
	if [ "${JOB_AUTOSTART[i]}" == "on" ]; then
		# Autostart enabled
		JOB_RESTART_COUNT[i]=0
		_start_job "$i"
	fi
done

# Kill a process group
_kill_process_group() {
	local i=$1

	if kill -0 -"${PIDS[i]}" 2>/dev/null; then
		kill -SIGTERM -"${PIDS[i]}" 2>/dev/null || true
		_status "Waiting for child processes to terminate: ${JOB_NAME[i]} (${PIDS[i]})"

		local grace_period_start=$SECONDS
		while kill -0 -"${PIDS[i]}" 2>/dev/null; do
			if (( SECONDS - grace_period_start >= SIGTERM_GRACE_PERIOD )); then
				# Kill possible orphaned processes
				if kill -SIGKILL -"${PIDS[i]}" 2>/dev/null; then
					_status "Child processes are still running, sending SIGKILL: ${JOB_NAME[i]} (${PIDS[i]})"
				fi
			fi
			sleep 0.2
		done

		_status "Child processes terminated: ${JOB_NAME[i]} (${PIDS[i]})"
	fi
}

_clean_up_job() {
	local i=$1 now _

	# Save runtime
	IFS=. read -r now _ </proc/uptime
	_get_runtime "$(( now - PIDS_STARTTIME[i] ))" >"$PID_DIR/${JOB_NAME[i]}.pid.runtime"

	unset "PIDS_STARTTIME[$i]"
	unset "PIDS[$i]"

	_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
}

# Wait for jobs to terminate
while :; do
	if wait -n -p JOB_PID; then
		JOB_EXIT_CODE=0
	else
		JOB_EXIT_CODE=$?
	fi

	if [ -z "${JOB_PID:-}" ]; then
		if (( ${#PIDS[@]} == 0 )); then
			# Only supervisor is running
			if [ "$KEEP_RUNNING" == "off" ]; then
				_status "No more jobs are running"
				_terminate NO_SIGNAL
			else
				sleep 1
				continue
			fi
		else
			# If $JOB_PID is empty while $PIDS is not, 'wait' was interrupted.
			# This happens when a signal such as SIGUSR1 is received.
			# JOB_EXIT_CODE = 138 = 128 + 10 (SIGUSR1)
			continue
		fi
	fi

	for i in "${!PIDS[@]}"; do
		if [ "${PIDS[i]}" == "$JOB_PID" ]; then
			if [[ $JOB_EXIT_CODE -gt 0 && ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]]; then
				_status "Job failed with exit code $JOB_EXIT_CODE: ${JOB_NAME[i]} (${PIDS[i]})" ERROR
			else
				if [ -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
					# Job was stopped via 'supervisor.sh stop <job>'
					_status "Job terminated (expected): ${JOB_NAME[i]} (${PIDS[i]})"
				else
					_status "Job terminated: ${JOB_NAME[i]} (${PIDS[i]})"
				fi
			fi

			# Kill possible orphaned processes
			_kill_process_group "$i"

			# Restart job if necessary
			if [[ "${JOB_RESTART[i]}" == "error" && $JOB_EXIT_CODE -gt 0 || "${JOB_RESTART[i]}" == "on" ]]; then
				if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
					# Job termination is unexpected
					# Restart job if limit is not already reached
					if (( JOB_RESTART_LIMIT[i] == 0 || JOB_RESTART_COUNT[i] < JOB_RESTART_LIMIT[i] )); then
						(( ++JOB_RESTART_COUNT[i] ))

						if (( JOB_RESTART_LIMIT[i] == 0 )); then
							# No restart limit
							_status "Restarting (${JOB_RESTART_COUNT[i]}): ${JOB_NAME[i]}"
						else
							_status "Restarting (${JOB_RESTART_COUNT[i]}/${JOB_RESTART_LIMIT[i]}): ${JOB_NAME[i]}"
						fi

						# _clean_up_job (which creates the .stopped marker file) must not be called before _start_job
						# to prevent a race condition when "supervisor.sh start <job>" is run between _clean_up_job() and _start_job().
						_start_job "$i"
						break
					else
						_status "Restart limit (${JOB_RESTART_LIMIT[i]}) reached: ${JOB_NAME[i]}"
					fi
				fi
			fi

			_clean_up_job "$i"
			_exit_app_if_job_is_required "$i"
			break
		fi
	done
done
