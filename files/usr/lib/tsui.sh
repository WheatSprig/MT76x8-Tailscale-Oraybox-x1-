#!/bin/sh
# 控制台的登录态与密码校验，供 api.sh / upgrade.sh 共用。
# 被 source，不直接执行。

TOKEN_FILE=/tmp/tsui.tokens
PASSWORD_FILE=/etc/tsui.passwd

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
