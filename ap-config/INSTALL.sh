#!/bin/bash
# INSTALL.sh — turnkey installer for the AIC8800D40 WiFi (AC WPA2 AP) fix.
# Idempotent. Run as root on the box (ophub 6.18.37 Armbian).
#
# Env (all optional — defaults are EXAMPLE values):
#   SSID        (default AIC8800D40-AP)
#   PASS        (default ChangeMe12345)
#   CHANNEL     (default 36)
#   AP_IP       (default 192.168.43.1)   — the AP's wlan0 address; DHCP = .10-.50 of its /24
set -euo pipefail

SSID="${SSID:-AIC8800D40-AP}"
PASS="${PASS:-ChangeMe12345}"
CHANNEL="${CHANNEL:-36}"
AP_IP="${AP_IP:-192.168.43.1}"

# AP subnet base (first 3 octets) for DHCP range
AP_BASE="$(echo "$AP_IP" | awk -F. '{print $1"."$2"."$3}')"

HERE="$(cd "$(dirname "$0")/.." && pwd)"   # repo root (parent of ap-config/)
KVER="$(uname -r)"

say(){ printf '\n\033[1;33m▶ %s\033[0m\n' "$*"; }
ok(){ printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo)."; exit 1; }

say "AIC8800D40 WiFi installer  (SSID=$SSID  CH=$CHANNEL  AP_IP=$AP_IP  kernel=$KVER)"

# ─── firmware ────────────────────────────────────────────────────────────────
say "Firmware"
FW="$HERE/firmware"
if ! ls "$FW"/*.bin >/dev/null 2>&1; then
  echo "  No firmware blobs in $FW/."
  echo "  Download the Release asset (aic8800D40-firmware.tar.gz) and extract it into $FW/,"
  echo "  or extract your own (firmware/FIRMWARE-EXTRACTION.md). Aborting."
  exit 1
fi
for d in /lib/firmware/aic8800_fw/SDIO/aic8800D80 \
         /lib/firmware/aic8800/SDIO/aic8800D80 \
         /usr/lib/firmware/aic8800_fw/SDIO/aic8800D80 \
         /usr/lib/firmware/aic8800/SDIO/aic8800D80 \
         /usr/lib/firmware/aic8800_sdio/aic8800 \
         /usr/lib/firmware/aic8800_sdio; do
  mkdir -p "$d"; cp -f "$FW"/*.bin "$FW"/*.txt "$d/" 2>/dev/null || true
done
ok "firmware set copied to loader search paths"

# ─── driver (prebuilt for ophub 6.18.37) ─────────────────────────────────────
say "Driver"
MODDIR="/lib/modules/$KVER/kernel/drivers/net/wireless/aic8800"
mkdir -p "$MODDIR"
if [ -f "$HERE/driver/prebuilt-$KVER/aic8800_bsp.ko" ]; then
  cp -f "$HERE/driver/prebuilt-$KVER/aic8800_bsp.ko" \
        "$HERE/driver/prebuilt-$KVER/aic8800_fdrv.ko" "$MODDIR/"
  ok "prebuilt modules for $KVER installed"
else
  echo "  No prebuilt modules for kernel '$KVER' in driver/prebuilt-$KVER/."
  echo "  Rebuild from source: see docs/BUILD-DRIVER.md"
  echo "  (continuing — assuming you installed the .ko yourself)"
fi
depmod -a || true
printf 'aic8800_bsp\naic8800_fdrv\n' > /etc/modules-load.d/aic8800.conf
ok "driver autoload enabled"

# ─── regdom ──────────────────────────────────────────────────────────────────
say "Regulatory domain (5 GHz AP)"
cp -f "$HERE/ap-config/regdom-ru.conf" /etc/modprobe.d/regdom-ru.conf
iw reg set RU 2>/dev/null || true
ok "regdom RU"

# ─── packages ───────────────────────────────────────────────────────────────
say "hostapd + dnsmasq"
if ! command -v hostapd >/dev/null; then
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq hostapd dnsmasq
fi
command -v hostapd >/dev/null && ok "hostapd present"
command -v dnsmasq >/dev/null && ok "dnsmasq present"

# ─── wlan0 boot (IP + regdom) ────────────────────────────────────────────────
say "wlan0 boot service"
cp -f "$HERE/ap-config/sbc-ap-wifi-up.sh" /usr/local/sbin/sbc-ap-wifi-up.sh
chmod +x /usr/local/sbin/sbc-ap-wifi-up.sh
sed "s|^Environment=AP_IP=.*|Environment=AP_IP=$AP_IP|" \
    "$HERE/ap-config/sbc-wlan0-up.service" > /etc/systemd/system/sbc-wlan0-up.service
systemctl daemon-reload
systemctl enable sbc-wlan0-up.service >/dev/null 2>&1 || true
ok "sbc-wlan0-up enabled (AP_IP=$AP_IP)"

# ─── hostapd (AP) ────────────────────────────────────────────────────────────
say "hostapd AP config (SSID=$SSID, CH=$CHANNEL, WPA2)"
mkdir -p /etc/hostapd
sed -e "s|^ssid=.*|ssid=$SSID|" \
    -e "s|^wpa_passphrase=.*|wpa_passphrase=$PASS|" \
    -e "s|^channel=.*|channel=$CHANNEL|" \
    "$HERE/ap-config/hostapd.conf" > /etc/hostapd/hostapd.conf
# DAEMON_CONF (deprecated but still honored by Debian's unit)
grep -q '^DAEMON_CONF=' /etc/default/hostapd 2>/dev/null \
  && sed -i "s|^DAEMON_CONF=.*|DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"|" /etc/default/hostapd \
  || echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
systemctl unmask hostapd.service >/dev/null 2>&1 || true
systemctl enable hostapd.service >/dev/null 2>&1 || true
ok "hostapd configured + enabled"

# ─── dnsmasq (DHCP) ──────────────────────────────────────────────────────────
say "dnsmasq DHCP (${AP_BASE}.10-${AP_BASE}.50)"
sed -e "s|192\.168\.43\.|${AP_BASE}.|g" "$HERE/ap-config/dnsmasq-ap.conf" > /etc/dnsmasq.d/ap.conf
systemctl enable dnsmasq.service >/dev/null 2>&1 || true
ok "dnsmasq configured + enabled"

# ─── bring it up now ─────────────────────────────────────────────────────────
say "Starting services"
# release NetworkManager's grip on wlan0 if present
nmcli dev set wlan0 managed no 2>/dev/null || true
systemctl restart sbc-wlan0-up 2>/dev/null || /usr/local/sbin/sbc-ap-wifi-up.sh
systemctl restart dnsmasq 2>/dev/null || true
systemctl restart hostapd 2>/dev/null || hostapd -B /etc/hostapd/hostapd.conf
sleep 3

say "Done. Verify:"
echo "    iw dev wlan0 info            # expect: type AP, ssid $SSID, channel $CHANNEL (5 GHz)"
echo "    systemctl is-active hostapd dnsmasq"
echo "    Connect a client to '$SSID' with password '$PASS'"
iw dev wlan0 info 2>/dev/null | grep -E 'type|ssid|channel' || echo "(wlan0 not yet up — check dmesg | grep -E 'aic|rd_version')"
