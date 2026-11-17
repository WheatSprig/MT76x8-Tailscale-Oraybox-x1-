#!/bin/sh
# 控制台动作接口：接收 POST（application/x-www-form-urlencoded），返回 JSON。
# 纯 BusyBox sh，不依赖 jq / bash。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

json_escape() {
    printf '%s' "$1" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
    printf '\r\n'
}

ok() {
    json_header
    printf '{"ok":true,"msg":"%s"}\n' "$(json_escape "$1")"
    exit 0
}

fail() {
    json_header
    printf '{"ok":false,"msg":"%s"}\n' "$(json_escape "$1")"
    exit 0
}

# 只解码浏览器的 encodeURIComponent / URLSearchParams 会产出的字符，
# 足以覆盖网段、端口和 /dev/... 路径。
urldecode() {
    printf '%s' "$1" \
        | sed -e 's/+/ /g' \
              -e 's/%2F/\//g' \
              -e 's/%3A/:/g' \
              -e 's/%2C/,/g' \
              -e 's/%2E/./g' \
              -e 's/%5F/_/g' \
              -e 's/%2D/-/g'
}

param() {
    _raw=$(printf '%s' "$BODY" \
        | tr '&' '\n' \
        | sed -n "s/^$1=//p" \
        | head -n 1)
    urldecode "$_raw"
}

ensure_printer_section() {
    [ -n "$(uci -q get p910nd.printer)" ] && return 0
    uci -q set p910nd.printer=p910nd
    uci -q set p910nd.printer.device='/dev/usb/lp0'
    uci -q set p910nd.printer.port='0'
    uci -q set p910nd.printer.bidirectional='1'
}

[ "$REQUEST_METHOD" = "POST" ] || fail "只接受 POST 请求"

if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    BODY=$(cat)
else
    BODY="$QUERY_STRING"
fi

ACTION=$(param do)

case "$ACTION" in
    routes)
        CIDR=$(param cidr)
        if [ -z "$CIDR" ]; then
            tailscale set --advertise-routes= >/dev/null 2>&1
            : > /etc/tailscale/lan-cidr
            ok "已停止发布子网路由"
        fi
        printf '%s' "$CIDR" | grep -Eq \
            '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?(,([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?)*$' \
            || fail "网段格式不正确，示例：192.168.1.0/24"
        tailscale set --advertise-routes="$CIDR" >/dev/null 2>&1 \
            || fail "设置失败：节点可能尚未登录"
        echo "$CIDR" > /etc/tailscale/lan-cidr
        ok "已发布 $CIDR，记得在管理后台批准"
        ;;

    tailscale_logout)
        tailscale logout >/dev/null 2>&1 || fail "退出失败（节点可能未登录）"
        ok "已退出 Tailscale"
        ;;

    printer_toggle)
        ensure_printer_section
        CUR=$(uci -q get p910nd.printer.enabled)
        [ -n "$CUR" ] || CUR=0
        if [ "$CUR" = "1" ]; then
            NEW=0
        else
            NEW=1
        fi
        uci -q set p910nd.printer.enabled="$NEW"
        uci -q commit p910nd
        /etc/init.d/p910nd restart >/dev/null 2>&1
        if [ "$NEW" = "1" ]; then
            ok "打印机服务已启用（TCP 9100）"
        else
            ok "打印机服务已停用"
        fi
        ;;

    printer_restart)
        ensure_printer_section
        uci -q set p910nd.printer.enabled='1'
        uci -q commit p910nd
        /etc/init.d/p910nd restart >/dev/null 2>&1
        ok "打印机服务已重启"
        ;;

    printer_device)
        DEVICE=$(param device)
        printf '%s' "$DEVICE" | grep -Eq '^/dev/[A-Za-z0-9._/-]+$' \
            || fail "设备路径不合法，示例：/dev/usb/lp0"
        ensure_printer_section
        uci -q set p910nd.printer.device="$DEVICE"
        uci -q commit p910nd
        /etc/init.d/p910nd restart >/dev/null 2>&1
        ok "已切换到 $DEVICE"
        ;;

    printer_port)
        PORT=$(param port)
        printf '%s' "$PORT" | grep -Eq '^[0-9]$' \
            || fail "端口只支持 0-9（0 表示 TCP 9100）"
        ensure_printer_section
        uci -q set p910nd.printer.port="$PORT"
        uci -q commit p910nd
        /etc/init.d/p910nd restart >/dev/null 2>&1
        ok "已切换到 TCP $((9100 + PORT))"
        ;;

    reboot)
        ( sleep 2; reboot ) >/dev/null 2>&1 &
        ok "设备将在 2 秒后重启"
        ;;

    *)
        fail "未知操作"
        ;;
esac
