FROM python:3.12.13-slim-bookworm@sha256:8a7e7cc04fd3e2bd787f7f24e22d5d119aa590d429b50c95dfe12b3abe52f48b

ARG TARGETARCH
ARG GIT_DEBIAN_VERSION=2.39.5-0+deb12u3
ARG GIT_MAN_DEBIAN_VERSION=1:2.39.5-0+deb12u3
ARG GIT_SHA_AMD64=637a85ddd6247fab13bdd0592f2f39aff04ce4dbf0655d3ab553ac359a38ce6f
ARG GIT_SHA_ARM64=435176549a9f5c8bbadaa126b64a036b38ea34ad9f3eb128dc40b8407a5b5620
ARG GITLEAKS_VERSION=8.30.1
ARG GITLEAKS_SHA_AMD64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
ARG GITLEAKS_SHA_ARM64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl openssl util-linux "git-man=${GIT_MAN_DEBIAN_VERSION}" \
    && case "$TARGETARCH" in \
         amd64) deb_arch=amd64; git_expected="$GIT_SHA_AMD64"; asset=x64; gitleaks_expected="$GITLEAKS_SHA_AMD64" ;; \
         arm64) deb_arch=arm64; git_expected="$GIT_SHA_ARM64"; asset=arm64; gitleaks_expected="$GITLEAKS_SHA_ARM64" ;; \
         *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
       esac \
    && curl --proto '=https' --tlsv1.2 -fsSLo /tmp/git.deb \
         "https://deb.debian.org/debian/pool/main/g/git/git_${GIT_DEBIAN_VERSION}_${deb_arch}.deb" \
    && printf '%s  %s\n' "$git_expected" /tmp/git.deb | sha256sum -c - \
    && apt-get install -y --no-install-recommends /tmp/git.deb \
    && test "$(git --version)" = 'git version 2.39.5' \
    && curl --proto '=https' --tlsv1.2 -fsSLo /tmp/gitleaks.tar.gz \
         "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_${asset}.tar.gz" \
    && printf '%s  %s\n' "$gitleaks_expected" /tmp/gitleaks.tar.gz | sha256sum -c - \
    && tar -xzf /tmp/gitleaks.tar.gz -C /usr/local/bin gitleaks \
    && rm /tmp/git.deb /tmp/gitleaks.tar.gz \
    && rm -rf /var/lib/apt/lists/* \
    && if [ ! -x /usr/bin/python3 ]; then ln -s /usr/local/bin/python3 /usr/bin/python3; fi \
    && groupadd --gid 10001 fieldwork-broker \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fieldwork-broker \
    && groupadd --gid 10002 fieldwork-bot \
    && useradd --uid 10002 --gid 10002 --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin fieldwork-bot \
    && usermod -a -G fieldwork-bot fieldwork-broker

COPY lib/broker/server.py lib/broker/policy_writer.py lib/broker/originnorm.py /usr/local/lib/fieldwork-pr-broker/
COPY lib/broker/git-askpass lib/broker/rotate-pat /usr/local/lib/fieldwork-pr-broker/
COPY lib/broker/maintenance-submit /usr/local/bin/fieldwork-pr-maintenance-submit
COPY schema/pr-request.schema.json /usr/local/lib/fieldwork-pr-broker/pr-request.schema.json
COPY lib/scripts/fieldwork-bot /usr/local/bin/fieldwork-bot
COPY lib/local/entrypoint.sh /usr/local/bin/fieldwork-local-entrypoint
COPY lib/local/rotate-token /usr/local/bin/fieldwork-local-rotate-token
COPY lib/local/local-admin /usr/local/bin/fieldwork-local-admin

RUN chmod 0755 /usr/local/bin/fieldwork-bot /usr/local/bin/fieldwork-local-entrypoint \
      /usr/local/bin/fieldwork-local-rotate-token /usr/local/bin/fieldwork-local-admin /usr/local/lib/fieldwork-pr-broker/git-askpass \
      /usr/local/bin/fieldwork-pr-maintenance-submit \
    && chmod 0644 /usr/local/lib/fieldwork-pr-broker/server.py \
      /usr/local/lib/fieldwork-pr-broker/policy_writer.py /usr/local/lib/fieldwork-pr-broker/originnorm.py \
      /usr/local/lib/fieldwork-pr-broker/pr-request.schema.json

ENTRYPOINT ["/usr/local/bin/fieldwork-local-entrypoint"]
CMD ["broker"]
