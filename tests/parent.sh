#!/bin/bash

_sigterm() {
	echo "Parent: SIGTERM received. Terminating.."
	exit
}

trap _sigterm SIGTERM

# start bad child
child.sh &

# Keep alive
while :; do
	sleep 1
done
