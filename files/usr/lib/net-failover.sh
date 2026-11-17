#!/bin/sh
# 有线网关不通时，把默认路由让给 WiFi（wwan），恢复后再切回去。
#
# 只改默认路由的“有无”，不动地址、不动 uci、不重启接口：
#   - 有线网关连续 FAIL_NEED 次 ping 不通，且 WiFi 有默认路由 → 删掉有线默认路由；
#   - 有线网关恢复 → 把有线默认路由加回来（metric 0）。
#
# 没配 wwan 的设备上，脚本只是空转，不会有任何动作。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

LAN_DEV=br-lan
CHECK=15
FAIL_NEED=3

fail=0
mode=ok

alt_dev() {
    _d=$(ubus call network.interface.wwan status 2>/dev/null \
        | tr -d ' \t\n' | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p')
    [ -n "$_d" ] || _d=phy0-sta0
    echo "$_d"
}

lan_gw() {
    ip route show default dev "$LAN_DEV" 2>/dev/null \
        | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n 1
}

alt_gw() {
    ip route show default dev "$(alt_dev)" 2>/dev/null \
        | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n 1
}

while true; do
    GW=$(lan_gw)
    if [ -n "$GW" ]; then
        if ping -c 1 -W 2 "$GW" >/dev/null 2>&1; then
            fail=0
            if [ "$mode" = "failover" ]; then
                ip route replace default via "$GW" dev "$LAN_DEV" 2>/dev/null
                mode=ok
                logger -t net-failover "有线网关 $GW 恢复，切回有线"
            fi
        else
            fail=$((fail + 1))
            if [ "$fail" -ge "$FAIL_NEED" ] && [ "$mode" = "ok" ]; then
                AGW=$(alt_gw)
                if [ -n "$AGW" ]; then
                    ip route del default via "$GW" dev "$LAN_DEV" 2>/dev/null
                    mode=failover
                    logger -t net-failover "有线网关 $GW 连续 $fail 次不通，切到 WiFi（$AGW）"
                fi
            fi
        fi
    else
        # 有线没有默认路由（网线断了 / 接口还没起来）：WiFi 会自然接管，不用插手
        fail=0
        mode=ok
    fi
    sleep "$CHECK"
done
