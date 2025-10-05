#!/bin/bash

# shellcheck disable=2178,2128 # shellcheck bug

# Dependencies: yq, bash >= 5.1
# BASH_VERSION 5.1 or higher is required to support 'wait -p'

set -ueo pipefail        # Exit on errors
shopt -s inherit_errexit # Exit on errors - also in sub-shells
shopt -s nullglob        # Return nothing if '*' does not expand

# Global variables
APP="supervisor.sh"
APP_PATH=$(readlink -f "$0")
VER=0.7

PID_DIR="/run/$APP"
PID_FILE="$PID_DIR/$APP.pid"

FOREGROUND=0
CONFIG_FILE_BASH=0
PIDS=()
COLOR=""

# Begin shared part (client & server)

# Show usage
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
		  -c, --config    Specify config file, e.g. '$APP -c /path/config.yaml'.
		  -h, --help      Show this help.

		Commands:
		  start           Start $APP as daemon.
		  start <job>     Start job.
		  stop            Stop $APP.
		  stop  <job>     Stop job.
		  restart         Restart daemon.
		  restart <job>   Restart job.
		  status          Show process status.
		  fix             Fix unclean shutdown.
		  log             Show continuously the $APP log.
		  logs            Show continuously the $APP log + job logs.
		  convert         Convert the YAML config file to Bash. This allows the usage
		                  without the 'yq' dependency.

		If no command is provided, $APP will start in foreground.

	USAGE
	exit 0
}
if [[ "${1:-}" =~ ^(-h|--help)$ ]]; then
 	_usage
fi

# Check if config file exist and is readable
_check_config_file() {
	if [ ! -f "$CONFIG_FILE" ]; then
		echo "Error: Configuration file '$CONFIG_FILE' not found."
		echo
		exit 1
	fi
	if [ ! -r "$CONFIG_FILE" ]; then
		echo "Error: Configuration file '$CONFIG_FILE' is not accessible."
		echo
		exit 1
	fi
} >&2

