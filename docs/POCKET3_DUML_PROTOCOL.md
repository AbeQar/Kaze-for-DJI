# Pocket 3 DUML Protocol Reference

**Updated:** 2026-08-21
**Scope:** DJI Osmo Pocket 3 direct BLE/Wi-Fi session, transport, gimbal, telemetry,
camera state, and direct live-view behavior established by the Kaze for DJI project.

This is an unofficial reverse-engineered reference. It is not DJI documentation,
does not imply DJI support for third-party use, and must not be assumed to apply
unchanged to other DJI camera models or firmware revisions.

For the larger camera-settings tables, see:

`CAMERA_SETTINGS_PROTOCOL.md`

Machine-readable regression fixtures shared by the iOS and Android implementations
are in:

`../protocol/test-vectors/`

## Evidence labels

- **PHYSICALLY_CONFIRMED** — exercised against a real Pocket 3 and the physical
  result matched.
- **CAPTURE_CONFIRMED** — directly identified from controlled DJI Mimo traffic.
- **SOURCE_CONFIRMED** — present in an upstream/reference implementation and
  successfully used as part of the proven Pocket 3 path.
- **IMPLEMENTATION_CORROBORATED** — independently reproduced in current code or
  locked by exact regression vectors; this does not by itself promote a behavior
  to physical confirmation.
- **STRONGLY_IDENTIFIED** — capture correlation is strong, but a dedicated isolated
  physical confirmation is still desirable.
- **OBSERVED** — seen in traffic/device behavior but not yet fully mapped.
- **INFERRED** — interpretation is supported by evidence but not yet a protocol fact.
- **UNVERIFIED** — insufficiently established for production control.
- **UNSAFE** — known bad/unsafe experiment; do not send.

Unknown bytes and bit fields should remain unnamed until stronger evidence exists.
An accepted command is not automatically evidence that the assumed semantic meaning
is correct.

---

# 1. Network and transport

## Endpoints

| Item | Value | Status |
|---|---|---|
| Pocket 3 IP / gateway | `192.168.2.1` | PHYSICALLY_CONFIRMED |
| TCP bootstrap / poke | `7001` | PHYSICALLY_CONFIRMED |
| UDP datalink | `9004` | PHYSICALLY_CONFIRMED |

The proven direct-session sequence begins with a TCP/7001 poke, then establishes
the DJI UDP/9004 datalink.

A successful UDP handshake alone is **not** sufficient to declare the session
healthy. A working command path, fresh camera traffic, and sane transport-window
state are also required.

## UDP datagram layout

Pocket 3 UDP datagrams use:

```text
[8-byte transport header]
[12-byte routing header]
[DUML frame or media payload]
```

Established behavior:

- non-zero outgoing transport sequence numbers advance in steps of **8**
- initial outgoing sequence is synchronized from the camera channel
- proven initialization uses `nextTx = cameraChannel + 8`
- `pktType 0x05` carries outgoing DUML command traffic
- `pktType 0x02` carries direct live-view media fragments
- `pktType 0x03` is tracked as a separate receive window
- `pktType 0x04` is the app's ACK/window-status packet
- incoming `pktType 0x01` carries camera transport/window status
- the outgoing routing header must advertise the camera's actual ACK cursor for
  the app TX stream rather than assuming `currentSeq - 8`
- one serialized transport owner should control UDP receive/send and all sequence,
  routing, and ACK-window mutation

A useful implementation health metric is:

```text
txLagSlots = ((lastTx - peerAckTx) & 0xffff) / 8
```

This is implementation diagnostics, not a DJI-defined health threshold.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED for the working Pocket 3
transport behavior.

## `pktType 0x04` ACK payload

The known-good app ACK packet is 34 bytes total with a 26-byte payload:

```text
group 1: [rxType2:u16][rxType2:u16][00000000]
group 2: [rxType3:u16][rxType3:u16][00000000]
group 3: [peerAckTx:u16][lastTx:u16][00000000]
trailing: 00 00
```

The shared regression vectors preserve an exact representative payload.

---

# 2. DUML framing

Kaze for DJI uses DJI DUML frames inside the transport described above.

The current implementations preserve:

- DUML CRC8 header validation
- DUML CRC16 frame validation
- short-frame scanning and rejection of malformed frames
- command set / command id decoding
- target/source addressing
- request/reply command flags

Exact encoder/decoder fixtures are stored under:

```text
protocol/test-vectors/
```

Do not infer command meaning solely from a valid CRC or an accepted reply.

