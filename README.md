# AIC8800D40 built-in WiFi on Allwinner H618 (Armbian / ophub 6.18) — fix & 802.11ac WPA2 AP

> Get the built-in **AIC8800D40** WiFi (802.11ac / WiFi 5, 5 GHz, single antenna) working on
> Allwinner **H616/H618** TV boxes (Vontar H618 / X98H class) running **Armbian with an ophub
> 6.18.x kernel**, and turn it into a WPA2 access point.

## TL;DR

The chip works. A clean Armbian/ophub image fails to bring up `wlan0` for **three independent
reasons** — each with its own `dmesg` signature, all must be fixed:

1. **Wrong firmware blob** — the stock firmware uploads but never boots
   (`rd_version=00000000`, `8800d80 wifi start fail`, **no** `data error`). Fix: the device's own
   Android firmware (`fmacfw_8800d80_u02.bin` md5 `48c3e1db`).
2. **DTB `mmc1 max-frequency` too high (150 MHz)** — the ophub Vontar-H618 device tree lets the
   SDIO bus run at 50 MHz, which corrupts the firmware upload (`sunxi-mmc: data error`). This is
   the real "sunxi-mmc" cause — **not** controller tuning. Fix: cap mmc1 at **25 MHz**
   (`ap-config/aic-dtb-25mhz.sh`). (The driver's `FEATURE_SDIO_CLOCK=150` is just a *request*; the
   DTB is the real lever, and 25 MHz is the working frequency.)
3. **No driver** — the AIC8800 SDIO driver is out-of-tree and absent from a clean ophub image.
   Fix: the ported driver (prebuilt for `6.18.37-ophub`, or rebuild).

Plus a 5 GHz regulatory domain (RU) + `hostapd` for the AC WPA2 AP.

> **⚠️ Known gotchas (handled automatically by `INSTALL.sh`):**
> - **`sunxi-mmc data error`** on a clean install = DTB clock too high → `aic-dtb-25mhz.sh` + reboot.
> - System **`wpa_supplicant`** grabs `wlan0` before `hostapd`; **hostapd is masked** on Debian by
>   default; **AIC8800 HT40 scan** fails → use HT20. `INSTALL.sh` handles all of these and sets up
>   DHCP/DNS/NAT. For manual config, see [docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md).

**Result:** a working 5 GHz 802.11ac WPA2 access point — DHCP, DNS, and NAT internet
for clients. Expected throughput is ~70-90 Mbps down (the 1T1R SDIO PHY ceiling — not a
bug; use a 2×2 USB dongle for more).

```bash
git clone https://github.com/skvarovski/Armbian-aic8800D40-wifi-driver-kernel-6.18
cd Armbian-aic8800D40-wifi-driver-kernel-6.18
# 1. download the firmware release-asset and extract it into firmware/
# 2. install (defaults: SSID=AIC8800D40-AP, password=ChangeMe12345, channel 36)
./ap-config/INSTALL.sh
# or customize:
#   SSID=MyAP PASS=supersecret CHANNEL=36 AP_IP=192.168.43.1 ./ap-config/INSTALL.sh
iw dev wlan0          # → interface wlan0, type AP, ssid AIC8800D40-AP, 5 GHz
```

## Symptoms (you probably arrived here from a search)

**Mode A — wrong firmware** (`rd_version=0`, no `data error`):
```
aicbsp: aicbsp_sdio_probe:1 vid:0xC8A1  did:0x0082
aicbsp: aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fmacfw_8800d80_u02.bin
rd_version_val=00000000
8800d80 wifi start fail          # ← with the stock firmware blob
```

**Mode B — DTB SDIO clock too high** (`data error`, happens on a clean ophub install once the
firmware is correct):
```
aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fw_patch_table_8800d80_u02.bin
sunxi-mmc 4021000.mmc: data error, sending stop command   ← bus at 50 MHz, transfer corrupts
aicwf_sdio_send_pkt fail-110
```

In both: no `wlan0`, no AP. Mode A = firmware didn't boot (file is wrong). Mode B = the SDIO
transfer itself corrupted (bus too fast). Different causes, different fixes — see below.

## Root cause

* **Wrong firmware blob** (mode A). The `fmacfw_8800d80_u02.bin` shipped in Armbian/ophub firmware
  packages does not boot this silicon revision (`chip rev: 7`). The chip's own original Android
  firmware boots it. The firmware **file names** carry `d80` — that's the vendor/driver naming
  convention; the **chip** is the AIC8800D40.
* **DTB `mmc1 max-frequency` too high** (mode B). The ophub Vontar-H618 device tree sets the WiFi
  SDIO slot to 150 MHz. The driver requests 150, the controller runs the bus at **50 MHz** (SD
  high-speed), and large firmware transfers corrupt → `sunxi-mmc: data error`. Capping mmc1 at
  **25 MHz** makes them clean. (The driver's `FEATURE_SDIO_CLOCK=150` is a request, not a hard
  setting — `min(DTB max-frequency, request)` is what actually runs; 25 MHz is the working value.)
* **No driver** — out-of-tree, absent from a clean ophub image. Nothing probes the chip.

