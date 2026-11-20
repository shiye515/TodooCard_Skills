---
name: todoocard-skills
description: Pair, probe, prepare, validate, and explicitly send photos to compatible TodooCard/T3 528x792 six-color BLE e-paper cards from macOS. Optimized for v167 capabilities with safe fallback to legacy firmware.
---

# TodooCard Skills (v167-first)

Use this skill only on macOS with `swiftc`, Bluetooth permission, and physical proximity to the device. Image preparation additionally requires `python3` and `/usr/bin/sips`. This workflow is local BLE only.

## v167 secure pairing contract

Treat current T3 as secure and v167-first:

- Manufacturer `0x5053`, screen type `0x134C`.
- Secure capability bit `0x01` means encrypted GATT is required.
- Physical pairing-window bit `0x02` means pairing is open (up to 60 seconds).
- On current firmware (including v167 `raw=0xA7`), hold rear button for 5 seconds until front LED fast-flashes.
- Pairing succeeds **only** when encrypted Battery Level `180F/2A19` is read successfully.

Connection retry policy:

- Retry only `CBErrorDomain code=15` (encryption timeout).
- Max 2 retries after first attempt, with 0.75s then 1.5s backoff.
- Report all other errors immediately.

## Required operating sequence

1. List nearby devices:

   ```bash
   scripts/prepare_and_send.sh --list
   ```

2. Pair exact UUID when needed:

   ```bash
   scripts/prepare_and_send.sh --pair --device-id UUID
   ```

3. Probe exact UUID after pairing:

   ```bash
   scripts/prepare_and_send.sh --probe --device-id UUID
   ```

4. Prepare and validate image payload locally:

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic
   ```

5. Explicitly send only after confirmation:

   ```bash
   scripts/prepare_and_send.sh --input /path/image.heic --device-id UUID --send
   ```

## v167 transfer contract

For v167, use the verified v157+ reliable transfer model:

- Prefer independent 2 KB QuickLZ 1.5 level-3 blocks.
- If compression does not reduce over-the-air bytes, switch to RAW controller payload.
- Transfer by 32-block windows.
- After each window, wait for durable Flash checkpoint.
- If device requests a lower block index, treat it as repair within the same session; continue from requested index.
- On checkpoint timeout, resend only previous window-end block to solicit retained progress.
- Allow at most 16 repair/probe requests.
- Require final `0x05 0x08` refresh acknowledgement before reporting success.

## Diagnostics and fault interpretation

Image ACK failures:

- `0x01`: malformed or out-of-order block.
- `0x09`: external Flash write failure.
- `0x0A`: external Flash readback verification failure.

For v165+ firmware, read retained image-ACK diagnostics characteristic:

- Service `D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1001`
- Characteristic `D8B282F0-0F9B-4A7A-B5E8-8E6E5A3C1003`

Report session flags, generated/accepted/rejected ACK counts, requested block, previous status, notify result, and last received block.

## Image pipeline contract

- Input image limit: 100 MB and 50 megapixels.
- Normalize input via local conversion, then six-color Floyd-Steinberg dithering.
- For T3 528x792 (`0x134C`), always use `todoocard-correct` orientation.
- Do not expose `--screen-orientation`; reject overrides.
- Allow optional source correction with `--rotate-right-90` only for sideways inputs.

## Guardrails

- Always require exact UUID for pair/probe/send.
- Never choose target by name only.
- Refuse probe/send while pairing window is open.
- Refuse transfer in OTA recovery mode (capability bit `0x08`).
- Keep `--send` explicit (never implicit side effect).
- Do not send arbitrary external `.bin` or `.protocol.qlz`; generate and validate with bundled scripts.
- A disconnect is not success; only `0x05 0x08` is success.

## Legacy compatibility note

If firmware is pre-v157 (`raw < 0x9D`), automatically fall back to legacy 64-byte stored QuickLZ payload format for compatibility. Do not use legacy mode for v167 unless explicitly debugging protocol differences.