---

# 3. BLE to Wi-Fi handoff

## GATT

| Item | Value | Status |
|---|---|---|
| Service | `FFF0` | SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED |
| Relevant characteristics | `FFF3`, `FFF4`, `FFF5` | SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED |
| Notifications | `FFF4` and `FFF5` | SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED |
| Pair-arm write | `FFF4 <- 01 00` | SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED |

The working flow subscribes to the relevant notifications before sending the
pair/wake sequence.

## `00/2B` — BLE session wake

```text
cmdSet/cmdId: 00/2B
payload: 04 00
receiver type: 0x10
receiver id: 7
encoded target: 0xF002
```

This belongs to the BLE wake path. It is not the normal UDP control heartbeat.

**Status:** SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED as part of the successful
Pocket 3 connection sequence.

## `07/45` — pairing PIN

```text
cmdSet/cmdId: 07/45
receiver: Wi-Fi subsystem
payload: PackString(identifier) + PackString("osmo")
```

Observed status reply layout begins with:

```text
00 <status>
```

Observed meanings include:

```text
01 = already paired
02 = approval required
```

Pair approval can subsequently arrive as `07/46` request traffic and must be
answered by the client.

**Status:** SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `53/10` — Wi-Fi/AP wake

```text
cmdSet/cmdId: 53/10
payload: 00 00 00 00
receiver type: 0x1C
receiver id: 0
encoded target: 0x1C02
```

Observed Pocket/Mimo reply:

```text
01 00 00 00
```

This command is correlated with waking the Pocket 3 Wi-Fi AP in the working
BLE handoff.

**Status:** SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `00/2B` — post-pair BLE keepalive

```text
cmdSet/cmdId: 00/2B
payload: 01 01
receiver type: 0x10
receiver id: 7
```

Used approximately in the 1 Hz class during the proven post-pair Wi-Fi handoff.

**Status:** SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `07/07` — query Wi-Fi SSID

The reply carries DJI status information and a packed string containing the
Pocket AP SSID.

**Status:** SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `07/0E` — query Wi-Fi password

The reply carries DJI status information and a packed string containing the
Pocket AP password.

**Status:** SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED.

Security rule: do not log, publish, or persist a user's plaintext Pocket Wi-Fi
password in protocol diagnostics.

---

# 4. UDP registration, presence, and readiness

## `00/81` — APP device-info registration

```text
cmdSet/cmdId: 00/81
receiver type: 0x08
receiver id: 2
cmdType: 4
payload length: 62 bytes
payload prefix: 00 41 50 50
```

Known payload construction:

```text
00 41 50 50
+ 37 zero bytes
+ 02
+ 8 zero bytes
+ 02 08
+ 10 zero bytes
```

**Status:** SOURCE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `00/88` — APP presence

```text
cmdSet/cmdId: 00/88
receiver type: 0x08
receiver id: 1
cmdType: 2
payload:
17 00 46 23 7c 41 50 50 00 00 00 00 00 02
```

Repeated approximately in the 1 Hz class in the proven session.

**Status:** PHYSICALLY_CONFIRMED.

## `03/DA` — gimbal/session initialization

```text
cmdSet/cmdId: 03/DA
receiver type: 0x03
receiver id: 0
cmdType: 2
payload: 05 ff ff ff ff
```

Used in the working startup sequence before normal gimbal control.

**Status:** PHYSICALLY_CONFIRMED as part of the proven startup sequence.

## `04/50` — gimbal heartbeat/readiness probe

```text
cmdSet/cmdId: 04/50
receiver type: 0x04
receiver id: 0
cmdType: 2
request payload: 01 04 05
```

Used approximately in the 1 Hz class.

A missing heartbeat reply is an important command-path health signal, but it
should be interpreted together with fresh inbound telemetry and transport-window
state rather than treated as proof that Wi-Fi itself disappeared.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED.

---

# 5. Gimbal control

## `04/01` — virtual joystick / gimbal velocity

```text
cmdSet/cmdId: 04/01
receiver type: 0x04
receiver id: 0
cmdType: 0
payload length: 10 bytes
```

Known payload layout:

```text
offset 0..1  pitch  UInt16 LE
offset 2..3  00 00       unknown/reserved; do not label as roll
offset 4..5  yaw    UInt16 LE
offset 6..9  00 80 22 00 fixed/flags in confirmed joystick traffic
```

Neutral:

