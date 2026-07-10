# Security Policy

## Supported versions

Security fixes are applied to the latest release and to `main`.

## Reporting a vulnerability

Please **do not report security vulnerabilities through public GitHub
issues.**

Instead, use GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/henrywang/Berthly/security/advisories/new)**
(Security tab → "Report a vulnerability").

Include as much of the following as you can:

- A description of the issue and its impact
- Steps to reproduce, or a proof of concept
- Affected version (or commit) and your macOS / `container` versions

You'll get an acknowledgement within a few days. Please allow time for a fix
to be prepared and released before disclosing publicly.

## Scope

Berthly is a GUI over [Apple's `container`](https://github.com/apple/container)
tooling. Vulnerabilities in the container runtime, daemon, or
`containerization` framework itself should be reported to Apple through
[their security process](https://github.com/apple/container/blob/main/SECURITY.md);
issues in how *Berthly* drives them (credential handling, XPC usage,
privilege escalation via the app) belong here.
