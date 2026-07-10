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

## AP bring-up symptoms (chip is up, AP/DHCP/DNS/internet misbehave)

These are Linux AP issues, not AIC8800/firmware issues — but they're the common
"got the chip working, now the AP is broken" follow-ups. All are handled by
`INSTALL.sh`; this table is for manual debugging.

| Symptom | Cause | Fix |
|---|---|---|
| hostapd `inactive` / `failed`; dmesg shows `wlan0: AP started` then `AP Stopped` ~1 ms later; a `p2p-dev-wlan0` interface appears | **wpa_supplicant grabbed wlan0** before hostapd (D-Bus activation). hostapd logs `UNINITIALIZED->HT_SCAN` then `Deactivated`, never `AP-ENABLED`. | `systemctl mask wpa_supplicant` (+ `stop` if running); install the `hostapd.service.d/retry-ap.conf` drop-in; `systemctl restart hostapd` |
| hostapd crashes/exits 0 on AP failure → no retry, AP stays down | Debian's stock unit is `Type=forking` + `hostapd -B`, which exits 0 even when the AP fails → `Restart=on-failure` never fires | install the retry drop-in (`Type=simple`, no `-B`, `Restart=always`) |
| clients connect (WPA OK) then drop every ~18 s; `dnsmasq` logs `DHCP packet received on wlan0 which has no address` | **wlan0 has no IP** — the boot oneshot raced with the driver creating wlan0 | set the wlan0 IP in the hostapd `ExecStartPost` (`ip addr replace <AP_IP>/24 dev wlan0`), not only at boot |
| connected but **no internet / DNS fails**; clients can't resolve names | **systemd-resolved** holds `:53` and/or dnsmasq has `port=0` (DNS disabled) | `systemctl disable --now systemd-resolved`; static `/etc/resolv.conf`; dnsmasq `no-resolv` + `server=1.1.1.1`/`server=8.8.8.8`; remove `port=0` |
| dnsmasq logs `warning: DNS service disabled` / clients get DHCP but never resolve | a `port=0` line is being loaded from **somewhere** in `/etc/dnsmasq.d/` | check **ALL** files in `/etc/dnsmasq.d/` (incl. `.bak`, `.pre-*`, `.orig`) — dnsmasq loads every one via `-7`; move backups OUT of that dir |
| connected, DNS resolves, but still no internet (ping by IP fails) | **NAT/forwarding missing** — AP subnet isn't masqueraded to WAN | run `sbc-ap-nat.sh` (from hostapd `ExecStartPost`); verify `net.ipv4.ip_forward=1`; check WAN interface detected by `ip route show default` |
| speed ~70-90 Mbps down, not higher | **normal** — the AIC8800D40 is 1T1R over SDIO; that's the PHY/SDIO ceiling | not a bug; for more throughput use a 2×2 USB WiFi dongle instead |

## Sanity-check order
1. `dmesg | grep -E 'aic|rd_version'` — you want `rd_version_val=0609…` (non-zero) and
   `New interface create wlan0`. If `rd_version_val=00000000` → firmware (the #1 cause).
2. `iw dev wlan0 info` — `type AP`, an ssid, a 5 GHz channel.
3. `systemctl is-active hostapd dnsmasq` — both active.
4. From a client device: see the SSID, connect with the WPA2 passphrase, get a DHCP lease.
5. `ip addr show wlan0` — the AP IP (e.g. `192.168.43.1/24`) is present (set by
   hostapd's `ExecStartPost`, not only the boot oneshot).
6. `systemctl is-active wpa_supplicant` — should be `inactive` (masked). If it's
   `active`, it will fight hostapd for wlan0.
7. On the client: `ping 192.168.43.1` (gateway), then `nslookup example.com`,
   then `ping 1.1.1.1`. The first failing step tells you AP / DNS / NAT
   respectively.

## "It worked once, then the box locked up / rebooted"
The AIC8800 driver is an out-of-tree module on a bleeding-edge kernel (6.18). Under AP traffic a
driver bug can panic the kernel. If it's a one-off, a power-cycle restores it (the boot services
bring the AP back up). If it panic-loops on boot, disable the driver autoload to recover:
- boot from SD / attach UART,
- `rm /etc/modules-load.d/aic8800.conf` (or rename it),
- reboot from eMMC, then debug the driver.

Stabilizing the driver fully (beyond getting WiFi up) is future work; contributions welcome.
