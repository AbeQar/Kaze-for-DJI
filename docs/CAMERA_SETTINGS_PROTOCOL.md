# Pocket 3 Camera Settings Protocol

This document records the writable Pocket 3 settings currently exposed by Kaze for DJI.
The mappings were derived from controlled DJI Mimo 2.11.5 ↔ DJI Osmo Pocket 3 traffic captures and checked against camera state pushes where available.

This is not DJI documentation and it is not a claim that the same values apply to other DJI camera families.

## Command routing

The settings below use DUML command set `0x02`, App → Camera receiver `0x01` / id `0`, request flags `0x40` (`cmdType = 2`) unless noted otherwise.

## Implemented, isolated setters

| Setting | DUML | Captured encoding |
|---|---|---|
| Shooting mode | `02/E1` | captured IDs include Slow Motion `00`, Video `01`, Timelapse `02`, Photo `05`, Hyperlapse `0A`, Panorama `0C`, Motionlapse `18`, Low-Light `28`; the current UI uses the confirmed Timelapse `02` ↔ Motionlapse `18` transition |
| Video format | `02/18` | `[resolution][fps][00][slow-motion multiplier][00]` |
| Video compression | `02/AB` | H.264 Compatibility `00 00`, HEVC Efficiency `01 00` |
| Exposure mode | `02/1E` | AUTO `01 00`, Manual `04 00` |
| Manual ISO | `02/2A` | complete menu: Auto `00`, 50 `02`, 100 `03`, 200 `04`, 400 `05`, 800 `06`, 1600 `07`, 3200 `08`, 6400 `09` |
| ISO MAX | `02/8E` PID `000F` | one-byte selector: 100 `01`, 200 `02`, 400 `03`, 800 `04`, 1600 `05`, 3200 `06`, 6400 `07` |
| Manual shutter | `02/28` | complete Photo menu `1\"` through `1/8000`; exact 7-byte capture-confirmed payloads |
| AUTO EV compensation | `02/2E` | `07...19`, center `10`; one code step = 1/3 EV |
| White balance | `02/2C` | Auto `00 00 00 00 00`; Custom `06 [Kelvin/100] 00 00 00`; tested range 2000K–10000K in 100K steps |
| Color profile | `02/42` | Normal `00`, HLG `3C`, D-Log M `3D` |
| Focus mode | `02/24` | Single `01`, Continuous `02` |
| Still-photo shutter | `02/01` | single capture trigger `01` |
| Photo frame | `02/12` | 16:9 `00 01`, 1:1 `00 03` |
| Photo format | `02/16` | JPEG `01`, JPEG+RAW `02` |
| Photo countdown | `02/4A` | `00 01 [seconds] 00 00 00`; captured 0/3/5/7 seconds |
| Timelapse config | `02/6C` | `04 00 [format] [interval:u16 LE, tenths s] [duration:u32 LE, seconds] 00×7` |
| Motionlapse direction | `02/8E` PID `0037` | Custom `00`, L→R `01`, R→L `02` |
| Motionlapse Custom waypoint set | `02/6C` | `05 [slot:u16 LE] [interval:u16 LE] [duration:u32 LE] [yaw:s16 LE] [roll:s16 LE] [pitch:s16 LE] 00`; set slots `0005`, `0009`, `000D`, `0011` for points 1–4 |
| Motionlapse Custom waypoint delete | `02/6C` | same structure with zeroed yaw/roll/pitch; reverse-delete tokens `0006`, `000A`, `000E`, `0012` for points 1–4 |
| Motionlapse Custom path Preview | `02/8E` PID `0036` | SET value `00 00`; Pocket completes traversal automatically, no stop command observed |
| Hyperlapse speed | `02/6C` | `0B 00 00 [speed] 00×12`; Auto `00`, 2x `02`, 5x `05`, 10x `0A`, 15x `0F`, 30x `1E` |
| Panorama type | `02/6E` | 180° `05`, 3×3 `07` |
| Panorama photo format | `02/E7` | RAW settled at `01 00`; JPEG settled at `03 00` |
| Panorama shutter/start | `02/01` | payload `07`; same trigger captured for both 180° and 3×3 |
| Pro master gate | `02/8E` PID `0000` | SET value `00`/`01` |
| Product Showcase | `02/8E` PID `003B` | SET value `01 00` / `01 01` |
| Audio channel | `02/8E` PID `0020` | Mono `01`, Stereo `02` |
| Selfie / forward toggle | `04/4C` | `FE 09`, receiver gimbal `0x04` |

