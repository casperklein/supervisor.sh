#!/usr/bin/env bash

set -e

export CONFIG_FILE="supervisor.yaml"

cd "$(dirname "$(readlink -f "$0")")"

# Run simple YQ tests
./run-yq-tests.sh

# Show info about the base image, Bash version, current user, configuration, directory for runtime data and used Bash builtins.
./run-info.sh

# Run supervisor
PATH="$PWD/jobs:$PATH" exec ../supervisor.sh -c "$CONFIG_FILE" "$@"
