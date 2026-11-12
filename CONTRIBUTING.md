# Contributing

Thanks for taking an interest. Contributions of any size are welcome, typo fixes and bug reports included.
Please be kind and assume good faith in every discussion.

## The most useful thing you can contribute

1. **Device reports from other headphones.** Sennsei is verified on exactly one pair of headphones (ACCENTUM
   Wireless SE, firmware 3.12.14). A read-only probe run on another Sennheiser, or another Qualcomm GAIA
   headphone, tells us what the device reports and decides what could be supported. See
   [Device reports](#device-reports).
2. **Intel Mac testing.** The x86_64 slice is built but nobody has run the app on an Intel Mac. Tell us what
   happens, even if everything works.
3. **macOS 14 and 15.** Only macOS 26 on Apple silicon has been used so far. Reports from Sonoma and Sequoia
   are valuable (Insights needs 14.2 or later).
4. **Gen2 equalizer writing** for firmware 3.16.4 and later. It needs someone with such firmware and
   patience; see the Gen2 equalizer [issue #1](https://github.com/onlyilkr/sennsei/issues/1).

## Getting set up

You need a Mac with macOS 14 or later and Xcode (the build uses Xcode's `appintentsmetadataprocessor`; the
Command Line Tools alone are not enough). The only dependency is
[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts), pinned to 2.4.0.

```sh
git clone https://github.com/onlyilkr/sennsei.git
cd sennsei
make check    # unit tests, release build of the app, command line smoke test
make docs     # README and documentation checks (needs the build from make check)
```

| Target | Does |
| --- | --- |
| `make build` / `make test` | `swift build` / `swift test` for `Packages/HeadsetKit` |
| `make check` | tests, a release build of the app, and a smoke test of the `sennsei` tool |
| `make docs` | `scripts/check-docs.sh`: README covers every CLI command and exit code, local links resolve, no forbidden strings |
| `make app` | `build/Sennsei.app` and `build/sennsei` for your Mac's architecture, ad-hoc signed |
| `make preview` | regenerates the README images from invented sample data |
| `make dist VERSION=x.y.z` | release zip, checksums and cask in `dist/`, nothing published |

`make check` never launches Sennsei.app. If a copy happens to be running on your Mac, the smoke test notices
and expects `sennsei status` to succeed instead of failing with exit 3.

Layout and how the parts fit: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The wire protocol:
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Device reports

The probe's default run is **read-only**: it connects to headphones that are already connected to the Mac,
asks which services and settings they report, and writes a log. It sends only the fixed list of read commands
in `ProbePlan` and never changes a setting. It stays read-only only while `SENNSEI_MODE` is unset (or is
`eq1-read` or `dump-sdp`): the modes `eq1-write` and `eq1-restore` WRITE to the headphones (see the end of
this section).

1. Connect the headphones to your Mac and quit Sennsei (only one program can hold the control channel).
2. From a clone of the repository: `bash Tools/probe/run_probe.sh`. It builds the probe, wraps it in a small
   signed app (the Bluetooth permission belongs to an app bundle, not a terminal), runs it and prints the
   path of the log, inside `~/Library/Application Support/Sennsei/probe`. macOS asks for Bluetooth permission
   for `SennseiProbe` the first time.
3. If your headphones are not called `ACCENTUM` in Bluetooth settings, run it with
   `SENNSEI_DEVICE_NAME="Your Name" bash Tools/probe/run_probe.sh`.
4. Open a [device report](https://github.com/onlyilkr/sennsei/issues/new?template=device_report.yml) issue and
   paste what the script printed, and the contents of the log file (attach it if it is long), after redaction.

**Redact before you post.** The log contains your headphones' Bluetooth address and name, and the list of
paired devices (names and addresses of your phone and computers). Replace every Bluetooth address with
`XX:XX:XX:XX:XX:XX`, remove device names and serial numbers, and check for your user name in paths. If in
doubt, leave it out.

The probe's modes `eq1-read` and `dump-sdp` are read-only, and so is the default run (`SENNSEI_MODE` unset).
The write modes (`SENNSEI_MODE=eq1-write`, `eq1-restore`) WRITE to the headphones: they change the equalizer,
can send the audio mode command (`0803`), and are maintainer-only. Do **not** set `SENNSEI_MODE` to
`eq1-write` or `eq1-restore`.

## Code rules

- **Tests never touch hardware.** Anything that needs headphones is tested against `SimulatedHeadset`, and
  anything you could only try on real headphones should be tried by hand and said so in the pull request.
  Tests must also not touch the running app, its socket or your real Application Support folder; use
  temporary directories.
- **Every write path goes through `CommandCatalog`.** A new command is added to the catalog with its payload
  rule, firmware range and status, as `needsHardwareTest` until it has been tried on a real device. Nothing
  may write while connecting, polling or reconnecting. Do not add a way to send raw frames. The deny-list
  entries stay denied.
- **User-visible strings** live in `Localizable.xcstrings` with English and Turkish; a test fails when a key
  is missing in either language. No sentence is assembled from pieces in code.
- **Swift 6 language mode, strict concurrency, no warnings.** UI and model state on the main actor, the
  session as an actor, no blocking on the main actor, and no `NSApp.terminate` from inside a main-actor task
  (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#quitting)).
- **Wait with `Pause.sleep`, never `Task.sleep(for:)`.** The generic stdlib call can clash with a dependency
  at link time and crash the app (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#why-the-code-never-calls-tasksleepfor)).
  `make check` runs an ODR guard (`scripts/check-async-odr.py`) that fails on such mismatches.
- The app makes no network requests and runs no shell commands; a change that adds either needs a very good
  reason and a note in [SECURITY.md](SECURITY.md).

## Pull requests

- Keep a pull request to one thing, and describe what and why.
- `make check` and `make docs` must pass. CI runs both.
- Update the README and [CHANGELOG.md](CHANGELOG.md) when behaviour changes. If the panel changed, run
  `make preview` and commit the new images.
- Keep personal data out of everything you commit: tests, fixtures, docs and logs. That means Bluetooth
  addresses and device names (mask them as the files in `Fixtures/` do), serial numbers, and local paths.
- By contributing you agree that your work is released under the [MIT license](LICENSE).

## Security problems

Do not open a public issue. See [SECURITY.md](SECURITY.md).
