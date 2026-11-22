# Security policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub Security Advisories:
<https://github.com/jackh54/bamboo/security/advisories/new>

Please don't open a public issue or pull request for a vulnerability. Include the Bamboo and macOS versions, what an attacker can do, and steps to reproduce.

You can expect an acknowledgement within a few days. Fixes ship in a normal release; the advisory is published once a fixed version is available.

## Supported versions

Only the latest release receives security fixes. Bamboo updates itself, so most people are on it already.

## Scope

In scope: the Bamboo app, the Rust core, the `bamboo-mcp` bridge and its agent socket, and the release and update pipeline (a way to push a malicious update is a vulnerability).

Out of scope: bugs in WebKit itself (report those to Apple) and in websites Bamboo displays.
