#!/bin/sh
# LAN 配置回滚：commit-confirm 的“超时自动回滚”和“开机兜底”。
#
#   lan-rollback.sh check            立即检查（开机时用）：pending 还在就恢复
#   lan-rollback.sh guarded <token>  等 180 秒；pending 里的 token 没变才恢复
#
# 只有 token 对得上才动手，避免连续两次 apply 时旧定时器把新配置回滚掉。
# pending 放在 /etc（持久），这样“应用后马上断电”也能在开机时回滚。

PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

PENDING=/etc/lan-pending
BACKUP=/etc/config/network.bak
WAIT=180

case "$1" in
    check)
        ;;
    guarded)
        sleep "$WAIT"
        [ -f "$PENDING" ] || exit 0
        [ "$(head -n 1 "$PENDING" 2>/dev/null)" = "$2" ] || exit 0
        ;;
    *)
        echo "usage: $0 check | guarded <token>" >&2
        exit 2
        ;;
esac

[ -f "$PENDING" ] || exit 0

if [ -f "$BACKUP" ]; then
    cp "$BACKUP" /etc/config/network
else
    logger -t lan-guard "找不到备份，只清除 pending"
fi
rm -f "$PENDING"
logger -t lan-guard "LAN 配置未确认，已回滚到上一份配置"

# 让新（旧）配置生效；这次 reload 之后如果还有 pending 也不该有了。
/etc/init.d/network reload >/tmp/lan-reload.log 2>&1
exit 0
