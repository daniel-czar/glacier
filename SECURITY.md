---
id: 856dda7c88d32e6f
alias: lyrics human palace balance cream daring
kind: reference
title: Glacier security boundaries
created: '2026-11-02'
updated: '2026-11-06'
tags:
- glacier
- macos
- open-source
---

# Security

Glacier is a local desktop app with optional network tools. It does not need
Full Disk Access, an account or a subscription to start. Clipboard collection,
search folders, selected-text access, login startup, global shortcuts and AI
connections are separate choices. Cloud tools send the text supplied to the
configured provider; saving a key does not make a test request. API keys live
in Glacier's own Keychain namespace or in an explicitly selected external
source. Search roots do not authorize uploading file bodies or index metadata.

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub's vulnerability reporting form](https://github.com/daniel-czar/glacier/security/advisories/new).
Do not post exploitable details, API keys or personal data in a public issue.

Include the affected commit or app version, macOS version and architecture,
steps to reproduce, expected versus actual behavior, and the security impact.
Provide only the minimum redacted log or sample needed to reproduce it.
No response time or disclosure schedule is promised here.

## Boundaries to preserve

Exports must omit secrets. Revoking a credential or source must revoke old
results' authority too. Denying one permission or disabling one module must
leave unrelated local tools usable. Default tests and previews use temporary
state and fake effects; they must not touch another installation, register its
shortcuts, read personal credentials or call a live provider. A security fix
should include a focused regression and state whether it changes a network,
file, clipboard or macOS-permission boundary.
