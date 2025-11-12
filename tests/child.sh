#!/bin/bash

# Ignore SIGTERM
trap 'echo "Child: SIGTERM received."' SIGTERM

# Keep alive
while :; do
	sleep 1
done
