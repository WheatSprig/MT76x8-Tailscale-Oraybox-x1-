#!/bin/sh
# 控制台状态接口：返回一段扁平 JSON，供 /index.html 轮询。
# 纯 BusyBox sh，不依赖 jq。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

json_escape() {
    printf '%s' "$1" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

TS_STATE=""
TS_IP=""
if command -v tailscale >/dev/null 2>&1; then
    TS_STATE=$(tailscale status --json 2>/dev/null \
        | grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n 1 | cut -d '"' -f 4)
    TS_IP=$(tailscale ip -4 2>/dev/null | head -n 1)
fi

LAN_IP=$(ip -4 addr show dev br-lan 2>/dev/null \
    | sed -n 's/.*inet \([0-9.]*\)\/[0-9]*.*/\1/p' | head -n 1)
LAN_GW=$(ip -4 route show default 2>/dev/null \
    | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n 1)
LAN_PROTO=$(uci -q get network.lan.proto)
HOSTNAME=$(uci -q get system.@system[0].hostname)
[ -n "$HOSTNAME" ] || HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null)

TS_ROUTES=$(head -n 1 /etc/tailscale/lan-cidr 2>/dev/null)

PRN_ENABLED=$(uci -q get p910nd.printer.enabled)
[ -n "$PRN_ENABLED" ] || PRN_ENABLED=0
PRN_PORT=$(uci -q get p910nd.printer.port)
[ -n "$PRN_PORT" ] || PRN_PORT=0
PRN_DEVICE=$(uci -q get p910nd.printer.device)
[ -n "$PRN_DEVICE" ] || PRN_DEVICE=/dev/usb/lp0

PRN_RUNNING=0
pidof p910nd >/dev/null 2>&1 && PRN_RUNNING=1

PRN_PRESENT=0
[ -c "$PRN_DEVICE" ] && PRN_PRESENT=1

TCP_PORT=$((9100 + PRN_PORT))

printf 'Content-Type: application/json; charset=utf-8\r\n'
printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
printf '\r\n'
cat <<EOF
{
  "ts_state": "$(json_escape "$TS_STATE")",
  "ts_ip": "$(json_escape "$TS_IP")",
  "ts_routes": "$(json_escape "$TS_ROUTES")",
  "lan_ip": "$(json_escape "$LAN_IP")",
  "lan_gateway": "$(json_escape "$LAN_GW")",
  "lan_proto": "$(json_escape "$LAN_PROTO")",
  "hostname": "$(json_escape "$HOSTNAME")",
  "printer_enabled": "$(json_escape "$PRN_ENABLED")",
  "printer_port": "$(json_escape "$PRN_PORT")",
  "printer_tcp_port": "$TCP_PORT",
  "printer_device": "$(json_escape "$PRN_DEVICE")",
  "printer_present": "$PRN_PRESENT",
  "printer_running": "$PRN_RUNNING"
}
EOF

exit 0
