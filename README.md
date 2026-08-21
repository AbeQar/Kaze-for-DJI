# Kaze for DJI

Kaze for DJI is an experimental open-source camera-control application for DJI
Osmo cameras.

The current release is focused on the **DJI Osmo Pocket 3** and has been tested
on real hardware on both iOS and Android.

This is an early alpha release. The project is being published now so that the
implementation, protocol research, and working Pocket 3 support are available
to the community while development continues.

## Current Pocket 3 functionality

Current development includes:

- BLE discovery and camera wake/pairing flow
- automatic Wi-Fi connection
- direct DJI UDP session
- direct H.264 live preview
- video recording control and camera-state readback
- photo capture
- battery and storage status
- camera settings and readback
- ISO and ISO MAX
- shutter speed
- exposure compensation
- white balance
- focus controls
- video resolution and frame rate
- photo settings
- Timelapse
- Motionlapse
- Hyperlapse
- Panorama
- gimbal joystick control
- LINEAR and PROGRESSIVE joystick response
- RECENTER
- selfie/forward flip
- saved-position Mark / Return control
- physical game-controller support
- iOS motion/head-tracking experimentation
- Picture in Picture
- rotation, background, reconnect, and lifecycle handling

Some controls and screens still have developer-oriented UI and will be refined.

## Protocol documentation

Pocket 3 protocol research and implementation notes are included in:

- [`docs/POCKET3_DUML_PROTOCOL.md`](docs/POCKET3_DUML_PROTOCOL.md) — BLE/Wi-Fi
  connection, UDP/9004 transport, DUML framing, gimbal control, telemetry,
  recording, live view, known unsafe commands, and open questions.
- [`docs/CAMERA_SETTINGS_PROTOCOL.md`](docs/CAMERA_SETTINGS_PROTOCOL.md) —
  camera-setting commands, captured option tables, named-property readback,
  Timelapse, Motionlapse, Hyperlapse, Panorama, and related settings research.

Shared machine-readable protocol regression vectors are in:

`protocol/test-vectors/`

## Platforms

### iOS

The iOS implementation is in:

`ios/`

Open:

`ios/Pocket3Controller.xcodeproj`

You will need to select your own Apple Development Team and use a bundle
identifier available to your account before running on a physical device.

### Android

The Android implementation is in:

`android/`

Open the `android` directory in Android Studio or build from the command line.

## Hardware support

### Hardware tested

- DJI Osmo Pocket 3

### Future targets

The architecture and protocol research may later be expanded to additional:

- Osmo Pocket models
- Osmo Action models

Do not assume that unlisted models are currently compatible.

## Project status

Kaze for DJI is currently **alpha software**.

The Pocket 3 implementation has received substantial real-device testing, but
bugs, incomplete behavior, and unfinished UI should still be expected.

If using Kaze for important recording, verify the camera's actual state on the
physical camera.

## Reverse engineering

The direct camera-control implementation is based on independent protocol
research, packet analysis, real-device testing, and open-source reference work.

See:

- `PROVENANCE.md`
- `THIRD_PARTY_NOTICES.md`

for additional information.

## License

Kaze for DJI is released under the MIT License.

See `LICENSE`.

Third-party components retain their respective copyright and license notices.

## Disclaimer

Kaze for DJI is an independent third-party project.

It is not affiliated with, authorized by, sponsored by, or endorsed by DJI.

DJI, Osmo, and related product names are trademarks of their respective owners.
