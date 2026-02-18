#!/usr/bin/env bash

(
	source /etc/os-release
	echo "Base Image:    $PRETTY_NAME"
)

echo "Bash Version:  $BASH_VERSION"
echo "User:          $(id -un) ($(id -u))"
echo "Configuration: $(readlink -f "$CONFIG")"
echo "PID Directory: ${PID_DIR:-/run/supervisor.sh}"

# Check which Bash builtins are available
for i in rm sleep; do
	if enable "$i" &>/dev/null; then
		BUILTINS+="$i, "
	fi
done
echo "Bash Builtins: ${BUILTINS:0:-2}"

echo
