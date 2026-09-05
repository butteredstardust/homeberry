# Security Policy

homeberry manages authentication, DNS, storage, containers, and network access
for a household. Please report security problems privately and avoid testing
against systems you do not own or have permission to operate.

## Supported versions

Security fixes are applied to the latest revision of `main`. There are no
maintained release branches. Users should review changes and update from the
latest revision appropriate for their deployment.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Contact the
maintainer privately using the contact methods on the
[maintainer's GitHub profile](https://github.com/butteredstardust). If no private
contact method is available, open a public issue asking for a private contact
channel without including vulnerability details.

Include:

- the affected file, service, and revision;
- prerequisites and minimal reproduction steps;
- the potential impact and whether the issue is remotely reachable;
- suggested mitigations, if known; and
- whether any credentials or real household data may have been exposed.

You should receive an acknowledgment within 10 business days. The maintainer
will validate the report, coordinate a fix and disclosure timeline, and credit
the reporter if requested. Please allow a reasonable remediation period before
public disclosure.

## Scope

In scope are vulnerabilities introduced by this repository's Compose
configuration, provisioning and maintenance scripts, Caddy configuration,
example policies, and documentation. Vulnerabilities solely in an upstream
image or dependency should also be reported upstream; please notify this project
when its pinned version is affected.

Deployment mistakes involving changed defaults, exposed ports, leaked `.env`
files, weak credentials, or unsupported local modifications may not be project
vulnerabilities, but responsible reports are still welcome.

## Operational guidance

- Never publish `.env`, `appdata/`, backups, credentials, private keys, or
  internal network details.
- Do not port-forward the administrative services described in the README.
- Keep the host and pinned container images current after reviewing release
  notes and backups.
- Treat Docker socket access and the Arcane manager as root-equivalent.
