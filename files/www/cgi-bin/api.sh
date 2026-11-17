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

# 登录态与密码校验和 upgrade.sh 共用一份实现。
. /usr/lib/tsui.sh

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

# 规范化用户输入的网段：
#   192.168.1.10            -> 192.168.1.0/24（只写 IP 时按 /24）
#   192.168.1.0/255.255.255.0 -> 192.168.1.0/24
#   192.168.1.0/24          -> 原样（网络地址会被归一化）
normalize_cidr() {
    _raw=$(printf '%s' "$1" | tr -d ' ')
    [ -n "$_raw" ] || return 1
    NETWORK=""
    PREFIX=""
    case "$_raw" in
        */*)
            _ip=${_raw%%/*}
            _p=${_raw#*/}
            case "$_p" in
                *.*) eval "$(/bin/ipcalc.sh "$_ip" "$_p" 2>/dev/null | grep -E '^(NETWORK|PREFIX)=')" ;;
                *)   eval "$(/bin/ipcalc.sh "$_raw" 2>/dev/null | grep -E '^(NETWORK|PREFIX)=')" ;;
            esac
            ;;
        *)
            eval "$(/bin/ipcalc.sh "$_raw" 255.255.255.0 2>/dev/null | grep -E '^(NETWORK|PREFIX)=')"
            ;;
    esac
    [ -n "$NETWORK" ] && [ -n "$PREFIX" ] && echo "$NETWORK/$PREFIX"
}

# tailscaled 是否已经能接受 CLI 调用（tailscale0 上有地址）
ts_ready() {
    ip -4 addr show dev tailscale0 2>/dev/null | grep -q 'inet '
}

# 所有会写 prefs 的操作共用一把锁：开机循环和网页同时 set 时，后写的会覆盖
# 先写的。拿不到锁就让调用方稍后重试，而不是并发跑两个 22MB 的 CLI。
ts_lock_acquire() {
    if [ -f /tmp/ts-cli.lock ]; then
        _age=$(( $(date +%s) - $(cat /tmp/ts-cli.lock 2>/dev/null || echo 0) ))
        [ "$_age" -lt 240 ] && return 1
    fi
    date +%s > /tmp/ts-cli.lock
    return 0
}

ts_lock_release() {
    rm -f /tmp/ts-cli.lock
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
    # 没登录什么内部信息都不给：连状态都只回一个 auth=0。
    if ! auth_ok; then
        json_header
        printf '\r\n'
        printf '{"ok":false,"auth":0,"msg":"请先登录"}\n'
        exit 0
    fi

    TS_STATE=$(status_value state)
    TS_IP=$(status_value ip)
    TS_AUTH=$(status_value auth)

    # 登录流程是否在跑（ts_login 写的锁）。前端用它决定显示「正在生成授权链接」，
    # 而不是干等一个文案；锁最长 300 秒，超时视为已结束。
    TS_LOGIN_PENDING=0
    TS_LOGIN_AGE=0
    if [ -f /tmp/ts-login.lock ]; then
        TS_LOGIN_AGE=$(( $(date +%s) - $(cat /tmp/ts-login.lock 2>/dev/null || echo 0) ))
        case "$TS_LOGIN_AGE" in
            ''|*[!0-9]*) TS_LOGIN_AGE=0 ;;
        esac
        if [ "$TS_LOGIN_AGE" -ge 0 ] && [ "$TS_LOGIN_AGE" -lt 300 ]; then
            TS_LOGIN_PENDING=1
        else
            TS_LOGIN_AGE=0
        fi
    fi

    # 设备名（Tailscale 后台 / MagicDNS 显示名）。文件不存在时按历史默认 mt76x8，
    # 免得升级上来的设备一直显示“待应用”。
    TS_HOSTNAME=$(head -n 1 /etc/tailscale/hostname 2>/dev/null)
    [ -n "$TS_HOSTNAME" ] || TS_HOSTNAME=mt76x8
    TS_HOSTNAME_APPLIED=$(head -n 1 /etc/tailscale/hostname.applied 2>/dev/null)
    [ -n "$TS_HOSTNAME_APPLIED" ] || TS_HOSTNAME_APPLIED=mt76x8

    LAN_IP=$(lan_ip)
    LAN_GW=$(lan_gateway)
    LAN_PROTO=$(uci -q get network.lan.proto)
    HOSTNAME=$(uci -q get system.@system[0].hostname)
    [ -n "$HOSTNAME" ] || HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null)
    UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    MEM_TOTAL=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    MEM_FREE=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)

    TS_ROUTES=$(head -n 1 /etc/tailscale/advertised 2>/dev/null)
    [ -n "$TS_ROUTES" ] || TS_ROUTES=$(head -n 1 /etc/tailscale/lan-cidr 2>/dev/null)
    TS_LAN_AUTO=0
    [ -f /etc/tailscale/lan-auto ] && TS_LAN_AUTO=1
    TS_EXTRA=$(tr '\n' ',' < /etc/tailscale/routes 2>/dev/null | sed 's/,*$//')

    # 展示「期望广播的列表」，并单独标出是否已经真正生效。
    LAN_CIDR=$(head -n 1 /etc/tailscale/lan-cidr 2>/dev/null)
    WANT=""
    [ "$TS_LAN_AUTO" = "1" ] && [ -n "$LAN_CIDR" ] && WANT="$LAN_CIDR"
    [ -n "$TS_EXTRA" ] && WANT="${WANT:+$WANT,}$TS_EXTRA"
    TS_ROUTES="$WANT"
    TS_APPLIED=$(head -n 1 /etc/tailscale/advertised 2>/dev/null)
    TS_PENDING=0
    [ "$WANT" != "$TS_APPLIED" ] && TS_PENDING=1

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
  "ts_login_pending": $TS_LOGIN_PENDING,
  "ts_login_age": $TS_LOGIN_AGE,
  "ts_hostname": "$(json_escape "$TS_HOSTNAME")",
  "ts_hostname_applied": "$(json_escape "$TS_HOSTNAME_APPLIED")",
  "ts_routes": "$(json_escape "$TS_ROUTES")",
  "ts_pending": $TS_PENDING,
  "ts_lan_auto": $TS_LAN_AUTO,
  "ts_extra": "$(json_escape "$TS_EXTRA")",
  "ts_socket": $TS_SOCKET,
  "ts_daemon": $TS_SOCKET,
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

