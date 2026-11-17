#!/bin/sh
# 统一控制接口：所有读状态/写配置都走这一个 CGI。
#
#   GET  /cgi-bin/api.sh?op=status            读取状态（JSON，无需登录）
#   GET  /cgi-bin/api.sh?op=logs              读取系统日志（需要登录）
#   GET  /cgi-bin/api.sh?op=diag              读取诊断信息（需要登录）
#   POST /cgi-bin/api.sh   op=<动作>&...      执行动作（除 login 外都需要登录）
#
# 纯 BusyBox sh，不依赖 jq / bash / curl。所有可能卡住的命令都用
# run_limited 限时，保证 CGI 永远不会把 uhttpd 的请求槽位占死。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022

TMP_STATUS=/tmp/ts.status
TOKEN_FILE=/tmp/tsui.tokens
PASSWORD_FILE=/etc/tsui.passwd

# ---------------------------------------------------------------- 基础工具

json_escape() {
    printf '%s' "$1" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

json_header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
}

text_header() {
    printf 'Content-Type: text/plain; charset=utf-8\r\n'
    printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
}

ok() {
    json_header
    printf '\r\n'
    printf '{"ok":true,"msg":"%s"}\n' "$(json_escape "$1")"
    exit 0
}

fail() {
    json_header
    printf '\r\n'
    printf '{"ok":false,"msg":"%s"}\n' "$(json_escape "$1")"
    exit 0
}

# 设备里没有 timeout 工具，用后台进程 + 看门狗实现。
run_limited() {
    _secs=$1
    shift
    "$@" &
    _p=$!
    ( sleep "$_secs"; kill -9 "$_p" 2>/dev/null ) &
    _w=$!
    wait "$_p" 2>/dev/null
    _rc=$?
    kill "$_w" 2>/dev/null
    return $_rc
}

urldecode() {
    printf '%s' "$1" \
        | sed -e 's/+/ /g' \
              -e 's/%2F/\//g' \
              -e 's/%3A/:/g' \
              -e 's/%2C/,/g' \
              -e 's/%2E/./g' \
              -e 's/%5F/_/g' \
              -e 's/%2D/-/g' \
              -e 's/%40/@/g'
}

param() {
    _raw=$(printf '%s' "$BODY" \
        | tr '&' '\n' \
        | sed -n "s/^$1=//p" \
        | head -n 1)
    urldecode "$_raw"
}

# ---------------------------------------------------------------- 登录状态

load_password() {
    SALT=""
    PHASH=""
    if [ -s "$PASSWORD_FILE" ]; then
        SALT=$(cut -d: -f1 "$PASSWORD_FILE" 2>/dev/null)
        PHASH=$(cut -d: -f2 "$PASSWORD_FILE" 2>/dev/null)
    fi
}

password_ok() {
    [ -n "$SALT" ] || return 1
    _calc=$(printf '%s:%s' "$SALT" "$1" | sha256sum | cut -d' ' -f1)
    [ "$_calc" = "$PHASH" ]
}

new_token() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N
}

request_token() {
    printf '%s' "$HTTP_COOKIE" \
        | tr ';' '\n' \
        | sed -n 's/^[[:space:]]*tsui=//p' \
        | head -n 1
}

auth_ok() {
    _t=$(request_token)
    [ -n "$_t" ] || return 1
    [ -f "$TOKEN_FILE" ] || return 1
    grep -qxF "$_t" "$TOKEN_FILE"
}

drop_token() {
    _t=$(request_token)
    [ -n "$_t" ] || return 0
    [ -f "$TOKEN_FILE" ] || return 0
    grep -vxF "$_t" "$TOKEN_FILE" >"$TOKEN_FILE.$$" 2>/dev/null
    mv "$TOKEN_FILE.$$" "$TOKEN_FILE" 2>/dev/null
}

# ---------------------------------------------------------------- 状态采集

lan_ip() {
    ip -4 addr show dev br-lan 2>/dev/null \
        | sed -n 's/.*inet \([0-9.]*\)\/[0-9]*.*/\1/p' | head -n 1
}

