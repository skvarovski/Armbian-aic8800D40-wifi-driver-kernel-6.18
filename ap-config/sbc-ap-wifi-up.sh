#!/bin/sh
# Bring wlan0 up with its AP IP + set 5 GHz regulatory domain.
# AP_IP is substituted by INSTALL.sh (default 192.168.43.1).
AP_IP="${AP_IP:-192.168.43.1}"
iw reg set RU 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true
ip addr flush dev wlan0 2>/dev/null || true
ip addr add "$AP_IP/24" dev wlan0 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true
