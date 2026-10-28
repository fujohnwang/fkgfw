#!/bin/bash
set -euo pipefail
umask 077
# ExecStartPre clears the previous log and hostname. Poll only this startup's
# log, and publish the new Quick Tunnel hostname atomically.
for ((attempt = 0; attempt < 60; attempt++)); do
    domain=$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' /var/log/cloudflared.log | tail -n 1 | sed 's@https://@@' || true)
    if [ -n "$domain" ]; then
        tmp=$(mktemp /etc/sing-box/.argo.XXXXXX)
        trap 'rm -f "$tmp"' EXIT
        printf '%s\n' "$domain" | base64 > "$tmp"
        mv -f "$tmp" /etc/sing-box/argo.txt.b64
        exit 0
    fi
    sleep 1
done
echo "错误: 60 秒内未获取新的 Quick Tunnel 地址" >&2
exit 1
