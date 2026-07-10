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

## AP bring-up gotchas (after the chip boots)

The firmware/driver/clock fixes above get `wlan0` to appear and the chip to boot.
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

**Fix:** `systemctl mask wpa_supplicant` (and stop it if running). This box is
AP-only; its WAN is on ethernet, so it does not need `wpa_supplicant` at all.
Masking (not just stopping) prevents D-Bus from re-activating it.

### 2. `wlan0` has no IP → dnsmasq can't serve DHCP
A boot oneshot that sets the wlan0 IP (`sbc-wlan0-up.service`) races with the
AIC8800 driver creating `wlan0`. If the driver probes late, the IP is never set.
`dnsmasq` then logs `DHCP packet received on wlan0 which has no address`, and
clients connect (WPA handshake succeeds) then disconnect every ~18 s in a
DHCP-timeout loop.

**Fix:** set the wlan0 IP **after** the AP is up, in a `hostapd.service`
`ExecStartPost` (`ip addr replace <AP_IP>/24 dev wlan0`), in addition to the
boot oneshot. The drop-in in this repo does exactly that.

### 3. hostapd's forking unit silently swallows AP failures
Debian's stock `hostapd.service` is `Type=forking` and runs `hostapd -B`
(background/daemonize). `hostapd -B` exits 0 **even when the AP fails to come
up**, so systemd sees "success" and `Restart=on-failure` never fires — the box
sits with the AP down and no retry.

**Fix:** the drop-in `hostapd.service.d/retry-ap.conf` → `Type=simple` (no
`-B`), `Restart=always`, `RestartSec=5`, `StartLimitBurst=20`. Now a real AP
failure is a non-zero exit, and systemd restarts hostapd until it sticks.

### 4. systemd-resolved conflicts with dnsmasq on :53 (and `port=0`)
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

### 5. NAT for client internet
AP clients get a `192.168.43.x` address but can't reach the internet without
masquerading and forwarding. **Fix:** `sbc-ap-nat.sh` — an idempotent script
(`iptables -t nat -C ... || -A ...`) that MASQUERADES the AP subnet out to the
WAN interface, plus FORWARD rules (wlan0→WAN allow, established/related allow).
WAN is detected dynamically via `ip route show default` (not hardcoded `eth0`),
because some boards name it `end0` or `eth1`. The script runs from the hostapd
`ExecStartPost`, after the AP and the wlan0 IP are up.

### 6. dnsmasq loads every file in `/etc/dnsmasq.d/` (backup gotcha)
dnsmasq's default Debian invocation uses `-7 /etc/dnsmasq.d`, which reads
**every** file in that directory. A backup file left there — e.g.
`ap.conf.pre-dnsfix` still containing `port=0` — silently re-disables DNS even
after you fixed the real config. **Fix:** always move backups **out** of
`/etc/dnsmasq.d/` (to `/root/`, `/etc/backup/`, anywhere else). `INSTALL.sh`
scrubs common backup patterns from `/etc/dnsmasq.d/` and warns if any `port=0`
remains.

## Result
With the correct firmware + 150 MHz + the ported driver:
```
is 5g support = 1
Firmware Version: <date> ...
New interface create wlan0
```
`wlan0` up; `hostapd` brings up a 5 GHz 802.11ac WPA2 AP. With the AP bring-up
fixes above (wpa_supplicant masked, hostapd retry drop-in, dnsmasq DHCP+DNS, NAT),
clients get DHCP + DNS + internet. Expected throughput is ~70-90 Mbps down — this
is the 1T1R SDIO ceiling, not a bug.
