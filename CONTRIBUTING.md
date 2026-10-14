# Contributing

Keep changes focused and follow [AGENTS.md](AGENTS.md). Use Conventional Commits,
English documentation and synthetic examples without production data or secrets.
Keep this addon a minimal rsync wrapper.

Run these checks without Bundler or an installed rsync:

```sh
ruby -c bin/sync
ruby -c test/sync_test.rb
ruby test/sync_test.rb
git diff --check
```

Report which checks actually ran. The tests use a temporary rsync stub; they
do not connect to remote hosts. Preserve direct execution after checkout.

Contributions are licensed AGPL-3.0-only. Retain attribution and verify the
provenance and license compatibility of third-party material. No CLA or copyright
assignment is required. Use
[Empeira Discussions](https://github.com/c8m6/empeira/discussions) for questions
and [SECURITY.md](SECURITY.md) for undisclosed vulnerabilities.