if [ "$OP" = "net" ]; then
    auth_ok || fail "请先登录"
    DNS=$(awk '/^nameserver/ {printf "%s ", $2}' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null)
    [ -n "$DNS" ] || DNS=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
    MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null)
    PORTS=$(netstat -ltn 2>/dev/null | awk 'NR > 2 { split($4, a, ":"); print a[length(a)] }' | sort -n -u | tr '\n' ' ')
    json_header
    printf '\r\n'
    cat <<EOF
{
  "ok": true,
  "dns": "$(json_escape "$DNS")",
  "mac": "$(json_escape "$MAC")",
  "ports": "$(json_escape "$PORTS")"
}
EOF
    exit 0
fi

if [ "$OP" = "system" ]; then
    auth_ok || fail "请先登录"
    MODEL=$(cat /tmp/sysinfo/model 2>/dev/null)
    RELEASE=$(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
    SYS_HOSTNAME=$(uci -q get system.@system[0].hostname)
    [ -n "$SYS_HOSTNAME" ] || SYS_HOSTNAME=$(cat /proc/sys/kernel/hostname 2>/dev/null)
    KERNEL=$(uname -r 2>/dev/null)
    UPTIME=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    MEM_TOTAL=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    MEM_FREE=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    LOAD=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
    STORAGE=$(df -h /overlay 2>/dev/null | tail -n 1 | awk '{print $4 " 可用 / " $2}')
    BUILD_COMMIT=$(sed -n 's/^COMMIT=//p' /etc/mt76x8-build 2>/dev/null | cut -c1-8)
    BUILD_REF=$(sed -n 's/^REF=//p' /etc/mt76x8-build 2>/dev/null)
    BUILD_RUN=$(sed -n 's/^RUN=//p' /etc/mt76x8-build 2>/dev/null)
    BUILD_AT=$(sed -n 's/^BUILT_AT=//p' /etc/mt76x8-build 2>/dev/null)
    BUILD_TS=$(sed -n 's/^TAILSCALE=//p' /etc/mt76x8-build 2>/dev/null)
    json_header
    printf '\r\n'
    cat <<EOF
{
  "ok": true,
  "model": "$(json_escape "$MODEL")",
  "release": "$(json_escape "$RELEASE")",
  "kernel": "$(json_escape "$KERNEL")",
  "hostname": "$(json_escape "$SYS_HOSTNAME")",
  "uptime": "$(json_escape "$UPTIME")",
  "mem_total": "$(json_escape "$MEM_TOTAL")",
  "mem_free": "$(json_escape "$MEM_FREE")",
  "load": "$(json_escape "$LOAD")",
  "storage": "$(json_escape "$STORAGE")",
  "build_commit": "$(json_escape "$BUILD_COMMIT")",
  "build_ref": "$(json_escape "$BUILD_REF")",
  "build_run": "$(json_escape "$BUILD_RUN")",
  "build_at": "$(json_escape "$BUILD_AT")",
  "build_tailscale": "$(json_escape "$BUILD_TS")"
}
EOF
    exit 0
fi

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
        echo "== tailscale interface =="
        ip -4 addr show dev tailscale0 2>/dev/null || echo "(tailscale0 不存在：未登录或未启动)"
        echo
        echo "== /dev/net/tun =="
        ls -l /dev/net/tun 2>&1
        echo
        echo "== tailscaled socket =="
        ls -l /var/run/tailscale/ 2>/dev/null
        echo
        echo "== cached status =="
        cat /tmp/ts.status 2>/dev/null
        echo
        echo "== prefs =="
        echo "lan-auto=$(ls /etc/tailscale/lan-auto 2>/dev/null)"
        echo "routes=$(cat /etc/tailscale/routes 2>/dev/null)"
        echo "advertised=$(cat /etc/tailscale/advertised 2>/dev/null)"
        echo "hostname=$(cat /etc/tailscale/hostname 2>/dev/null)"
        echo "hostname_applied=$(cat /etc/tailscale/hostname.applied 2>/dev/null)"
        echo
        echo "== ts_login.log =="
        tail -n 20 /tmp/ts_login.log 2>/dev/null
        echo
        echo "== tailscale log tail =="
        logread 2>/dev/null | grep -i -E 'tailscale|tailscaled|AuthURL|loggedIn' | tail -n 30
        echo
        echo "== dmesg tail =="
        dmesg 2>/dev/null | tail -n 20
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
        # 22MB 的 CLI 在 580MHz 上启动一次要十几秒到几十秒，所以给足时间。
        if [ -f /tmp/ts-login.lock ]; then
            AGE=$(( $(date +%s) - $(cat /tmp/ts-login.lock 2>/dev/null || echo 0) ))
            [ "$AGE" -lt 300 ] && ok "登录流程已经在运行，请稍候刷新状态"
        fi
        date +%s >/tmp/ts-login.lock
        rm -f /tmp/ts.ignore-auth
        # 用保存过的设备名，别每次登录都硬写 mt76x8。
        TS_NAME=$(head -n 1 /etc/tailscale/hostname 2>/dev/null)
        [ -n "$TS_NAME" ] || TS_NAME=mt76x8
        ADVERTISE=""
        if [ -s /etc/tailscale/lan-cidr ]; then
            ADVERTISE="--advertise-routes=$(head -n 1 /etc/tailscale/lan-cidr)"
        fi
        (
            run_limited 240 tailscale up $ADVERTISE \
                --hostname="$TS_NAME" --reset </dev/null >/tmp/ts_login.log 2>&1 \
                && printf '%s\n' "$TS_NAME" > /etc/tailscale/hostname.applied
            rm -f /tmp/ts-login.lock
        ) &
        # 登录成功后让开机循环尽快重试广播，不要卡在失败退避里。
        rm -f /tmp/ts-readvertise.last
        ok "已经开始登录，授权链接生成后会在页面上自动出现（约 10~40 秒）"
        ;;

    ts_logout)
        run_limited 120 tailscale logout >/dev/null 2>&1 || fail "退出失败（可能未登录）"
        : > /tmp/ts.status
        : > /tmp/ts.ignore-auth
        ok "已退出 Tailscale"
        ;;

    ts_hostname_save)
        # 改的是 Tailscale 节点名（后台列表、MagicDNS 里显示的名字），同一台设备、
        # 同一个 100.x 地址，不会新建节点。规则跟 DNS label 一样。
        NAME=$(param name | tr 'A-Z' 'a-z')
        case "$NAME" in
            '') fail "设备名不能为空" ;;
            *[!a-z0-9-]*) fail "设备名只能用小写字母、数字和 -" ;;
            -*|*-) fail "设备名不能以 - 开头或结尾" ;;
        esac
        [ ${#NAME} -le 63 ] || fail "设备名最多 63 个字符"

        mkdir -p /etc/tailscale
        printf '%s\n' "$NAME" > /etc/tailscale/hostname

        # 和路由一样：先落盘，连上以后再应用。
        if ! ts_ready; then
            ok "已保存为 $NAME（Tailscale 未连接，连上后自动应用）"
        fi

        ts_lock_acquire || fail "Tailscale 正在执行其他操作，请稍后再试（配置已保存）"
        run_limited 120 tailscale set --hostname="$NAME" >/tmp/ts_setname.log 2>&1
        _rc=$?
        ts_lock_release

        if [ "$_rc" -ne 0 ]; then
            fail "应用失败：$(tail -n 1 /tmp/ts_setname.log 2>/dev/null)（已保存，连上后自动应用）"
        fi
        printf '%s\n' "$NAME" > /etc/tailscale/hostname.applied
        ok "设备名已改为 $NAME，Tailscale 后台和 MagicDNS 会同步更新"
        ;;

    ts_routes_save)
        LAN_FLAG=$(param lan)
        RAW=$(param routes)
        NORM=""

        # 逗号分隔输入；每项都规范化，重复的丢掉。
        OLDIFS=$IFS
        IFS=','
        for item in $RAW; do
            IFS=$OLDIFS
            [ -n "$(printf '%s' "$item" | tr -d ' ')" ] || continue
            c=$(normalize_cidr "$item") || fail "网段格式不正确：$item"
            case ",$NORM," in
                *",$c,"*) ;;
                *) NORM="${NORM:+$NORM,}$c" ;;
            esac
            IFS=','
        done
        IFS=$OLDIFS

        # 生效集合 = （可选）本机 LAN 网段 + 手写列表
        LAN_CIDR=$(head -n 1 /etc/tailscale/lan-cidr 2>/dev/null)
        EFF=""
        if [ "$LAN_FLAG" = "1" ]; then
            [ -n "$LAN_CIDR" ] || fail "还没拿到 LAN 地址，稍后再试"
            EFF="$LAN_CIDR"
            : > /etc/tailscale/lan-auto
        else
            rm -f /etc/tailscale/lan-auto
        fi
        [ -n "$NORM" ] && EFF="${EFF:+$EFF,}$NORM"

        printf '%s' "$NORM" | tr ',' '\n' | sed '/^$/d' > /etc/tailscale/routes

        # 和 LuCI 一样：先把改动落盘，再“应用”。Tailscale 还没连上时只落盘，
        # 由后台循环在连上后自动应用，避免和启动过程抢 prefs。
        if ! ts_ready; then
            ok "已保存（Tailscale 未连接，连上后会自动应用）"
        fi

        ts_lock_acquire || fail "Tailscale 正在执行其他操作，请稍后再试（配置已保存）"

        if [ -z "$EFF" ]; then
            run_limited 150 tailscale set --advertise-routes= >/dev/null 2>&1
            _rc=$?
        else
            run_limited 150 tailscale set --advertise-routes="$EFF" >/dev/null 2>&1
            _rc=$?
        fi
        ts_lock_release

        if [ "$_rc" -ne 0 ]; then
            fail "应用失败：节点可能尚未登录（配置已保存，连上后会自动应用）"
        fi

        if [ -z "$EFF" ]; then
            : > /etc/tailscale/advertised
            ok "已停止发布所有子网路由"
        fi
        echo "$EFF" > /etc/tailscale/advertised
        ok "已应用 $EFF（新网段需在后台批准）"
        ;;

    ts_serve)
        ts_lock_acquire || fail "Tailscale 正在执行其他操作，请稍后再试"
        run_limited 120 tailscale serve --bg http://127.0.0.1:80 >/tmp/ts_serve.log 2>&1
        _rc=$?
        ts_lock_release
        [ "$_rc" -eq 0 ] || fail "开启失败：$(tail -n 2 /tmp/ts_serve.log 2>/dev/null)"
        ok "已开启 HTTPS 访问（需 tailnet 启用 HTTPS Certificates）"
        ;;

    ts_daemon)
        # 停止/启动 tailscaled 本身（不是登出）。停止会保留登录态，省内存；
        # 启动后自动回到之前的节点身份。
        ACT=$(param action)
        ts_lock_acquire || fail "Tailscale 正在执行其他操作，请稍后再试"
        case "$ACT" in
            stop)
                run_limited 180 /etc/init.d/tailscale stop >/dev/null 2>&1
                : > /tmp/ts.status
                ts_lock_release
                ok "Tailscale 服务已停止（登录态保留）"
                ;;
            start)
                /etc/init.d/tailscale start >/dev/null 2>&1
                ts_lock_release
                ok "Tailscale 服务已启动"
                ;;
            *)
                ts_lock_release
                fail "未知操作"
                ;;
        esac
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

    sys_hostname_save)
        # 改的是 OpenWrt 的系统主机名（/etc/config/system），和 Tailscale 的
        # 设备名是两回事：Tailscale 名字由 tailscale set --hostname 单独管，
        # 不会被这里带跑（rc.local 也不读系统主机名）。
        SYS_NAME=$(param name | tr 'A-Z' 'a-z')
        case "$SYS_NAME" in
            '') fail "主机名不能为空" ;;
            *[!a-z0-9-]*) fail "主机名只能用小写字母、数字和 -" ;;
            -*|*-) fail "主机名不能以 - 开头或结尾" ;;
        esac
        [ ${#SYS_NAME} -le 63 ] || fail "主机名最多 63 个字符"

        uci -q set system.@system[0].hostname="$SYS_NAME"
        uci -q commit system
        # 立即生效，不用重启；DHCP 客户端下次续租时会带上新名字。
        printf '%s\n' "$SYS_NAME" > /proc/sys/kernel/hostname
        ok "系统主机名已改为 $SYS_NAME"
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
