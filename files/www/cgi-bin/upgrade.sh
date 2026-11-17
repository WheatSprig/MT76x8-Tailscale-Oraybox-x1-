#!/bin/sh
# 固件升级：接收 sysupgrade.bin（原始请求体），校验后交给 sysupgrade。
#
# 防刷死的几道闸门：
#   1. 必须登录（复用 api.sh 的登录态）；
#   2. 只接受局域网地址上传（Tailscale 地址会被拒绝：升级前要停掉
#      tailscaled 腾内存，否则 12MB 镜像写进 tmpfs 会把设备 OOM）；
#   3. 大小必须在 4 MiB ~ 15 MiB 之间；
#   4. uImage 魔数 + 镜像里必须带 `oraybox,x1` 元数据（不是本设备的镜像直接拒收）；
#   5. 浏览器算好的 sha256 会再核对一遍（可选，但控制台总会带）；
#   6. 只写 firmware 分区，u-boot/Breed 不受影响；写坏了还能进 Breed 重刷。
#
# 仍然无法防住的情况只有一种：升级过程中断电。文档里写明了恢复方法。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 077

. /usr/lib/tsui.sh

MAX_BYTES=15728640
MIN_BYTES=4194304
TMP_IMG=/tmp/fw.bin

json_header() {
    printf 'Content-Type: application/json; charset=utf-8\r\n'
    printf 'Cache-Control: no-store, no-cache, must-revalidate\r\n'
    printf '\r\n'
}

fail() {
    json_header
    printf '{"ok":false,"msg":"%s"}\n' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n')"
    exit 0
}

ok() {
    json_header
    printf '{"ok":true,"msg":"%s"}\n' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\r\n')"
    exit 0
}

[ "$REQUEST_METHOD" = "POST" ] || fail "只接受 POST 上传"

load_password
auth_ok || fail "请先登录"

# Tailscale 地址上传会在停掉 tailscaled 时断线，也会因为内存不够而失败。
case "$REMOTE_ADDR" in
    100.*) fail "请用局域网地址访问控制台后再升级（Tailscale 地址不支持上传固件）" ;;
esac

# 同一时刻只允许一个升级流程。
if [ -f /tmp/upgrade.lock ]; then
    fail "已经有升级任务在进行"
fi

SIZE=$CONTENT_LENGTH
case "$SIZE" in
    ''|*[!0-9]*) fail "缺少 Content-Length" ;;
esac
[ "$SIZE" -ge "$MIN_BYTES" ] || fail "文件太小（$SIZE 字节），不是 sysupgrade 镜像"
[ "$SIZE" -gt "$MAX_BYTES" ] && fail "文件超过 15 MiB 分区上限（$SIZE 字节）"

[ -x /sbin/sysupgrade ] || fail "设备上没有 sysupgrade"

# 腾内存：12MB 镜像要落在 tmpfs 里，tailscaled 必须先停。
/etc/init.d/tailscale stop >/dev/null 2>&1
/etc/init.d/p910nd stop >/dev/null 2>&1
sync
sleep 1

AVAIL=$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
[ -n "$AVAIL" ] || AVAIL=0
if [ "$AVAIL" -lt 24 ]; then
    /etc/init.d/tailscale start >/dev/null 2>&1
    fail "可用内存只有 ${AVAIL}MB，升级至少需要 24MB，请稍后重试"
fi

: > /tmp/upgrade.lock
rm -f "$TMP_IMG"
cat > "$TMP_IMG" 2>/dev/null

GOT=$(wc -c < "$TMP_IMG" 2>/dev/null)
GOT=${GOT:-0}

restore_and_fail() {
    rm -f "$TMP_IMG" /tmp/upgrade.lock
    /etc/init.d/tailscale start >/dev/null 2>&1
    fail "$1"
}

[ "$GOT" = "$SIZE" ] || restore_and_fail "上传不完整（收到 $GOT / $SIZE 字节）"

# uImage 魔数 0x27051956
MAGIC=$(dd if="$TMP_IMG" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
[ "$MAGIC" = "27051956" ] || restore_and_fail "不是 uImage 格式的 sysupgrade 镜像"

# sysupgrade 元数据里带设备名；不是这块板子的镜像直接拒收。
grep -aq 'oraybox,x1' "$TMP_IMG" \
    || restore_and_fail "镜像不是 OrayBox X1（oraybox,x1）的固件"

# 浏览器算好的 sha256（可选），核对一次，防止上传被截断/篡改。
WANT_SHA=$(printf '%s' "$QUERY_STRING" | sed -n 's/.*sha256=\([0-9a-fA-F]\{64\}\).*/\1/p' | head -n 1)
if [ -n "$WANT_SHA" ]; then
    GOT_SHA=$(sha256sum "$TMP_IMG" | cut -d' ' -f1)
    [ "$GOT_SHA" = "$(printf '%s' "$WANT_SHA" | tr 'A-F' 'a-f')" ] \
        || restore_and_fail "sha256 不一致（镜像可能损坏）"
fi

sync

# 先回响应，再交给 sysupgrade：它会自己重启，请求不能等着它。
( sleep 2; sysupgrade -q "$TMP_IMG" ) >/tmp/upgrade.log 2>&1 &

ok "镜像校验通过，2 秒后开始升级并重启（约 2~3 分钟，期间不要断电）"
