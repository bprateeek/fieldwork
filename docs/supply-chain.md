# Install Integrity And Releases

Fieldwork is security infrastructure, so the install path matters too.

Recommended developer preview install path:

```sh
git clone https://github.com/bprateeek/fieldwork.git ~/fieldwork
cd ~/fieldwork
git fetch --tags
git tag -v v0.1.0
bash install.sh
```

When release archives are published, verify checksums before installing:

```sh
shasum -a 256 -c SHA256SUMS
```

Fieldwork does not recommend blind `curl | bash` installs. Review the tag,
checkout, or release archive before running `install.sh`.

Bootstrap installs host packages such as GitHub CLI, Claude Code support,
Docker support, bubblewrap, gitleaks, semgrep, jq, git, curl, and systemd
support tools using the host package manager or vendor install path documented
by those projects. Developer preview releases document intentionally unpinned
dependencies in release notes when they matter for reproducibility.

Dependency posture for developer preview:

| Dependency area | Posture | Rationale |
|---|---|---|
| Fieldwork source | signed release tag and source archive checksum | users can verify the exact Fieldwork checkout or archive before install |
| Codex CLI installed by setup | pinned npm package by default (`@openai/codex@0.137.0`, override with `FIELDWORK_CODEX_NPM_PACKAGE`) | keeps Codex setup reproducible while allowing operator override |
| gitleaks | pinned release archive with upstream checksum verification | broker and verify paths rely on secret scanning |
| Node.js, GitHub CLI, OS packages | distro/vendor apt repositories, not pinned per package | preview bootstrap favors supported update streams over snapshot management |
| Claude Code and rootless Docker installers | vendor install path, not pinned by Fieldwork | these tools are external runtimes with their own release channels |
| semgrep rules | live `p/owasp-top-ten` config when semgrep is installed | verify checks should catch current common web risks, not a stale local ruleset |
| GitHub Actions runners/actions | `ubuntu-latest` and major-pinned actions | public CI stays simple; release gates also require local and VPS rehearsal |

Release checklist:

- worktree is clean
- changelog has the release entry
- tests pass
- Docker eval smoke passes
- clean VPS setup path has been rehearsed
- Claude E2E passes
- Codex E2E passes
- signed tag exists
- GitHub Release is published
- checksums are published for archives and verified
