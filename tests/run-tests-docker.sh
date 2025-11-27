#!/bin/bash

set -ueo pipefail
shopt -s inherit_errexit

APP="supervisor.sh"

cd "$(dirname "$(readlink -f "$0")")"/../

docker build -t "$APP" -f tests/Dockerfile .

docker run --rm -it --name "$APP" "$APP"
