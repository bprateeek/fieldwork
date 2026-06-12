# Contributing

Fieldwork is developer preview security infrastructure. Small, focused PRs are the
easiest to review.

Before opening a PR:

```sh
tests/static-checks.sh
python3 tests/broker-validation-tests.py
python3 tests/pr-prepare-validation-tests.py
python3 tests/bot-tests.py
```

Security-boundary changes need extra care. If you edit the broker, runners,
socket permissions, install path, or token handling, update the threat model
and add a regression test.

Do not include real tokens, private keys, ntfy topics, Telegram bot tokens, or
full production logs in issues or PRs.
