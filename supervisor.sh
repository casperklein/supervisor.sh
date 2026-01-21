#!/usr/bin/env bash

# shellcheck disable=2178,2128 # shellcheck bug

# Dependencies: yq, bash >= 5.1
# Bash 5.1 or later is required to support 'wait -p'

# Also these common core utilities are required: cat mkdir readlink rm setsid sleep tail

# Source: https://github.com/casperklein/supervisor.sh/

# Shell options
set   -o errexit         # Exit immediately if a command exits with a non-zero status
set   -o nounset         # Treat unset variables as an error when substituting
shopt -s inherit_errexit # Exit on errors - also in sub-shells
shopt -s nullglob        # Return nothing if '*' does not expand

# Global variables
APP="supervisor.sh"
APP_PATH=$(readlink -f "$0")
VER=0.12

: "${PID_DIR:=/run/$APP}" # Allow override via ENV
PID_FILE="$PID_DIR/$APP.pid"

CONFIG_FILE_BASH=0
FOREGROUND=0
LINT=0
NO_COLOR=0
PIDS=()
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
		  -l, --lint       Validate and display the full configuration, including implicit default values.
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
		  log              Show continuously the $APP log.
		  logs             Show continuously the $APP log + job logs.
		  convert          Convert the YAML configuration file to Bash. This allows the
		                   usage without the 'yq' dependency.

		If no command is provided, $APP will start in foreground.

	USAGE
	exit 0
}

_read_config_file() {
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
	local marker
	read -r -N 7 marker < "$CONFIG_FILE" || true # 'read' may fail if the file is empty or smaller than 7 bytes
	if [ "$marker" == "declare" ]; then
		CONFIG_FILE_BASH=1
		# shellcheck disable=1090
		source "$CONFIG_FILE"
		return 0
	fi

	# Check if 'yq' binary is available
	if ! hash yq 2>/dev/null; then
		echo "Error: 'yq' binary is not available. Get it from: https://github.com/mikefarah/yq"
		echo
		exit 1
	fi >&2

	# Check if the correct 'yq' program is used
	if [[ "$(yq --version)" != "yq (https://github.com/mikefarah/yq/)"* ]]; then
		echo "Error: Wrong 'yq' program detected."
		echo
		echo "There are at least two, that have the same name:"
		echo
		echo "$APP depends on 'yq' from: https://github.com/mikefarah/yq"
		echo "The Debian repository, for example, provides 'yq' from: https://github.com/kislyuk/yq"
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

	# Check required job keys
	local i
	for i in "${!JOB_NAME[@]}"; do
		if [[ -z "${JOB_NAME[i]}" || -z "${JOB_COMMAND[i]}" ]]; then
			__show_error_and_exit "Parsing job #$((++i)) configuration failed. The 'name' or 'command' key cannot be empty/missing."
		fi
	done

	# JOB_NAME must be uniq
	declare -A job_name_uniq
	local j=0
	for i in "${JOB_NAME[@]}"; do
		((++j))
		if [ -n "${job_name_uniq[$i]:-}" ]; then
			__show_error_and_exit "Invalid job #$j name. Job #${job_name_uniq[$i]} is already named '$i'."
		else
			job_name_uniq[$i]=$j
		fi
	done

	__is_integer() {
		# $1   Description
		# $2   Value

		if ! [[ "$2" =~ ^[0-9]+$ ]]; then
			__show_error_and_exit "$1 must be an integer >= 0. Current value is: $2"
		fi
	}

	__is_integer "supervisor key 'sigterm_grace_period'" "$SIGTERM_GRACE_PERIOD"

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

	__has_valid_value "supervisor key 'keep_running'" "$KEEP_RUNNING" on off

	for i in "${!JOB_AUTOSTART[@]}"; do
		__has_valid_value "Job #$(( i + 1 )) key 'autostart'" "${JOB_AUTOSTART[i]}" on off
	done

	for i in "${!JOB_RESTART[@]}"; do
		__has_valid_value "Job #$(( i + 1 )) key 'restart'" "${JOB_RESTART[i]}" error on off
	done

	for i in "${!JOB_REQUIRED[@]}"; do
		__has_valid_value "Job #$(( i + 1 )) key 'required'" "${JOB_REQUIRED[i]}" yes no
	done
}

