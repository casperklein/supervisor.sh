#!/usr/bin/env bash

# Usage: run-tests-docker.sh [base-image]
#
# Alpine and Debian based images are supported.
#
# Examples:
#   run-tests-docker.sh alpine
#   run-tests-docker.sh bash:4.4
#   run-tests-docker.sh debian:13-slim
#   run-tests-docker.sh ubuntu

set -ueo pipefail
shopt -s inherit_errexit

APP="supervisor.sh"

cd "$(dirname "$(readlink -f "$0")")"/../

# If no argument is given, default to 'alpine' as base image.
BASE_IMAGE=${1:-alpine}

# Build image
echo "Using base image: $BASE_IMAGE"
echo
docker build -t "$APP" -f tests/Dockerfile  --build-arg "BASE_IMAGE=$BASE_IMAGE" .
echo

# Run container
docker run --rm -it --name "$APP" "$APP"
