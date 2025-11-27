#!/bin/bash

set -e

cd "$(dirname "$(readlink -f "$0")")"

# Run simple YQ tests
./yq-test.sh

PATH="$PWD:$PATH" exec ../supervisor.sh -c supervisor.yaml "$@"
