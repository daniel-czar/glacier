---
id: c4129407703295e8
alias: series net achieve there citizen village
kind: readme
title: Glacier minimal module example
created: '2026-11-02'
updated: '2026-11-02'
tags:
- glacier
- modules
- example
---

# Minimal compiled module

Run `swift run --disable-index-store glacier-example`. This uses a fresh temporary support root and preview mode (no global shortcuts or clipboard collection). In the launcher, use `trm` then Tab, or `/trim some text`. When automatic requests are off, Return/Generate runs the transform.

`App.swift` registers `TextTrimModule` in one line through `GlacierDesktop(additionalModules:)`. The same descriptor supplies module settings, slash/Tab routes and presentation; the host's routing switches do not change. The example is not registered in the normal app.

To add a tool, implement `GlacierToolModule`, declare unique namespaced IDs/aliases and a producer with bounded input/output, then pass its type-erased registration into composition. These are trusted compiled modules, not an untrusted plugin sandbox. Network or filesystem work needs its own reviewed service boundary.
