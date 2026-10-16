# Empeira Addon Sync

A small Ruby addon that synchronizes files and directories using the host's
rsync. Configured sources and destinations run sequentially. AGPL-3.0-or-later.

## Installation

Requires Empeira API 1 with the per-addon configuration exports introduced in
[Empeira PR #16](https://github.com/c8m6/empeira/pull/16), Ruby 3.1, 3.2, 3.3, 3.4 or 4.0 on PATH, and an
already installed `rsync`. SSH is needed for remote transfers. Supported hosts
are Linux, macOS and WSL2. The addon never installs packages or gems.

Add this to the control repository's existing `.empeira.yaml`:

```yaml
addons:
  sync:
    git: https://github.com/c8m6/empeira-addon-sync.git
    ref: main
    config:
      targets:
        - source: server:/srv/puppet/control/
          destination: ./
          username: deploy

        - source: ../hiera-common/
          destination: server:/srv/puppet/hiera/
          # No username: prompt when the addon runs
```

Run `empeira addons sync` to install. Empeira also installs a missing addon on
first invocation; `empeira addons update` refreshes the configured ref.
For reproducibility, use a commit or a tag from
[GitHub Releases](https://github.com/c8m6/empeira-addon-sync/releases) instead
of `main`. After checkout, `./bin/sync --help` works without a build step.

## Usage

```sh
empeira addon sync
empeira addon sync --dry-run
empeira addon sync --help
```

Every entry in `targets` requires `source` and `destination`; `username` is
optional for SSH transfers. Their order defines the transfer direction: the first
example copies from a server to the control repository, the second copies local
data to a server. Local-to-local transfers work without a username or prompt.
All entries run in array order; an empty array does nothing.

The addon reads only Empeira's `EMPEIRA_ADDON_CONFIG_TARGETS_COUNT` and indexed
`EMPEIRA_ADDON_CONFIG_TARGETS_0_SOURCE`, `_DESTINATION`, and optional
`_USERNAME` exports (and so on). It does not read YAML itself or create
another configuration file.

Relative local paths resolve against `EMPEIRA_CONTROL_REPO`, even when invoked
from a subdirectory. Absolute local paths and remote `user@host:/path` paths
are preserved. Existing local directory sources automatically get a trailing
`/` so their **contents** are copied. **Always include the trailing `/` for
remote directory sources**: the addon cannot inspect remote directories and
passes those paths unchanged. File sources do not need a trailing slash.

Transfers use `rsync -a --exclude=.git/`, plus `--dry-run` when requested.
Archive mode preserves contents, timestamps and permissions within rsync's and
the user's permissions. `.git/` directories are excluded. Extra destination
files are never deleted; existing files may be overwritten. Dry-run forwards
rsync's native option and output; without verbose options rsync may be quiet.
Remote transfers use the host's existing SSH configuration and authentication.
For `server:/path/`, `username: deploy` produces `deploy@server:/path/`.
If `username` is missing, the addon asks `SSH username for server:` on the
terminal, once per host per invocation. In a non-interactive session, a missing
username produces an actionable error instead of waiting for input. Existing
`user@server:/path/` entries continue to work without a prompt; if both forms
specify different usernames, the addon reports the conflict. No passwords,
credentials or SSH key settings are stored or requested.

Each target prints its number, source and destination, followed by native rsync
output. Successful completion prints `Sync completed.`. On the first failure,
the addon reports the error, returns rsync's exit code and skips remaining
targets. Earlier transfers are not rolled back. Missing rsync produces:

```text
Error: rsync is not installed or not available in PATH.
Please install rsync and retry.
```

## Limitations and development

- No retries, conflict resolution, automatic deletion, background jobs or state.
- No per-target options other than the optional SSH `username`; no filters,
  profiles, passwords or credentials. Only local paths and rsync's SSH paths
  are intended; rsync does not support two remote endpoints in one transfer.
  Use explicit paths; shell expansions are not performed.
- Archive mode does not add hard-link, ACL or extended-attribute preservation.
- Remote directory trailing slashes are the user's responsibility.
- API 1 has no completion for options at the addon entrypoint; see `--help`.
- Empeira versions without PR #16's configuration exports cannot run this addon.

For more complex requirements, use rsync directly or a specialized tool.
Run `ruby test/sync_test.rb` for focused checks with a local rsync stub and PTY;
see [CONTRIBUTING.md](CONTRIBUTING.md) for syntax checks. CI tests Ruby 3.1, 3.2, 3.3, 3.4 and 4.0 on Linux and macOS.

Questions: [Empeira Discussions](https://github.com/c8m6/empeira/discussions).
Security reports: [SECURITY.md](SECURITY.md).

Ruby 3.1 is the minimum supported version. All five supported versions (3.1, 3.2,
3.3, 3.4 and 4.0) run standalone behavior and actual addon/Core acceptance tests
on Linux and macOS in regular CI. See [CONTRIBUTING.md](CONTRIBUTING.md) for
local commands, optional dependencies and runtime/WSL2 validation limits.
