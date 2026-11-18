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
NOIP=0
CYCLE=0
WAN_NO=0

# 开机兜底
/usr/lib/lan-rollback.sh check

if [ -f /etc/lan-rescue ]; then
    ip addr add 192.168.1.2/24 brd + dev br-lan 2>/dev/null
fi

while true; do
    if [ -f "$PENDING" ]; then
        _ts=$(sed -n '2p' "$PENDING" 2>/dev/null)
        case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
        _now=$(date +%s)
        if [ "$_ts" -gt 0 ] && [ $((_now - _ts)) -ge "$WAIT" ]; then
            /usr/lib/lan-rollback.sh check
        fi
    fi

    # 兜底：br-lan 连续 45 秒没有 IPv4 地址（切 proto 后 udhcpc 没起来、
    # 或者地址被误删）就重新拉起一次 lan 接口。实测 static→dhcp 切换后
    # 只 reload 不会重启 DHCP 客户端，必须 ifup。
    if ip -4 addr show dev br-lan 2>/dev/null | grep -q 'inet '; then
        NOIP=0
    else
        NOIP=$((NOIP + 1))
        if [ "$NOIP" -ge 3 ]; then
            logger -t lan-guard "br-lan 没有 IPv4 地址，重新拉起 lan 接口"
            ifup lan >/dev/null 2>&1
            NOIP=0
            sleep 45
        fi
    fi

    # 每 60 秒处理一次 DHCP 的事：
    #   - 无线 WAN 模式：如果当前为了避让关着 DHCP，探测到长期没有别的 DHCP
    #     就自动打开（拔掉上行网线后不用手动改）；
    #   - 其他模式：交给 rescue-dhcp.sh 判断要不要给直连电脑发 192.168.1.x。
    CYCLE=$((CYCLE + 1))
    if [ $((CYCLE % 4)) -eq 0 ]; then
        if [ -f /etc/wifi-wan ] && [ -f /etc/lan-dhcp-auto ]; then
            if [ "$(uci -q get dhcp.lan.ignore)" = "1" ]; then
                if udhcpc -i br-lan -n -q -t 2 -T 2 -s /bin/true >/dev/null 2>&1; then
                    WAN_NO=0
                else
                    WAN_NO=$((WAN_NO + 1))
                    if [ "$WAN_NO" -ge 2 ]; then
                        uci -q set dhcp.lan.ignore='0'
                        uci -q commit dhcp
                        /etc/init.d/dnsmasq restart >/dev/null 2>&1
                        WAN_NO=0
                        logger -t dhcp-watch "LAN 上仍没有 DHCP，本机 DHCP 已自动打开"
                    fi
                fi
            fi
        else
            /usr/lib/rescue-dhcp.sh check
        fi
    fi

    sleep 15
done