```text
pitch = 1024
yaw   = 1024

payload:
00 04 00 00 00 04 00 80 22 00
```

Direction mapping established by the working controller:

```text
pitch > 1024 = UP
pitch < 1024 = DOWN

yaw < 1024 = LEFT
yaw > 1024 = RIGHT
```

Known controller ranges:

```text
LINEAR:      approximately 1024 ± 330
PROGRESSIVE: full command ceiling approximately 1024 ± 550
```

The working controller transmits active joystick traffic around 20 Hz and sends
explicit neutral on release, interruption, and safe shutdown paths.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED.

### Unknown possible third axis

Bytes `2..3` are zero in the confirmed joystick traffic. They remain
**UNVERIFIED** and must not be assumed to represent roll.

---

# 6. Gimbal telemetry

## `04/05` — unsolicited gimbal telemetry

Minimum confirmed payload layout:

```text
offset 0..1  pitch        Int16 LE / 10 degrees
offset 2..3  roll         Int16 LE / 10 degrees
offset 4..5  wrapped yaw  Int16 LE / 10 degrees
offset 6     mode/status byte, when present
offset 10    candidate limit/status flags, when present
```

The current parser rejects payloads shorter than six bytes rather than
manufacturing zero-valued telemetry.

Known mode observations include:

```text
0x40 = observed normal/follow state in project tests
0x00 = observed locked state in lock tests
0x60 = observed transiently during earlier RECENTER captures
```

Those observations do **not** establish a complete gimbal-mode enum.

Candidate limit/status bits currently exposed by the implementation are:

```text
bit 0x01 = candidate pitch-at-limit
bit 0x02 = candidate roll-at-limit
bit 0x04 = candidate yaw-at-limit
bit 0x40 = candidate stuck flag
```

These bits remain **UNVERIFIED as authoritative mechanical-limit protection**.
Physical testing showed candidate limit bits may remain clear at a real yaw stop.

**Status:** pitch/roll/yaw layout PHYSICALLY_CONFIRMED; complete mode mapping
OBSERVED but incomplete; limit semantics UNVERIFIED.

## Continuous yaw

Raw yaw is wrapped. Closed-loop control must not treat the `+180/-180` boundary
as a physical 360-degree jump.

The current reducer:

1. seeds continuous yaw from the first wrapped sample
2. computes the shortest signed delta between consecutive wrapped samples
3. accumulates that delta
4. resets state explicitly when the session telemetry state is reset

Forward crossing:

```text
+179 -> -179
```

becomes approximately:

```text
+179 -> +181
```

Reverse crossing is handled symmetrically.

This continuous yaw model is required by higher-level closed-loop motion such
as Mark/Return.

**Status:** IMPLEMENTATION_CORROBORATED + hardware-validated in the current
Pocket 3 application behavior.

---

# 7. RECENTER, selfie, and software lock/follow

## `04/4C FE08` — RECENTER

```text
cmdSet/cmdId: 04/4C
receiver type: 0x04
receiver id: 0
cmdType: 2
payload: FE 08
observed response status: 00 00
```

This is the confirmed Pocket 3 RECENTER command.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `04/4C FE09` — selfie / forward flip

Deliberate capture correlation showed alternating:

```text
FE 09  selfie/forward flip
FE 08  RECENTER
FE 09  selfie/forward flip
FE 08  RECENTER
```

`FE08` is independently proven as RECENTER, which strongly identifies `FE09`
as the selfie/forward toggle.

**Status:** STRONGLY_IDENTIFIED from capture evidence and used by the current
implementation. Keep the distinction from RECENTER explicit.

## `04/4C 00 00` — software gimbal lock

```text
cmdSet/cmdId: 04/4C
payload: 00 00
receiver type: 0x04
receiver id: 0
cmdType: 2
```

Project hardware tests have confirmed the software-lock behavior.

**Status:** PHYSICALLY_CONFIRMED.

## `04/4C 01 00` — return to follow/unlocked behavior

```text
cmdSet/cmdId: 04/4C
payload: 01 00
receiver type: 0x04
receiver id: 0
cmdType: 2
```

Project hardware tests have confirmed return from software lock to normal
follow behavior.

**Status:** PHYSICALLY_CONFIRMED.

These two software lock/follow commands should not be over-generalized into a
complete mapping of the Pocket UI's Follow / Tilt Locked / FPV selector. That
three-mode UI mapping still needs cleaner isolated capture evidence.

---

# 8. Camera recording and `02/80` state

## `02/02` — record start/stop request

