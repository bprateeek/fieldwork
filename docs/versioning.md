# Versioning And Compatibility

Fieldwork uses semver during developer preview.

- Patch releases preserve developer preview config compatibility.
- Minor releases may add config keys, commands, adapters, or transports.
- Breaking config or install changes require migration notes in
  `CHANGELOG.md`.
- `0.x` releases may still change operational shape, but releases must say so
  plainly.

Upgrade path:

```sh
git fetch --tags
git checkout <release-tag>
bash install.sh
fieldwork sync-vps --force-install
fieldwork doctor --remote --explain
```

If repo templates changed, refresh onboarded repos explicitly:

```sh
fieldwork onboard <owner>/<repo> --reseed-templates
```
