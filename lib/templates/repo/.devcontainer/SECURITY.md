# Devcontainer security invariants

This devcontainer is the **build/test runtime boundary**: `npm test`, `cargo build`, and similar isolated commands run here. **It is not the Claude execution boundary.** Claude itself runs on the host with `--sandbox` + `permissions.deny` as part of the Fieldwork host sandbox.

If you ever want the container to be the actual Claude execution boundary, run `claude remote-control` *inside* the container instead. That's not the default; it requires extra plumbing (volume mounts for `~/.claude`, container lifecycle vs systemd, port plumbing).

## Hardening invariants: every Dockerfile + devcontainer.json variant

Future-you and Claude must not relax these without a recorded reason and approval.

1. **Non-root user** `vscode` (uid 1000). Never `USER root` at the end of a Dockerfile.
2. **No Docker socket mount.** Never bind-mount `/var/run/docker.sock`. If DinD is genuinely needed for a project, use rootless DinD with explicit user namespace remap and document the reason in this file.
3. **No SSH agent forward.** `SSH_AUTH_SOCK` must not appear in `mounts` or env propagation.
4. **No host home mount.** Bind-mount the repo directory only. Specifically NOT: `~`, `~/.aws`, `~/.ssh`, `~/.config`, `~/.kube`, `~/.docker`, `~/.npmrc`, `~/.gnupg`, `~/.gitconfig`.
5. **`runArgs`** must include `--cap-drop=ALL --security-opt=no-new-privileges`.
6. **`--network=none`** for unit-test runs where feasible. Most unit tests don't need network; runtime tests that do can opt-in selectively.
7. **Resource limits**: `--memory=2g --cpus=2 --pids-limit=512` defaults. Bump per project only with documented reason.
8. **Read-only `/etc` and `/usr`** mounts where the base image allows.

## Healthcheck

`/etc/devcontainer/healthcheck.sh` runs at container start and fails the container if any invariant is loose. Don't bypass; fix the dockerfile.

## `--dangerously-skip-permissions`

Acceptable inside a hardened container that has passed healthcheck. Only there. Never on the host.