```text
cmdSet/cmdId: 02/02
receiver type: 0x01
receiver id: 0
cmdType: 2

payload 01 = request START
payload 00 = request STOP
```

An inbound `02/02` response payload `00` indicates that the request was accepted.

**Important:** command acceptance is not proof that recording actually reached
the requested state.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `02/80` — camera status / recording state

Observed recording-state values in the first payload byte:

```text
0x01 = IDLE
0x41 = TRANSITION
0xC1 = TRANSITION + recording bit
0x81 = RECORDING
```

Current bit interpretation:

```text
0x80 = recording active
0x40 = recording transition in progress
```

Production rule:

```text
send 02/02
  -> observe command acceptance
  -> require fresh 02/80 state
  -> confirm actual resulting camera state
```

The current parser also extracts these fields when at least 58 bytes are present:

```text
payload[4]       video-like state flag (current implementation treats 0x01 as video-like)
payload[5..8]    storage total MiB, UInt32 LE
payload[9..12]   storage free MiB, UInt32 LE
payload[17..18]  remaining record seconds, UInt16 LE
payload[29..30]  elapsed record seconds, UInt16 LE
payload[57]      shooting-mode ID
```

Confirmed shooting-mode readback IDs:

```text
00 = Slow Motion
01 = Video
02 = Timelapse
05 = Photo
0A = Hyperlapse
0C = Panorama
18 = Motionlapse
28 = Low-Light
```

These readback IDs should not automatically be treated as safe writer values
without separate writer evidence.

**Status:** record-state handling CAPTURE_CONFIRMED and hardware-validated;
the listed status fields are current capture-derived production interpretations.

---

# 9. Storage telemetry

## `02/DC` — storage push

Pocket 3 uses a single microSD store. The current implementation recognizes a
22-byte `02/DC` body and extracts:

```text
payload[2]       store count
payload[6..9]    SD total MiB, UInt32 LE
payload[10..13]  SD free MiB, UInt32 LE
```

Short payloads are rejected.

The implementation may also receive storage figures through the broader
`02/80` camera-status payload described above.

**Status:** IMPLEMENTATION_CORROBORATED for the current Pocket 3 implementation.

---

# 10. Battery telemetry

## `0D/02` — battery status

For the tested Pocket 3 payload:

```text
payload[20] = battery percentage, 0...100
payload[32] = charging state
```

Charging-state values:

```text
00 = not charging
01 = charging
other = unknown
```

The parser requires at least 33 bytes and rejects impossible percentages above
100.

This is deliberately documented as **charging state**, not as a generic
"external power connected" bit. Hardware testing showed that external power
may be attached while the Pocket is not actively charging at high state of
charge.

**Status:** PHYSICALLY_CONFIRMED.

---

# 11. Camera named-property readback (`00/99`)

DJI Mimo uses a named-property subscription bus for live camera settings/state.
Kaze for DJI subscribes to this bus after the direct session is ready.

Subscriptions are read-only and use:

```text
cmdSet/cmdId: 00/99
receiver type: 0x08
receiver id: 1
cmdType: 2
```

The current subscription payload begins:

```text
02 02 00 00
<transaction id:u32 LE>
00 00 00
<record length:u16 LE>
<name length:u16 LE>
<ASCII property name>
00 00 00 00
```

Pocket-to-app property pushes use operation `0x06`. The current parser expects:

```text
payload[0..3] = 02 06 00 00
payload[4..7] = transaction id, UInt32 LE
payload[13..14] = property-name length, UInt16 LE
payload[15..] = ASCII property name
after name: six reserved bytes
then: value length, UInt16 LE
then: property value
```

Current decoded property names:

```text
cam_video_param_v2
cam_sensor_aspect_ratio
cam_image_effect
cam_expo_param
cam_lens_state
cam_photo_param
cam_lapse_param
cam_pano_params
cam_motionlapse_params
```

Decoded fields include video format/frame rate/compression, effective
Landscape/Portrait orientation, color/WB, exposure/EV/effective ISO, focus,
photo settings, Timelapse/Hyperlapse state, Motionlapse state, and Panorama
state.

Exact field mappings and writable camera-setting commands are documented in:

```text
docs/CAMERA_SETTINGS_PROTOCOL.md
```

**Status:** CAPTURE_CONFIRMED + IMPLEMENTATION_CORROBORATED, with the documented
settings/readback behavior hardware-tested where stated in the settings reference.

---

# 12. Direct live view

## `01/01` — live-view state

