#!/bin/sh
# BusyBox /bin/sh CGI: 获取 Tailscale 官方授权链接，或展示当前节点状态。
# 不依赖 bash / jq。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

AUTH_URL=""
BACKEND_STATE=""
IPV4=""

get_auth_url() {
    tailscale status --json 2>/dev/null \
        | grep -o '"AuthURL"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n 1 \
        | cut -d '"' -f 4
}

get_backend_state() {
    tailscale status --json 2>/dev/null \
        | grep -o '"BackendState"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -n 1 \
        | cut -d '"' -f 4
}

html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

if ! command -v tailscale >/dev/null 2>&1; then
    BACKEND_STATE="tailscale-not-found"
else
    AUTH_URL=$(get_auth_url)
    BACKEND_STATE=$(get_backend_state)

    # 已登录运行中的节点不要重复执行 tailscale up --reset，避免短暂断线。
    if [ -z "$AUTH_URL" ] && [ "$BACKEND_STATE" != "Running" ]; then
        # 作为子网路由，把办公室局域网发布到 Tailnet（需在管理后台批准）。
        ADVERTISE=""
        if [ -s /etc/tailscale/lan-cidr ]; then
            ADVERTISE="--advertise-routes=$(cat /etc/tailscale/lan-cidr)"
        fi

        (
            tailscale up $ADVERTISE \
                --hostname=mt76x8 --reset \
                </dev/null >/tmp/ts_login.log 2>&1 &
        )

        count=0
        while [ "$count" -lt 6 ]; do
            sleep 1
            AUTH_URL=$(get_auth_url)
            [ -n "$AUTH_URL" ] && break
            count=$((count + 1))
        done

        BACKEND_STATE=$(get_backend_state)
    fi

    IPV4=$(tailscale ip -4 2>/dev/null | head -n 1)
fi

# 去掉可能存在的控制字符，避免 HTTP 头注入。
AUTH_URL=$(printf '%s' "$AUTH_URL" | tr -d '\r\n')

if [ -n "$AUTH_URL" ]; then
    printf 'Status: 302 Found\r\n'
    printf 'Location: %s\r\n' "$AUTH_URL"
    printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
    printf 'Content-Type: text/html; charset=utf-8\r\n'
    printf '\r\n'
    printf '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Redirecting</title></head>'
    printf '<body><p>正在跳转到 Tailscale 授权页面……</p>'
    printf '<p><a href="%s">如果没有自动跳转，请点击这里</a></p></body></html>' "$AUTH_URL"
    exit 0
fi

[ -n "$BACKEND_STATE" ] || BACKEND_STATE="Unknown"
[ -n "$IPV4" ] || IPV4="未获取到 IPv4 地址（可能尚未登录或尚未联网）"

STATE_HTML=$(html_escape "$BACKEND_STATE")
IP_HTML=$(html_escape "$IPV4")

printf 'Content-Type: text/html; charset=utf-8\r\n'
printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
printf '\r\n'
cat <<EOF
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Tailscale 登录状态</title>
<style>
  * { box-sizing: border-box; }
  body {
    margin: 0;
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px 18px;
    background: radial-gradient(circle at 50% 0%, #17233b 0%, #0b1220 55%, #070b13 100%);
    color: #e8eefc;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                 "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  }
  .card {
    width: 100%;
    max-width: 460px;
    padding: 30px 24px;
    border: 1px solid rgba(120, 160, 255, 0.18);
    border-radius: 18px;
    background: rgba(18, 27, 46, 0.9);
    box-shadow: 0 24px 70px rgba(0, 0, 0, 0.45);
  }
  h1 { margin: 0 0 18px; font-size: 22px; }
  .row { margin: 12px 0; padding: 12px 14px; border-radius: 10px; background: rgba(255,255,255,0.04); }
  .label { color: #8ea3c7; font-size: 12px; letter-spacing: 0.05em; }
  .value { margin-top: 5px; font-size: 15px; word-break: break-all; }
  .tip { margin: 18px 0; color: #f6c177; font-size: 13px; line-height: 1.7; }
  .back {
    display: block;
    padding: 13px 16px;
    border-radius: 10px;
    background: #2563eb;
    color: #fff;
    text-align: center;
    font-weight: 700;
    text-decoration: none;
  }
</style>
</head>
<body>
  <main class="card">
    <h1>Tailscale 登录状态</h1>
    <div class="row">
      <div class="label">BackendState</div>
      <div class="value">${STATE_HTML}</div>
    </div>
    <div class="row">
      <div class="label">Tailscale IPv4</div>
      <div class="value">${IP_HTML}</div>
    </div>
    <p class="tip">暂未获取到授权链接。若节点已经处于 Running 状态，说明它已登录；否则请确认设备已联网后返回首页重试。</p>
    <a class="back" href="/">返回首页</a>
  </main>
</body>
</html>
EOF

exit 0
