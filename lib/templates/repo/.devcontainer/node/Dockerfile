FROM node:20-bookworm-slim

# Hardening invariants enforced by /etc/devcontainer/healthcheck.sh. See SECURITY.md.

RUN groupadd -g 1000 vscode \
 && useradd -m -u 1000 -g 1000 -s /bin/bash vscode \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq \
 && rm -rf /var/lib/apt/lists/*

# Install healthcheck script. Real path is /etc/devcontainer/healthcheck.sh.
COPY healthcheck.sh /etc/devcontainer/healthcheck.sh
RUN chmod 755 /etc/devcontainer/healthcheck.sh

USER vscode
WORKDIR /workspace

# Run healthcheck on every container start; if any invariant fails, the shell exits.
ENTRYPOINT ["/bin/bash", "-c", "/etc/devcontainer/healthcheck.sh && exec \"$@\"", "--"]
CMD ["sleep", "infinity"]
