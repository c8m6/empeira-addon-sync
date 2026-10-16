# Project conventions

Standalone Empeira API 1 addon: a minimal host rsync wrapper in one executable
Ruby file. Use Ruby standard libraries only, no build step, Bundler, framework,
containers, install hooks or automatic package/gem installation. Do not modify
Empeira Core. Preserve the executable bit on `bin/sync`.

Read only Empeira's `EMPEIRA_ADDON_CONFIG_TARGETS_*` exports for configuration.
Targets require source/destination and may specify an SSH username. Without one,
prompt interactively for remote hosts; preserve explicit user@host paths and fail
clearly when a prompt cannot be displayed. Keep the direct CLI limited to
`empeira addon sync`, `--dry-run` and `--help`. Use argument arrays, exclude
`.git/`, never add `--delete`, and stop on the first rsync failure with its status.
Relative local paths use `EMPEIRA_CONTROL_REPO`; SSH usernames only change
the remote login part, never the remote path.

Code and documentation use AGPL-3.0-or-later. Documentation and comments are English.
Support Linux, macOS and WSL2 with portable Ruby operations. Keep tests small and
synthetic; use a simple rsync stub, never production data or infrastructure.
Update affected documentation. Do not create temporary planning documents.

Before committing, run `ruby -c bin/sync`, `ruby -c test/sync_test.rb`,
`ruby test/sync_test.rb` and `git diff --check`. Report actual checks honestly.
Use focused Conventional Commits and follow the user's branch, push and release
instructions. Do not add release automation that modifies the README.
