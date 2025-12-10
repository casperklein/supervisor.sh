#!/usr/bin/env bash

(
	source /etc/os-release
	echo "Base Image:    $PRETTY_NAME"
)

echo "Bash Version:  $BASH_VERSION"
echo "User:          $(id -un) ($(id -u))"
echo "PID Directory: ${PID_DIR:-/run/supervisor.sh}"
echo