### Video resolution codes captured on Pocket 3

| UI value | code |
|---|---:|
| 1080p | `0A` |
| 2.7K | `2D` |
| 4K | `10` |
| 1080p 1:1 | `69` |
| 2160p 1:1 | `6A` |
| 3K 1:1 | `6B` |
| 1080p 9:16 | `42` |
| 2.7K 9:16 | `43` |
| 3K 9:16 | `6C` |

### Frame-rate codes

| fps | code |
|---:|---:|
| 24 | `01` |
| 25 | `02` |
| 30 | `03` |
| 48 | `04` |
| 50 | `05` |
| 60 | `06` |
| 120 | `07` |
| 240 | `08` |

Slow Motion additionally used byte 3 of `02/18`: `04` for 4x and `08` for 8x in the captured matrix.

### Mode-specific format observations

The controlled campaign also captured the following mode-specific combinations.
These describe the tested Pocket 3 / Mimo menus and should not be assumed to
apply unchanged to other firmware or camera models.

- Low-Light: 1080p and 4K; 24, 25, and 30 fps were captured.
- Slow Motion: 4K / 4x / 120 fps, 2.7K / 4x / 120 fps,
  1080p / 4x / 120 fps, and 1080p / 8x / 240 fps.
- Timelapse: captured format selections included 1080p / 25 fps,
  2.7K / 30 fps, and 4K / 30 fps.

The 9:16 `02/18` codes change recording format only. Hardware testing showed that sending a vertical format while the Pocket was in Landscape did **not** rotate the camera into Portrait. Orientation policy is therefore treated as a separate control and is not exposed as a writer here.

## Live camera-state readback

Kaze for DJI subscribes to the capture-derived DUML `00/99` named-property bus after the direct session becomes ready. These subscriptions are read-only and use receiver type `0x08`, receiver id `1`.

Current decoded properties:

| Property | Decoded state |
|---|---|
| `cam_video_param_v2` | resolution, frame rate, compression |
| `cam_sensor_aspect_ratio` | effective orientation: `00` Landscape, `01` Portrait |
| `cam_image_effect` | color profile, Auto/custom-Kelvin white balance |
| `cam_expo_param` | exposure mode, EV, effective numeric ISO |
| `cam_lens_state` | Single/Continuous AF |
| `cam_photo_param` | photo frame, JPEG/JPEG+RAW, countdown |
| `cam_lapse_param` | Timelapse/Motionlapse output, interval in tenths of a second, duration in seconds (`0` = infinity); Hyperlapse speed from mirrored UInt16 LE fields at bytes 9–10 and 11–12 |
| `cam_motionlapse_params` | Motionlapse direction, Custom saved-waypoint count (0–4), Custom Preview active flag |
| `cam_pano_params` | Panorama type (`05` 180°, `07` 3×3) and photo format (`03` JPEG, `01` RAW) |

`cam_sensor_aspect_ratio` is an **effective orientation readback**, not a decoded Auto/Landscape/Portrait policy enum. In controlled testing, selecting Auto while the Pocket remained physically vertical continued to report `01`. The public UI therefore follows the Pocket's reported orientation and does not claim remote orientation switching.

Capture-confirmed `cam_photo_param` is 13 bytes for the tested Photo state. The public decoder uses byte 1 for frame (`01` 16:9, `03` 1:1), byte 3 for format (`01` JPEG, `02` JPEG+RAW), and byte 7 for countdown (`00`, `03`, `05`, `07`).