### START

```text
cmdSet/cmdId: 01/01
receiver type: 0x01
receiver id: 0
cmdType: 0
payload:
01 00 00 00 00 04 00 00 00 05 01
```

Mimo repeats this state in a short burst during direct live-view startup.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED through direct video.

### IDLE

```text
cmdSet/cmdId: 01/01
receiver type: 0x01
receiver id: 0
cmdType: 0
payload:
00 00 00 00 00 04 00 00 00 04 01
```

After requesting live view, Mimo returns `01/01` to this normal/idle state while
`pktType 0x02` video continues.

The validated shutdown path uses the safe idle/close behavior rather than the
playback-state payload documented in the unsafe section.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED.

## `09/A8` — live-view companion/start command

```text
cmdSet/cmdId: 09/A8
receiver type: 0x01
receiver id: 2
cmdType: 2
payload:
00 04 02 00 00 00 00 00 00 00
```

Known-good captured/implemented startup cadence:

```text
START -> A8 -> START -> A8 -> START x5 -> IDLE x4
```

The exact repetition counts and millisecond gaps are retained as known-good
implementation policy. They are not claimed to be the minimum DJI-required
sequence.

**Status:** CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED through the working direct
video path; exact repetition policy IMPLEMENTATION_CORROBORATED.

## `pktType 0x02` — direct H.264 media

Direct datagram layout:

```text
bytes 0..7   transport header
bytes 8..19  routing header
bytes 20..   media fragment
```

First fragment:

```text
+0   00 00 01 FF
+4   UInt32 LE assembled H.264 message length
+8   8 bytes media metadata
+12  UInt32 LE timestamp-like counter within that metadata
+16  Annex-B H.264 data
```

Because the media fragment begins at absolute datagram byte 20, the preserved
timestamp-like field is at absolute bytes `32..35`.

Continuation fragments append from datagram byte 20.

A robust reassembler should:

- bounds-check declared lengths
- discard an incomplete message if a new first fragment arrives
- not retain partial messages indefinitely
- impose a sane maximum message size
- preserve timestamp metadata
- wait for usable SPS/PPS/decoder configuration before presenting video

The stream is Annex-B H.264. The current iOS path recognizes both three-byte
and four-byte Annex-B start codes and converts NAL units to the length-prefixed
form required by Apple's H.264 decode path.

Capture-derived timestamp samples advanced about 41/42 ticks per 60 Hz picture,
consistent with a possible 2500 Hz clock:

```text
2500 / 60 = 41.67
```

The **2500 Hz interpretation remains INFERRED**, not a DJI protocol constant.

**Status:** H.264 fragmentation CAPTURE_CONFIRMED + PHYSICALLY_CONFIRMED;
timestamp field location IMPLEMENTATION_CORROBORATED; 2500 Hz timebase INFERRED.

---

# 13. Camera settings

The broad Mimo settings campaign established substantially more of the Pocket 3
camera-control protocol than the original DUML reference contained.

The detailed current mappings are intentionally maintained separately in:

```text
docs/CAMERA_SETTINGS_PROTOCOL.md
```

That document includes, among other items:

- shooting modes
- video resolution/frame-rate encodings
- 1:1 and 9:16 format codes
- compression
- exposure mode
- complete tested ISO and ISO MAX menus
- complete tested Photo manual-shutter menu
- normal-Video shutter restrictions
- EV
- white balance and Kelvin
- color profiles
- focus
- Photo frame/format/countdown
- Timelapse
- Motionlapse direction/waypoints/preview
- Hyperlapse
- Panorama
- Pro gate
- Product Showcase
- Mono/Stereo audio channel
- named-property live readback
- controls intentionally withheld because their structure remains ambiguous

Do not duplicate those large tables here; keep the settings document as the
canonical camera-settings reference.

---

# 14. Known unsafe / forbidden behavior

## `04/14` experimental recenter attempts

An experimental `04/14` payload was accepted by the camera, but one tested
payload drove the real gimbal in the wrong direction toward a mechanical
limit/error.

```text
04/14 = DO NOT USE for RECENTER
```

The proven RECENTER path is:

```text
04/4C FE 08
```

**Status:** `04/14` RECENTER experiments are UNSAFE.

## Playback-state payload must not be used as live-view STOP

This `01/01` payload was once treated as a possible live-view stop:

```text
03 00 00 00 00 04 00 00 00 07 01
```

Physical testing showed that it transitions the Pocket into playback/media mode
and produces the on-camera Mimo/LightCut playback state.

