# AIC8800D40 built-in WiFi on Allwinner H618 (Armbian / ophub 6.18) — fix & 802.11ac WPA2 AP

> Get the built-in **AIC8800D40** WiFi (802.11ac / WiFi 5, 5 GHz, single antenna) working on
> Allwinner **H616/H618** TV boxes (Vontar H618 / X98H class) running **Armbian with an ophub
> 6.18.x kernel**, and turn it into a WPA2 access point.

## TL;DR

The chip works. The stock Armbian/ophub image ships the **wrong firmware** for the AIC8800D40
revision on these boards — the firmware upload completes but the chip never boots
(`rd_version=00000000`, `8800d80 wifi start fail`). It is **not** a sunxi-mmc / kernel issue.

Fix = three things:
1. The **AIC8800 SDIO driver**, ported to the 6.18 kernel, with the SDIO clock forced to **150 MHz**
   (the chip revision on these boards fails at the driver's default 50/25 MHz).
2. The **correct firmware** — the device's own original Android firmware (`fmacfw_8800d80_u02.bin`
   and the rest of the set). Provided as a [GitHub Release asset](#firmware), with a self-extraction
   guide if you prefer.
3. A 5 GHz regulatory domain (RU works) + `hostapd` for the AC WPA2 AP.

```bash
git clone https://github.com/<you>/armbian-aic8800d40-wifi
cd armbian-aic8800d40-wifi
# 1. download the firmware release-asset and extract it into firmware/
# 2. install (defaults: SSID=AIC8800D40-AP, password=ChangeMe12345, channel 36)
./ap-config/INSTALL.sh
# or customize:
#   SSID=MyAP PASS=supersecret CHANNEL=36 AP_IP=192.168.43.1 ./ap-config/INSTALL.sh
iw dev wlan0          # → interface wlan0, type AP, ssid AIC8800D40-AP, 5 GHz
```

## Symptoms (you probably arrived here from a search)

```
aicbsp: aicbsp_sdio_probe:1 vid:0xC8A1  did:0x0082
aicbsp: aicbsp_driver_fw_init, chip rev: 7
rwnx_load_firmware :firmware path = .../fmacfw_8800d80_u02.bin
rd_version_val=00000000
8800d80 wifi start fail          # ← with the stock firmware
```
No `wlan0`, no AP. The driver loads, the chip enumerates, the firmware file is found and uploaded,
but the chip never reports a version — i.e. the firmware didn't boot. No `sunxi-mmc data error` is
logged; the SDIO bus itself is fine.

## Root cause

* **Wrong firmware blob.** The `fmacfw_8800d80_u02.bin` shipped in Armbian/ophub firmware packages
  does not boot this silicon revision (`chip rev: 7`). The chip's own original Android firmware
  boots it. The firmware **file names** carry `d80` in them — that's the vendor/driver naming
  convention (the driver serves this chip through that path); the **chip** is the AIC8800D40.
* **SDIO clock.** The driver defaults to 50 MHz (or 25 MHz in some trees). This chip revision
  (rev 7) needs **150 MHz**; at 50/25 MHz the bring-up fails.

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
git clone <this repo> && cd armbian-aic8800d40-wifi
# Firmware: download the latest Release asset (aic8800D40-firmware.tar.gz),
#           extract into ./firmware/ so the .bin files sit there.
#           Verify: sha256sum -c firmware/SHA256SUMS
SSID=MyAP PASS=ChangeMe12345 CHANNEL=36 AP_IP=192.168.43.1 ./ap-config/INSTALL.sh
```

`INSTALL.sh` is idempotent. It installs the prebuilt modules for `6.18.37-ophub`, places the
firmware on all paths the loader searches, sets regdom RU, installs hostapd/dnsmasq, enables the
boot services, and starts the AP. After it: `iw dev wlan0` should show `type AP`.

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
| Mode | 802.11ac (HT40, WPA2-PSK/CCMP) |
| AP IP / DHCP | `192.168.43.1/24`, DHCP `.10–.50` |

This only brings up the **WiFi AP**. Internet routing / NAT / a captive portal are out of scope —
add your own (`iptables` MASQUERADE, dnsmasq upstream, etc.) as needed.

## Contents

```
driver/prebuilt-6.18.37-ophub/   # ready aic8800_bsp.ko + aic8800_fdrv.ko (ophub 6.18.37)
driver/patches/                  # the 6.18 port (cfg80211 wdev, timer API, 150 MHz clock, ...)
driver/build.sh                  # rebuild for your kernel from upstream LYU4662 + patches
firmware/SHA256SUMS              # verify the Release firmware asset
firmware/FIRMWARE-EXTRACTION.md # extract the firmware from your own Android dump
ap-config/                       # hostapd.conf, dnsmasq, boot services, INSTALL.sh
docs/                            # ROOT-CAUSE, BUILD-DRIVER, TROUBLESHOOTING
```

## Credits & references

* **LYU4662/aic8800-sdio-linux-1.0** — the driver base (SDIO, base+D80 procedure).
* **ArtinChip aic8800D40L documentation** — confirmed the same chip (`rev 7`, SDIO `0x0082`) works
  with 150 MHz + a good firmware blob.
* **NickAlilovic/build** — the X98H device-tree patch confirmed the WiFi power/pwrseq wiring.

## License

GPL-2.0 for code/scripts/docs (see [LICENSE](LICENSE)). Firmware blobs are vendor property, shared
only as a Release convenience.
