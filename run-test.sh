#!/bin/bash

tests/yq-test.sh

PATH="$(readlink -f tests):$PATH" exec ./supervisor.sh -c tests/supervisor.yaml "$@"