```text
DO NOT use this as live-view shutdown.
Use the validated LIVE_IDLE / transport-close behavior.
```

**Status:** PHYSICALLY_CONFIRMED + UNSAFE.

---

# 15. Higher-level behaviors built from confirmed commands

The following are application behaviors, not separate DJI commands.

## Mark / Return

A saved-position return can be built from:

```text
04/05 telemetry
  -> continuous-yaw reducer
  -> closed-loop controller
  -> 04/01 joystick commands
```

This approach deliberately avoids guessed `04/14` movement commands.

## Input sources

Touch joystick, physical game controller, and motion/head-tracking inputs should
feed a normalized application control layer that ultimately uses the same
confirmed `04/01` command path.

Input sources should not each implement their own independent DUML transport.

---

# 16. Known open questions

The broad settings campaign closed many of the original reference's open
questions. Remaining important areas include:

1. Complete Pocket 3 mapping of the user-facing `Follow`, `Tilt Locked`, and
   `FPV` selector.
2. Rotational Speed / Gimbal Easy Control semantics and whether they are camera
   settings or primarily app-side joystick behavior.
3. Whether direct roll-axis actuation exists; `04/01` bytes `2..3` remain unknown.
4. Complete semantic map of the `04/05` mode byte.
5. Whether any `04/05` status/limit bits can be made reliable enough for actual
   mechanical-limit protection.
6. Cleaner decoding of composite `02/9F` audio settings such as Wind Noise
   Reduction / Directional Audio.
7. Cleaner typed decoding of Beauty/Glamour PID `0039`.
8. Tracking / Smart Gimbal commands.
9. Media browsing/transfer/playback commands.
10. Mic-specific control/status behavior.
11. Livestream/RTMP setup and quality fields.
12. Firmware compatibility matrix across Pocket 3 releases.
13. Compatibility mapping for additional Pocket and Action models.

Unknown items should remain unknown rather than being filled by plausible-looking
values.

---

# 17. Known-good regression vectors

The repository's machine-readable vectors are preferred for automated tests:

```text
protocol/test-vectors/crc/crc.json
protocol/test-vectors/transport/transport.json
protocol/test-vectors/gimbal/gimbal.json
protocol/test-vectors/camera/camera.json
```

Representative exact vectors include:

```text
BLE 00/2B session-wake full DUML frame:
550F04A202F02B8040002B04002440

UDP header:
pktType=05 payloadLength=34 session=1234 seq=5678
2A803412785605A7

ACK payload:
rx2=1111 rx3=2222 peerAck=3333 lastTx=4444
1111111100000000222222220000000033334444000000000000

Routing header:
seq=5678 peerAck=1234 counter=9a
34127856000000009A010000

Neutral 04/01 payload:
00040000000400802200

RECENTER payload:
FE08
```

Keep regression vectors separate from semantic evidence. A byte-exact regression
can prove that two implementations encode the same bytes without proving that
every byte's meaning has been completely understood.

---

# 18. Provenance and update discipline

This reference consolidates evidence from:

- controlled DJI Mimo ↔ Pocket 3 packet captures
- direct physical Pocket 3 experiments
- known-good Python direct-control/live-view harnesses
- the current Kaze for DJI iOS and Android implementations
- shared byte-exact protocol regression vectors
- open-source reference work identified in `THIRD_PARTY_NOTICES.md`

Protocol knowledge and source-code provenance are separate questions. Finding or
confirming a command on the wire does not imply that implementation source was
copied from another project.

For new reverse-engineered behavior, prefer this workflow:

```text
UI/device behavior inventory
  -> labeled capture + action timestamps
  -> decode cmdSet/cmdId/payload/replies
  -> record as OBSERVED / CAPTURE_CONFIRMED
  -> safe direct physical test where appropriate
  -> promote only when evidence supports it
  -> add regression vectors
  -> implement
  -> hardware-test the implementation
```

Never silently overwrite an old interpretation when new evidence refines it.
Record the new evidence and change the status/meaning explicitly.

---

# 19. Scope boundary

This document is primarily a Pocket 3 direct-control reference.

Pocket 1 with the DJI Wireless Module has separately been observed using the
same broad UDP/9004 family, but Pocket 1-specific commands and semantics should
not be folded into Pocket 3 behavior merely to create a common abstraction.

Likewise, no Pocket 4, Pocket 4P, or Osmo Action behavior should be claimed from
Pocket 3 evidence alone.
