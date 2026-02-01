#!/usr/bin/env bash

# Ignore TERM signal
_sigterm() {
	# Print current date/time + message
	printf -- "%(%F  %T)T  %s\n" -1 "Child process of parent.sh:  TERM signal received. Ignoring.."
}
trap _sigterm SIGTERM

# Keep alive
while :; do
	# Run sleep in own process group to avoid "Terminated" message (supervisor does only send SIGTERM to job process group)
	setsid sleep 1
done
