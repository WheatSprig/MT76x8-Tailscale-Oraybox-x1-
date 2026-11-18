#!/bin/sh
# LAN 改动的守夜人：
#   1. 开机时先回滚上一次“没确认就重启/断电”的改动；
#   2. 补回救援地址（手工加的地址，network reload 会清掉）；
#   3. 每 15 秒检查一次 /etc/lan-pending：超过 180 秒没人确认就回滚。
#
# 回滚不能靠 CGI 里的一次性后台任务 —— uhttpd 结束请求时会把它带走。放到
# 这个常驻循环里才可靠。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PENDING=/etc/lan-pending
WAIT=180

# 开机兜底
/usr/lib/lan-rollback.sh check

if [ -f /etc/lan-rescue ]; then
    ip addr add 192.168.1.2/24 brd + dev br-lan 2>/dev/null
fi

while true; do
    if [ -f "$PENDING" ]; then
        # 确认之前把改动前的地址一直挂着，改错网段也能从旧地址回来。
        _oip=$(sed -n '3p' "$PENDING" 2>/dev/null)
        _opfx=$(sed -n '4p' "$PENDING" 2>/dev/null)
        if [ -n "$_oip" ] && [ -n "$_opfx" ]; then
            ip -4 addr show dev br-lan 2>/dev/null | grep -q "inet $_oip/$_opfx" \
                || ip addr add "$_oip/$_opfx" brd + dev br-lan 2>/dev/null
        fi

        _ts=$(sed -n '2p' "$PENDING" 2>/dev/null)
        case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
        _now=$(date +%s)
        if [ "$_ts" -gt 0 ] && [ $((_now - _ts)) -ge "$WAIT" ]; then
            /usr/lib/lan-rollback.sh check
        fi
    fi
    sleep 15
done
