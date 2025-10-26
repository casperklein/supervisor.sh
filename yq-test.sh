#!/bin/bash

# Perform some simple tests to ensure that the YAML file is parsed successfully.

set -ueo pipefail

APP="supervisor.sh"
CONFIG_FILE="supervisor.yaml"

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

_show_error_and_exit() {
	if [ "$1" == "ARRAY" ]; then
		echo "Internal error: Wrong element count for array $2"
	else
		echo "Internal error: Variable '$2' is empty"
	fi
	echo
	echo "The cause for that is most likely the usage of the wrong 'yq' program."
	echo
	echo "There are at least two, that have the same name:"
	echo
	echo "$APP depends on 'yq' from: https://github.com/mikefarah/yq"
	echo "The Debian repository, for example, provides 'yq' from: https://github.com/kislyuk/yq"
	echo
	exit 1
} >&2

[ -z "$LOG_FILE" ]                   && _show_error_and_exit "VAR" "LOG_FILE"
[ -z "$SIGTERM_GRACE_PERIOD" ]       && _show_error_and_exit "VAR" "SIGTERM_GRACE_PERIOD"
[ -z "$KEEP_RUNNING" ]               && _show_error_and_exit "VAR" "KEEP_RUNNING"
[ -z "$COLOR" ]                      && _show_error_and_exit "VAR" "COLOR"

count=${#JOB_NAME[@]}
(( count !=  ${#JOB_COMMAND[@]} ))   && _show_error_and_exit "ARRAY" "JOB_COMMAND"
(( count !=  ${#JOB_RESTART[@]} ))   && _show_error_and_exit "ARRAY" "JOB_RESTART"
(( count !=  ${#JOB_REQUIRED[@]} ))  && _show_error_and_exit "ARRAY" "JOB_REQUIRED"
(( count !=  ${#JOB_LOGFILE[@]} ))   && _show_error_and_exit "ARRAY" "JOB_LOGFILE"
(( count !=  ${#JOB_AUTOSTART[@]} )) && _show_error_and_exit "ARRAY" "JOB_AUTOSTART"

echo "Parsing was successful. Everything seems fine :)"
echo