Capture-confirmed `cam_lapse_param` is 21 bytes for the tested lapse states. The public decoder uses byte 0 for Timelapse output (`00` Video, `02` JPEG+Video, `03` RAW+Video), bytes 1–2 as interval tenths (`UInt16` little-endian), and bytes 5–8 as duration seconds (`UInt32` little-endian, `0` = infinity). In Hyperlapse, bytes 9–10 and 11–12 are mirrored `UInt16` little-endian speed values; both copies settled to `0`, `2`, `5`, `10`, `15`, or `30` for Auto/2×/5×/10×/15×/30×. Bytes 3–4 and 13–20 remain unnamed.

For `cam_motionlapse_params`, byte 2 matches PID `0037` direction (`00` Custom, `01` L→R, `02` R→L); byte 3 is `80` while Custom path Preview is active and returns to `00` when traversal completes. For Custom, byte 7 is the saved-point count from 0 through 4. The embedded waypoint-record bytes are not exposed as a general readback model.

For `cam_pano_params`, byte 0 is the Panorama type (`05` 180°, `07` 3×3), byte 1 is the photo format (`03` JPEG, `01` RAW), and byte 2 remains intentionally unnamed. The separate Panorama shutter/start capture showed the same `02/01 07` trigger for both 180° and 3×3 after type selection.

The Custom waypoint writer uses fresh `04/05` gimbal telemetry. The captured `02/6C` waypoint wire order is **yaw, roll, pitch**, not the `04/05` decode order of pitch, roll, yaw. Four-point creation and reverse-order deletion were physically validated on Pocket 3 hardware.

Shooting mode is read separately from unsolicited `02/80` status telemetry. Confirmed readback IDs include Slow Motion `00`, Video `01`, Timelapse `02`, Photo `05`, Hyperlapse `0A`, Panorama `0C`, Motionlapse `18`, and Low-Light `28`. The Timelapse `02` ↔ Motionlapse `18` transition is separately capture- and hardware-validated; the other readback IDs do not by themselves establish a safe public shooting-mode writer.

## `02/8E` keyed parameter format

Capture evidence agrees with the following parameter-store layout:

```text
GET = 00 01 <pid:u16-LE>
SET = 01 01 <pid:u16-LE> <len:u8> <value...>
```

Kaze for DJI currently exposes only PIDs whose SET payloads were isolated cleanly enough to write without replaying unrelated state.

## Intentionally not exposed as writable settings yet

The campaign captured useful evidence for the following controls, but the current write structures are composite, ambiguous, or likely Mimo-side UI behavior. They remain out of the public writable API until the semantics are stronger:

- Beauty/Glamour: PID `0039` contains a larger composite settings block; individual slider offsets are visible but should not be written by replaying a captured whole block.
- Wind Noise Reduction / Directional Audio: `02/9F` changes are captured, but the structure contains multiple audio fields and should be decoded before a safe typed setter is published.
- Motionlapse arbitrary waypoint overwrite/reorder and any unobserved path-edit operations remain intentionally unclaimed. The public API exposes only the capture- and hardware-validated sequential point writes, reverse-order deletes, direction selector, saved-count readback, and Preview trigger described above.
- Gimbal Follow / Tilt Locked / FPV selector: `04/4C` traffic was captured, but one cleaner isolated capture is still required before publishing a definitive three-mode mapping.
- Rotational Speed and Gimbal Easy Control: no isolated camera setter was found; current evidence points to Mimo-side control/UI behavior.
- Histogram, overexposure alert, grid, color-recovery display, and timecode display: no isolated camera setter was found in the campaign; these appear primarily app-side display functions.
- RTMP setup / quality: intentionally postponed.

## Media management

Media enumeration, photo/video transfer, playback, and media-management commands are deliberately outside the scope of this settings implementation.

## Evidence policy

`Capture-confirmed` means a requested UI change produced an isolated outgoing command and, where available, a consistent camera-side state change in the controlled Pocket 3 campaign. It does not mean DJI officially documents or supports the command for third-party applications.

