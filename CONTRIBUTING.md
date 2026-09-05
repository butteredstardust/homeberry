# Contributing to homeberry

Thanks for helping improve homeberry. Changes should keep the stack safe to
operate on a Raspberry Pi and useful to people adapting it to their own homes.

## Before you start

- Search the existing issues before opening a new one.
- For security problems, follow [SECURITY.md](SECURITY.md) instead of filing a
  public issue.
- Keep site-specific values, credentials, hostnames, addresses, and device
  inventories out of the repository. Configuration belongs in `.env`; use
  `.env.example` only for documented placeholders.
- Read the operational and design decisions in `docs/` before changing network,
  storage, authentication, backup, or recovery behavior.

## Development workflow

1. Fork the repository and create a focused branch from `main`.
2. Make the smallest change that solves the problem.
3. Preserve the separation between `docker-compose.yml` (services),
   `provision.sh` (host setup), and the gitignored `appdata/` directory (state).
4. Update the relevant documentation whenever behavior, configuration, or an
   operational procedure changes.
5. Test idempotent scripts by running them more than once where practical.
6. Open a pull request with the motivation, risks, validation performed, and a
   rollback or recovery note for operational changes.

## Shell and configuration changes

- Write defensive shell code and preserve existing refusal checks around disks,
  firewalls, credentials, and destructive operations.
- Do not weaken loopback binds, firewall rules, authentication, TLS, backup
  verification, or secret handling for convenience.
- Keep examples generic and safe to publish.
- Do not commit `.env`, `appdata/`, backups, keys, tokens, certificates, or
  machine-specific state.

## Pull requests

A useful pull request is focused, explains user-visible and operational impact,
updates docs and examples, and records exactly how it was checked. Screenshots
or command output are welcome when they make a configuration or UI change easier
to review, but redact private network and account information first.

By participating, you agree to follow the
[Code of Conduct](CODE_OF_CONDUCT.md).