_show_config() {
	local color color_error
	# Escape ANSI colors
	color=$(      printf -- '%q' "$COLOR")
	color_error=$(printf -- '%q' "$COLOR_ERROR")

	cat <<-CONFIG
		supervisor:
		  logfile: $LOG_FILE
		  sigterm_grace_period: $SIGTERM_GRACE_PERIOD
		  keep_running: $KEEP_RUNNING
		  color: ${color:2:-1}
		  color_error: ${color_error:2:-1}
		  time_format: $TIME_FORMAT

		jobs:
	CONFIG

	for i in "${!JOB_NAME[@]}"; do
		cat <<-CONFIG
		  # Job $(( i + 1 ))"
		  - name: ${JOB_NAME[i]}
		    command: ${JOB_COMMAND[i]}
		    autostart: ${JOB_AUTOSTART[i]}
		    logfile: ${JOB_LOGFILE[i]}
		    restart: ${JOB_RESTART[i]}
		    restart_limit: ${JOB_RESTART_LIMIT[i]}
		    required: ${JOB_REQUIRED[i]}

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
		printf -- "%s%($TIME_FORMAT)T %s%s\n" "$color" -1 "$1" $'\e[0m'
	else
		printf -- "%($TIME_FORMAT)T %s\n" -1 "$1"
	fi

	return 0
}

