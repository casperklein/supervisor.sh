#!/usr/bin/env bash

# Ignore TERM signal
trap '' SIGTERM

# Prefix each line from STDIN with the current date/time
while IFS= read -r line; do
	printf -- '%(%F  %T)T  %s\n' -1 "$line"
done

# Terminate when STDIN is closed
exit 0
