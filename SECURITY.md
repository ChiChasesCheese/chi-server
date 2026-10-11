# Security policy

## Reporting a vulnerability

Please do not open a public issue for security problems.

Report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**
(private vulnerability reporting). Include:

- what is affected (script, stack, configuration) and the commit or version,
- steps to reproduce, and
- the impact you expect (for example, a service reachable from the internet or the LAN that should not be).

You should receive an acknowledgement within a week. Fixes are released as soon as practical and credited in
`CHANGELOG.md` unless you prefer otherwise.

## Scope

In scope: the scripts in this repository, the compose files and templates it ships, and the defaults it applies
to macOS (firewall, SSH, auto-login, sudoers guidance, Tailscale and Cloudflare exposure).

Out of scope: vulnerabilities in upstream software (Jellyfin, Immich, Vaultwarden, n8n, Tailscale, OrbStack,
mihomo and others). Report those to their projects. If our configuration makes an upstream issue worse, that is in
scope.

## Supported versions

Only the latest release on the `main` branch receives fixes.

## Hardening guidance

The trade-offs chi-server makes (FileVault off with auto-login, what is exposed where, secret handling) are
documented in [docs/security.md](docs/security.md).