lan_gateway() {
    ip -4 route show default 2>/dev/null \
        | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -n 1
}

status_value() {
    sed -n "s/^$1=//p" "$TMP_STATUS" 2>/dev/null | head -n 1
}

# ---------------------------------------------------------------- 输入解析

[ "$REQUEST_METHOD" = "POST" ] || REQUEST_METHOD=GET

if [ "$REQUEST_METHOD" = "POST" ]; then
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        BODY=$(cat)
    else
        BODY=""
    fi
else
    BODY="$QUERY_STRING"
fi

OP=$(param op)
[ -n "$OP" ] || OP=status

load_password

# ---------------------------------------------------------------- 只读接口

if [ "$OP" = "status" ]; then
    TS_STATE=$(status_value state)
    TS_IP=$(status_value ip)
    TS_AUTH=$(status_value auth)

    LAN_IP=$(lan_ip)
    LAN_GW=$(lan_gateway)
    LAN_PROTO=$(uci -q get network.lan.proto)
    HOSTNAME=$(uci -q get system.@system[0].hostname)
    [ -n "$HOSTNAME" ] || HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null)
    UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    MEM_TOTAL=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    MEM_FREE=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)

    TS_ROUTES=$(head -n 1 /etc/tailscale/lan-cidr 2>/dev/null)

    PRN_ENABLED=$(uci -q get p910nd.printer.enabled)
    [ -n "$PRN_ENABLED" ] || PRN_ENABLED=0
    PRN_PORT=$(uci -q get p910nd.printer.port)
    [ -n "$PRN_PORT" ] || PRN_PORT=0
    PRN_DEVICE=$(uci -q get p910nd.printer.device)
    [ -n "$PRN_DEVICE" ] || PRN_DEVICE=/dev/usb/lp0
    PRN_TCP=$((9100 + PRN_PORT))

    PRN_PRESENT=0
    [ -c "$PRN_DEVICE" ] && PRN_PRESENT=1
    PRN_DEVICES=$(ls /dev/usb/lp* 2>/dev/null | tr '\n' ' ')

    PRN_RUNNING=0
    PORT_HEX=$(printf '%04X' "$PRN_TCP")
    if grep -qE ":$PORT_HEX [0-9A-F]{8}:[0-9A-F]{4} 0A" /proc/net/tcp 2>/dev/null; then
        PRN_RUNNING=1
    fi

    TS_SOCKET=0
    [ -S /var/run/tailscale/tailscaled.sock ] && TS_SOCKET=1

    LOGGED_IN=0
    auth_ok && LOGGED_IN=1

    DEFAULT_PW=0
    [ -f /etc/tsui.default ] && DEFAULT_PW=1

    json_header
    printf '\r\n'
    cat <<EOF
{
  "ok": true,
  "auth": $LOGGED_IN,
  "default_password": $DEFAULT_PW,
  "ts_state": "$(json_escape "$TS_STATE")",
  "ts_ip": "$(json_escape "$TS_IP")",
  "ts_auth_url": "$(json_escape "$TS_AUTH")",
  "ts_routes": "$(json_escape "$TS_ROUTES")",
  "ts_socket": $TS_SOCKET,
  "ts_updated": "$(json_escape "$(status_value updated)")",
  "lan_ip": "$(json_escape "$LAN_IP")",
  "lan_gateway": "$(json_escape "$LAN_GW")",
  "lan_proto": "$(json_escape "$LAN_PROTO")",
  "hostname": "$(json_escape "$HOSTNAME")",
  "uptime": "$(json_escape "$UPTIME")",
  "mem_total": "$(json_escape "$MEM_TOTAL")",
  "mem_free": "$(json_escape "$MEM_FREE")",
  "printer_enabled": "$(json_escape "$PRN_ENABLED")",
  "printer_port": "$(json_escape "$PRN_PORT")",
  "printer_tcp_port": "$PRN_TCP",
  "printer_device": "$(json_escape "$PRN_DEVICE")",
  "printer_devices": "$(json_escape "$PRN_DEVICES")",
  "printer_present": $PRN_PRESENT,
  "printer_running": $PRN_RUNNING
}
EOF
    exit 0
