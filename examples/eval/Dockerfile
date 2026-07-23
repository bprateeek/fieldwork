FROM python:3.12-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash git jq curl ca-certificates \
  && rm -rf /var/lib/apt/lists/*

COPY examples/eval/fake-gitleaks /usr/local/bin/gitleaks
RUN chmod 0755 /usr/local/bin/gitleaks

WORKDIR /workspace
