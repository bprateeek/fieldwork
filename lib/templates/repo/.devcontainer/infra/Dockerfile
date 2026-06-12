FROM debian:bookworm-slim

# Infra/IaC stack: terraform, opentofu, ansible-lint, kubeval, etc.
# Specific tool versions installed per-repo as needed; this is the base.

RUN groupadd -g 1000 vscode \
 && useradd -m -u 1000 -g 1000 -s /bin/bash vscode \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq make python3 python3-pip unzip gnupg \
 && rm -rf /var/lib/apt/lists/*

COPY healthcheck.sh /etc/devcontainer/healthcheck.sh
RUN chmod 755 /etc/devcontainer/healthcheck.sh

USER vscode
WORKDIR /workspace

ENTRYPOINT ["/bin/bash", "-c", "/etc/devcontainer/healthcheck.sh && exec \"$@\"", "--"]
CMD ["sleep", "infinity"]
