---
id: 5cdf6bad51f3b8dd
alias: fresh win twice physical describe hub
kind: reference
title: Glacier demo media
created: '2026-11-04'
updated: '2026-11-05'
summary: Provenance and reproduction details for the public README media.
tags: [glacier, documentation, media]
---

# Demo media

These files reuse the existing Glacier website's selected artwork, native
onboarding capture and finished Mail/Express recording. No live provider calls
or new personal-data recordings were made for the README.

| File | Origin and purpose |
| --- | --- |
| `glacier-icon.webp` | Lossless derivative of `Assets/GlacierAppIcon.png`: the approved centered geometric Glacier icon. The app, onboarding resource and website use this same artwork. |
| `onboarding.png` | Actual native welcome capture with the centered geometric Glacier icon, also used by the website as `onboarding-welcome.png`. |
| `mail-express.mp4` | Finished 30.83-second website recording, unchanged from `omni-mail-express.mp4`. Includes captions, edited pacing and the existing personal-address mask. |
| `mail-express.gif` | 960-pixel-wide, 10 fps conversion of that complete recording. Approximately 2.1 MiB, with a 128-colour palette. |

The recording predates the Glacier rename and newer interface refinements.
It demonstrates the workflow, not pixel-for-pixel fidelity to the current
build. The source recording is deliberately retained as a sharper, controllable
alternative to the looping GIF. Embedded macOS/Mail interface artwork remains
attributable to Apple; it is not a Glacier endorsement or affiliation claim.
The repository license and third-party notices apply; this inventory is not a
separate rights-clearance assertion.

## Icon geometry

The 1024-pixel source has a clean transparent exterior and tile bounds
`(52, 52)–(972, 972)`. The mark's bounding box is `(215, 179)–(809, 845)`:
left/right margins are 163 pixels each, and top/bottom margins are 127 pixels
each. Bounds use exclusive right/bottom coordinates. Website and onboarding
derivatives preserve this source alpha and padding without an additional mask.

`Assets/GlacierAppIcon.icns` is the platform-specific export. It preserves the
mark's proportions and balanced margins within the tile, but uses the conventional
macOS rounded enclosure: an 832-pixel tile centered in a 1024-pixel canvas.
This avoids macOS Tahoe placing the already-framed artwork inside a second gray
tile. The website and native onboarding continue to use the approved PNG geometry.

The corresponding platform raster is retained at
`Assets/GlacierAppIcon-macOS.png`. Its preparation removes the source's outer
52-pixel transparent frame, retains the glacier artwork and its margin ratios,
and uses a rounded rectangle with radius 224 at a 1024-pixel working size before
scaling the tile to 832 pixels and centering it with 96 pixels of transparent
padding. This enclosure adjustment is specific to the system app-icon export.

Recreate the ICNS from that checked-in platform raster from the repository root:

```sh
uv run --no-project --with pillow==13.0.0 python -c 'from PIL import Image; Image.open("Assets/GlacierAppIcon-macOS.png").save("Assets/GlacierAppIcon.icns", format="ICNS")'
```

The export was verified through macOS 26.6.2's system icon renderer. The native
PNG remains inspectable on older macOS; an older-OS runtime check was not run.

## Reproduce the GIF

With FFmpeg installed, run from the repository root. Use a new output path if
comparing encodings; FFmpeg will ask before replacing an existing file.

```sh
ffmpeg -i docs/media/mail-express.mp4 \
  -filter_complex '[0:v]fps=10,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle' \
  -loop 0 docs/media/mail-express.gif
```

Keep the already-masked MP4 as the conversion input. Do not substitute an
unreviewed original recording. After a change, inspect frames at each caption
transition and the address region, check the entire animation, and update the
README's description if the workflow changes.
