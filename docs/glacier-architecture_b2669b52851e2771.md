---
id: b2669b52851e2771
alias: raven crumble start any tiny review
kind: architecture
title: Glacier architecture
created: '2026-11-02'
updated: '2026-11-05'
tags:
- glacier
- macos
- open-source
---

# Glacier architecture

Glacier is a detached native Swift/AppKit app. It reuses the current Omni window/session/core implementation while replacing its personal composition, credentials and paths. The original Omni installation is never a runtime dependency.

## Ownership

- `GlacierApp` owns process entry. `GlacierRuntime` composes local stores, providers, settings and native UI.
- `GlacierWorkspace` coordinates existing native tool windows against injected services; it has no fixture or installed-personal-owner graph.
- `GlacierConfiguration` owns nonsecret versioned preferences and private app paths. `GlacierModuleKit` projects module availability across aliases, shortcuts and help.
- `GlacierConnections` owns selected credential sources, per-provider destination grants, Keychain references and HTTP transports. No background credential discovery or connection testing occurs.
- `GlacierSearch` owns explicit sources, metadata snapshots, source authority and FSEvents updates. `OmniApplication.LauncherService` supplies the existing scorer and interaction pipeline.
- `GlacierPlatform` adapts shortcuts, keyboard labels, terminal/Finder actions and help. Registration is explicit and safe preview forbids it.
- `GlacierPronunciation` owns a versioned stdin/events bridge to a pinned app-bundled Python helper. The helper receives request-scoped credentials, never a personal CLI environment.
- `OmniCore`, `OmniRun`, `OmniApplication`, `OmniModels`, `OmniPresentation` retain the proven domain, run history, model validation and native surfaces. `OmniFixtures` is test-only.

## Authority

The entry point uses new app identities and stores. All automated checks use temporary roots and fake effects; provider keys and live-smoke flags are stripped by the test runner. Module-off and shortcut-off are distinct. A module check applies to typed routes as well as hotkeys. Source revocation clears active index generations and prevents old result actions from bypassing current scope. Explicit Finder actions use their separate selection/origin authority.

Production composition adds app-only roots for system, shared and user Applications folders, and a direct Finder bundle root. The direct root grants Finder itself without traversing its contents or embedded helper apps. Injected app roots replace these defaults in synthetic tests; an empty injected list keeps fixtures isolated. Search policy still governs cached rows, watcher updates and launch authority after source changes.

The app's local filename search does not send its index to a model. AI-assisted corpus metadata sharing is not enabled by default. AI pause stops inference; offline stops remote services while allowing configured loopback models. Manual generation remains available when automatic typing-triggered generation is off.

Desktop invocations reserve foreground order before asynchronous work starts. Native hotkeys use external-selection entry points; pad Tab actions use pad-local input. Clipboard handoffs transfer an explicit return target without reading a hidden application's selection. An active external app takes precedence over a workspace that remains visible in the background.

For local Markdown links selected with Hyper O, R or G, the path destination takes precedence over display text and URL guesses. Glacier resolves absolute, home-relative and file URL destinations directly; G does not query the configured search index for those links. Search remains the fallback for other G input. Only existing local paths are acted on, and line or heading references are removed only when the literal path does not exist. Relative destinations have no implicit base in Glacier.

Shutdown is terminal for the desktop and native workspace: queued settings changes and actions cannot restart services or reopen a panel. Session revision checks discard stale completions; cancellation of a still-current request resolves through the existing failure state instead of leaving a busy indicator indefinitely.

## Deliberate boundaries

The old standalone composition was rejected because it predates the current tools. A new native rewrite was rejected because it would discard useful behavior and validation. Dynamic untrusted plugins and a binary ABI are out of scope; contribution is through compiled Swift modules and ordinary pull requests. Physical Caps Lock remapping remains external. Task/reminder owners are optional integrations, not a new task manager.

GitHub-style direct distribution is the target. The local package uses a development bundle identity and ad-hoc signing; Developer ID, notarization, final naming and publication remain separate release work. Managed AI, billing and marketing operations are not first-release dependencies.

## First-run onboarding

`GlacierRuntime` owns the Focused six-step native onboarding window and its
observable model. `GlacierDesktop` presents it for fresh installations, resumes
unfinished setup, and exposes a manual Getting started action through Settings.
An existing settings file without an onboarding checkpoint skips automatic
onboarding. A separate private, atomic `onboarding.json` stores only schema,
step and completion; it cannot overwrite application or credential settings.

