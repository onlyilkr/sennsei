# Protocol notes

What Sennsei knows about the control channel of Sennheiser ACCENTUM headphones, and how much of it is
verified. Everything here comes from the code in this repository, from third-party protocol notes (see the
Credits in the README) and from sessions with one pair of headphones: an **ACCENTUM Wireless SE (model ID `ACAEBT SE`), firmware 3.12.14**, on macOS 26. Where a
statement rests on less than that, it says so.

These notes describe an unofficial, reverse-engineered channel. Sennsei is not affiliated with or endorsed
by Sennheiser; names are used only to identify the compatible product. No code, files or data from the official
app are in this repository.

## Contents

- [Transport](#transport)
- [Frame format](#frame-format)
- [Finding the channel](#finding-the-channel)
- [Session procedure](#session-procedure)
- [Commands](#commands)
- [Noise control model](#noise-control-model)
- [Equalizer](#equalizer)
- [Firmware gates](#firmware-gates)
- [Commands that are never sent](#commands-that-are-never-sent)
- [Recorded frames](#recorded-frames)

## Transport

The headphones expose a Qualcomm GAIA v3 control channel over Bluetooth Classic RFCOMM. There is no
authentication on this channel: anything that can open it on a paired, connected device can talk to the
headphones. That is why every outgoing frame in Sennsei goes through one gate, the
[`CommandCatalog`](ARCHITECTURE.md#the-gate-commandcatalog-and-headsetsession).

Two vendor identifiers appear in frames: Sennheiser `0x0495` for the headphone features, and Qualcomm
`0x001D` for the generic GAIA commands (only used in the deny-list).

## Frame format

```
FF 03 00 <len> <vendor:2, big-endian> <command:2, big-endian> <payload: len bytes>
```

| Byte | Meaning |
| --- | --- |
| 0 | Start byte `FF` |
| 1 | GAIA version `03` |
| 2 | Flags, always `00` in every frame seen; a frame with another value is dropped by the deframer |
| 3 | Payload length (0 to 254) |
| 4-5 | Vendor ID |
| 6-7 | Command ID. Bits 7 and 8 carry the frame kind (below) |
| 8... | Payload |

The kind of a frame is `(command >> 7) & 3`:

| Kind | Command bits | How it is formed |
| --- | --- | --- |
| Request / command | `00` | the base command, for example `1A05` |
| Notification | `01` | base `\| 0x0080`, for example `1A85` |
| Response | `10` | base `\| 0x0100`, for example `1B05` |
| Error | `11` | base `\| 0x0180` |

A reply is matched to its request by `(vendor, command & ~0x0180)`. The deframer reassembles frames from an
arbitrarily chunked byte stream and re-synchronises on the next `FF` after garbage.

## Finding the channel

The RFCOMM channel number is not fixed and is never hard-coded. Sennsei asks the paired, already connected
device for its SDP records and picks the record whose `ServiceClassIDList` contains

```
a2129ff3-081b-4c45-8afe-469d9c4842ec
```

On the verified headphones that record is on RFCOMM channel 15 (the UUID arrives as a single element, not as
a list). A second record, on channel 14, is Apple's iAP2 accessory service (UUID
`00000000-deca-fade-deca-deafdecacaff`). Other projects report that sending a GAIA frame to the iAP2 channel switches the
headphones off (unverified, from third-party reports; not tried here), so a record that lists the iAP2 UUID is never treated as GAIA, and Sennsei never falls
back to a service name, a record position or a channel number (newer macOS versions do not return the service
name at all). If no record qualifies, opening fails with "GAIA service not found".

Opening times out after 8 seconds; the SDP query after 10 seconds. The device is found by its paired name
(`ACCENTUM` by default; override with the `SENNSEI_DEVICE_NAME` environment variable) and must already be
connected to the Mac. Sennsei does not connect the headphones for you.

## Session procedure

1. Query SDP, pick the GAIA channel, open it.
2. Read `1201` (firmware) and `1206` (model ID); derive the capability profile from the model and firmware.
3. Read battery, ANC and transparency switches, and the audio mode.
4. For firmware that has the Gen1 equalizer on a writable model, read the equalizer (reads only).
5. Poll the status fields (reads only) every 60 seconds. There is no keep-alive. Two failed polls in a row
   mean the link is lost; Sennsei shows that and offers **Reconnect** (it does not reconnect by itself).

**Nothing is written while connecting, polling or reconnecting.** Until the profile is known, the gate only
lets reads pass. A read times out after 1.5 seconds.

## Commands

The table lists the commands in `CommandCatalog.standard`. "Catalog status" is the status in the code:
`verified` (exercised on the headphones and observed to behave), `needsHardwareTest` (read-only commands whose
answers were recorded but not studied further, or commands never sent on hardware), `blocked` (never sent).
"Used by Sennsei" says whether the shipped app sends it. All ids are hexadecimal, vendor `0495` unless noted.

| Id (get / set) | Name | Payload | Catalog status | Used by Sennsei |
| --- | --- | --- | --- | --- |
| `1201` | firmware version | 3 x u16 (major, minor, patch) | verified | read on connect |
| `1206` | model ID | ASCII, NUL-terminated | verified | read on connect |
| `0603` | battery | 1 byte, percent, observed in steps of 10 (design notes; one sample recorded) | verified | read |
| `0602` | charging state | 2 bytes; the second is non-zero while charging | needsHardwareTest | read |
| `0800` | codec | 1 byte (`01` = AAC on the verified unit) | verified | read |
| `081A` | sample rate | u32 Hz; firmware 3.12.0 or later | needsHardwareTest | probe only |
| `0804` | audio mode | u16; `0001` = user equalizer on the verified unit | needsHardwareTest | read |
| `0803` | set audio mode | 2 bytes | needsHardwareTest | **never** (see below) |
| `1A05` / `1A04` | ANC switch | 1 byte, 0 or 1 | verified | read / write |
| `1805` / `1804` | transparency switch | 1 byte, 0 or 1 | verified | read / write |
| `1801` / `1800` | pause music when Transparency starts | 1 byte, 0 or 1 | verified | read / write |
| `1A01` | noise mode table | 3 x (mode, state) pairs | needsHardwareTest | probe only |
| `1A03` | noise level | 1 byte | needsHardwareTest | probe only |
| `0806` / `0805` | sidetone | 1 byte | needsHardwareTest | probe only (read) |
| `0601` / `0600` | auto power-off | read: 1-byte mode, answer 3 bytes | needsHardwareTest | probe only (read) |
| `0802` / `0801` | voice prompts | 1 byte | needsHardwareTest | probe only (read) |
| `1400`, `1401`, `1404`, `1407`, `1409` | paired device list, own index, link limit | index-based | needsHardwareTest | probe only (read) |
| `1402` | connect a paired device | 1 byte index | needsHardwareTest | never |
| `0007` | register for notifications | 1 byte | needsHardwareTest | never (the app polls instead) |
| `1007`, `1005`, `1003` | Gen1 equalizer reads | see [Equalizer](#equalizer) | needsHardwareTest | read |
| `1002`, `1006`, `1004` | Gen1 equalizer writes | see [Equalizer](#equalizer) | verified | write |
| `1000`, `1002`, `1003`, `100B`, `1009` | Gen2 equalizer reads | firmware 3.16.4 or later | needsHardwareTest | never (no such firmware here) |
| `1001`, `1008` | Gen2 equalizer writes | firmware 3.16.4 or later | needsHardwareTest | **not implemented** |

Observations from the verified unit that are recorded but not used by any feature: sidetone `1`, auto
power-off mode 0 and duration 0, voice prompts `2` (tone and voice), four paired devices with this Mac at
index 2 and at most two simultaneous links, sample rate 44100 Hz while connected over AAC. The unit of the
auto power-off duration was not determined (the value was 0), and whether wind-noise reduction exists on this
model is **not verified** (`1A01` answers with a three-entry table, all entries 0, but which entry is which
was not confirmed). Sennsei exposes none of these.

The paired-device answers contain Bluetooth names and addresses; in `Fixtures/` those bytes are masked with
asterisks, keeping only the first three bytes (index, priority, status).

## Noise control model

ANC and transparency are two independent switches, `1A05` and `1805`. The first model Sennsei assumed
(mutually exclusive switches) was **wrong**, and the first hardware click showed it: after one
`1804 [01]` write the read-back was ANC = 1 and transparency = 1. The headphones keep the ANC switch on when
transparency is turned on.

What Sennsei does with the two flags:

- Reading: transparency on means **Transparency** (it wins), else ANC on means **ANC**, else **Off**. If
  either flag is unknown, the mode is unknown and nothing is written.
- Writing **Transparency**: `1804 [01]`, unless it is already on.
- Writing **ANC**: if transparency is on, `1804 [00]` (the ANC switch is left alone; if it then reads off, the
  read-back mismatch is reported); otherwise `1A04 [01]` if ANC is off; otherwise nothing.
- Writing **Off**: `1804 [00]` if transparency is on, then `1A04 [00]` if ANC is on, inside one operation with
  no other frame in between.
- Every write is followed by a read-back; a mismatch is reported and the device value wins.

Verified on the unit by hand, with music playing: ANC to Transparency, Transparency to ANC, ANC to Off, and
Off from the combined (both flags on) state. Switching to Transparency made the headphones pause the music,
which is their own "pause music when Transparency starts" setting (`1801`); Sennsei's panel switch writes it
(`1800`) and was verified both ways. The noise level (`1A03`) stayed at 100 after Off and had no audible
effect; Sennsei never writes it, and the level command (`1A02`) is not in the catalog.

## Equalizer

Two generations exist, chosen by firmware:

| Firmware | Generation | Sennsei |
| --- | --- | --- |
| below 2.12.0 | none | not available |
| 2.12.0 up to (not including) 3.16.4 | Gen1 | **read and write**, verified on 3.12.14 |
| 3.16.4 and later | Gen2 | **not implemented**; tracked in the issue tracker |

The same ids mean different things in the two generations: `1002` writes the equalizer on Gen1 and reads a
band gain on Gen2, `1003` reads on both. The catalog therefore holds two specs for those ids with disjoint
firmware ranges (`2.12.0 <= fw < 3.16.4` and `fw >= 3.16.4`), and a firmware outside both is refused.

The Gen1 equalizer encoding follows protocol facts from the unlicensed xndbogdan/sennheiser-control notes (facts
only, no code or data copied) and was verified on an ACCENTUM Wireless SE by reading the settings back from the
headphones. One detail of that read-back: the headphones report each shelf step one unit (1/60 dB) smaller than
the encoder writes (-239 for -240, -359 for -360); the unit test accepts a difference of 1 there and nothing more.

Gen1 in short (the five UI bands are 50, 250, 800, 3000 and 8000 Hz, gain range plus or minus 6 dB in 0.1 dB
steps; the headphones' own filter model is a master gain plus four shelving filters at 125, 400, 1600 and
5000 Hz, with a level shift to avoid clipping):

- The five gains are encoded into one `1002` write (a list of 16-bit words), a level shift `1006` (one signed
  byte, dB x 10) and a knob value `1004 [0001, value]` (`0x4000` marks the newer storage format, `0x1000` adds
  the bass boost flag). Order: `1002`, `1006`, `1004`.
- Read back with `1007` (level shift), `1005 [0001]` (knob), and two `1003` queries (gains, filter types).
  Sennsei trusts the equalizer only after all four answers arrived and match the write.
- The ACCENTUM has no headroom margin, so a preset that raises a band lowers the overall level by roughly
  that amount (`6,0,0,0,-6` gave a level shift of -6.0 dB). That is expected.
- Presets are not stored on the headphones; Sennsei writes five gains each time. The built-in presets (dB)
  are Rock `0 0 3 3 -1`, Pop `0 -5 0 5 0`, Dance `2 -3 -3 1 1`, Hip-Hop `3 -1 -4 2 0`, Classical `0 0 0 1 2`,
  Movie `0 0 2 2 -1`, Jazz `-3 0 2 2 0` and Flat `0 0 0 0 0`. The panel highlights a preset only when the
  gains read from the headphones match it within 0.11 dB.
- An equalizer that was never set up (filter types for bands 3 and 4 read 0) is not written on connect; the
  first user change writes it.

Verified on the unit: flat written and read back exactly; `+4 dB` bass; `6,0,0,0,-6` (the sound changed, as
reported by the tester); restore to flat; presets Rock and Flat from the app. Not verified: what happens if
the headphones switch to another device in the middle of a write, and whether an interrupted write can always
be undone. Filter type `11` is assumed to be a high shelf; it matched what the official app wrote, but that is
an inference.

The equalizer is only audible, and only offered, when the audio mode is already the equalizer mode (`0804`
reads `0001`). Sennsei does not switch the audio mode itself (next section).

## Firmware gates

Every catalog entry may carry a minimum firmware and an exclusive maximum. A frame is refused when the
connected firmware is outside its range, and with an unknown firmware only entries without any bound apply.
The gates in use: sample rate from 3.12.0, Gen1 equalizer from 2.12.0 and below 3.16.4, Gen2 equalizer from
3.16.4. Sennsei **never flashes firmware**: the firmware update commands are on the deny-list, and the way to
update is the official Smart Control Plus app. Reading the version only decides which features are offered.

## Commands that are never sent

`CommandCatalog` rejects these in every mode, whatever else shares their id; a unit test pins each one.
(`blocked` always wins over an entry with the same id.)

| Id | Why |
| --- | --- |
| `0040` | factory reset, deletes pairings |
| `1403`, `1405`, `1406` | disconnect a paired device (reported to have deleted a pairing on older firmware, not tried here), delete a pairing, wipe the list |
| `0200`, `0201`, Qualcomm `0C00`-`0C02` | firmware update (DFU) |
| `0607`, `0613`, `0685` | take the headphones offline until a power cycle, reset the control link |
| `1600`, `1604` | write or reset the touch map |
| `0817` | low latency mode, blocked as a precaution (side effects unknown) |
| Qualcomm `000D` | transport parameter, changes the framing |
| Qualcomm `0009`, `000A` | data transfer |
| Qualcomm `0803`, `0804` | read or clear the panic log |
| Qualcomm `0601` | voice assistant |

There is no id range scan, and no raw-frame entry point: the remote protocol only has typed commands.

### Why `0803` (audio mode) is not sent

`0803 [00 01]` selects the user-equalizer audio mode. The Gen1 write path was designed to send it when the
mode is something else, and the simulator and the tests model it. But it was **never verified on the
headphones**, because the verification unit was already in that mode. It is therefore marked
`needsHardwareTest`, and the app builds its session with unverified writes off, so the gate refuses it before
a byte goes out. In practice: the app never sends `0803`; with another audio mode set in Smart Control Plus,
the panel says to switch to Equalizer there. The only code that can enable unverified writes is the
maintainer verification modes of `SennseiProbe` (`SENNSEI_MODE=eq1-write` and `eq1-restore`); they need
explicit environment variables and are not part of the app. `eq1-write` and `eq1-restore` write the equalizer and
will send `0803` if the headphones are not in the Equalizer audio mode. `eq1-read` and `dump-sdp` are read-only.
Do not use the write modes.

## Recorded frames

`Fixtures/accentum-3.12.14-20261111-013741.jsonl` is a read-only probe log (26 frames; no write command was
sent). Each line has the request (`tx`) and the replies (`rx`) in hex. A few, annotated:

```
tx ff03000004951201                 request firmwareVersion (1201), no payload
rx ff030006 0495 1301 0003 000c 000e   response (1201 | 0100 = 1301): firmware 3.12.14

tx ff03000004950603                 request batteryLevel
rx ff030001 0495 0703 14            response (0603 | 0100 = 0703): 0x14 = 20 %

tx ff03000004951a05                 request ancEnabled
rx ff030001 0495 1b05 01            ANC on
tx ff03000004951805                 request transparencyEnabled
rx ff030001 0495 1905 00            transparency off

tx ff03000004950804                 request audioMode
rx ff030002 0495 0904 0001          audio mode 1 (user equalizer)

tx ff03000004951206                 request modelID
rx ff03000a 0495 1306 41434145425420534500   "ACAEBT SE" + NUL
```

The paired-device entries in the same file are masked, for example
`ff030014 0495 1501 00 01 00 ***...`: index, priority and status stay, name and address are asterisks.

The Gen1 equalizer results are in `Fixtures/eq1-*.json` (snapshots, writes and restores, each with the state
before and after). For example, `eq1-write-20261111-143122.json` records the write of gains `6,0,0,0,-6`: read
back as gains `[6, 0, 0, 0, -6]`, bass boost off, level shift `-60` (= -6.0 dB x 10), knob `16384`
(`0x4000`), filter types all `11`.

A frame you could build from the format above (constructed, not taken from a log): writing the
transparency switch on is `ff0300010495180401` (`FF 03 00`, length 1, vendor `0495`, command `1804`,
payload `01`).
