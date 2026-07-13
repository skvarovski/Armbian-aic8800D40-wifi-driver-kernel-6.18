# Root-cause analysis — AIC8800D40 won't boot (firmware + DTB SDIO clock + driver)

## TL;DR
The AIC8800D40 on these H616/H618 boards fails to produce `wlan0` for **three independent
reasons**, each with its own `dmesg` signature. All three must be fixed:

1. **Wrong firmware blob** (Armbian/ophub stock) → `rd_version_val=00000000`, the chip never boots.
   Fix: the device's own Android firmware (`fmacfw_8800d80_u02.bin` md5 `48c3e1db`).
2. **DTB `mmc1 max-frequency` too high** (150 MHz in the ophub Vontar-H618 tree) → the SDIO bus
   runs at 50 MHz, can't hold signal integrity → `sunxi-mmc: data error` during firmware upload.
   Fix: cap mmc1 at **25 MHz** (`ap-config/aic-dtb-25mhz.sh`). **This is the real "sunxi-mmc"
   root cause** — not controller tuning.
3. **No driver** in the stock image (the AIC8800 SDIO driver is out-of-tree) → nothing probes the chip.
   Fix: the ported driver (prebuilt for `6.18.37-ophub`, or rebuild from source).

The two failure modes look different in the logs (see below) and people chase the wrong one.
**Both** can hit the same board — fix firmware *and* DTB.

## The chip
- **AIC8800D40**, SDIO vendor `0xc8a1`, device `0x0082`, **chip rev 7**.
- The driver reports it as "AIC8800D80" and loads firmware files named `*_8800d80_u02.bin`. This is
  the vendor/driver naming — the SDIO id `0x0082` is served through the D80 code path. The physical
  chip on these boards is the AIC8800D40 (confirmed by the package marking and the AIC8800D4-series
  datasheets).
- Single antenna (1T1R), 802.11a/b/g/n/ac, AP + STA.

## Failure mode A — wrong firmware (`rd_version=0`, **no** data error)
```
aicbsp_sdio_probe:1 vid:0xC8A1  did:0x0082
aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fmacfw_8800d80_u02.bin
rd_version_val=00000000              ← firmware uploaded but did NOT boot
8800d80 wifi start fail
```
Note: there is **no** `sunxi-mmc: data error` here — the transfer completed cleanly, the chip just
refused the firmware binary. The stock Armbian/ophub blob (`423e5b57`) and one community tree
(`01acfbeb`) fail this way. The fix is the right blob.

## Failure mode B — DTB SDIO clock too high (`data error`)
```
aicbsp_sdio_probe:1 vid:0xC8A1  did:0x0082
aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fw_patch_table_8800d80_u02.bin
sunxi-mmc 4021000.mmc: data error, sending stop command   ← SDIO transfer corrupted
sunxi-mmc 4021000.mmc: send stop command failed
aicbsp: sdio_err:<aicwf_sdio_send_pkt,971>: aicwf_sdio_send_pkt fail-110
```
This is what happens on a **clean** ophub install once the correct firmware is in place: the driver
asks for 150 MHz, the controller accepts (DTB allows 150) and raises the bus to **50 MHz** (SD
high-speed), which this board's SDIO routing can't hold — large firmware transfers corrupt.

**This was long misdiagnosed as a sunxi-mmc controller bug / "phase tuning". It is not.** The
controller is fine; the clock is simply too fast for the board. Capping `mmc1 max-frequency` at
**25 MHz** in the DTB makes the transfers clean. (Known-good Armbian images that "just work" already
run this slot at 25 MHz.)

### The SDIO clock, precisely
The driver's `FEATURE_SDIO_CLOCK_V3 = 150000000` is a **request**, not a hard setting. The actual
bus clock is `min(DTB max-frequency, request)`:

| DTB `mmc1 max-frequency` | actual bus clock | result |
|---|---|---|
| 150 MHz (0x8f0d180) — ophub Vontar-H618 default | 50 MHz (SD high-speed) | ❌ `data error` |
| 25 MHz (0x17d7840) | 25 MHz | ✅ clean, chip boots |

So "150 MHz in the driver" is harmless (the controller caps it). The **DTB** is the real lever, and
the working frequency is **25 MHz** — slow but solid. The 1T1R SDIO PHY ceiling (~70-90 Mbps) is the
same at 25 MHz as at 50. Patch: `ap-config/aic-dtb-25mhz.sh` (touches only `mmc@4021000`; mmc0/mmc2
stay at 150 MHz).

## The three real levers

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

