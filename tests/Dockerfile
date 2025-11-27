FROM debian:13-slim

ARG YQ_VERSION=v4.49.1
ARG TARGETARCH

SHELL ["/bin/bash", "-e", "-c"]

RUN <<EOF
	apt update
	apt install -y curl dumb-init procps
	rm -rf /var/lib/apt/lists/*
EOF

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

# ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["/supervisor/tests/run-tests.sh"]