## Battery telemetry

Pocket 3 battery state arrives as unsolicited DUML `0D/02` telemetry.

| Payload field | Hardware-confirmed meaning |
|---|---|
| byte 20 | battery percentage, `0...100` |
| byte 32 | charging state: `00` not charging, `01` charging |

The percentage mapping was checked against the Pocket 3's own display at multiple levels. The charging field was correlated against explicit charger plug/unplug tests where the on-device charging indicator appeared and disappeared.

This flag is intentionally documented as **charging state**, not external-power presence. Testing showed external power can be connected while the Pocket 3 is not actively charging at high state of charge. Unknown future byte-32 values are represented as unknown rather than guessed.


### C3 option-completeness menus

Controlled DJI Mimo ↔ Pocket 3 captures completed the user-visible tables below.

**ISO (`02/2A`)**

`Auto=00`, `50=02`, `100=03`, `200=04`, `400=05`, `800=06`, `1600=07`, `3200=08`, `6400=09`.

Code `01` was not exposed by the tested Pocket 3 Mimo menu and remains intentionally unnamed.

**Manual shutter (`02/28`)**

The complete tested Photo menu is:

`1"`, `1/1.25`, `1/1.67`, `1/2`, `1/2.5`, `1/3`, `1/4`, `1/5`, `1/6.25`, `1/8`, `1/10`, `1/12.5`, `1/15`, `1/20`, `1/25`, `1/30`, `1/40`, `1/50`, `1/60`, `1/80`, `1/100`, `1/120`, `1/160`, `1/200`, `1/240`, `1/320`, `1/400`, `1/500`, `1/640`, `1/800`, `1/1000`, `1/1250`, `1/1600`, `1/2000`, `1/2500`, `1/3200`, `1/4000`, `1/5000`, `1/6400`, `1/8000`.

`1"` uses `01 01 00 00 00 00 40`.

Ordinary reciprocal integer speeds use `01 [LE16(0x8000 | denominator)] 00 00 00 40`.

Capture-confirmed fractional-denominator exceptions:

- `1/1.25` → `01 01 80 19 00 00 40`
- `1/1.67` → `01 01 80 43 00 00 40`
- `1/2.5` → `01 02 80 05 00 00 40`
- `1/6.25` → `01 06 80 19 00 00 40`
- `1/12.5` → `01 0C 80 05 00 00 40`

Normal-Video Mimo minimums observed directly:

- 24/25 fps → `1/25`
- 30 fps → `1/30`
- 48/50 fps → `1/50`
- 60 fps → `1/60`

The same restriction behavior was observed at 1080p, 2.7K, and 4K. Slow Motion 120/240 fps is intentionally not generalized from this evidence.

**Timelapse interval** — complete Mimo menu, UInt16 LE tenths of a second:

`0.5s=5`, `1s=10`, `2s=20`, `3s=30`, `4s=40`, `5s=50`, `6s=60`, `8s=80`, `10s=100`, `15s=150`, `20s=200`, `25s=250`, `30s=300`, `40s=400`, `1m=600`.

**Timelapse duration** — complete Mimo menu, UInt32 LE seconds:

`∞=0`, `5m=300`, `10m=600`, `20m=1200`, `30m=1800`, `1h=3600`, `2h=7200`, `3h=10800`, `5h=18000`.


### C3 ISO MAX

A clean control-only DJI Mimo ↔ Pocket 3 capture completed the ISO MAX table.

Setter:

```text
02/8E
PID 000F
SET payload = 01 01 0F 00 01 XX
```

The one-byte selector is:

```text
100  = 01
200  = 02
400  = 03
800  = 04
1600 = 05
3200 = 06
6400 = 07
```

The full Mimo menu was observed as `100, 200, 400, 800, 1600, 3200, 6400`. Direct hardware smoke testing confirmed that values written by the app are reflected by the Pocket 3 / Mimo setting. No additional selector values are claimed.