### 2. DTB mmc1 max-frequency = 25 MHz
See "Failure mode B" above. `ap-config/aic-dtb-25mhz.sh` patches only the WiFi SDIO slot
(`mmc@4021000`) from 150 MHz → 25 MHz and recompiles the DTB. Reboot to apply. Without this you get
`data error` even with the correct firmware.

### 3. Driver port to 6.18
The AIC8800 SDIO driver is out-of-tree, and a clean ophub image ships **no** `aic8800_*.ko` at all
(nothing probes the chip). The base is **LYU4662/aic8800-sdio-linux-1.0** (SDIO, base+D80 procedure).
Linux 6.18 broke it in several ways; the port covers:
- cfg80211 `net_device → wireless_dev` op conversion (the 6.12+ refactor) for ~10 ops.
- timer API renames (`del_timer_sync`→`timer_delete_sync`, etc.) + a `from_timer` compat shim.
- wakelock API (`wakeup_source_create/add/remove/destroy` → `register/unregister`).
- guards/disables for ops removed or changed in 6.18 (`channel_switch`, `start_radar_detection`,
  TDLS `mgmt->u`).
- `FEATURE_SDIO_CLOCK_V3 = 150000000` (the request; capped by the DTB — see above).
- the Rockchip-Android `VFS_internal_…` namespace import removed.

→ [BUILD-DRIVER.md](BUILD-DRIVER.md) to rebuild for your kernel. Prebuilt for `6.18.37-ophub` is in
`driver/prebuilt-6.18.37-ophub/`.

## How the working firmware was obtained
From the device's own Android eMMC image (the box ships Android; Armbian is installed alongside or
instead). The Android `vendor` partition contains the firmware the manufacturer validated for this
exact board. Extraction: dump eMMC → find the `super` partition → unpack its logical partitions
(LP metadata) → mount/`debugfs` the `vendor_a` ext4 → copy `/etc/firmware/aic8800d80/*`.
Step-by-step (no personal paths) → [../firmware/FIRMWARE-EXTRACTION.md](../firmware/FIRMWARE-EXTRACTION.md).

## AP bring-up gotchas (after the chip boots)

The firmware + DTB + driver fixes above get `wlan0` to appear and the chip to boot.
A **second, unrelated** set of problems lives in the AP bring-up path — these are
what make the AP actually serve clients with DHCP, DNS, and internet. They are
generic Linux AP issues, not AIC8800-specific, but they bite hard on a stock
Armbian image because nothing is pre-configured for a hostapd AP. `INSTALL.sh`
handles all of them; this section explains the "why" for anyone debugging.

### 1. `wpa_supplicant` grabs wlan0 before hostapd (AP fails to hold)
On a stock Armbian/Debian image, D-Bus activates a system `wpa_supplicant`
instance (`-u -s`) which claims `wlan0` the moment the driver creates it. When
`hostapd` then tries to bring the AP up, it loses the race. The tell-tale `dmesg`
signature is `wlan0: AP started` immediately followed by `wlan0: AP Stopped`
(1 ms later), and a `p2p-dev-wlan0` virtual interface appears. In `hostapd`
logs you see `interface state UNINITIALIZED->HT_SCAN` then
`Deactivated successfully` — it never reaches `AP-ENABLED`.

**Fix:** `systemctl stop wpa_supplicant` + `systemctl mask wpa_supplicant` (+ the
`.socket` unit if present). `mask` alone is **not** enough if a D-Bus instance is
already running — `stop`/`pkill` it first. This box is AP-only; its WAN is on
ethernet, so it does not need `wpa_supplicant` at all.

### 2. hostapd is **masked** on Debian by default
Debian ships `hostapd.service` masked. `systemctl enable` silently does nothing
and after a reboot hostapd is `inactive`. **Fix:** `systemctl unmask hostapd`
**before** `enable`. `INSTALL.sh` does this.

### 3. AIC8800 HT40 coexistence scan fails → AP never reaches ENABLED
With `ht_capab=[HT40+]`, hostapd runs an HT coexistence scan (`HT_SCAN`) before
bringing the AP up. On AIC8800 this scan frequently fails →
`Interface initialization failed` → `HT_SCAN->DISABLED`, looping. (Upstream
hostapd has **no** `noscan` option — that exists only in OpenWrt patches, don't
waste time on it.) **Fix:** use **HT20** (`ht_capab=[SHORT-GI-20]`). HT20+AC is
stable. The default `hostapd.conf` in this repo is HT20.

