# Omi CV1 firmware privacy audit

Status: preliminary source audit complete; shipped-device attestation pending

Audited upstream revision:
`0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07`

This audit distinguishes three different claims:

1. **Source behavior:** what the pinned public source is configured to do.
2. **Release behavior:** what an official build from that source would do.
3. **Shipped-device behavior:** what the individual pendant actually runs.

Only the first claim is established today. Device Information Service strings
will help identify the shipped release, but a string is not cryptographic
attestation. Strong confirmation requires an image hash/readback or installing
a firmware and bootloader built under keys we control.

## Executive finding

The audited stock CV1 source is not suitable for a strong private-audio claim
without modification.

It has no enabled direct Internet path, but it intentionally records audio to
unencrypted soldered SD NAND whenever no phone is connected. Its BLE storage and
audio characteristics do not require an encrypted or authenticated GATT link in
the audited source. Its ring-clear operation resets metadata without overwriting
the recorded sectors. The configured MCUboot signing private key is also present
in the public repository.

Accordingly, the initial HomeBlend production target should use HomeBlend-owned
firmware before the pendant handles sensitive conversations.

## Source-confirmed findings

### 1. Offline audio recording is enabled — high privacy impact

- `CONFIG_OMI_ENABLE_OFFLINE_STORAGE=y` is enabled in
  [`omi.conf`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/omi.conf#L211-L220).
- The firmware describes the hardware as soldered SD NAND with a raw-sector
  audio ring in
  [`README.md`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/README.md#L25-L36).
- The ring capacity constant is `0x1E000000` bytes (480 MiB) in
  [`sd_card.h`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/src/lib/core/sd_card.h#L1-L18).
- The audio pusher writes to storage when there is no BLE connection; when a
  subscribed connection exists it streams over BLE instead. See
  [`transport.c`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/src/lib/core/transport.c#L1215-L1253).

This is not a speculative capability: it is enabled production behavior in the
pinned configuration.

### 2. Stored audio is plaintext in the audited source — high impact

The raw-ring write path writes timestamps and audio payload bytes directly to
SD sectors. No audio encryption, per-device storage key, or authenticated
encryption layer appears in the ring path. See
[`sd_card.c`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/src/sd_card.c#L690-L710).

An attacker with physical access to the NAND, a debug path, or an inadequately
protected BLE storage path may therefore recover audio.

### 3. Ring clear is logical deletion, not secure erasure — high impact

`clear_ring_internal()` resets read/write sequence metadata and persists the new
metadata. It does not overwrite the data sectors. See
[`sd_card.c`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/src/sd_card.c#L550-L570).

Old audio remains on NAND until later ring writes happen to overwrite it. A
normal `CMD_RING_CLEAR` acknowledgement is therefore not proof that past audio
is unrecoverable.

### 4. BLE audio/storage access is not encryption-gated in source — critical

- The device starts generic connectable advertising.
- Production connection handling does not request a security level with
  `bt_conn_set_security()`.
- Audio and storage characteristics use `BT_GATT_PERM_READ` / `WRITE`, not the
  encrypted or authenticated permission variants.
- The storage protocol exposes info, read, advance, and clear commands over BLE.

See
[`storage.c`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/src/lib/core/storage.c#L22-L95)
and
[`transport.c`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/src/lib/core/transport.c#L589-L656).

`CONFIG_BT_SMP=y` alone does not protect a characteristic. Physical testing must
still confirm the precise shipped behavior, but the audited source does not
provide the access-control properties we require.

### 5. No enabled direct Internet path — positive, with a caveat

The CV1 hardware lists an nRF7002 Wi-Fi part, but the source README says Wi-Fi is
not enabled in current firmware. The audited production configuration and source
contain BLE transport, not an enabled IP upload client. The NFC payload includes
an Omi pairing URL and device identifier, but NFC is passive and does not itself
make a network request.

This means Omi cloud exposure primarily comes through a connected phone/app,
not a direct pendant Internet connection, for the audited source.

### 6. Public firmware signing key — critical update-chain concern

`sysbuild.conf` configures MCUboot with
`../bootloader/mcuboot/root-rsa-2048.pem`. Inspection confirms that tracked file
begins with `BEGIN RSA PRIVATE KEY`; the repository also tracks the OTA encryption
private key. The normal documented update path accepts MCUmgr OTA packages over
BLE.

See
[`sysbuild.conf`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/sysbuild.conf#L7-L17)
and
[`BUILD.md`](https://github.com/BasedHardware/omi/blob/0dee519ad05b22f53c6ad45ee538fa7d5e8d2f07/omi/firmware/omi/BUILD.md#L47-L63).

If shipped devices trust this same public signing key, possession of a valid
signature does not establish an Omi-authored image. We must test the individual
device rather than assume its bootloader key matches the repository.

### 7. Advertised version is inspectable but not attestation

The pinned source advertises firmware `3.0.21`, hardware `5.0`, model `Omi CV 1`,
and manufacturer `Based Hardware` through the standard BLE Device Information
Service. These values are useful inventory evidence but can be changed by any
firmware image.

## What we can verify when the pendant arrives

Without installing the stock Omi app or creating an Omi account:

1. Read the complete BLE GATT table.
2. Read model, manufacturer, hardware revision, and firmware revision.
3. Read the custom feature bitmask and confirm offline-storage capability.
4. Query ring metadata without reading or clearing content.
5. Confirm whether a fresh, unpaired client can connect to and use audio/storage
   characteristics. Use only synthetic audio for this test.
6. Record the MCUboot/DFU services exposed in normal and recovery modes.
7. Attempt a signed test image only after preserving a stock recovery route.
8. For strong identity, use SWD/J-Link readback where permitted, hash the relevant
   application/bootloader regions, and compare them with locally built artifacts.
9. Verify logical-clear recoverability using synthetic audio and a debug/readback
   procedure; never use private speech for this experiment.

The read-only Windows/macOS/Linux BLE inventory is prepared at
[`scripts/probe-omi-firmware.py`](../scripts/probe-omi-firmware.py). It does not
subscribe to audio, download stored audio, clear storage, change settings, or
start DFU.

## HomeBlend firmware direction

### Privacy firmware v0 — fastest safe bring-up

- Disable offline audio storage entirely.
- Require LE Secure Connections and an authenticated bond.
- Require encrypted/authenticated GATT permissions for audio, button, haptic,
  settings, storage, and DFU controls.
- After enrollment, accept connections only from the bonded HomeBlend phone.
- Disable Wi-Fi, Omi NFC pairing URL, debug shell, and routine wireless DFU.
- Use a unique HomeBlend MCUboot signing key kept offline and outside Git/source.
- Expose an immutable build identifier and image digest for inventory.

This gives the strongest early privacy but accepts gaps during phone/BLE failure.

### Privacy firmware v1 — reliability without plaintext retention

- Restore a bounded audio recovery ring using per-device authenticated encryption.
- Provision its key from the HomeBlend phone through an authenticated channel.
- Use unique nonces and authenticated sequence metadata.
- Implement cryptographic erase by destroying/rotating the storage key.
- Release ring ranges only after authenticated DGX custody confirmation.
- Keep a visible backlog counter and an explicit verified purge operation.

## Release decision

Do not approve the stock firmware for sensitive continuous listening solely on
the basis that our phone app avoids Omi cloud. The app removes Omi's service from
the data path, but stock firmware still leaves local audio and BLE/update-chain
risks. Use synthetic phrases for arrival testing, then move to HomeBlend-owned
firmware before real-world private capture.
