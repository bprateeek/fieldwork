# Backup And Restore

Fieldwork state lives in a few places.

Back up:

- `/etc/fieldwork-pr-broker/gh-token`
- `/etc/fieldwork-bot/config.toml`
- `/etc/fieldwork-bot/secret`
- `/var/lib/fieldwork-pr-broker/requests`
- `/var/lib/fieldwork-pr-broker/pending`
- `/var/lib/fieldwork-pr-broker/audit.jsonl`
- `/var/lib/fieldwork-bot`
- the onboarded repo checkouts under the configured projects directory
- per-repo `.claude/` state in those checkouts

Forge-side state is not on the VPS:

- broker token project selection and permissions
- read-only deploy keys
- branch protection
- open PRs/MRs and branches

Restore outline:

1. Rebuild the VPS and reinstall Fieldwork.
2. Restore broker and bot config/secrets with the documented owners and modes.
3. Restore or reclone onboarded repositories.
4. If compromise or token exposure is possible, rotate the broker token instead
   of restoring it.
5. Run `fieldwork verify-security`.
6. For GitHub repos, run `fieldwork smoke <owner>/<repo>` for each important repo. For GitLab projects, use a throwaway MR path because `fieldwork smoke` is GitHub-only.

If the VPS is lost while requests are pending, treat pending approvals as stale:
restore the pending directory only if you understand the repo state it refers
to. Otherwise delete pending requests and have the agent resubmit.
