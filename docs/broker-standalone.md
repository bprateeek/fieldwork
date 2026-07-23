# Standalone broker

Use the standalone installer to give another agent the protocol-v2 delivery
boundary without the rest of the Fieldwork VPS UI.

## Requirements

- systemd Linux with Python 3.10+, Git, OpenSSL, and gitleaks;
- an existing unprivileged agent user;
- a verified Fieldwork release tree;
- a least-privilege GitHub or GitLab token.

`gh` is not a runtime dependency.

## Install

```sh
sudo bash lib/broker/standalone-install.sh --agent-user alice
```

Optional flags select a different broker user or submit-socket group. The
installer creates:

- broker service and submit/approve sockets;
- non-enabled root-only maintenance socket;
- broker-owned policy, CA, pending, ledger, tombstone, and key stores;
- persistent 0600 pending-record MAC key;
- root-owned build/upload clients and policy/token maintenance tools.

The broker has `ProtectHome=yes` and no checkout access.

## Wire a slug

```sh
sudo /usr/local/sbin/fieldwork-policy-write \
  --policy-dir /var/lib/fieldwork-pr-broker/policy \
  --ca-dir /var/lib/fieldwork-pr-broker/ca \
  --slug app \
  --forge github \
  --project owner/app \
  --base-branch main \
  --approval require
```

The writer defaults to required approval, validates endpoint relationships,
copies custom CA material into a content-addressed store, refuses symlink
targets, and replaces policy atomically. For self-managed GitLab supply the
GitLab endpoint options and use `--allow-private-network` only when the
operator intends access to private address space.

## Store or rotate the credential

```sh
sudo /usr/local/sbin/rotate-pat
```

The helper validates the token against the configured forge and stores it as a
broker-only 0600 file. The broker rereads the credential per request.

## Agent delivery

The agent commits on `fieldwork/...` and writes:

```json
{
  "schema_version": 2,
  "slug": "app",
  "branch": "fieldwork/change",
  "title": "Change",
  "body": "Summary and tests"
}
```

Then:

```sh
fieldwork-pr-build .fieldwork/local/pr-build-request.json
/usr/local/bin/fieldwork-pr-upload <printed-request-id>
```

For required approval, an operator or isolated approval service speaks the
`POST /approve` contract on the approve socket. Query with uploader
`--status`.

## Operational checks

```sh
systemctl status fieldwork-pr-broker.socket fieldwork-pr-approve.socket
journalctl -u fieldwork-pr-broker.service
sudo stat -c '%U:%G %a' /etc/fieldwork-pr-broker/gh-token
sudo stat -c '%U:%G %a' /var/lib/fieldwork-pr-broker/keys/pending-mac.key
```

Back up policy, CA material, token, MAC key, replay ledger, pending stores, and
tombstones together. Do not rotate the MAC key while work is pending.

## Upgrade

Protocol v1 and v2 are not mixed. Stop agent intake/sessions, drain or quarantine
v1 pending work, verify and install the v2 release, re-wire policies, start the
root-only maintenance socket explicitly, migrate structural instructions on
`fieldwork/...` branches through PRs, stop maintenance, and restart normal
intake. Use `sudo fieldwork-pr-maintenance-mode start` and
`sudo fieldwork-pr-maintenance-mode stop` for the fail-closed socket/service
transaction. See [runbook](runbook.md).