_is_app_running() {
	if [ -f "$PID_FILE" ]; then
		if kill -0 "$(<"$PID_FILE")" 2>/dev/null; then
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
	local i
	if ! _is_app_running; then
		for i in "$PID_DIR"/*.pid* "$PID_DIR"/.sigterm*; do
			return 1
		done
	fi
	return 0
}

_exit_if_unclean_shutdown() {
	if ! _check_clean_shutdown; then
		echo "Error: $APP was not stopped gracefully. See the process status table below."
		echo
		_show_process_status_table
		echo "Run '$APP fix' to stop any running jobs and clean up."
		echo
		exit 1
	fi >&2
}

_delete_runtime_files() {
	rm -f "$PID_DIR/"*.pid*
	rm -f "$PID_DIR/.sigterm"
}

# Stop any running jobs and delete runtime files
_fix_unclean_shutdown() {
	local i name pid signal wait_grace_period=0

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
					_status "Sending $signal: $name ($pid)"
					kill -"$signal" -"$pid" 2>/dev/null || true
					if [ "$signal" == "SIGTERM" ]; then
						wait_grace_period=1
					fi
				fi
			fi
		done
		if (( wait_grace_period == 1 )); then
			wait_grace_period=0
			_status "Waiting for a grace period of ${SIGTERM_GRACE_PERIOD}s before sending SIGKILL to any jobs that are still running."
			sleep "$SIGTERM_GRACE_PERIOD"
		else
			break
		fi
	done
	sleep 1

	_delete_runtime_files
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
	# Shutdown is now in progress. Ignore further INT/TERM signals.
	trap "" SIGINT SIGTERM

	# Signal to CLI commands (e.g. 'supervisor.sh stop') that the shutdown is in progress
	: >"$PID_DIR/.sigterm"

	_status "Stopping $APP ($$)"

	if (( ${#PIDS[@]} > 0 )); then
		# Send SIGTERM to all job process groups
		kill -SIGTERM "${PIDS[@]/#/-}" 2>/dev/null || true
	fi

	# Trigger _clean_up()
	exit 0
}

_show_process_status_table() {
	local i basename name=("Name") state=("State") pid=("PID") logfile=("Logfile")

	# Get process states
	for i in "$PID_DIR"/*.pid; do
		basename=${i##*/}
		name+=("${basename:0:-4}")
		if kill -0 -"$(<"$i")" 2>/dev/null; then
			state+=(running)
			pid+=("$(<"$i")")
			logfile+=("$(readlink -f "/proc/${pid[-1]}/fd/1" || true)")
		else
			state+=(stopped)
			pid+=("")
			logfile+=("")
		fi
	done

	if (( ${#name[@]} == 1 )); then
		echo "Error: $APP is not running."
		echo
		return 1
	fi >&2

	__get_max_element_length_from_array() {
		local max_len=0
		local i
		for i in "$@"; do
			if (( ${#i} > max_len )); then
				max_len=${#i}
			fi
		done
		echo "$max_len"
	}

	# Set column padding
	local padding_name padding_state padding_pid padding_logfile
	padding_name=$(    __get_max_element_length_from_array "${name[@]}"    )
	padding_state=$(   __get_max_element_length_from_array "${state[@]}"   )
	padding_pid=$(     __get_max_element_length_from_array "${pid[@]}"     )
	padding_logfile=$( __get_max_element_length_from_array "${logfile[@]}" )

	# Repeat $1 "$2"-times
	__str_repeat(){
		local char=$1 count=$2 output
		printf -v output -- "%${count}s"
		printf -- "%s" "${output// /$char}"
	}

	__print_table_line() {
		# $1   Filler
		# $2   Start character
		# $3   Separator
		# $4   End character

		# Start character
		printf -- "%s" "$2"

		# 1st column
		__str_repeat "$1" $(( padding_name  + 2 ))

		# Separator
		printf -- "%s" "$3"

		# 2nd column
		__str_repeat "$1" $(( padding_state  + 2 ))

		# Separator
		printf -- "%s" "$3"

		# 3rd column
		__str_repeat "$1" $(( padding_pid  + 2 ))

		# Separator
		printf -- "%s" "$3"

		# 4th column
		__str_repeat "$1" $(( padding_logfile  + 2 ))

		# End character
		printf -- "%s\n" "$4"
	}

	# Top border
	__print_table_line "─" "┌" "┬" "┐"

	# Print table
	local green=$'\e[0;32m'
	local red=$'\e[1;31m'
	local white=$'\e[1;37m'
	local reset=$'\e[0m'

	for i in "${!name[@]}"; do
		if (( NO_COLOR == 0 )); then
			# The '%-*s' printf (dynamic) padding does not handle "colored" strings properly
			# Manual padding is required instead

			# 1st column (Name)
			echo -n "│ "
			if (( i == 0 )); then
				# Print header row in bright white
				printf -- "%s" "$white${name[i]}$reset"
			else
				printf -- "%s"       "${name[i]}"
			fi
			__str_repeat " " $(( padding_name - ${#name[i]} + 1 ))

			# 2nd column (State)
			echo -n "│ "
			case "${state[i]}" in
				  State) printf -- "%s" "$white${state[i]}$reset" ;; # Print header row in bright white
				running) printf -- "%s" "$green${state[i]}$reset" ;; # Print "running" jobs in green
				stopped) printf -- "%s"   "$red${state[i]}$reset" ;; # Print "stopped" jobs in red
			esac
			__str_repeat " " $(( padding_state - ${#state[i]} + 1 ))

			# 3rd column (PID)
			echo -n "│ "
			case "${pid[i]}" in
				PID) printf -- "%s" "$white${pid[i]}$reset" ;;
				  *) printf -- "%s"       "${pid[i]}"       ;;
			esac
			__str_repeat " " $(( padding_pid - ${#pid[i]} + 1 ))

			# 4th column (Logfile)
			echo -n "│ "
			case "${logfile[i]}" in
				Logfile) printf -- "%s" "$white${logfile[i]}$reset" ;;
				      *) printf -- "%s"       "${logfile[i]}"       ;;
			esac
			__str_repeat " " $(( padding_logfile - ${#logfile[i]} + 1 ))
		else
			# Colorless table
			# 1st column (Name)
			printf -- "│ %-*s " "$padding_name"    "${name[i]}"

			# 2nd column (State)
			printf -- "│ %-*s " "$padding_state"   "${state[i]}"

			# 3rd column (PID)
			printf -- "│ %-*s " "$padding_pid"     "${pid[i]}"

			# 4th column (Logfile)
			printf -- "│ %-*s " "$padding_logfile" "${logfile[i]}"
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
}

_start_job_cli() {
	_exit_if_app_is_not_running

	local name=$1

	if [ -f "$PID_DIR/$name.pid" ]; then
		if [ -f "$PID_DIR/$name.pid.stopped" ]; then
			# Request job start once
			if [ -f "$PID_DIR/$name.pid.start" ]; then
				echo "Error: Job is already being started."
				echo
				return 1
			fi >&2

			# Set marker
			_set_job_state "start" "$PID_DIR/$name"

			# Send USR1 signal to supervisor to trigger the job start
			# start_job_trap() will then start the job
			if ! kill -SIGUSR1 "$(<"$PID_FILE")"; then
				echo "Error: Triggering job start failed."
				echo
				return 1
			fi >&2

			_status "Starting job: $name"

			# Wait until job has started
			while [ -f "$PID_DIR/$name.pid.start" ]; do
				sleep 0.2
			done

			_status "Job started: $name ($(<"$PID_DIR/$name.pid"))"
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

	local name=$1 job_pid
	local grace_period_start=$SECONDS

	if [ -f "$PID_DIR/$name.pid" ]; then
		if [ ! -f "$PID_DIR/$name.pid.stopped" ]; then
			# Send SIGTERM to job process group
			job_pid=$(<"$PID_DIR/$name.pid")
			_status "Stopping job: $name ($job_pid)"
			_set_job_state "stop" "$PID_DIR/$name"
			kill -SIGTERM -"$job_pid" 2>/dev/null || true

			_status "Waiting for a grace period of ${SIGTERM_GRACE_PERIOD}s before sending SIGKILL."

			# Wait until job has stopped
			while kill -0 -"$job_pid" 2>/dev/null; do
				if (( SECONDS - grace_period_start >= SIGTERM_GRACE_PERIOD )); then
					_status "Job is still running, sending SIGKILL: $name ($job_pid)"
					kill -SIGKILL -"$job_pid" 2>/dev/null || true
				fi
				sleep 0.2
			done

			_status "Job terminated: $name ($job_pid)"
			return 0
		else
			echo "Error: $name is not running." >&2
			echo >&2
			exit 1
		fi
	else
		echo "Error: Job '$name' not found." >&2
		echo >&2
		exit 1
	fi
}

_set_job_state() {
	local state=$1 job_file=$2

	case "$state" in
		start)
			: >"$job_file.pid.start"
			;;

		stop)
			# Let supervisor know, that the job is stopped on purpose.
			# This is important
			# - if a job is stopped and configured with 'required: yes'
			# - if a job is stopped and configured with 'restart: on'
			# The marker below ensures that supervisor takes no action in these cases.
			: >"$job_file.pid.stop"
			;;

		stopped)
			: >"$job_file.pid"
			rm -f "$job_file.pid.start"
			: >"$job_file.pid.stopped"
			;;

		started)
			rm -f "$job_file.pid."{start,stop,stopped}
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

		-l|--lint)
			LINT=1
			shift
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

# Check and print config
if (( LINT == 1 )); then
	_read_config_file
	echo "Configuration is valid."
	echo
	_show_config
	exit 0
fi

# Some commands don’t require the config file, e.g. status / start <job> / stop
if ! [[ "${1:-}" == "status" || "${1:-}" == "start" && -n "${2:-}" || "${1:-}" == "stop" && -z "${2:-}" ]]; then
	_read_config_file
fi

# CLI option > config file
if (( NO_COLOR == 1 )); then
	COLOR=""
	COLOR_ERROR=""
fi

# shellcheck disable=SC2174
if ! mkdir -m 700 -p "$PID_DIR" 2>/dev/null; then
	echo "Error: PID directory '$PID_DIR' could not be created. Check permissions."
	echo
	exit 1
fi >&2

# Get command
case "${1:-}" in
	fix)    _fix_unclean_shutdown; exit ;;

	status) _show_process_status_table; exit ;;

	start)
		# Start daemon or job?
		if [ -z "${2:-}" ]; then
			# Start daemon if not running
			_exit_if_unclean_shutdown
		else
			# Start job if not running
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
			sleep 1
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
		echo "${VARS//declare/& -g}" > "$CONFIG_FILE".sh
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
		_exit_if_unclean_shutdown
		_exit_if_app_is_already_running
		set -- "--daemon" # Pretend to be already in daemon mode --> Don't start as daemon
		FOREGROUND=1      # Run in foreground, not as daemon
		;;

	*)
		echo "Error: Unknown command '$1'" >&2
		echo >&2
		exit 1
		;;
esac

# Bash version >= 5.1 ?
if ! (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then
	echo "Error: Bash 5.1 or later is required to run $APP"
	echo
	exit 1
fi >&2

# Begin server only part

# Run as daemon
if [ "$1" != "--daemon" ]; then
	_exit_if_app_is_already_running

	if ! { : >> "$LOG_FILE"; } 2>/dev/null; then
		echo "Error: $APP log file '$LOG_FILE' is not writeable."
		echo
		exit 1
	fi >&2

	_status "Starting $APP"

	cd /
	setsid bash "$APP_PATH" --config "$CONFIG_FILE" "--daemon" &
	echo $! >"$PID_FILE"

	_status "$APP $VER started ($!)"
	exit 0
fi

_clean_up() {
	__total_runtime() {
		local total=$SECONDS
		local days=$((   total / 86400         ))
		local hours=$(( (total % 86400) / 3600 ))
		local mins=$((  (total %  3600) /   60 ))
		local secs=$((   total %    60         ))
    		local output

		(( days > 0 )) && output="${days}d "
		output+="${hours}h ${mins}m ${secs}s"

    		echo "$output"
	}

	local i grace_period_start=$SECONDS last_wait_info=$SECONDS

	__wait_info() {
		local wait_jobs seconds_until_sigkill
		for i in "${!PIDS[@]}"; do
			wait_jobs+="${JOB_NAME[i]}, "
		done
		if [ -n "${wait_jobs:-}" ]; then
			seconds_until_sigkill=$(( SIGTERM_GRACE_PERIOD + grace_period_start - SECONDS ))
			(( seconds_until_sigkill > 0 )) && _status "Waiting ${seconds_until_sigkill} seconds for job termination: ${wait_jobs:0:-2}"
		fi
		return 0
	}
	__wait_info

	# Wait until all jobs are stopped
	while :; do
		for i in "${!PIDS[@]}"; do
			if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stopped" ]; then
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
			fi
		done

		# Are all jobs stopped?
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

	_delete_runtime_files

	_status "$APP ($$) terminated after $(__total_runtime)"
	exit 0
}
trap "      _clean_up" EXIT
trap "echo; _stop_app" SIGINT
trap "      _stop_app" SIGTERM

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
fi

_status "$APP $VER started ($$)"

_start_job() {
	local i=$1

	# Prevent restart loop if log file is not writeable
	if ! { : >> "${JOB_LOGFILE[i]}"; } 2>/dev/null; then
		_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
		_status "Error: Job '${JOB_NAME[i]}' could not be started. Log file '${JOB_LOGFILE[i]}' is not writeable."
		# 0 is mandatory. Any 'return' executed within a trap handler, returns the exit status of the last command
		# executed before the handler was invoked. In this case, 130 (128 + 10 [SIGUSR1]).
		return 0
	fi

	# setsid --> run each job in his own process group
	setsid bash -c "${JOB_COMMAND[i]}" &>>"${JOB_LOGFILE[i]}" &
	PIDS[i]=$!
	echo "${PIDS[i]}" >"$PID_DIR/${JOB_NAME[i]}.pid"

	_set_job_state "started" "$PID_DIR/${JOB_NAME[i]}"

	_status "Job started: ${JOB_NAME[i]} (${PIDS[i]})"
}

# Start jobs
for i in "${!JOB_NAME[@]}"; do
	if [ "${JOB_AUTOSTART[i]}" == "on" ]; then
		# Autostart enabled
		JOB_RESTART_COUNT[i]=0
		_start_job "$i"
	else
		# Autostart disabled
		_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
	fi
done

# Start jobs, when USR1 signal is received
_start_job_trap() {
	local i name
	# For jobs that have to be started, a JOB.pid.start file exists
	for name in "$PID_DIR"/*.pid.start; do
		name=${name##*/}
		name=${name:0:-10}

		# Search job
		for i in "${!JOB_NAME[@]}"; do
			if [ "${JOB_NAME[i]}" == "$name" ]; then
				# (Re)set restart count
				JOB_RESTART_COUNT[i]=0

				_start_job "$i"
				# break 2
			fi
		done
	done
}
# Listen for USR1 signal
trap _start_job_trap SIGUSR1

# Kill a process group
_kill_process_group() {
	local i=$1
	local grace_period_start=$SECONDS

	if kill -0 -"${PIDS[i]}" 2>/dev/null; then
		kill -SIGTERM -"${PIDS[i]}" 2>/dev/null || true
		_status "Waiting for child processes to terminate: ${JOB_NAME[i]} (${PIDS[i]})"

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

_exit_app_if_job_is_required() {
	local i=$1
	# Stop the supervisor if a required job has stopped
	if [ "${JOB_REQUIRED[i]}" == "yes" ]; then
		# Keep running, if the job was stopped on purpose (via the 'stop' command)
		if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
			_status "Required job stopped: ${JOB_NAME[i]}" ERROR
			_stop_app
		fi
	fi
}

_clean_up_job() {
	local i=$1

	# Kill possible orphaned processes
	_kill_process_group "$i"

	unset "PIDS[$i]"
	_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
}

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
				_status "No more jobs are running. Stopping $APP"
				exit 0
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
			if [ -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
				_status "Job termination is expected: ${JOB_NAME[i]} (${PIDS[i]})"
			fi

			if [[ $JOB_EXIT_CODE -gt 0 && ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]]; then
				_status "Job failed with exit code $JOB_EXIT_CODE: ${JOB_NAME[i]} (${PIDS[i]})" ERROR
			else
				_status "Job terminated: ${JOB_NAME[i]} (${PIDS[i]})"
			fi

			_clean_up_job "$i"

			# Restart job if necessary
			if [[ "${JOB_RESTART[i]}" == "error" && $JOB_EXIT_CODE -gt 0 || "${JOB_RESTART[i]}" == "on" ]]; then
				if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
					# Job termination is unexpected
					# Restart job if limit is not already reached
					if (( JOB_RESTART_LIMIT[i] == 0 || JOB_RESTART_COUNT[i] < JOB_RESTART_LIMIT[i] )); then
						(( ++JOB_RESTART_COUNT[i] ))
						if (( JOB_RESTART_LIMIT[i] == 0 )); then
							_status "Restarting (${JOB_RESTART_COUNT[i]}): ${JOB_NAME[i]}"
						else
							_status "Restarting (${JOB_RESTART_COUNT[i]}/${JOB_RESTART_LIMIT[i]}): ${JOB_NAME[i]}"
						fi
						_start_job "$i"
					else
						_status "Restart limit (${JOB_RESTART_LIMIT[i]}) reached: ${JOB_NAME[i]}"
						_exit_app_if_job_is_required "$i"
					fi
				fi
			else
				# No restart
				_exit_app_if_job_is_required "$i"
			fi
		fi
	done
done
