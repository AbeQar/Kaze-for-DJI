# Kaze for DJI — Provenance

Kaze for DJI is an unofficial open-source camera-control project for supported
DJI Osmo cameras.

## Development

Development of the current Pocket 3 implementation has involved:

- independent observation of DJI Mimo behavior
- packet capture and protocol analysis
- controlled real-device experiments
- hardware validation
- protocol fixtures and regression testing
- independently developed iOS implementation work
- Android implementation work that includes portions with Osmosis lineage

Protocol knowledge and source-code provenance are treated separately.

Discovering or confirming a protocol command does not imply that production
implementation code was copied from another project where the same behavior
was observed.

## Third-party source

The Android source contains code with lineage from the MIT-licensed Osmosis
project.

The Osmosis MIT license is preserved as:

`android/LICENSE_OSMOSIS.txt`

The Android source also contains DUML utility, message, CRC, and payload code
vendored or adapted directly from the MIT-licensed `dimadesu/dji-remote`
project by Dmytro Antonov.

The dji-remote MIT license is preserved as:

`android/LICENSE_DJI_REMOTE.txt`

See `THIRD_PARTY_NOTICES.md`.

## DJI protocol work

Much of the current Pocket 3 behavior has been independently characterized
through packet analysis and physical camera testing.

The project does not claim that every currently implemented DJI command or
field has been fully documented or understood.

Unknown behavior should remain identified as such until independently
validated.

## Independence

Kaze for DJI is not an official DJI application and does not use an official
DJI Osmo camera SDK for its direct Pocket 3 control implementation.

Kaze for DJI is not affiliated with, authorized by, sponsored by, or endorsed
by DJI.
