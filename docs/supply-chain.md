# Supply-chain verification

Fieldwork requires two independent chains before candidate code executes:

1. An operator-pinned SSH signing key verifies the Git tag.
2. A separately protected, commit-pinned trusted builder attests the release
   archive.

Neither chain substitutes for the other. The candidate repository cannot build
an acceptable archive or schedule the authenticated hard-boundary probe runner.

## External trusted-builder prerequisite

Before a release, deploy a trusted workflow in a separately protected
repository and pin all of these in the `trusted-builder-dispatch` environment:

- `FIELDWORK_TRUSTED_BUILDER_REPOSITORY`
- `FIELDWORK_TRUSTED_BUILDER_WORKFLOW`
- `FIELDWORK_TRUSTED_BUILDER_REF`
- `FIELDWORK_TRUSTED_BUILDER_WORKFLOW_SHA` (full 40-character commit)
- secret `FIELDWORK_TRUSTED_BUILDER_DISPATCH_TOKEN`

The workflow must independently verify the signed source tag, build with fixed
`git archive` logic without executing candidate release scripts, attest the
archive, and publish it. Its authenticated Linux probes run only in a protected
environment on an ephemeral runner and use a dedicated inference-only Claude
token plus a forge credential scoped to the smoke repository. The candidate
`release.yml` can request that workflow but cannot mint provenance or target
the runner. macOS provenance and a local hard-boundary security claim remain
deferred until a separate real-hardware acceptance gate exists.

The dispatch inputs are untrusted hints: `source_repository`, `source_ref`,
`source_event_oid`, and `expected_workflow_sha`. The trusted workflow must check
its own immutable identity, fetch and verify the tag, and derive the peeled
commit itself; it must never treat the candidate event OID as the provenance
source digest.

## First-install tag anchor

Obtain the maintainer SSH signing public key through an independent channel.
Store an allowed-signers file outside the downloaded repository, root-owned and
not writable by the installing user. For example:

```text
fieldwork-release namespaces="git" ssh-ed25519 AAAA... independently-obtained-key
```

Fetch tag objects without executing repository code, then verify:

```sh
git -c gpg.format=ssh \
  -c gpg.ssh.allowedSignersFile=/usr/local/etc/fieldwork/allowed_signers \
  verify-tag vX.Y.Z
commit="$(git rev-parse 'vX.Y.Z^{commit}')"
test "$(git cat-file -t "$commit")" = commit
```

Keep the allowed-signers file as the upgrade trust anchor. Key rotation is an
explicit operator event confirmed through the same independent channel.

## Archive provenance

Download the archive and its attestation from the trusted builder. Pin both the
workflow path and workflow commit:

```sh
gh attestation verify fieldwork-vX.Y.Z.tar.gz \
  --repo bprateeek/fieldwork \
  --signer-workflow owner/trusted-builder/.github/workflows/fieldwork-release.yml \
  --signer-digest <trusted-builder-workflow-commit> \
  --source-ref refs/tags/vX.Y.Z \
  --source-digest "$commit"
```

The verification must bind the archive subject digest, source tag, peeled source
commit, workflow identity, and workflow digest. A valid attestation from the
candidate repository or a different trusted-builder commit is not acceptable.

Only after both checks succeed:

```sh
mkdir fieldwork-vX.Y.Z
tar -xzf fieldwork-vX.Y.Z.tar.gz -C fieldwork-vX.Y.Z --strip-components=1
cd fieldwork-vX.Y.Z
sudo bash lib/local/install.sh        # local mode
# or run the documented VPS root installers
```

`gh`, Git, and SSH tooling are bootstrap dependencies only. The running broker
uses Git plus host-pinned REST and does not invoke GitHub CLI.

## Fail-closed rules

- Never install from a source checkout whose tag was not verified.
- Never accept provenance based only on repository or workflow filename.
- Never use a mutable branch, tag, or short SHA for the trusted builder.
- Never run candidate install or release scripts before both chains pass.
- A changed Claude executable digest disables the hard-boundary claim until the
  hostile probe is rerun.
