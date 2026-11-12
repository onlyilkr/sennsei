# Changelog

All notable changes to Sennsei are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.1.0] - Unreleased

First public release.

### Added

- Menu bar app for Sennheiser ACCENTUM headphones, with a panel showing the connection state and battery
  level (also in the menu bar).
- Noise control: ANC, Transparency and Off, and the "Pause music in Transparency" setting.
- Equalizer presets (Rock, Pop, Dance, Hip-Hop, Classical, Movie, Jazz, Flat) for firmware 2.12.0 up to, but
  not including, 3.16.4 ("Gen1"). Writing the equalizer on firmware 3.16.4 and later is not implemented.
- Scenes: Focus, Meeting and Travel by default, your own scenes in `scenes.json`, and automatic scenes that
  follow the front app (off by default; a manual action pauses them for the current app).
- The `sennsei` command line tool: `noise`, `anc`, `pause`, `eq`, `scene`, `auto`, `status [--json]`,
  `battery`, `doctor`, with documented exit codes, talking to the running app over a private local socket.
- Global keyboard shortcuts (cycle noise control, next equalizer preset, one per scene); none set by default.
- Shortcuts app actions: Apply Scene, Set Noise Control, Set Equalizer Preset, Get Battery Level.
- Insights: listening and call time per app, noise control share, daily hours and battery, stored only on this
  Mac, with a switch to turn it off, app exclusion, history deletion and CSV export.
- English and Turkish interface.
- A command gate (`CommandCatalog`) with a deny-list, firmware gates and a model check; nothing is written when
  connecting or polling. Read-only profiles for ACCENTUM Plus, MOMENTUM 4 and unknown models.
- A read-only probe (`Tools/probe`) for device reports, and a simulated headset (`SENNSEI_DEMO=1`).
- Release packaging: universal binary (arm64 and x86_64), ad-hoc signed, GitHub Releases zip with checksums,
  and a Homebrew cask.

### Known limitations

- Verified only on an ACCENTUM Wireless SE (firmware 3.12.14) with macOS 26 on Apple silicon: noise control, the
  pause setting, battery, Gen1 equalizer, manual and automatic scenes, `noise`/`status`/`doctor` from the command
  line, one global shortcut (cycle noise control) and Insights (headphone audio per app). The other CLI commands
  and the Shortcuts actions other than Get Battery Level were tested against the simulator only.
- The Intel slice has not been tested on an Intel Mac.
- Ad-hoc signed, not notarized; macOS asks for the Bluetooth permission again after every update.
