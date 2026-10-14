# Security policy

Use [GitHub private vulnerability reporting](https://github.com/c8m6/empeira-addon-sync/security/advisories/new)
if enabled. Otherwise ask for a private contact through
[Empeira Discussions](https://github.com/c8m6/empeira/discussions), without posting
vulnerability details. Do not disclose exploits in public issues or pull requests.
There is no response-time or backport guarantee; check current `main` when reporting.

Include the affected commit, Ruby and rsync versions, host OS, and a minimal
reproduction using synthetic data. Never attach credentials or production data.

This addon runs with the invoking user's permissions. Trust and review the
configured sources, destinations, host rsync and SSH configuration. Transfers
may overwrite destination files; excluding `.git/` is not a sandbox. There is
no credential store, privilege escalation, rollback or remote-host verification
layer beyond the host's existing tools.
