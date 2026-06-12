FROM rust:1.82-bookworm

RUN groupadd -g 1000 vscode \
 && useradd -m -u 1000 -g 1000 -s /bin/bash vscode \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq pkg-config libssl-dev \
 && rm -rf /var/lib/apt/lists/*

COPY healthcheck.sh /etc/devcontainer/healthcheck.sh
RUN chmod 755 /etc/devcontainer/healthcheck.sh

USER vscode
WORKDIR /workspace

# Pre-install rustfmt + clippy components so first run isn't slow.
RUN rustup component add rustfmt clippy

ENTRYPOINT ["/bin/bash", "-c", "/etc/devcontainer/healthcheck.sh && exec \"$@\"", "--"]
CMD ["sleep", "infinity"]
