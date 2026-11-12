# Architecture

How Sennsei is put together. For the wire protocol see [PROTOCOL.md](PROTOCOL.md); for how to build and test
see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Contents

- [Modules](#modules)
- [The gate: CommandCatalog and HeadsetSession](#the-gate-commandcatalog-and-headsetsession)
- [AppModel](#appmodel)
- [Scenes](#scenes)
- [Remote commands](#remote-commands)
- [Insights pipeline](#insights-pipeline)
- [Quitting](#quitting)
- [Concurrency rules](#concurrency-rules)

## Modules

Everything lives in one Swift 6 package, `Packages/HeadsetKit`. The dependency direction is one way:
surfaces, then the app core, then the headset kit, then the platform adapters. Only the headset kit ever
talks to the headphones.

```
                    SennseiApp (menu bar app, SwiftUI, App Intents, hotkeys)
                   /      |            \                       \
        SennseiCore   SennseiControl   HeadsetBluetooth   HeadsetSimulator
        (AppModel,    (Unix socket     (RFCOMM, SDP,      (simulated
         scenes,       server+client)   IOBluetooth)        headphones)
         insights)          |                 |                  |
              \        RemoteProtocol         |                  |
               \______ (typed commands) ______|                  |
                 \                            v                  v
                  \____________________>  HeadsetCore  <---------+
                                          (session, catalog, profile, EQ)
                                                |
                                           GaiaProtocol (frames)

   sennsei (SennseiCLI -> SennseiCLICore) --> SennseiControl --> RemoteProtocol
   SennseiProbe (probe, read-only by default)         --> HeadsetCore, HeadsetBluetooth
```

| Module | What it does | Depends on |
| --- | --- | --- |
| `GaiaProtocol` | Frame encoding, the streaming deframer, vendor ids. Pure functions. | nothing |
| `HeadsetCore` | `HeadsetSession` (actor), `CommandCatalog`, `CapabilityProfile`, firmware versions, Gen1 equalizer codec, the `HeadsetTransport` protocol, the probe plan. No UI, no Bluetooth. | `GaiaProtocol` |
| `HeadsetBluetooth` | `RFCOMMTransport` (IOBluetooth), SDP lookup and `GaiaServiceLocator`. | `HeadsetCore` |
| `HeadsetSimulator` | `SimulatedHeadset`, a transport that behaves like the headphones, for tests and `SENNSEI_DEMO=1`. | `HeadsetCore`, `GaiaProtocol` |
| `RemoteProtocol` | The commands a remote client may send, the JSON line format. There is deliberately no raw-command case. | nothing |
| `SennseiControl` | The Unix socket server (app side) and client (CLI side). | `RemoteProtocol` |
| `SennseiCore` | `AppModel`, scenes, the Insights pipeline, preset catalog, localized strings (`Localizable.xcstrings`), the quit coordinator. UI-free and testable. | `HeadsetCore`, `RemoteProtocol` |
| `SennseiApp` | The executable: menu bar panel, Insights and Shortcuts windows, App Intents, global hotkeys, screenshot renderer. | most of the above, `KeyboardShortcuts` 2.4.0 |
| `SennseiCLICore`, `SennseiCLI` | Argument parsing, output and the `sennsei` executable. Never touches Bluetooth. | `RemoteProtocol`, `SennseiControl` |
| `SennseiProbe` | A command line probe, read-only unless a maintainer write mode is selected, that records frames to a log (see CONTRIBUTING). | `HeadsetCore`, `HeadsetBluetooth` |

## The gate: CommandCatalog and HeadsetSession

`CommandCatalog` lists every frame that may be sent: vendor, id, name, direction (get or set), payload
length rule, firmware range and status (`verified`, `needsHardwareTest`, `blocked`). A frame that is not in
the catalog is refused; so is a blocked one, one outside its firmware range, one with a wrong payload length,
and a write while the session is read-only. This is enforced at run time in one place, not by convention.

`HeadsetSession` is an actor and the only thing in the app that talks to a transport. Its guarantees:

- Every outgoing frame passes `CommandCatalog.validate` first; a refused frame is never sent.
- Until the connection has produced a capability profile, the gate is in read-only mode, so nothing is
  written while connecting. Writes also require a writable profile: models other than the ACCENTUM
  (`ACAEBT...`) are read-only.
- The app builds its session with unverified writes off, so entries marked `needsHardwareTest` cannot be
  written.
- One operation at a time (a FIFO lock). A reply is matched to the single outstanding request; a late reply
  to a timed-out request is never taken for a later one. A read times out after 1.5 s.
- Every write is read back. A failed step stops the remaining writes, and the affected field becomes unknown
  rather than stale; a read-back that differs is reported and the device value is kept.

`CapabilityProfile` derives, from the model id and firmware, whether the model is writable, which equalizer
generation applies and which parameters it uses. An unknown model is not "allowed by default": it is
read-only.

## AppModel

`AppModel` is `@MainActor @Observable`, the single source of truth for every surface (panel, command line,
hotkeys, Shortcuts, scenes). Its rules:

- **State comes only from the session.** There are no optimistic updates; after an action, and after a
  failure, the state is re-taken from the session. If the session has no state, the link is gone.
- **Refresh first.** Before a write the headphones are re-read (reads only), because they can be changed with
  their own button or the official app. If the value is already what was asked, nothing is written.
- **One action at a time.** Actions run in call order under a single action lock; `busy` stays true until the
  last queued action is done. A scene is one action: its steps run under one hold of the lock and the first
  failing step aborts the rest.
- **Nothing writes on its own.** `start`, polling (every 60 s) and reconnecting only read. A write happens
  only from an explicit user action, or from a scene or automatic scene the user has set up.
- The equalizer step is skipped, not failed, when the equalizer is not available (wrong firmware, read-only
  model or audio mode not the equalizer mode); the scene reports "Equalizer skipped".

## Scenes

`Scene` is `id`, `name`, optional `noiseMode`, `pauseInTransparency`, `eqPreset`, and `triggers`. The only
trigger kind today is `frontApp` (a bundle id). `SceneStore` loads `scenes.json` and never writes: a missing
file gives the three defaults, a corrupt file gives the defaults and is left untouched. `SceneEngine` is pure:
it turns a scene into ordered steps (pause setting, noise mode, equalizer), matches the front app against
triggers (first scene in file order wins) and decides between `apply`, `restore` and `nothing`.

The automatic part, in `AppModel`:

- A front-app change is debounced for 1.5 s. Refresh, decision and writes then happen under one hold of the
  action lock.
- Applying an automatic scene snapshots the values it is about to change; when the app leaves the front, only
  those fields are restored, and only where the snapshot value was known. Going from scene A to scene B keeps
  the snapshot taken before A.
- Any manual action (panel, command line, hotkey, Shortcuts) bumps an epoch and pins the current front app:
  a decision made before it neither writes nor books anything, and the trigger of that app stays quiet until
  another app comes to the front.
- Turning automatic scenes on writes nothing; a lost connection forgets what was applied.
- The switch is stored in `UserDefaults` (`sennsei.automaticScenes`, off by default).

## Remote commands

`RemoteCommand` has seven cases: noise, pause, equalizer, scene, automatic scenes, status and ping. There is
no way to send a raw frame. `AppModel.run(_:)` is the single entry point and maps each command onto the same
user action the panel uses, so a command line request, a global hotkey and a Shortcuts action all take
exactly the same path and the same checks.

```
sennsei CLI --> SennseiControl client --(JSON line over unix socket)--> ControlServer
                                                                           |
Global hotkey (HotkeyCenter) ----------------------------------------> AppModel.run
Shortcuts action (App Intents) --------------------------------------> AppModel.run
                                                                           |
                                                          AppModel actions -> HeadsetSession -> gate -> transport
```

The socket is `~/Library/Application Support/Sennsei/control.sock`, in a directory made `0700`, with the
socket itself `0600`. The server checks the peer's uid against its own (`getpeereid`), reads at most one line
of 4096 bytes per request within a deadline, and removes the socket when it stops. A stale socket left by a
killed app is cleaned up on the next launch (a connect that is refused removes it). Responses carry an error
code (`notConnected`, `readOnly`, `unknownScene`, `unknownPreset`, `stateUnknown`, `eqUnavailable`, `failed`,
`badRequest`) that the CLI turns into an exit code.

A hotkey press while an action is running is dropped, never queued, so a held key cannot stack up writes.
App Intents wait up to 8 s for the connection, and send nothing if it never comes.

## Insights pipeline

```
CoreAudio process objects ──> AudioActivitySource ──┐
                                                    v
AppModel.insightsSnapshot (connected, noise mode, battery) ──> InsightsService (5 s tick)
                                                                      |
                                                              InsightsRecorder (pure)
                                                                      |
                                                              InsightsStore (SQLite)
                                                                      |
                                              InsightsQueries / InsightsViewState ──> InsightsView
```

- `CoreAudioActivitySource` (macOS 14.2 or later) lists processes that use audio and, for each, whether it
  runs output or input and which devices it uses, taking the **output scope** for "plays to the headphones".
  Processes inside a `.app` bundle map to their outermost app (so a browser helper counts as the browser).
  Below macOS 14.2 an unavailable source is used and only noise mode and battery are recorded.
- `InsightsService` ticks every 5 seconds while recording is on. It reads the audio source and the headphone
  snapshot, feeds the recorder, and appends what the recorder closes to the store. With recording off the loop
  does not run, the source is not read and the store is not touched.
- `InsightsRecorder` is pure (fake clock and fake source in tests): it merges samples into intervals per
  `(app, kind)`, bridges short gaps and drops excluded apps. A process with
  output and input both running is a call; listening and call are independent keys, so they may overlap.
  While the control link is down, recording pauses.
- `InsightsStore` is plain SQLite (the system library, no extra dependency) at
  `~/Library/Application Support/Sennsei/insights.sqlite` (file `0600`, directory `0700`, `secure_delete`
  on). Raw intervals are kept 90 days, then rolled into per-day summaries kept 12 months; noise and battery
  rows are kept 90 days.
- The view layer turns raw ids into readable names ("Safari & WebKit apps", "System sounds"); the row ids and
  the CSV keep the raw ids. CSV export is a user action through a save panel and neutralises spreadsheet
  formulas.

If a store write fails, the unwritten output stays in memory (bounded) and the service reports a degraded
state instead of stopping.

## Quitting

All quit paths (the panel's Quit, Cmd+Q, the Dock) end in `NSApp.terminate`. The delegate answers
`.terminateLater` and hands over to `QuitCoordinator`, which runs once, in this order: stop the control
socket (no remote command may arrive meanwhile), flush Insights (bounded), stop the headphone model (best
effort), then reply to AppKit. A run-loop timer in the common modes enforces a 3 second deadline, because it
is still serviced inside AppKit's nested terminate-later loop.

The rule that came out of a real hang: **never call `NSApp.terminate` from inside a main-actor task**. The
nested run loop would occupy the main-actor executor and the coordinator's own tasks could never run. Call it
synchronously from an event handler.

## Concurrency rules

- Swift 6 language mode, strict concurrency, and no warnings.
- UI and model state live on the main actor; the session is an actor; types crossing between them are
  `Sendable`.
- Anything that waits (a reply, a timer, a poll) suspends; the main actor is never blocked on hardware.
- Pure logic (frames, catalog, scenes engine, recorder, CSV) is kept free of I/O so tests need no hardware
  and run on any Mac.

### Why the code never calls `Task.sleep(for:)`

`Task.sleep(for:)` and `Clock.sleep` are generic, so each module that calls them emits its own weak copy and
the linker keeps one. A dependency compiled with other language features (KeyboardShortcuts 3.1.0 does this)
can emit a copy with a different async context size, and the linked app then aborts at the first sleep. Our
modules therefore wait through `Pause.sleep` (`HeadsetCore/Pause.swift`), which calls the non-generic
`Task.sleep(nanoseconds:)`; a test rejects the generic calls in the sources, and
`scripts/check-async-odr.py` runs after every release build in `Tools/app/build_app.sh` and fails the build
when any shared async specialization has diverging sizes.
