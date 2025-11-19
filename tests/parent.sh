#!/bin/bash

# Terminate gracefully
_sigterm() {
	echo "Parent: SIGTERM received. Terminating.."
	exit
}
trap _sigterm SIGTERM

# Start bad child
child.sh &

# Keep alive
while :; do
	# Run sleep in own process group to avoid "Terminated" message (supervisor does only send SIGTERM to job process group)
	setsid sleep 1
done
