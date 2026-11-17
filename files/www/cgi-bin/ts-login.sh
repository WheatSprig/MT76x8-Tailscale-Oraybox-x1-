#!/bin/sh
# 兼容入口：/cgi-bin/ts-login.sh
#
# 不再在 CGI 里同步等待授权链接（那会把 uhttpd 的请求槽位占死）。
#   - 状态缓存里已经有 AuthURL：直接 302 过去；
#   - 没有：触发一次后台 `tailscale up`，立刻 303 回控制台，
#     授权链接生成后由控制台显示。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

AUTH_URL=$(sed -n 's/^auth=//p' /tmp/ts.status 2>/dev/null | head -n 1)
AUTH_URL=$(printf '%s' "$AUTH_URL" | tr -d '\r\n')

if [ -n "$AUTH_URL" ]; then
    printf 'Status: 302 Found\r\n'
    printf 'Location: %s\r\n' "$AUTH_URL"
    printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
    printf 'Content-Type: text/html; charset=utf-8\r\n'
    printf '\r\n'
    printf '<!DOCTYPE html><meta charset="utf-8"><p>正在跳转到 Tailscale 授权页面…</p>'
    exit 0
fi

# 同一时刻只允许一个 tailscale up（点击多次不会堆积进程）。
START=1
if [ -f /tmp/ts-login.lock ]; then
    AGE=$(( $(date +%s) - $(cat /tmp/ts-login.lock 2>/dev/null || echo 0) ))
    [ "$AGE" -lt 300 ] && START=0
fi

if [ "$START" = "1" ]; then
    date +%s >/tmp/ts-login.lock
    rm -f /tmp/ts.ignore-auth
    ADVERTISE=""
    if [ -s /etc/tailscale/lan-cidr ]; then
        ADVERTISE="--advertise-routes=$(head -n 1 /etc/tailscale/lan-cidr)"
    fi
    (
        tailscale up $ADVERTISE --hostname=mt76x8 --reset \
            </dev/null >/tmp/ts_login.log 2>&1
        rm -f /tmp/ts-login.lock
    ) &

    # up 已经带上 --advertise-routes，标记一下，避免开机循环再跑一次 CLI。
    if [ -s /etc/tailscale/lan-cidr ]; then
        head -n 1 /etc/tailscale/lan-cidr > /etc/tailscale/advertised 2>/dev/null
    fi
    rm -f /etc/tailscale/routes-manual 2>/dev/null
fi

printf 'Status: 303 See Other\r\n'
printf 'Location: /?login=pending\r\n'
printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
printf 'Content-Type: text/html; charset=utf-8\r\n'
printf '\r\n'
printf '<!DOCTYPE html><meta charset="utf-8"><p>正在生成授权链接，请返回控制台查看。</p>'
exit 0
