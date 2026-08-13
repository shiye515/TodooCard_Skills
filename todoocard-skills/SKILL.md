---
name: todoocard-skills
description: Pair, probe, prepare, validate, and explicitly send photos to compatible TodooCard/T3 528x792 six-color BLE e-paper cards from macOS. Use when a user asks to pair a Mac with a current secure TodooCard, transfer JPG, PNG, or HEIC images, inspect nearby compatible BLE cards, or diagnose pairing, encrypted GATT access, image orientation, and color rendering.
---

# TodooCard Skills

Use this skill only on macOS with `swiftc`, Bluetooth permission, and physical
proximity to the device. Image preparation additionally requires `python3` and
`/usr/bin/sips`. This is a local BLE workflow; it makes no network calls.

## Secure pairing contract

Current secure T3 firmware advertises manufacturer `0x5053`, screen type
`0x134C`, encrypted-GATT capability bit `0x01`, and physical-pairing-window bit
`0x02`. Treat firmware `0x8C+` with bit `0x01` as secure. The latest v0x95
(v149) flow is:

- Hold the rear button for 10 seconds until the front light fast-flashes.
- Detect bit `0x02`; it remains open for at most 60 seconds.
- Connect only the exact CoreBluetooth UUID and read encrypted Battery Level
  `180F/2A19` to create and verify the macOS system bond.
- Pairing succeeds only after encrypted access succeeds. An ordinary BLE
  connection is not proof of pairing.
- Retry only `CBErrorDomain` code `15` (encryption timeout), at most twice
  after the first attempt with 0.75-second and 1.5-second backoff. Report all
  other errors immediately.
- Pair separately from probing or sending. The firmware rejects pairing when
  the physical window is closed and rejects an old bonded central while a new
  device is pairing.

## Safety-first workflow

1. Build and list nearby devices without writing:

   ```bash
   scripts/prepare_and_send.sh --list
   ```

2. Ask the user to select the exact UUID. If the list reports `secure=yes` and
   the Mac is not already paired, request confirmation before changing the
   macOS system bond. Then start the pairing waiter and tell the user to hold
   the rear button for 10 seconds:

   ```bash
   scripts/prepare_and_send.sh --pair --device-id UUID
   ```

   The command waits for `pairing=open`; it must not connect while the bit is
   closed. If macOS shows a pairing prompt, ask the user to accept it.

3. Probe the exact UUID after pairing. This verifies manufacturer `0x5053`,
   screen `0x134C`, the existing encrypted bond, and FEF1/FEF2 access without
   changing the display:

   ```bash
   scripts/prepare_and_send.sh --probe --device-id UUID
   ```

4. Prepare and validate the image first. This does not contact a device:

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic
   ```

5. State the exact target UUID and request confirmation immediately before the irreversible display update. Only after confirmation, send:

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic --device-id UUID --send
   ```

The script normalizes images to PNG, uses six-color Floyd-Steinberg dithering,
creates a compressed T3 payload, and validates its size and QuickLZ wrapper
before Bluetooth transfer. For TodooCard/T3 528x792 (`0x134C`), it always
uses the bottom-layer `todoocard-correct` panel calibration.

## Canonical display orientation

Treat an upright source image as the correct user-facing orientation. Always
use the bottom-layer `todoocard-correct` calibration for TodooCard/T3 528x792
(`0x134C`) payloads. Its current implementation performs the proven panel
compensation internally; callers must not rotate, mirror, reproduce, or
override that implementation. Reject every other T3 orientation and do not
expose `--screen-orientation` as a user option.

For an individual source image that is sideways, add the optional source-image
correction below. The canonical bottom-layer panel calibration still runs
afterward:

```bash
--rotate-right-90
```

The screen controller transform is already handled internally; do not add a
second controller rotation.

## Guardrails

- Require an exact device UUID for probe or send. Do not select a device by name alone.
- Require an exact device UUID for pairing. Never connect merely because a
  name, RSSI, or service resembles TodooCard.
- Pair only through `--pair`, only after the user authorizes creating a system
  bond, and only after the target advertises `pairing=open`.
- Refuse `--probe` and `--send` while the new-device pairing window is open.
  Use `--pair` for a genuinely new Mac, or wait for normal advertising to
  resume before accessing an existing bond.
- Treat encrypted Battery Level access as the pairing proof. Do not claim
  success from `didConnect`, service discovery, or a system prompt alone.
- Keep `--send` opt-in. A successful transfer permanently changes the screen until another image is sent.
- Always use `todoocard-correct` for TodooCard/T3 528x792 (`0x134C`) controller
  packing. Accept upright source images and refuse raw orientation overrides.
- Do not send arbitrary `.bin` or `.protocol.qlz` files. Always generate and validate them with the bundled converter.
- Treat local images and generated payloads as private. The script keeps transient copies under `/tmp`; do not upload them or log their paths externally.
- The input-size limit is 100 MB and 50 megapixels. Refuse larger inputs rather than exhausting memory.
- If the final device acknowledgement is absent, report failure; do not claim the display refreshed.
