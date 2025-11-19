#!/bin/bash

# Ignore SIGTERM
trap 'echo "Child: SIGTERM received."' SIGTERM

# Keep alive
while :; do
	# Run sleep in own process group to avoid "Terminated" message (supervisor does only send SIGTERM to job process group)
	setsid sleep 1
done