# Parse config file and create global variables
_read_config_file() {
	# Is the config file a Bash script (converted from yaml)?
	if [ "$(head -c 7 "$CONFIG_FILE")" == "declare" ]; then
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

	__yq_info() {
		echo "There are at least two, that have the same name."
		echo "$APP depends on 'yq' from: https://github.com/mikefarah/yq"
		echo "The Debian repository, for example, offers 'yq' from: https://github.com/kislyuk/yq"
	}

	# Check if the correct yq version
	if [[ "$(yq --version)" != "yq (https://github.com/mikefarah/yq/)"* ]]; then
		echo "Error: Wrong 'yq' program detected."
		echo
		__yq_info
		echo
		exit 1
	fi >&2

	# mapfile -t --> Remove a trailing DELIM from each line read (default newline)
	# yq -r      --> unwrap scalar, print the value with no quotes, colors or comments

	# Global config
	LOG_FILE=$(            yq -r '.supervisor.logfile // "/dev/stdout"'    "$CONFIG_FILE")
	SIGTERM_GRACE_PERIOD=$(yq -r '.supervisor.sigterm_grace_period // "2"' "$CONFIG_FILE")
	KEEP_RUNNING=$(        yq -r '.supervisor.keep_running // "off"'       "$CONFIG_FILE")
	COLOR=$(               yq -r '.supervisor.color // ""'                 "$CONFIG_FILE")

	# Job config
	mapfile -t JOB_NAME      < <(yq -r '.jobs[].name      // ""'            "$CONFIG_FILE") # Default value is an empty string, instead of 'null'
	mapfile -t JOB_COMMAND   < <(yq -r '.jobs[].command   // ""'            "$CONFIG_FILE") # Default value is an empty string, instead of 'null'
	mapfile -t JOB_RESTART   < <(yq -r '.jobs[].restart   // "error"'       "$CONFIG_FILE") # Default value is         'error', instead of 'null'
	mapfile -t JOB_REQUIRED  < <(yq -r '.jobs[].required  // "no"'          "$CONFIG_FILE") # Default value is            'no', instead of 'null'
	mapfile -t JOB_LOGFILE   < <(yq -r '.jobs[].logfile   // "/dev/stdout"' "$CONFIG_FILE") # Default value is   '/dev/stdout', instead of 'null'
	mapfile -t JOB_AUTOSTART < <(yq -r '.jobs[].autostart // "on"'          "$CONFIG_FILE") # Default value is            'on', instead of 'null'

	# Some simple tests, to see if the parsing of the YAML file was successful
	__show_error_and_exit() {
		if [ "$1" == "ARRAY" ]; then
			echo "Internal error: Wrong element count for array $2"
		else
			echo "Internal error: Variable '$2' is empty"
		fi
		echo
		echo "The cause for that is most likely the usage of the wrong 'yq' program."
		__yq_info
		echo
		exit 1
	} >&2

	[ -z "$LOG_FILE" ]                   && __show_error_and_exit "VAR" "LOG_FILE"
	[ -z "$SIGTERM_GRACE_PERIOD" ]       && __show_error_and_exit "VAR" "SIGTERM_GRACE_PERIOD"
	[ -z "$KEEP_RUNNING" ]               && __show_error_and_exit "VAR" "KEEP_RUNNING"

	local count=${#JOB_NAME[@]}
	(( count !=  ${#JOB_RESTART[@]} ))   && __show_error_and_exit "ARRAY" "JOB_RESTART"
	(( count !=  ${#JOB_REQUIRED[@]} ))  && __show_error_and_exit "ARRAY" "JOB_REQUIRED"
	(( count !=  ${#JOB_LOGFILE[@]} ))   && __show_error_and_exit "ARRAY" "JOB_LOGFILE"
	(( count !=  ${#JOB_AUTOSTART[@]} )) && __show_error_and_exit "ARRAY" "JOB_AUTOSTART"

	return 0
}

# Set default configuration path
if hash yq 2>/dev/null; then
	CONFIG_FILE="/etc/supervisor.yaml"
else
	CONFIG_FILE="/etc/supervisor.yaml.sh"
fi

# Use config file from argument if given
if [[ $# -gt 1 && $1 =~ ^(-c|--config)$ ]]; then
	CONFIG_FILE=$2
	shift 2
fi

_check_config_file
_read_config_file

cd /
mkdir -p "$PID_DIR"

_status() {
	[ -n "$COLOR" ] && (( FOREGROUND == 1 )) && printf -- '%s' "$COLOR" # set color

	printf -- '%(%F %T)T ' -1 # Print current date/time
	printf -- '%s\n' "$1"     # Print status message

	[ -n "$COLOR" ] && (( FOREGROUND == 1 )) && printf -- '%s' $'\e[0m' # reset color
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
		echo "Error: $APP is not running"
		echo
		exit 1
	fi >&2
}

_exit_if_app_is_already_running() {
	if _is_app_running; then
		echo "Error: $APP is already running"
		echo
		exit 1
	fi >&2
}

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
		echo "Error: $APP was not stopped gracefully. See the process status below."
		echo "Run '$APP fix' to stop any running jobs and clean up."
		echo
		_show_process_status
		exit # _show_process_status should already exit, because $app is not running
	fi
}

_delete_runtime_files() {
	rm -f "$PID_FILE"
	rm -f "$PID_DIR/"*
	rm -f "$PID_DIR/.sigterm"
}

_fix_unclean_shutdown() {
	local i j name pid signal check_success=0

	if _check_clean_shutdown; then
		echo "Everything is fine, no action required."
		echo
		exit
	fi

	# Send SIGTERM to running jobs, later SIGKILL if necessary
	for signal in "SIGTERM" "SIGKILL"; do
		for i in "$PID_DIR"/*.pid; do
			if [ ! -f "$i.stopped" ]; then
				name=$(basename "${i:0:-4}")
				pid=$(<"$i")
				if kill -0 "$pid" 2>/dev/null; then
					_status "Sending $signal to $name ($pid)"
					kill -"$signal" -"$pid" 2>/dev/null || true
					if [ "$signal" == "SIGTERM" ]; then
						check_success=1
					else
						check_success=0
					fi
				fi
			fi
		done
		if (( check_success == 1 )); then
			check_success=0
			_status "Waiting for a grace period of ${SIGTERM_GRACE_PERIOD}s before sending SIGKILL to still running jobs."
			sleep "$SIGTERM_GRACE_PERIOD"
		else
			break
		fi
	done
	sleep 1
	_delete_runtime_files
	echo
}

_stop_app() {
	if [ -f "$PID_DIR/.sigterm" ]; then
		# Prevent SIGTERM trap loop
		exit
	fi

	_exit_if_app_is_not_running

	local app_pid
	app_pid=$(<"$PID_FILE")
	_status "Stopping $APP ($app_pid)"

	# Send SIGTERM to all process groups (supervisor + jobs)
	local i job_pids
	for i in "$PID_DIR"/*.pid; do
		if [ ! -f "$i.stopped" ]; then
			job_pids+=(-"$(<"$i")")
			# Change job state
			: >"$i.stop"
		fi
	done
	: >"$PID_DIR/.sigterm" # Prevent SIGTERM trap loop

	# Run in own process group to avoid a race condition, e.g.:
	# kill -SIGTERM job1 job2 job3 supervisor
	# If job1 runs 'supervisor.sh stop', job1 may be killed before sending SIGTERM to all PIDs, especially to the last one (supervisor)
	setsid bash -c "kill -SIGTERM  ${job_pids[*]} 2>/dev/null" &

	# Wait until stopped
	while kill -0 "$app_pid" 2>/dev/null; do
		sleep 0.2
	done
	_status "$APP stopped ($app_pid)"

	[ -n "${1:-}" ] && return 0 # Return and start supervisor again if $1 is not empty
	exit 0
}

_show_process_status() {
	local i name=("NAME") status=("STATUS") pid=("PID")

	# Get status of processes
	for i in "$PID_DIR"/*.pid; do
		name+=("$(basename "${i:0:-4}")")
		if kill -0 "$(<"$i")" 2>/dev/null; then
			status+=(running)
			pid+=("$(<"$i")")
		else
			status+=(stopped)
			pid+=("")
		fi
	done

	# Get longest value from given arguments + 2
	__get_max_value_length_plus_2() {
		local max_len=0
		local i
		for i in "$@"; do
			if (( ${#i} > max_len )); then
				max_len=${#i}
			fi
		done
		echo "$(( max_len + 2 ))"
	}

	# Calculate padding
	local padding_name padding_status
	padding_name=$(__get_max_value_length_plus_2 "${name[@]}")
	padding_status=$(__get_max_value_length_plus_2 "${status[@]}")

	# Print table
	for i in "${!name[@]}"; do
		printf -- '%-*s'  "$padding_name"   "${name[i]}"
		printf -- '%-*s'  "$padding_status" "${status[i]}"
		printf -- '%-s\n'                   "${pid[i]}"
	done
	echo

	_exit_if_app_is_not_running
}

_start_job_cli() {
	local name=$1 job_pid

	if [ -f "$PID_DIR/$name.pid" ]; then
		job_pid=$(<"$PID_DIR/$name.pid")
		if [ -f "$PID_DIR/$name.pid.stopped" ]; then
			# Request job start once
			if [ -f "$PID_DIR/$name.pid.start" ]; then
				echo -e "Error: Job start already in progress\n" >&2
				return 1
			fi

			# Request job start
			: >"$PID_DIR/$name.pid.start"

			_status "Starting $name"

			# Send USR1 signal to server to trigger the job start
			# start_job_trap() will then start the job
			kill -SIGUSR1 "$(<"$PID_FILE")"

			# Wait until job has started
			while [ -f "$PID_DIR/$name.pid.start" ]; do
				sleep 0.2
			done

			_status "$name started ($(<"$PID_DIR/$name.pid"))"
			return 0
		else
			echo -e "Error: '$name' is already running\n" >&2
			return 1
		fi
	else
		echo -e "Error: Job '$name' not found\n" >&2
		return 1
	fi
}

_stop_job_cli() {
	local name=$1 job_pid
	local grace_period_start=$SECONDS

	if [ -f "$PID_DIR/$name.pid" ]; then
		job_pid=$(<"$PID_DIR/$name.pid")
		if kill -0 -"$job_pid" 2>/dev/null; then
			# Let supervisor know, that the job is stopped on purpose
			: >"$PID_DIR/$name.pid.stop"

			# Send SIGTERM to job process group
			_status "Stopping $name ($job_pid)"
			kill -SIGTERM -"$job_pid" 2>/dev/null || true

			# Wait until stopped
			while kill -0 -"$job_pid" 2>/dev/null; do
				if (( SECONDS - grace_period_start >= SIGTERM_GRACE_PERIOD )); then
					_status "Process still running, sending SIGKILL: $name ($job_pid)"
					kill -SIGKILL -"$job_pid" 2>/dev/null || true
				fi
				sleep 0.2
			done

			# Wait until cleanup is done
			until [ -f "$PID_DIR/$name.pid.stopped" ]; do sleep 0.2; done

			_status "$name stopped ($job_pid)"
			return 0
		else
			echo -e "Error: $name is not running\n" >&2
			return 1
		fi
	else
		echo -e "Error: Job '$name' not found\n" >&2
		return 1
	fi
}

# Get command
case "${1:-}" in
	fix)    _fix_unclean_shutdown; exit ;;

	status) _show_process_status; exit ;;

	start)
		# Start daemon or job?
		if [ -z "${2:-}" ]; then
			# Start daemon if not running
			_exit_if_unclean_shutdown
		else
			# Start job if not running
			_exit_if_app_is_not_running
			_start_job_cli "$2"
			exit
		fi
		;;

	stop)
		# Stop app or job?
		if [ -z "${2:-}" ]; then
			# Stop daemon or interactive run
			_stop_app
		else
			# Stop job if running
			_stop_job_cli "$2"
			exit
		fi
		;;

	restart)
		_exit_if_app_is_not_running

		# Restart app or job?
		if [ -z "${2:-}" ]; then
			LAST_ARG=$(tr '\0' '\n' < "/proc/$(<"$PID_FILE")/cmdline" | tail -1)
			if [ "$LAST_ARG" != "--daemon" ]; then
				echo "Error: $APP is running in interactive mode, not as daemon."
				echo
				exit 1
			fi >&2

			_stop_app no-exit # Continue from here after the app was stopped to start again
		else
			if _stop_job_cli "$2"; then
				_start_job_cli "$2"
				exit
			else
				exit 1
			fi
		fi
		;;

	convert)
		if (( CONFIG_FILE_BASH == 1 )); then
			echo "Error: Config file '$CONFIG_FILE' is already converted to Bash"
			echo
			exit 1
		fi >&2
		echo -e "Converting '$CONFIG_FILE' to Bash --> '$CONFIG_FILE.sh'\n"
		# Display the attributes and value of each variable
		declare -p                               \
			LOG_FILE                         \
			SIGTERM_GRACE_PERIOD             \
			KEEP_RUNNING                     \
			COLOR                            \
			JOB_NAME                         \
			JOB_COMMAND                      \
			JOB_RESTART                      \
			JOB_LOGFILE                      \
			JOB_AUTOSTART                    \
			| sed 's/^declare /declare -g /' \
			| tee "$CONFIG_FILE".sh
		echo
		exit
		;;

	log)
		if [[ "$LOG_FILE" != "/dev/stdout" && -f "$LOG_FILE" ]]; then
			# Show the last 10 log lines, then output appended data as the file grows
			tail -n 10 -F "$LOG_FILE"
			exit
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
			tail -n 10 -F "${LOGS[@]}"
			exit
		else
			echo "Error: No log files configured in '$CONFIG_FILE'" >&2
			echo >&2
			exit 1
		fi
		;;

	--daemon) : ;; # Already in daemon mode --> Don't start again

	# No argument? Run in foreground
	"")
		_exit_if_unclean_shutdown
		_exit_if_app_is_already_running
		set -- "--daemon" # Pretend to be already in daemon mode --> Don't start again
		FOREGROUND=1      # Run interactively, not as daemon
		;;

	*)
		echo "Error: Unknown argument '$1'" >&2
		echo >&2
		exit 1
		;;
esac

# Begin server only part

for i in "${!JOB_NAME[@]}"; do
	if [[ -z "${JOB_NAME[i]}" || -z "${JOB_COMMAND[i]}" ]]; then
		_status "Error: Parsing job $i failed. Check $CONFIG_FILE"
		echo
		exit 1
	fi >&2
done

# Start daemon if not running
if [ "$1" != "--daemon" ]; then
	_exit_if_app_is_already_running
	_status "Starting $APP"
	setsid bash "$APP_PATH" --config "$CONFIG_FILE" "--daemon" &
	echo $! >"$PID_FILE"
	_status "$APP started ($!)"
	exit 0
fi

_clean_up() {
	local i grace_period_start=$SECONDS last_wait_info=$SECONDS

	__wait_info() {
		local wait_jobs seconds_until_sigkill
		for i in "${!PIDS[@]}"; do
			wait_jobs+="${JOB_NAME[i]}, "
		done
		if [ -n "${wait_jobs:-}" ]; then
			seconds_until_sigkill=$(( SIGTERM_GRACE_PERIOD + grace_period_start - SECONDS ))
			(( seconds_until_sigkill > 0 )) && _status "Waiting ${seconds_until_sigkill} seconds for process termination: ${wait_jobs:0:-2}"
		fi
		return 0
	}
	__wait_info

	# Wait until all processes are terminated
	while :; do
		for i in "${!PIDS[@]}"; do
			if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stopped" ]; then
				if ! kill -0 -"${PIDS[i]}" 2>/dev/null; then
					_status "Process terminated: ${JOB_NAME[i]} (${PIDS[i]})"
					: >"$PID_DIR/${JOB_NAME[i]}.pid.stopped"
					unset "PIDS[$i]"
				else
					if (( SECONDS - grace_period_start >= SIGTERM_GRACE_PERIOD )); then
						_status "Process still running, sending SIGKILL: ${JOB_NAME[i]} (${PIDS[i]})"
						kill -9 -"${PIDS[i]}" 2>/dev/null || true
					fi
				fi
			fi
		done

		# Are all processes terminated?
		if (( ${#PIDS[@]} == 0 )); then
			break
		fi

		# Show remaining running processes every 5 seconds
		if (( SECONDS - last_wait_info > 4 )); then
			last_wait_info=$SECONDS
			__wait_info
		fi
		sleep 0.2
	done

	_delete_runtime_files

	_status "$APP stopped ($$)"
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

		# Redirect STDOUT & STDERR to log file
		if [ "$LOG_FILE" == "/dev/stdout" ]; then
			exec &>> /dev/null
		else
			exec &>> "$LOG_FILE"
		fi
else
	echo "$$" >"$PID_FILE"
fi

_status "$APP started ($$)"

_set_job_state() {
	local state=$1 job_file=$2
	case "$state" in
		stopped)
			: >"$job_file.pid"
			rm -f "$job_file.pid."{start,stop}
			: >"$job_file.pid.stopped"
			;;

		started)
			rm -f "$job_file.pid."{start,stop,stopped}
			;;
	esac
	return 0
}

_start_job() {
	local i=$1

	# Prevent restart loop if log file is not writeable
	touch "${JOB_LOGFILE[i]}" 2>/dev/null || true # 'test -w' expects the file to exist. Create it first. Fails if log file is /dev/stdout
	if [ ! -w "${JOB_LOGFILE[i]}" ]; then
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

	_status "Process started: ${JOB_NAME[i]} (${PIDS[i]})"
}

# Start jobs
for i in "${!JOB_NAME[@]}"; do
	if [ "${JOB_AUTOSTART[i]}" == "on" ]; then
		# Autostart enabled
		_start_job "$i"
	else
		# Autostart disabled
		_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
	fi
done

# Start jobs, when USR1 signal is received
_start_job_trap() {
	local i j
	# For jobs that have to be started, a JOB.pid.start file exists
	for i in "$PID_DIR"/*.pid.start; do
		# Search job
		for j in "${!JOB_NAME[@]}"; do
			if [ "${JOB_NAME[j]}" == "$(basename "${i:0:-10}")" ]; then
				_start_job "$j"
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
		kill -SIGTERM -"${PIDS[i]}" 2>/dev/null
		_status "Waiting for ${JOB_NAME[i]} child processes to terminate."

		while kill -0 -"${PIDS[i]}" 2>/dev/null; do
			if (( SECONDS - grace_period_start >= SIGTERM_GRACE_PERIOD )); then
				# Kill possible orphaned zombie processes
				if kill -SIGKILL -"${PIDS[i]}" 2>/dev/null; then
					_status "${JOB_NAME[i]} child processes are still running, sending SIGKILL (${PIDS[i]})"
				fi
			fi
			sleep 0.2
		done

		_status "${JOB_NAME[i]} child processes terminated."
	fi
}

while :; do
	if wait -n -p JOB_PID; then
		JOB_STATUS=0
	else
		JOB_STATUS=$?
	fi

	if [ -z "${JOB_PID:-}" ]; then
		if (( ${#PIDS[@]} == 0 )); then
			if [ "$KEEP_RUNNING" == "off" ]; then
				_status "No more processes are running. Stopping $APP"
				exit 0
			else
				sleep 1
				continue
			fi
		else
			sleep 0.2 # safety net to slow down a loop in case of a bug
			continue
		fi
	fi

	for i in "${!PIDS[@]}"; do
		if [ "${PIDS[i]}" == "$JOB_PID" ]; then

			if [ -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
				_status "Process termination is expected: ${JOB_NAME[i]} (${PIDS[i]})"
			fi

			if [[ "${JOB_RESTART[i]}" == "error" && $JOB_STATUS -gt 0 || "${JOB_RESTART[i]}" == "on" ]]; then
				if [[ "${JOB_RESTART[i]}" == "error" && $JOB_STATUS -gt 0 && ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]]; then
					_status "Process failed [$JOB_STATUS]: ${JOB_NAME[i]} (${PIDS[i]})"
				else
					_status "Process terminated: ${JOB_NAME[i]} (${PIDS[i]})"
				fi

				# Kill possible orphaned zombie processes
				_kill_process_group "$i"

				# Clean up job
				unset "PIDS[$i]"

				# Restart job, if job was not stopped on purpose (via the 'stop' command)
				if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
					_status "Restarting: ${JOB_NAME[i]}"
					_start_job "$i"
				else
					_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
				fi
			else
				_status "Process terminated: ${JOB_NAME[i]} (${PIDS[i]})"

				# Kill possible orphaned zombie processes
				_kill_process_group "$i"

				# Clean up job
				unset "PIDS[$i]"

				# Stop the app if a required job has stopped
				if [ "${JOB_REQUIRED[i]}" == "yes" ]; then
					# Keep running, if the job was stopped on purpose (via the 'stop' command)
					if [ ! -f "$PID_DIR/${JOB_NAME[i]}.pid.stop" ]; then
						_status "Required job '${JOB_NAME[i]}' stopped. Shutting down.."
						_stop_app
					fi
				fi

				_set_job_state "stopped" "$PID_DIR/${JOB_NAME[i]}"
			fi
		fi
	done
done
