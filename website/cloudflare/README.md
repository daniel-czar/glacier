---
id: 63bad45576afcb8a
alias: glove stove best unhappy witness shallow
kind: readme
title: Glacier Cloudflare deployment
created: '2026-11-04'
updated: '2026-11-06'
summary: Live Cloudflare website, local workflow and remaining release boundaries for glacierformac.com.
tags: [glacier, website, cloudflare]
---

# Glacier website deployment

Live: https://glacierformac.com/, deployed on 6 November 2026 to the existing
Cloudflare account using Workers Static Assets. HTTP redirects to HTTPS.
The GitHub repository remains private, and no app download is published.
This folder is the deployment source; it contains no account credentials.
The local checks below do not deploy it.

## Local source workflow

Run from this folder with Node.js and npm:

```sh
npm ci
npm run build
npm test
WRANGLER_SEND_METRICS=false npm run check:cloudflare
WRANGLER_SEND_METRICS=false npm run preview
```

The preview is `http://127.0.0.1:8280/`. With it running, a second terminal can run
`npm run check:http` to verify real asset responses and exact video byte ranges.
No login, upload or Cloudflare account mutation is needed for these checks.

`npm run package` creates `artifacts/glacier-cloudflare-LOCAL-READY.zip`, its SHA-256
file and an unpacked deployment folder. The ZIP includes its own `dist/`, Worker,
pinned npm dependency lock, configuration, public-file manifest and this guide.
It contains no Git history, backups, private receipts or earlier studies.

## Using the prepared ZIP

Extract the ZIP, enter `glacier-cloudflare/`, run `npm ci`, then use
`npm run preview` or `npm run check:cloudflare`. The ZIP is already built;
the source-only build/test/package commands above intentionally are not included.
Use the source folder for subsequent website edits and regenerate the ZIP.

## Public files and video

`scripts/build.mjs` uses an explicit allowlist. It copies only the selected
Glacier HTML, CSS, JavaScript, images, provider marks/notices and the finished
masked recording. The page becomes the domain root; recording URLs become
`media/recording-20261102/`. Media bytes are unchanged. `dist/` is the only
directory Wrangler uploads as public assets; worker/configuration files sit
outside it. Unknown paths return the branded 404, not the homepage.

`worker.mjs` handles only the two video paths. Cloudflare's asset service does
not supply partial responses itself; the Worker implements single byte ranges,
HEAD, unsatisfiable ranges and If-Range while preserving conditional responses.
Multiple or malformed ranges receive the complete file. The small bounded video
files make this simpler than adding an R2 account/storage dependency.
All other requests use static asset serving.

## Deliberately pending

- Keep the Glacier repository private until its later source release. Public
  links go to the labeled developer profile, and source and download remain
  marked coming soon. No local ad-hoc app archive is exposed from this site.
- Complete Apple signing/notarization and the real first-use checks before
  presenting an app download as ready.
- Future deployments use the authorized Cloudflare account and `npm run deploy`
  from this folder. The configuration declares only the apex domain; `www`
  is not configured.

Live verification passed for HTTPS, HTTP redirection, every exported asset,
excluded-file 404s, MP4/WebM full bytes and range responses, browser playback,
interactive examples and a 390-pixel mobile layout. The build manifest is a
local build artifact, not a live deployment status record. GitHub Actions are
disabled for this private setup stage; no hosted CI run is claimed.

The canonical URL, Open Graph URL/image and sitemap already target
`https://glacierformac.com/`. The public site has no analytics, forms, AI requests
or website-side credentials. Static response headers restrict scripts and media
to this origin while permitting the existing inline styling used by the demos.

## Why this arrangement

An allowlisted export prevents accidental publication of the experiment root.
Workers Static Assets follows Cloudflare's current new-project recommendation;
a small video-only Worker provides Safari-compatible ranges. Copying the whole
experiment directory, rewriting the site in a framework, and adding R2 solely
for these small videos were unnecessary.

References: [static assets](https://developers.cloudflare.com/workers/static-assets/),
[range limitation](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/#range-requests),
[selective Worker routing](https://developers.cloudflare.com/workers/static-assets/binding/#run_worker_first).
