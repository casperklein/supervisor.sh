ARG BASE_IMAGE=alpine
FROM $BASE_IMAGE

ARG BASE_IMAGE=alpine
ARG PACKAGES="curl dumb-init procps htop"
ARG YQ_VERSION=v4.49.1
ARG TARGETARCH

RUN <<EOF
	set -e

	# Install packages and add user for rootless container
	case "$BASE_IMAGE" in
		alpine*|bash*)
			apk upgrade --no-cache
			apk add --no-cache $PACKAGES

			if ! bash --version &>/dev/null; then
				apk add --no-cache bash
			fi

			adduser --disabled-password supervisor
			;;
		*)
			export DEBIAN_FRONTEND="noninteractive"
			apt-get update
			apt-get -y upgrade
			apt-get -y install $PACKAGES

			if ! bash --version &>/dev/null; then
				apt-get -y install bash
			fi

			rm -rf /var/lib/apt/lists/*

			useradd -m supervisor
			;;
	esac

	# Symlink configuration to the default location
	# This allows easy usage of supervisor.sh without the need of the --config option
	ln -s /supervisor/tests/supervisor.yaml /etc/
EOF

SHELL [ "/usr/bin/env", "bash", "-e", "-c" ]

# Install yq
RUN <<EOF
	curl -sSLf -o /usr/bin/yq "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$TARGETARCH"
	chmod +x /usr/bin/yq

	# Test binary
	yq --version
EOF

WORKDIR /supervisor

COPY . .

ENV PATH=/supervisor:$PATH

# Rootless container
USER supervisor
ENV PID_DIR=/home/supervisor/supervisor.sh

RUN <<EOF
	# Enable bash completion
	echo "source /supervisor/supervisor-completion.bash" >> ~/.bashrc
EOF

# When ENTRYPOINT below is disabled, supervisor runs as PID 1.
# ENTRYPOINT ["/usr/bin/dumb-init", "--"]

CMD [ "/supervisor/tests/run-tests.sh" ]
