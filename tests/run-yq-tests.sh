#!/usr/bin/env bash

# Perform some simple tests to ensure that the YAML file is parsed successfully.

set -ueo pipefail

APP="supervisor.sh"
CONFIG_FILE="../supervisor.yaml"

cd "$(dirname "$0")"

# Check if 'yq' binary is available
if ! hash yq 2>/dev/null; then
	echo "Error: 'yq' binary is not available. Get it from: https://github.com/mikefarah/yq"
	echo
	exit 1
fi >&2

# supervisor config
LOG_FILE=$(            yq -r '.supervisor.logfile // "/dev/stdout"'    "$CONFIG_FILE")
SIGTERM_GRACE_PERIOD=$(yq -r '.supervisor.sigterm_grace_period // "2"' "$CONFIG_FILE")
KEEP_RUNNING=$(        yq -r '.supervisor.keep_running // "off"'       "$CONFIG_FILE")
COLOR=$(               yq -r '.supervisor.color // "FOO-BAR"'          "$CONFIG_FILE")

# Job config
mapfile -t JOB_NAME      < <(yq -r '.jobs[].name      // ""'            "$CONFIG_FILE") # Default value is an empty string, instead of 'null'
mapfile -t JOB_COMMAND   < <(yq -r '.jobs[].command   // ""'            "$CONFIG_FILE") # Default value is an empty string, instead of 'null'
mapfile -t JOB_RESTART   < <(yq -r '.jobs[].restart   // "error"'       "$CONFIG_FILE") # Default value is         'error', instead of 'null'
mapfile -t JOB_REQUIRED  < <(yq -r '.jobs[].required  // "no"'          "$CONFIG_FILE") # Default value is            'no', instead of 'null'
mapfile -t JOB_LOGFILE   < <(yq -r '.jobs[].logfile   // "/dev/stdout"' "$CONFIG_FILE") # Default value is   '/dev/stdout', instead of 'null'
mapfile -t JOB_AUTOSTART < <(yq -r '.jobs[].autostart // "on"'          "$CONFIG_FILE") # Default value is            'on', instead of 'null'

__explain() {
	echo "There are at least two, that have the same name:"
	echo
	echo "$APP depends on 'yq' from: https://github.com/mikefarah/yq"
	echo "The Debian repository, for example, provides 'yq' from: https://github.com/kislyuk/yq"
	echo
}

# Check if 'yq' behaves the way it should
_show_error_and_exit() {
	if [ "$1" == "ARRAY" ]; then
		echo "Internal error: Wrong element count for array $2"
	else
		echo "Internal error: Variable '$2' is empty"
	fi
	echo
	echo "The cause for that is most likely the usage of the wrong 'yq' program."
	echo
	__explain
	exit 1
} >&2

[ -z "$LOG_FILE" ]                   && _show_error_and_exit "VAR" "LOG_FILE"
[ -z "$SIGTERM_GRACE_PERIOD" ]       && _show_error_and_exit "VAR" "SIGTERM_GRACE_PERIOD"
[ -z "$KEEP_RUNNING" ]               && _show_error_and_exit "VAR" "KEEP_RUNNING"
[ -z "$COLOR" ]                      && _show_error_and_exit "VAR" "COLOR"

JOB_COUNT_EXPECTED=$(grep -c name: $CONFIG_FILE)
JOB_COUNT=${#JOB_NAME[@]}
if (( JOB_COUNT == JOB_COUNT_EXPECTED )); then
	(( JOB_COUNT !=  ${#JOB_COMMAND[@]} ))   && _show_error_and_exit "ARRAY" "JOB_COMMAND"
	(( JOB_COUNT !=  ${#JOB_RESTART[@]} ))   && _show_error_and_exit "ARRAY" "JOB_RESTART"
	(( JOB_COUNT !=  ${#JOB_REQUIRED[@]} ))  && _show_error_and_exit "ARRAY" "JOB_REQUIRED"
	(( JOB_COUNT !=  ${#JOB_LOGFILE[@]} ))   && _show_error_and_exit "ARRAY" "JOB_LOGFILE"
	(( JOB_COUNT !=  ${#JOB_AUTOSTART[@]} )) && _show_error_and_exit "ARRAY" "JOB_AUTOSTART"
else
	echo "Error: Parsing 'supervisor.yaml' failed. $JOB_COUNT_EXPECTED jobs were expected, but the result was $JOB_COUNT." >&2
	echo >&2
	exit 1
fi

# Check if the correct 'yq' program is used
if [[ "$(yq --version)" != "yq (https://github.com/mikefarah/yq/)"* ]]; then
	echo "Error: Wrong 'yq' program detected."
	echo
	__explain
	echo "debug $(yq --version)"
	exit 1
fi >&2

echo "'yq' tests completed successfully."
echo
