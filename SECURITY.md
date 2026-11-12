# Security policy

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub Security Advisories:
[Report a vulnerability](https://github.com/onlyilkr/sennsei/security/advisories/new). This works once
private vulnerability reporting is enabled for the repository (see [RELEASING.md](RELEASING.md)). Do not open
a public issue or pull request for a security problem.

Include the Sennsei version (`sennsei --version`), your macOS version, what you did and what happened.
Redact personal data: your user name, Bluetooth addresses and device names. You can expect an
acknowledgement within a few days; this is a small volunteer project, so there is no formal SLA.

## What the app touches

Knowing this helps judge whether something is in scope.

| Where | What | How |
| --- | --- | --- |
| `~/Library/Application Support/Sennsei/` | The app's own folder | Created with mode `0700` (tightened if it exists) |
| `.../Sennsei/control.sock` | Unix socket for the `sennsei` tool | Mode `0600`; connections from other users are refused (peer uid check); one request line of at most 4096 bytes; removed on quit, a stale one is removed on the next launch |
| `.../Sennsei/scenes.json` | Your scenes | Read only; the app never writes or repairs it; an invalid file means the defaults are used |
| `.../Sennsei/insights.sqlite` | Insights database | Created `0600`; written only while recording is on; bundle id, app name, route, times, noise mode, battery; deleted from the app on request; `secure_delete` on |
| `.../Sennsei/probe/` | Probe logs | Written only when you run `Tools/probe/run_probe.sh`; contain Bluetooth addresses, redact before sharing |
| Defaults domain `io.github.onlyilkr.sennsei` | Settings | Automatic scenes switch, Insights recording switch, excluded apps, recorded global shortcuts |
| Bluetooth RFCOMM to the headphones | Control channel | Only to a paired device that is already connected, found by name; only frames that pass `CommandCatalog`; nothing is written when connecting or polling |
| CoreAudio, read only | Which processes play audio to which device | Process and device property queries for Insights (macOS 14.2+); nothing is recorded or changed in the audio system |
| Front application, read only | Bundle id of the app in front | For automatic scenes; not stored |
| CSV export | A file you choose | Written only through a save panel you confirm; fields that start like a spreadsheet formula are neutralised |

### What it never does

- It makes **no network requests**: no update check, no analytics, no crash reporting.
- It does **not flash firmware** and never sends the factory reset, pairing deletion or update commands;
  these are on a deny-list that the tests pin.
- It does **not run shell commands** or other programs.
- The app never sends the audio mode command (`0803`) and has no way to send a raw frame.
- It does not read window titles, URLs or the content of anything.

## Scope

In scope:

- Anything that makes the app write to the headphones when the user did not ask, or send a command outside
  the catalog (including a way past the deny-list, the firmware gates, or the read-only mode of other
  models).
- The control socket: access from another user, a request that does more than the documented command set,
  path or symlink tricks, an oversized or malformed request that hangs or crashes the app.
- Data written outside `~/Library/Application Support/Sennsei` and the app's defaults, or with looser
  permissions than listed above.
- Leaking Insights data (a path, a file mode, a CSV that executes in a spreadsheet).
- Supply-chain issues in the release pipeline (unpinned actions, a tampered checksum or cask).

Out of scope: problems that need an attacker who already controls your user account, the fact that anything
nearby that can pair with the headphones can use their unauthenticated control channel (that is how the
headphones work), and bugs that only affect the ad-hoc signature or notarization status (these are documented
limitations).

## Supported versions

Only the latest release receives fixes.