fi

# ---------------------------------------------------------------- 需要登录

if [ "$OP" = "logs" ] || [ "$OP" = "diag" ]; then
    auth_ok || fail "请先登录"
    text_header
    printf '\r\n'
    if [ "$OP" = "logs" ]; then
        run_limited 10 logread 2>/dev/null | tail -n 150
    else
        echo "== uptime / load =="
        cat /proc/uptime /proc/loadavg 2>/dev/null
        echo
        echo "== memory (kB) =="
        grep -E '^(MemTotal|MemFree|MemAvailable|Cached|Buffers|Swap)' /proc/meminfo 2>/dev/null
        echo
        echo "== network =="
        ip -4 addr show 2>/dev/null
        ip -4 route show 2>/dev/null
        echo
        echo "== listening =="
        netstat -ltn 2>/dev/null
        echo
        echo "== processes =="
        ps w 2>/dev/null
        echo
        echo "== tailscaled socket =="
        ls -l /var/run/tailscale/ 2>/dev/null
        echo
        echo "== tailscale status (max 8s) =="
        run_limited 8 tailscale status 2>&1 | head -n 30
        echo
        echo "== tailscale log tail =="
        run_limited 10 logread 2>/dev/null | grep -i -E 'tailscale|tailscaled|tun' | tail -n 25
        echo
        echo "== dmesg tail =="
        dmesg 2>/dev/null | tail -n 30
    fi
    exit 0
fi

if [ "$OP" = "login" ]; then
    PASS=$(param password)
    if [ -z "$PHASH" ]; then
        fail "控制台密码尚未初始化，请重启设备或检查 /etc/uci-defaults/96-web-auth"
    fi
    password_ok "$PASS" || fail "密码错误"
    TOKEN=$(new_token)
    echo "$TOKEN" >>"$TOKEN_FILE"
    json_header
    printf 'Set-Cookie: tsui=%s; Path=/; Max-Age=86400; HttpOnly\r\n' "$TOKEN"
    printf '\r\n'
    printf '{"ok":true,"msg":"登录成功"}\n'
    exit 0
fi

if [ "$OP" = "logout" ]; then
    drop_token
    json_header
    printf 'Set-Cookie: tsui=; Path=/; Max-Age=0\r\n'
    printf '\r\n'
    printf '{"ok":true,"msg":"已退出登录"}\n'
    exit 0
fi

auth_ok || fail "请先登录"

# ---------------------------------------------------------------- 写操作

