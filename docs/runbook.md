# Runbook

This doc is task-oriented (flows you'll do). For a per-command index, see [cli-reference.md](cli-reference.md).

## Flow A: Onboard an Existing Repo

1. Widen the existing broker credential to include the target project. For
   GitHub, that means adding `<owner>/<repo>` to the fine-grained PAT or GitHub
   App installation. For GitLab, use a Project Access Token on the target
   project with Developer role and `api` plus `write_repository` scopes.
2. Run:

   ```sh
   fieldwork onboard <project> --with-approval-gate
   ```

   If the broker PAT does not have Workflows read/write, use:

   ```sh
   fieldwork onboard <project> --no-workflows
   ```

3. Paste the read-only deploy key when prompted.
4. In Claude mode, run the printed `ssh -t fieldwork-vps ...` commands to
   prime workspace trust and remote-control consent. In Codex mode, Codex
   Desktop owns the live SSH session and remote-project folder state.
5. Review the init PR/MR in GitHub or GitLab mobile.
6. Merge only after reading the diff and CI results; failed workflow checks
   need review even when the broker successfully opened the PR.
7. Prove the broker path without Claude or Codex:

   ```sh
   fieldwork smoke <owner>/<repo>
   ```

   `fieldwork smoke` is GitHub-only. For GitLab, use a throwaway project and
   prove onboarding, broker preflight, push/MR creation, approval-gated push,
   no-diff, and verify-fail paths.

8. Refresh the VPS checkout:

   ```sh
   fieldwork refresh <slug>
   ```

### Pause And Resume

`fieldwork onboard` is designed to be rerun. It stores a non-secret checkpoint in the VPS checkout at `.fieldwork/local/fieldwork-onboard-state.json` after the repo has been cloned.

If you stop during deploy-key setup, workspace trust, remote-control consent, init PR creation, or systemd startup, rerun:

```sh
fieldwork onboard <project>
```

To inspect progress without changing anything:

```sh
fieldwork onboard <project> --status
```

If the checkpoint is stale or corrupt:

```sh
fieldwork onboard <project> --reset-state
```

## Flow B: Bootstrap a New Project

For an empty GitHub-first project:

```sh
gh repo create <owner>/<repo> --private --description "<description>"
fieldwork onboard <owner>/<repo>
```

Then open Claude mobile or Codex Desktop and ask the repo session to scaffold
the project in a follow-up PR.

For a local scaffold first:

```sh
pnpm create vite my-app --template react-ts
cd my-app
git init -b main
git add -A
git commit -m "initial scaffold"
gh repo create <owner>/my-app --private --source=. --push
fieldwork onboard <owner>/my-app
```

## Flow C: Daily Agent Work

1. Open Claude mobile and tap the `vps-<slug>` session, or open Codex Desktop
   `Connections -> SSH`, enable `"Available from signed-in devices"` in Details,
   then open `/home/fieldwork/projects/<slug>` on mobile or desktop. For Codex
   folder or Offline confusion, run `fieldwork doctor --remote <slug> --explain`.
   Before Codex PR work, the mobile header should show the repo on the
   configured VPS SSH connection (for example, `fieldwork-vps`; it may display
   as the server name), not the local Mac/Windows host.
2. Describe the task. For broad work, ask the agent for a plan first.
3. Respond when the agent needs input or permission. Claude can send ntfy
   lifecycle notifications; Codex lifecycle notifications are not wired in this
   milestone.
4. If the repo is approval-gated, approve or deny the PR/MR request in Telegram.
5. Review the PR/MR in GitHub or GitLab mobile.
6. Merge only when the diff and checks are acceptable.
7. Refresh the VPS checkout after merge.

## Notification Icons

| Icon | Meaning | Action |
|---|---|---|
| checkmark | clean turn end | open the session if a PR URL is expected |
| question mark | Claude needs input or approval | answer in Claude mobile or Telegram |
| x | failure | read the session and, if needed, inspect the journal |

## Caveats

- Workspace trust is one-time per repo, but must be repeated if the clone is deleted.
- Default onboarding adds workflow templates; `--no-workflows` skips them and leaves existing workflow files untouched. Do not merge an init PR with failed workflow checks until you understand whether the failure is template tuning, GitHub billing/permissions, or an intentional no-workflows choice.
- Approval gating requires `fieldwork setup-notify --telegram-bot` and `.fieldwork/approval-gate`.
- Private repos without paid GitHub features may not enforce branch protection or secret scanning. GitLab onboarding currently skips branch protection, secret scanning, CodeQL, and `.github/` templates.
- If GitHub Actions says billing is locked, Fieldwork opened the PR successfully but GitHub refused to start CI. Fix billing or rerun checks before treating the PR as green.
- Fieldwork records the forge default branch during onboarding. Rename unusual
  default branches before onboarding if `fieldwork onboard` rejects the branch
  shape.
- Anything merged to the default branch may deploy if the repo has Vercel,
  Cloudflare Pages, or similar automation.

## Future Codex Paths

- Experimental direct VPS `codex remote-control` is not part of the supported
  V1 path; it needs a controlled test before Fieldwork can expose `start|stop`
  helpers.
- A Fieldwork-owned mobile controller over Codex app-server/SDK is the stronger
  long-term option because it can preserve the broker PR boundary without
  depending on Codex Desktop mobile rollout details.
- Queued mobile jobs via Telegram or a small web surface are a lighter fallback
  for non-interactive Codex work.
