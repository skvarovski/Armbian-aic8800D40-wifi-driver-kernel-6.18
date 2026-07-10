# Troubleshooting — symptom → diagnosis

## Quick table

| `dmesg` symptom | meaning | fix |
|---|---|---|
| `rd_version_val=00000000` then `8800d80 wifi start fail` | firmware uploaded but didn't boot — **wrong firmware blob** | install the device's original Android firmware (see [../firmware/](../firmware/)) |
| `aicwifi_patch_config_8800d80 fail` / `cmd timed-out` | firmware partially incompatible (different vendor build) | use the matched firmware **set** from one source |
| `aicbsp_driver_fw_init, chip rev: 7` then it hangs/fails | rev 7 needs **150 MHz** SDIO clock | rebuild driver with `FEATURE_SDIO_CLOCK_V3=150000000` |
| `aicwf_sdio_func_init ... reg:11 write failed!` / `probe ... -34` | you forced the **base (AIC8801)** chip-id on a chip that needs the D80 procedure | don't force base; leave the default SDIO-id → D80 mapping |
| `aicbsp_driver_fw_init, unsupport chip rev: 255` | SDIO bus went down before the rev read (often follows one of the above) | fix the prior error first |
| `sunxi-mmc ... data error, sending stop command` / `aicwf_sdio_send_pkt fail-110` | genuine SDIO transfer corruption (rare for rev 7; more about other revisions) | different issue — sunxi-mmc DTB/phase tuning, out of scope here |
| `modprobe: ERROR: could not insert aic8800_fdrv: No such device` | bsp didn't bring the chip up (see above), so fdrv has nothing to bind | fix bsp/firmware/clock first |
| `modprobe: invalid module format` / vermagic mismatch | prebuilt `.ko` built for a different kernel | rebuild for your kernel ([BUILD-DRIVER.md](BUILD-DRIVER.md)) |
| `wlan0` exists but `iw dev` shows `type managed`, AP won't start | hostapd not running, or NM grabbed the interface | `systemctl status hostapd`; `nmcli dev set wlan0 managed no`; `ip link set wlan0 up` |
| hostapd: `AP-ENABLED` then immediately `AP-DISABLED` | regdom blocks the channel (5 GHz `no-IR`) or channel not allowed | `iw reg set <XX>` (RU works); pick an allowed channel (`iw list`) |

## Sanity-check order
1. `dmesg | grep -E 'aic|rd_version'` — you want `rd_version_val=0609…` (non-zero) and
   `New interface create wlan0`. If `rd_version_val=00000000` → firmware (the #1 cause).
2. `iw dev wlan0 info` — `type AP`, an ssid, a 5 GHz channel.
3. `systemctl is-active hostapd dnsmasq` — both active.
4. From a client device: see the SSID, connect with the WPA2 passphrase, get a DHCP lease.

## "It worked once, then the box locked up / rebooted"
The AIC8800 driver is an out-of-tree module on a bleeding-edge kernel (6.18). Under AP traffic a
driver bug can panic the kernel. If it's a one-off, a power-cycle restores it (the boot services
bring the AP back up). If it panic-loops on boot, disable the driver autoload to recover:
- boot from SD / attach UART,
- `rm /etc/modules-load.d/aic8800.conf` (or rename it),
- reboot from eMMC, then debug the driver.

Stabilizing the driver fully (beyond getting WiFi up) is future work; contributions welcome.
