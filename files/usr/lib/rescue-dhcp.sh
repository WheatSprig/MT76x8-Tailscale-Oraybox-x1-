#!/bin/sh
# 救援 DHCP：设备完全断网（没 WiFi、没上行、没别的 DHCP）时，给直连的电脑
# 发一个 192.168.1.x 的地址，省得手动配 IP。
#
# 只在满足这些条件时启用：
#   - 不是无线 WAN 模式（那边有自己的 DHCP）；
#   - 救援地址是开着的（/etc/lan-rescue）；
#   - 没有默认路由（说明没接在别人的网络上）；
#   - 探测不到别的 DHCP 服务器。
# 一旦接回有 DHCP 的网络（ifup 事件）就先停掉再重新判断，不会和主路由抢。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PID=/tmp/rescue-dhcp.pid
CONF=/tmp/rescue-dhcp.conf

running() {
    [ -f "$PID" ] && kill -0 "$(cat "$PID" 2>/dev/null)" 2>/dev/null
}

stop() {
    running && kill "$(cat "$PID" 2>/dev/null)" 2>/dev/null
    rm -f "$PID"
}

start() {
    running && return 0
    ip -4 addr show dev br-lan 2>/dev/null | grep -q '192\.168\.1\.2/' \
        || ip addr add 192.168.1.2/24 brd + dev br-lan 2>/dev/null

    cat >"$CONF" <<EOF
port=0
interface=br-lan
bind-interfaces
dhcp-range=192.168.1.100,192.168.1.150,255.255.255.0,1h
dhcp-option=3,192.168.1.2
dhcp-option=6,192.168.1.2
dhcp-authoritative
EOF
    /usr/sbin/dnsmasq --conf-file="$CONF" --pid-file="$PID" >/dev/null 2>&1
    logger -t rescue-dhcp "没有其他 DHCP，启用救援 DHCP（192.168.1.100-150，网关 192.168.1.2）"
}

# 发一次 DISCOVER，收到 OFFER 说明这个二层上已经有 DHCP 服务器
probe() {
    command -v udhcpc >/dev/null 2>&1 || return 1
    udhcpc -i br-lan -n -q -t 2 -T 2 -s /bin/true >/dev/null 2>&1
    [ $? -eq 0 ]
}

check() {
    [ -f /etc/wifi-wan ] && { stop; return 0; }
    [ -f /etc/lan-rescue ] || { stop; return 0; }
    running && return 0

    # 有默认路由 = 接在别人的网络上，交给对方发地址
    if ip route show default 2>/dev/null | grep -q .; then
        stop
        return 0
    fi

    if probe; then
        stop
        return 0
    fi

    start
}

case "$1" in
    start) start ;;
    stop) stop ;;
    check|"") check ;;
esac