Detailed write-up → [docs/ROOT-CAUSE.md](docs/ROOT-CAUSE.md). Symptom→diagnosis table →
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Confirmed hardware

| | |
|---|---|
| Board | Vontar H618 / X98H-class (Allwinner H616/H618) |
| WiFi/BT | **AIC8800D40**, SDIO (`vid 0xc8a1 / did 0x0082`), chip rev 7, single antenna (1T1R) |
| Capabilities | 802.11a/b/g/n/ac (5 GHz, VHT, ~390 Mbps PHY), AP + STA |
| OS | Armbian (Debian/trixie) with **ophub 6.18.37** kernel |

## Quick start (turnkey)

Requirements: your box already runs an ophub 6.18.37 Armbian, has the kernel headers installed
(`/lib/modules/$(uname -r)/build`), and `wlan0` appears once the driver loads. Internet access for
`apt install hostapd dnsmasq`.

```bash
git clone https://github.com/skvarovski/Armbian-aic8800D40-wifi-driver-kernel-6.18 && cd Armbian-aic8800D40-wifi-driver-kernel-6.18
# Firmware: download the latest Release asset (aic8800D40-firmware.tar.gz),
#           extract into ./firmware/ so the .bin files sit there.
#           Verify: sha256sum -c firmware/SHA256SUMS
SSID=MyAP PASS=ChangeMe12345 CHANNEL=36 AP_IP=192.168.43.1 ./ap-config/INSTALL.sh
```

`INSTALL.sh` is idempotent. It installs the prebuilt modules for `6.18.37-ophub`, places the
firmware on all paths the loader searches, sets regdom RU, installs hostapd/dnsmasq, masks
`wpa_supplicant`, disables `systemd-resolved`, installs the hostapd retry drop-in + NAT script,
sets up DHCP+DNS+NAT, and starts the AP. After it: `iw dev wlan0` should show `type AP`, and
clients should get DHCP + DNS + internet.

> Different kernel? The prebuilt `.ko` only matches `6.18.37-ophub` (vermagic). For any other
> kernel, rebuild the driver from source — see [docs/BUILD-DRIVER.md](docs/BUILD-DRIVER.md).

## Firmware
<a name="firmware"></a>

The working firmware is **proprietary** (vendor AICSEMI/ArtinChip), so it is **not** committed to
the repo tree. Get it either:

* **(easy)** Download `aic8800D40-firmware.tar.gz` from this repo's **Releases** page. Verify with
  `firmware/SHA256SUMS`.
* **(clean / legal / any box)** Extract it yourself from your device's own Android eMMC dump —
  see [firmware/FIRMWARE-EXTRACTION.md](firmware/FIRMWARE-EXTRACTION.md). Same method works for
  any AIC8800D40 board if the bundled firmware differs.

If you are the firmware vendor and want the Release asset taken down, open an issue.

## AP configuration

Defaults (override via env to `INSTALL.sh` or edit `/etc/hostapd/hostapd.conf` after install):

| Setting | Default |
|---|---|
| SSID | `AIC8800D40-AP` |
| WPA2 passphrase | `ChangeMe12345` |
| Band / channel | 5 GHz / 36 |
| Mode | 802.11ac (HT20, WPA2-PSK/CCMP) — HT40 scan fails on AIC8800, see [ROOT-CAUSE.md §3](docs/ROOT-CAUSE.md) |
| AP IP / DHCP | `192.168.43.1/24`, DHCP `.10–.50` |

This brings up the **WiFi AP with full client internet**: DHCP + DNS via `dnsmasq`
(forwarding to `1.1.1.1` / `8.8.8.8`), and NAT via `iptables` MASQUERADE (WAN detected
dynamically). A captive portal is out of scope — add your own if you need one.

## Contents

```
driver/prebuilt-6.18.37-ophub/   # ready aic8800_bsp.ko + aic8800_fdrv.ko (ophub 6.18.37)
driver/patches/                  # the 6.18 port (cfg80211 wdev, timer API, 150 MHz clock request, ...)
driver/build.sh                  # rebuild for your kernel from upstream LYU4662 + patches
firmware/SHA256SUMS              # verify the Release firmware asset
firmware/FIRMWARE-EXTRACTION.md # extract the firmware from your own Android dump
ap-config/aic-dtb-25mhz.sh       # ★ DTB patch: mmc1 WiFi 150 MHz → 25 MHz (fixes sunxi-mmc data error)
ap-config/                        # hostapd.conf (HT20), dnsmasq, NAT, hostapd retry drop-in, INSTALL.sh
docs/                             # ROOT-CAUSE, BUILD-DRIVER, TROUBLESHOOTING
```

## Credits & references

* **LYU4662/aic8800-sdio-linux-1.0** — the driver base (SDIO, base+D80 procedure).
* **ArtinChip aic8800D40L documentation** — confirmed the same chip (`rev 7`, SDIO `0x0082`) works
  with 150 MHz + a good firmware blob.
* **NickAlilovic/build** — the X98H device-tree patch confirmed the WiFi power/pwrseq wiring.

## License

GPL-2.0 for code/scripts/docs (see [LICENSE](LICENSE)). Firmware blobs are vendor property, shared
only as a Release convenience.
