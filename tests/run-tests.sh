#!/usr/bin/env bash

set -e

cd "$(dirname "$(readlink -f "$0")")"

# Run simple YQ tests
./run-yq-tests.sh

# Show info about the base image, bash version, current user and the used PID directory.
./run-info.sh

# Run supervisor
PATH="$PWD/jobs:$PATH" exec ../supervisor.sh -c supervisor.yaml "$@"