The action adapter uses the same serialized desktop settings changes, connection
store, model routes and platform owners as Settings. First-shortcut activation
registers before persisting and rolls back on failure. A session epoch is checked
inside queued transforms and again at the destination store's commit boundary,
so closing/reopening setup cannot revive an older opt-in. Once the synchronous
atomic transaction is authorized, it may finish; later stages require a current
session. Credential submission carries the endpoint actually shown by the
UI; the connection actor compares it before inserting a Keychain item. Saving
and testing remain separate, and a test response is not model qualification.
The transport rechecks its gate after suspended origin lookup and before dispatch.
API keys exist only transiently in the secure input/model and are cleared on
submission, provider changes, leaving the step or closing the window.

Local first-win results reuse the production date, calculator and character
engines and respect current module availability. They require an explicit Try
action; finishing setup never fabricates a result. Preview forbids OS setup,
credential/network setup, login registration and clipboard opt-in. Native capture
fixtures use injected effects and verify light/dark window framing.

Rejected alternatives: embedding the HTML mock as a web view (loses native
controls and permission semantics), making AI/access/clipboard/indexing mandatory
(blocks useful local tools), storing a second settings snapshot in onboarding
(would overwrite concurrent choices), and treating a completion-state observation
as an instruction to open the app (breaks reopening a completed flow).
This onboarding is specific to the public standalone app; the personal Omni
owner-bound composition keeps its existing setup path.

## Express output

`OmniCore` stores an Express-only primary/secondary language pair and output mode in native preferences. `GlacierRuntime` exposes these choices in Tools & Data. The `GlacierWorkspace` Express producer reads one preference snapshot per request and puts the selected language rule into its provider prompt. Primary mode offers alternatives in the primary language even when the input already uses it; paired mode sends primary-language input to secondary and other input to primary. The result protocol remains the same.

The validated final result is required before either copy action. Return and the round button copy the selected phrase alone, then close; ⌘⇧C retains that selected-copy behavior. Option+Return is the secondary Copy all action and includes group headings and cues. This supersedes the earlier C90 Return-as-Copy-all behavior. Pending manual input still uses Return or the round button to generate; Option+Return never generates.

Translate retains its separate source/target settings in `GlacierConfiguration`. Reusing those fields for Express was rejected because Translate's default source is automatic detection, which cannot represent Express's English/German pair or its primary-language rewording mode.

## Drafting

`OmniModels` owns source/request separation and the bounded draft fidelity check.
Text before a standalone `/email` or `/msg` is supplied material; text after it
is the author's request. Command-leading text and rough outgoing notes remain
supported. JSON fields preserve source line breaks and exact UTF-16 note anchors;
quoted source instructions never become author instructions. Missing decisions
request direction rather than inventing acceptance, refusal or a commitment.

Each draft uses a generation followed by one independent fidelity review through
the configured model. Review gets the original structured request, notes, intent
markers and candidate. Only the reviewed text becomes a result. Failure or
cancellation publishes no unchecked candidate, and the execution receipt retains
both stages. The per-tool chooser recommends the dedicated Qwen high drafting
profile. Existing saved selections, explicit setup, credential/origin authority,
offline exclusions and qualification behavior are preserved. No personal guide
or qualification ledger is imported.

Prompt-only changes without source roles were rejected after synthetic provider
comparisons still gave wrong-speaker replies. Lower reasoning and weaker automatic
fallbacks repeatedly invented commitments or calendar facts. A general planner
would add machinery without addressing a different failure, so this repair stays
inside drafting. The second model pass reduces tested semantic errors; it is not
a guarantee of semantic correctness.

## Calendar offsets and native navigation

`SpanCalculator` distinguishes period/elapsed queries from point-date offsets.
Offsets reuse the typed endpoint parser, Gregorian UTC civil arithmetic and
Foundation clamping, with bounded integer units and the existing 1583–9999 date
domain. Results and live headlines show the answer date first. A fixed number of
days per month was rejected because it gives incorrect calendar answers.

`/workspace` is a parser-visible native UI command, handled before run submission.
Its settings-role manifest entry has no module, capability or execution declaration;
the existing pad callback opens the existing window independently of Launcher.
Execution/storage fixture versions remain unchanged. A new owner operation or
module was unnecessary for window navigation. Standard Cmd+, uses the existing
native app-menu Settings action; hidden-status-item regressions cover both windows.