### 4. `wlan0` has no IP → dnsmasq can't serve DHCP
A boot oneshot that sets the wlan0 IP (`sbc-wlan0-up.service`) races with the
AIC8800 driver creating `wlan0`. If the driver probes late, the IP is never set.
`dnsmasq` then logs `DHCP packet received on wlan0 which has no address`, and
clients connect (WPA handshake succeeds) then disconnect every ~18 s in a
DHCP-timeout loop.

**Fix:** set the wlan0 IP **after** the AP is up, in a `hostapd.service`
`ExecStartPost` (`ip addr replace <AP_IP>/24 dev wlan0`), in addition to the
boot oneshot. The drop-in in this repo does exactly that.

### 5. dnsmasq starts before wlan0 exists → "unknown interface wlan0"
On boot, `dnsmasq` can start before the AIC8800 driver has created `wlan0`, so
`interface=wlan0` fails with `unknown interface wlan0` and dnsmasq exits. After
a reboot the AP is then up but DHCP is dead. **Fix:** order dnsmasq
`After=hostapd.service` and add `Restart=on-failure` (drop-in). hostapd is up ⇒
wlan0 exists.

### 6. hostapd's forking unit silently swallows AP failures
Debian's stock `hostapd.service` is `Type=forking` and runs `hostapd -B`
(background/daemonize). `hostapd -B` exits 0 **even when the AP fails to come
up**, so systemd sees "success" and `Restart=on-failure` never fires — the box
sits with the AP down and no retry.

**Fix:** the drop-in `hostapd.service.d/retry-ap.conf` → `Type=simple` (no
`-B`), `Restart=always`, `RestartSec=5`, `StartLimitBurst=20`. Now a real AP
failure is a non-zero exit, and systemd restarts hostapd until it sticks.

### 7. systemd-resolved conflicts with dnsmasq on :53 (and `port=0`)
Two separate DNS traps:

- **Port conflict.** systemd-resolved listens on `127.0.0.53:53`. dnsmasq tries
  to bind `wlan0:53`; depending on ordering this can fail, and clients querying
  the AP IP (`192.168.43.1:53`) get no answer because nothing serves it on that
  interface. **Fix:** `systemctl disable --now systemd-resolved`, break the
  `/etc/resolv.conf` symlink, and write a static resolv.conf
  (`nameserver 1.1.1.1` / `8.8.8.8`) — `chattr +i` so nothing re-symlinks it.

- **`port=0`.** The old dnsmasq config in this repo shipped `port=0`, which
  **disables dnsmasq's DNS server entirely** (DHCP-only mode). Clients get a DHCP
  lease that advertises the AP IP as their DNS server, but nothing answers there.
  **Fix:** remove `port=0`; instead use `no-resolv` + explicit `server=1.1.1.1`
  / `server=8.8.8.8` so dnsmasq doesn't depend on the resolvconf↔resolved plumbing.

### 8. NAT for client internet
AP clients get a `192.168.43.x` address but can't reach the internet without
masquerading and forwarding. **Fix:** `sbc-ap-nat.sh` — an idempotent script
(`iptables -t nat -C ... || -A ...`) that MASQUERADES the AP subnet out to the
WAN interface, plus FORWARD rules (wlan0→WAN allow, established/related allow).
WAN is detected dynamically via `ip route show default` (not hardcoded `eth0`),
because some boards name it `end0` or `eth1`. The script runs from the hostapd
`ExecStartPost`, after the AP and the wlan0 IP are up.

### 9. dnsmasq loads every file in `/etc/dnsmasq.d/` (backup gotcha)
dnsmasq's default Debian invocation uses `-7 /etc/dnsmasq.d`, which reads
**every** file in that directory. A backup file left there — e.g.
`ap.conf.pre-dnsfix` still containing `port=0` — silently re-disables DNS even
after you fixed the real config. **Fix:** always move backups **out** of
`/etc/dnsmasq.d/` (to `/root/`, `/etc/backup/`, anywhere else). `INSTALL.sh`
scrubs common backup patterns from `/etc/dnsmasq.d/` and warns if any `port=0`
remains.

## Result
With the correct firmware + DTB mmc1@25 MHz + the ported driver:
```
aicbsp_driver_fw_init, chip rev: 7
Firmware Version: mi Sep 05 2023 ...
sdio ready
New interface create wlan0
```
`wlan0` up; `hostapd` brings up a 5 GHz 802.11ac WPA2 AP. With the AP bring-up
fixes above (wpa_supplicant masked, hostapd unmasked + retry drop-in, HT20,
dnsmasq After=hostapd, DHCP+DNS, NAT), clients get DHCP + DNS + internet.
Expected throughput is ~70-90 Mbps down — this is the 1T1R SDIO ceiling, not a bug.
