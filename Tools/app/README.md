# Sennsei app

An unofficial macOS menu bar app to control Sennheiser ACCENTUM headphones' settings (noise control,
equalizer presets) from macOS. Sennsei is not affiliated with, endorsed or supported by Sennheiser or
Sonova; the name does not imply any affiliation.

## Build

```sh
bash Tools/app/build_app.sh
```

This builds the release binary, assembles `build/Sennsei.app` (including the SennseiCore
resource bundle in `Contents/Resources`), signs it ad hoc and prints the path. It does not launch the app.

The same script also builds the `sennsei` command line tool to `build/sennsei`. It is a separate
file and is not part of `Sennsei.app`.

## Command line tool

`build/sennsei` controls the running app through its local control socket (it never talks to
Bluetooth itself). Start the app first.

```sh
build/sennsei noise anc          # anc | transparency | off | next
build/sennsei anc on             # shortcut for noise anc (off = noise off)
build/sennsei pause on           # pause playback in Transparency mode
build/sennsei eq "Bass Boost"    # preset name, or next
build/sennsei scene focus
build/sennsei auto off
build/sennsei status [--json]
build/sennsei battery            # percentage, or "unknown"
build/sennsei doctor             # read-only connection checks
```

Exit codes: 0 success, 1 command failed, 2 usage error, 3 Sennsei is not running, 4 timed out.
Results go to stdout, errors to stderr.

## Run

```sh
open build/Sennsei.app
```

- Demo mode (no headphones needed): `open --env SENNSEI_DEMO=1 build/Sennsei.app`
- Pick a specific device by name: `open --env SENNSEI_DEVICE_NAME="<name>" build/Sennsei.app`
- `open` does not pass your shell environment to the app, so use `--env` as above. Running
  `build/Sennsei.app/Contents/MacOS/SennseiApp` directly does pass it, but then the Bluetooth permission
  attaches to the terminal instead of the app.
- Turkish UI: `open build/Sennsei.app --args -AppleLanguages '(tr)'`

## Bluetooth permission

macOS grants the Bluetooth permission to the .app, not to a terminal. The ad-hoc signature changes
with every build, so macOS may ask for permission again after a rebuild.

## Known limits

- No EQ editor and no scenes yet.
- Writing the EQ on Gen2 devices is not supported.
- Controls are only available for the ACCENTUM.
