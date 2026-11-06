---
id: d1e043654b567813
alias: spin acoustic sun note guide another
kind: reference
title: Using Glacier
created: '2026-11-04'
updated: '2026-11-06'
summary: Practical setup, provider configuration and everyday tool behavior.
tags: [glacier, macos, user-guide]
---

# Using Glacier

[Back to the README](../README.md)

## Getting started and settings


On first launch, the native **Getting started** window offers a short Focused
setup: an opening shortcut, selected-text access, an optional AI provider, local
search folders, clipboard history and login startup. **Try Glacier first** goes
straight to a useful local example without enabling any of those choices.
Closing the window keeps your progress; **Settings → General → Getting started…**
reopens it. Existing configured installations are not forced through the flow.

Accessibility is optional and checked from macOS rather than self-attested.
Provider setup displays the destination and chosen model; saving a key is local,
while **Test connection** sends a separate explicit request. Automatic AI requests
stay off until you opt in per tool. Search folders, clipboard collection and
login startup are separate choices. The navigation checkpoint contains no keys
or copies of your settings. Safe preview keeps OS setup actions unavailable and
lets you try the local examples.

Settings applies validated edits as made. Add provider credentials explicitly; saving never contacts a provider. Add folders to local search or opt into Home. Choose enabled modules separately from their keyboard bindings. The shortcuts tab records actual chords; physical-key remapping remains external. API tools support manual generation and optional automatic requests.

**Launch** opens a separate pinned-app palette. In **Settings → Shortcuts**, enable and record the **Apps** shortcut, or load the suggested Hyper layout for Hyper+A and activate saved shortcuts. Choose **Edit manifest…** there to edit `~/Library/Application Support/Glacier/manifest.json`. For example:

```json
{"launch":[{"bundleID":"com.apple.finder"},{"bundleID":"com.apple.Safari","key":"S"}]}
```

The list holds up to eight installed apps. Entries stay in order. By default, eight apps use QWER/ASDF; five or six use QWE/ASD; up to four use QW/AS. An optional letter `key` on an entry overrides its positional key; lowercase letters are accepted and assigned keys must be unique. Press the shown key or click a cell to open or bring forward its app. Enter chooses the hovered cell or the last launched app. Esc, the shortcut again, or clicking away closes the palette. A key without a cell is ignored. Edits take effect on the next opening. No app history is saved by Launch.

When Launcher is enabled, it finds apps in `/Applications`, `~/Applications`,
`/System/Applications` and `/System/Library/CoreServices/Applications`, plus
Finder. These automatic sources index app bundles only. Other local files require
a selected search folder or the Home option.

In **Tools & Data**, Express defaults to natural alternatives in its primary language (English), including for English input. Select **Switch between languages** to send primary-language input to the secondary language and other input to the primary language. Its language pair defaults to English and German and is separate from Translate's source and target settings.

In Express, choose an alternative with ↑/↓ or a click. Return and the round copy button copy only its wording and close; ⌘⇧C does the same. Option+Return copies all validated alternatives with their groups and cues. With manual generation enabled, Return and the round button generate pending input first.

For Email and Message, the per-tool model menu recommends Qwen 3.8 high with a
16,384-token budget. Existing explicit choices stay selected. Drafting separates
source material from the instruction after `/email` or `/msg`, then checks the
candidate in a second model call before showing it. Missing user direction asks
for input; review failure or cancellation does not return an unchecked draft.
Both calls use the configured provider and count toward its usage.


## Optional integrations

Personal task/reminder owners, subscription CLI connections and the optional TypeSafe Map verifier are not enabled in this standalone candidate. Map uses ordinary configured generation without that verifier. Glacier has independent preferences, credentials and stores; it does not import a personal Omni setup.

## Navigation

**⌘,** opens Settings while Glacier is active. `/workspace` opens the existing workspace even when the menu-bar icon is hidden or Launcher is disabled. It takes no input and creates no model request or run.

Closing the command pad discards its unfinished input, selected-text source, notes and one-request model choice. Opening it again starts empty unless it captures a new selection from the app in front. Saved runs, stash entries and workspace follow-up drafts remain available.

## Uninstall


Turn off **Launch at login** in Glacier's Settings if enabled, then quit Glacier. Move the `Glacier.app` copy you installed to Trash. To remove its local data, inspect and delete only these Glacier-owned folders in Finder:

- `~/Library/Application Support/Glacier/` — settings, runs, indexes and local helper data.
- `~/Library/Caches/Glacier/` and `~/Library/Logs/Glacier/` — cache and logs.

If you saved API keys, use Keychain Access to inspect and remove only Glacier items under the service `local.Glacier.Development`. A preview launched with `--support-root` uses that explicitly chosen test root instead; inspect it before deleting it. User-selected search folders and output folders are separate from Glacier's app data.