case "$OP" in
    ts_login)
        # 同一时刻只允许一个 tailscale up，避免多次点击堆进程把设备拖死。
        if [ -f /tmp/ts-login.lock ]; then
            AGE=$(( $(date +%s) - $(cat /tmp/ts-login.lock 2>/dev/null || echo 0) ))
            [ "$AGE" -lt 120 ] && ok "登录流程已经在运行，请稍候刷新状态"
        fi
        date +%s >/tmp/ts-login.lock
        ADVERTISE=""
        if [ -s /etc/tailscale/lan-cidr ]; then
            ADVERTISE="--advertise-routes=$(head -n 1 /etc/tailscale/lan-cidr)"
        fi
        (
            run_limited 90 tailscale up $ADVERTISE \
                --hostname=mt76x8 --reset </dev/null >/tmp/ts_login.log 2>&1
            rm -f /tmp/ts-login.lock
        ) &
        ok "已经开始登录，授权链接生成后会在页面上自动出现"
        ;;

    ts_logout)
        run_limited 20 tailscale logout >/dev/null 2>&1 || fail "退出失败（可能未登录）"
        : > /tmp/ts.status
        ok "已退出 Tailscale"
        ;;

    ts_routes)
        CIDR=$(param cidr)
        if [ -z "$CIDR" ]; then
            run_limited 20 tailscale set --advertise-routes= >/dev/null 2>&1
            : > /etc/tailscale/lan-cidr
            ok "已停止发布子网路由"
        fi
        printf '%s' "$CIDR" | grep -Eq \
            '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?(,([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?)*$' \
            || fail "网段格式不正确，示例：192.168.1.0/24"
        run_limited 20 tailscale set --advertise-routes="$CIDR" >/dev/null 2>&1 \
            || fail "设置失败：节点可能尚未登录"
        echo "$CIDR" > /etc/tailscale/lan-cidr
        ok "已发布 $CIDR，记得在 Tailscale 后台批准"
        ;;

    printer_toggle)
        uci -q set p910nd.printer=p910nd
        CUR=$(uci -q get p910nd.printer.enabled)
        [ -n "$CUR" ] || CUR=0
        if [ "$CUR" = "1" ]; then NEW=0; else NEW=1; fi
        [ -n "$(uci -q get p910nd.printer.device)" ] || uci -q set p910nd.printer.device='/dev/usb/lp0'
        [ -n "$(uci -q get p910nd.printer.port)" ] || uci -q set p910nd.printer.port='0'
        uci -q set p910nd.printer.enabled="$NEW"
        uci -q commit p910nd
        run_limited 15 /etc/init.d/p910nd restart >/dev/null 2>&1
        if [ "$NEW" = "1" ]; then
            ok "打印服务已启用"
        else
            ok "打印服务已停用"
        fi
        ;;

    printer_restart)
        uci -q set p910nd.printer=p910nd
        uci -q set p910nd.printer.enabled='1'
        uci -q commit p910nd
        run_limited 15 /etc/init.d/p910nd restart >/dev/null 2>&1
        ok "打印服务已重启"
        ;;

    printer_device)
        DEVICE=$(param device)
        printf '%s' "$DEVICE" | grep -Eq '^/dev/[A-Za-z0-9._/-]+$' \
            || fail "设备路径不合法，示例：/dev/usb/lp0"
        uci -q set p910nd.printer=p910nd
        uci -q set p910nd.printer.device="$DEVICE"
        uci -q commit p910nd
        run_limited 15 /etc/init.d/p910nd restart >/dev/null 2>&1
        ok "已切换到 $DEVICE"
        ;;

    printer_port)
        PORT=$(param port)
        printf '%s' "$PORT" | grep -Eq '^[0-9]$' \
            || fail "端口只支持 0-9（0 表示 TCP 9100）"
        uci -q set p910nd.printer=p910nd
        uci -q set p910nd.printer.port="$PORT"
        uci -q commit p910nd
        run_limited 15 /etc/init.d/p910nd restart >/dev/null 2>&1
        ok "已切换到 TCP $((9100 + PORT))"
        ;;

    set_password)
        OLD=$(param old)
        NEW=$(param new)
        password_ok "$OLD" || fail "原密码不正确"
        [ ${#NEW} -ge 6 ] || fail "新密码至少 6 位"
        printf '%s' "$NEW" | grep -q ':' && fail "新密码不能包含冒号"

        NEW_SALT=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-32)
        [ -n "$NEW_SALT" ] || NEW_SALT=$(date +%s)
        NEW_HASH=$(printf '%s:%s' "$NEW_SALT" "$NEW" | sha256sum | cut -d' ' -f1)
        printf '%s:%s\n' "$NEW_SALT" "$NEW_HASH" >"$PASSWORD_FILE"
        chmod 600 "$PASSWORD_FILE"
        rm -f /etc/tsui.default

        # 同步系统密码，让 SSH 用同一个密码。
        if printf '%s\n%s\n' "$NEW" "$NEW" | run_limited 15 passwd root >/tmp/passwd.log 2>&1; then
            ok "密码已更新（网页与 SSH 相同）"
        else
            ok "网页密码已更新，但系统密码同步失败，请用 SSH 执行 passwd 手动修改"
        fi
        ;;

    reboot)
        ( sleep 2; reboot ) >/dev/null 2>&1 &
        ok "设备将在 2 秒后重启"
        ;;

    *)
        fail "未知操作"
        ;;
esac
