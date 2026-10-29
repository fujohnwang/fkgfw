#!/bin/bash
# Public certificates are managed by sing-box's shared ACME provider (1.14+).
has_managed_tls() { jq -e 'any(.inbounds[]?; .tag == "vless-tls-in" or .tag == "anytls-in")' "$1" >/dev/null; }

prompt_tls_domain() {
    local value default="${1:-}"
    echo '域名须直接解析到本机公网 IP；Cloudflare 请设为灰云「仅 DNS」。' >&2
    while true; do
        read -r -p "证书域名${default:+ [默认 $default]}: " value || return 1
        value=${value:-$default}
        if jq -en --arg domain "$value" '$domain | length <= 253 and test("^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z]{2,63}$")' >/dev/null; then
            printf '%s\n' "$value" | tr '[:upper:]' '[:lower:]'
            return 0
        fi
        echo '请输入完整自有域名，不能留空、使用 IP、通配符或包含协议/路径。' >&2
    done
}

# Normalize equivalent compressed IPv6 spellings before comparing DNS records.
ip_key() {
    jq -Rr 'ascii_downcase | if contains(":") then
      split("::") as $s
      | ($s[0] | split(":") | map(select(length > 0))) as $left
      | (($s[1] // "") | split(":") | map(select(length > 0))) as $right
      | (if ($s | length) == 2 then $left + [range(0; 8 - ($left | length) - ($right | length)) | "0"] + $right else $left end)
      | map(sub("^0+"; "") | if . == "" then "0" else . end) | join(":")
      else . end'
}

verify_tls_domain() (
    set -e
    domain="$1" records="" known="" response=""
    for record_type in A AAAA; do
        response=$(curl -fsS --connect-timeout 5 --max-time 15 --get \
            --data-urlencode "name=$domain" --data-urlencode "type=$record_type" https://dns.google/resolve) || {
            echo "错误: 无法查询 $domain 的公网 DNS。" >&2; exit 1;
        }
        values=$(jq -er 'if .Status == 0 then [.Answer[]? | select(.type == 1 or .type == 28) | .data] | join("\n") else error("DNS lookup failed") end' <<< "$response") || {
            echo "错误: $domain 的 $record_type 查询失败，请等待 DNS 生效后重试。" >&2; exit 1;
        }
        records="${records}${values}"$'\n'
    done
    records=$(printf '%s' "$records" | sed '/^$/d' | ip_key | sort -u)
    [ -n "$records" ] || { echo "错误: $domain 没有公网 A/AAAA 记录。" >&2; exit 1; }
    for family in 4 6; do
        if value=$(curl -"$family"fsS --connect-timeout 5 --max-time 8 https://api.ipify.org); then
            known="${known}${value}"$'\n'
        fi
    done
    # SERVER_ADDRESS may explicitly supply the NAT/public address.
    if [[ "${SERVER_ADDRESS:-}" =~ ^[0-9a-fA-F:.]+$ ]]; then known="${known}${SERVER_ADDRESS}"$'\n'; fi
    known=$(printf '%s' "$known" | sed '/^$/d' | ip_key | sort -u)
    [ -n "$known" ] || { echo '错误: 无法确定本机公网 IP，可使用 SERVER_ADDRESS 指定。' >&2; exit 1; }
    while IFS= read -r value; do
        if ! grep -Fxq -- "$value" <<< "$known"; then
            echo "错误: $domain 的 A/AAAA 记录未全部指向本机公网 IP。请关闭 Cloudflare 橙云，修正多余或失效的记录后重试。" >&2
            exit 1
        fi
    done <<< "$records"
    echo "✓ $domain 的公网解析检查通过。" >&2
)

prepare_managed_tls() {
    local config="$1" previous="$2" binary="$3" domain listeners version
    has_managed_tls "$config" || return 0
    version=$("$binary" version) || return 1
    if ! grep -q 'with_acme' <<< "$version" || ! awk '/^sing-box version / {split($3,v,"."); if (v[1] > 1 || (v[1] == 1 && v[2] >= 14)) ok=1} END {exit !ok}' <<< "$version"; then
        echo '错误: 新增 TLS 协议需要 sing-box 1.14+ 且包含 with_acme；请先使用菜单 5 更新程序。' >&2
        return 1
    fi
    # Only changed/new domains need a DNS check; existing nodes keep their settings.
    while IFS= read -r domain; do
        verify_tls_domain "$domain" || return 1
    done < <(jq -r --slurpfile old "$previous" '
      [.inbounds[] | select(.tag == "vless-tls-in" or .tag == "anytls-in") | .tls.server_name] -
      [$old[0].inbounds[]? | select(.tag == "vless-tls-in" or .tag == "anytls-in") | .tls.server_name] | unique[]' "$config")
    if jq -e 'any(.inbounds[]; .type != "hysteria2" and .listen_port == 80)' "$config" >/dev/null; then
        echo '错误: TCP 80 必须留给 ACME 证书验证，请为代理选择其他端口。' >&2; return 1
    fi
    listeners=$(ss -H -ltn 'sport = :80') || return 1
    if [ -n "$listeners" ]; then
        echo '错误: TCP 80 已被其他监听占用，无法申请或续期证书；请先处理该端口。' >&2; return 1
    fi
    echo '证书将由 sing-box 自动申请和续期；请保持公网 TCP 80 可达，并放行所选代理 TCP 端口。'
}

enable_acme_storage() {
    install -d -o singbox -g singbox -m 700 /etc/sing-box/acme || return 1
    local unit=/etc/systemd/system/sing-box.service
    grep -q '^\[Service\]$' "$unit" || return 1
    if ! grep -Fxq 'ReadWritePaths=/etc/sing-box/acme' "$unit"; then
        sed '/^\[Service\]$/a\
ReadWritePaths=/etc/sing-box/acme
' "$unit" > "$unit.new" || return 1
        chmod 644 "$unit.new" && mv -f "$unit.new" "$unit" || return 1
    fi
}

wait_for_tls() {
    local config="$1" domain port deadline
    has_managed_tls "$config" || return 0
    echo '等待 TLS 证书和监听就绪（最多 180 秒；失败将恢复原配置）...'
    deadline=$((SECONDS + 180))
    while IFS=$'\t' read -r domain port; do
        while ! timeout 5 openssl s_client -connect "127.0.0.1:$port" -servername "$domain" \
            -verify_hostname "$domain" -verify_return_error </dev/null >/dev/null 2>&1; do
            if [ "$SECONDS" -ge "$deadline" ] || ! systemctl is-active --quiet sing-box; then
                echo '错误: TLS 证书或监听未就绪。请检查域名、TCP 80 和 journalctl -u sing-box。' >&2
                return 1
            fi
            sleep 2
        done
    done < <(jq -r '.inbounds[] | select(.tag == "vless-tls-in" or .tag == "anytls-in") | [.tls.server_name, .listen_port] | @tsv' "$config")
}
