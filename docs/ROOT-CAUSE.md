# Root-cause analysis — AIC8800D40 firmware mismatch

## TL;DR
The AIC8800D40 on these H616/H618 boards fails to boot because the **firmware blob shipped with
Armbian/ophub is wrong for this silicon revision** (`chip rev: 7`). The chip's own original
Android firmware boots it. The SDIO bus (sunxi-mmc) is **not** the problem.

## The chip
- **AIC8800D40**, SDIO vendor `0xc8a1`, device `0x0082`, **chip rev 7**.
- The driver reports it as "AIC8800D80" and loads firmware files named `*_8800d80_u02.bin`. This is
  the vendor/driver naming — the SDIO id `0x0082` is served through the D80 code path. The physical
  chip on these boards is the AIC8800D40 (confirmed by the package marking and the AIC8800D4-series
  datasheets).
- Single antenna (1T1R), 802.11a/b/g/n/ac, AP + STA.

## What the logs show with the broken firmware
```
aicbsp_platform_power_on
aicbsp_sdio_probe:1 vid:0xC8A1  did:0x0082
aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fmacfw_8800d80_u02.bin
file md5:<the broken blob>
rd_version_val=00000000              ← firmware uploaded but did NOT boot
8800d80 wifi start fail
```
Key point: there is **no** `sunxi-mmc: data error, sending stop command` and no
`aicwf_sdio_send_pkt fail-110`. Probe, register init, and the firmware upload all succeed — the SDIO
bus is healthy. The failure is *after* the upload: the chip never reports a version, i.e. the
firmware binary did not execute on this silicon.

## Why it was misdiagnosed as "sunxi-mmc"
Earlier community write-ups blamed the Allwinner sunxi-mmc controller for corrupting large SDIO
transfers. On this hardware that is **not** what happens: the transfer completes cleanly. The
`rd_version=0` is a firmware-execution failure, not a transfer error. (It's possible other board
silicon revisions did hit genuine sunxi-mmc issues — but for `rev 7` with the correct firmware, the
bus is fine.)

## The two real levers

### 1. Firmware blob
Four different `fmacfw_8800d80_u02.bin` were observed; only one boots this chip:

| firmware md5 | source | boots rev 7? |
|---|---|---|
| `423e5b57…` | Armbian/ophub stock | ❌ `rd_version=0` |
| `01acfbeb…` | one community driver tree | ❌ `cmd timed-out` |
| `13e6f0e5…` | ArtinChip SDK (per their D40L doc) | ✅ |
| `48c3e1db…` | **this device's own Android vendor partition** | ✅ ← used here |

The whole set is needed (`fmacfw_8800d80_u02.bin`, `fw_adid_8800d80_u02.bin`,
`fw_patch_8800d80_u02.bin`, `fw_patch_table_8800d80_u02.bin`, `lmacfw_rf_8800d80_u02.bin`,
`aic_userconfig_8800d80.txt`). They must all come from the same vendor build.

### 2. SDIO clock = 150 MHz
The driver's `FEATURE_SDIO_CLOCK_V3` defaults to 50 MHz (some trees 25 MHz). On `rev 7` the
bring-up fails at 50/25 MHz. Setting it to **150 MHz** (`150000000`) is required. The ArtinChip
D40L documentation independently shows this chip running at 150 MHz.

## How the working firmware was obtained
From the device's own Android eMMC image (the box ships Android; Armbian is installed alongside or
instead). The Android `vendor` partition contains the firmware the manufacturer validated for this
exact board. Extraction: dump eMMC → find the `super` partition → unpack its logical partitions
(LP metadata) → mount/`debugfs` the `vendor_a` ext4 → copy `/etc/firmware/aic8800d80/*`.
Step-by-step (no personal paths) → [../firmware/FIRMWARE-EXTRACTION.md](../firmware/FIRMWARE-EXTRACTION.md).

## Driver port to 6.18
The base is **LYU4662/aic8800-sdio-linux-1.0** (an SDIO driver with both the base and the D80
bring-up procedures). Linux 6.18 broke it in several ways; the port covers:
- cfg80211 `net_device → wireless_dev` op conversion (the 6.12+ refactor) for ~10 ops.
- timer API renames (`del_timer_sync`→`timer_delete_sync`, etc.) + a `from_timer` compat shim.
- wakelock API (`wakeup_source_create/add/remove/destroy` → `register/unregister`).
- guards/disables for ops removed or changed in 6.18 (`channel_switch`, `start_radar_detection`,
  TDLS `mgmt->u`).
- `FEATURE_SDIO_CLOCK_V3 = 150000000`.
- the Rockchip-Android `VFS_internal_…` namespace import removed.

→ [BUILD-DRIVER.md](BUILD-DRIVER.md) to rebuild for your kernel.

## Result
With the correct firmware + 150 MHz + the ported driver:
```
is 5g support = 1
Firmware Version: <date> ...
New interface create wlan0
```
`wlan0` up; `hostapd` brings up a 5 GHz 802.11ac WPA2 AP.
