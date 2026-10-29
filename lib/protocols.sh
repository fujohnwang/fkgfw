#!/bin/bash

has_protocol() { jq -e --arg tag "$2" 'any(.inbounds[]?; .tag == $tag)' "$1" >/dev/null; }
has_ws() { jq -e 'any(.inbounds[]?; .tag == "vmess-in" or .tag == "vless-ws-in")' "$1" >/dev/null; }
managed_tags() { jq -c '[.inbounds[].tag | select(. == "vless-in" or . == "hy2-in" or . == "vmess-in" or . == "vless-ws-in" or . == "vless-tls-in" or . == "anytls-in")]' "$1"; }

protocol_name() {
    case "$1" in
        vless-in) echo Reality ;;
        hy2-in) echo Hysteria2 ;;
        vmess-in) echo 'VMess WS' ;;
        vless-ws-in) echo 'VLESS WS' ;;
        vless-tls-in) echo 'VLESS TLS + Vision' ;;
        anytls-in) echo AnyTLS ;;
    esac
}

normalize_selection() {
    jq -cen --arg text "$1" '
      ["vless-in", "hy2-in", "vmess-in", "vless-ws-in", "vless-tls-in", "anytls-in"] as $tags
      | ($text | gsub(","; " ") | split(" ") | map(select(length > 0))) as $ids
      | if ($ids | length) == 0 or any($ids[]; test("^[1-6]$") | not) then
          error("Select one or more numbers from 1 to 6")
        else [$ids[] | tonumber] | unique | map($tags[. - 1]) end'
}

choose_protocols() {
    local default="$1" choice ids
    echo '选择协议组合：' >&2
    echo '1. 仅 Reality' >&2
    echo '2. 仅 Hysteria2' >&2
    echo '3. Reality + Hysteria2' >&2
    echo '4. VMess WS + VLESS WS' >&2
    echo '5. 全部四种协议' >&2
    echo '6. 自定义多选' >&2
    echo '7. 仅 VLESS TLS + Vision（自有域名）' >&2
    echo '8. 仅 AnyTLS（自有域名）' >&2
    echo '9. VLESS TLS + Vision + AnyTLS' >&2
    echo '10. 全部六种协议' >&2
    while true; do
        read -r -p "选择组合 [默认 $default]: " choice || return 1
        case "${choice:-$default}" in
            1) normalize_selection 1; return ;;
            2) normalize_selection 2; return ;;
            3) normalize_selection '1 2'; return ;;
            4) normalize_selection '3 4'; return ;;
            5) normalize_selection '1 2 3 4'; return ;;
            6)
                echo '1=Reality  2=Hysteria2  3=VMess WS  4=VLESS WS  5=VLESS TLS + Vision  6=AnyTLS' >&2
                read -r -p '输入编号，空格或逗号分隔，例如 1,4: ' ids || return 1
                if normalize_selection "$ids"; then return 0; fi
                ;;
            7) normalize_selection 5; return ;;
            8) normalize_selection 6; return ;;
            9) normalize_selection '5 6'; return ;;
            10) normalize_selection '1 2 3 4 5 6'; return ;;
            *) echo '请输入 1–10。' >&2 ;;
        esac
    done
}

prompt_port() {
    local label="$1" default="$2" value
    while true; do
        read -r -p "$label 端口 [默认 $default]: " value || return 1
        value=${value:-$default}
        if [[ "$value" =~ ^[0-9]{1,5}$ ]] && [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 65535 ]; then
            printf '%s\n' "$((10#$value))"
            return 0
        fi
        echo '端口必须为 1–65535。' >&2
    done
}

prompt_domain() {
    local label="$1" default="$2" value
    while true; do
        read -r -p "$label [默认 $default]: " value || return 1
        value=${value:-$default}
        if [[ "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]]; then printf '%s\n' "$value"; return 0; fi
        echo '请输入域名，不包含协议、路径或空格。' >&2
    done
}

prompt_ws_path() {
    local default="$1" value
    while true; do
        read -r -p "WebSocket 路径 [默认 $default]: " value || return 1
        value=${value:-$default}
        [[ "$value" = /* ]] || value="/$value"
        if [[ "$value" =~ ^/[a-zA-Z0-9_/-]+$ ]]; then printf '%s\n' "$value"; return 0; fi
        echo '路径只能包含字母、数字、下划线、连字符和斜杠。' >&2
    done
}

# Writes one inbound to stdout; newly generated key/certificate files stay in
# the private staging directory until all candidate configurations pass.
collect_inbound() (
    set -e
    tag="$1" previous="$2" stage="$3" binary="$4"
    label=$(protocol_name "$tag")
    case "$tag" in
        vless-in) default_port=443 ;;
        hy2-in) default_port=8443 ;;
        vmess-in) default_port=18443 ;;
        vless-ws-in) default_port=18444 ;;
        vless-tls-in) default_port=9443 ;;
        anytls-in) default_port=10443 ;;
    esac
    old=$(jq -c --arg tag "$tag" '[.inbounds[]? | select(.tag == $tag)][0] // null' "$previous")
    if [ "$old" != null ]; then default_port=$(jq -r .listen_port <<< "$old"); fi
    port=$(prompt_port "$label" "$default_port")
    if [ "$old" != null ]; then
        case "$tag" in
            vless-in)
                domain=$(prompt_domain 'Reality SNI' "$(jq -r .tls.server_name <<< "$old")")
                jq --argjson port "$port" --arg domain "$domain" '.listen_port = $port | if .tls.server_name != $domain then .tls.server_name = $domain | .tls.reality.handshake.server = $domain else . end' <<< "$old"
                ;;
            hy2-in) jq --argjson port "$port" '.listen_port = $port' <<< "$old" ;;
            vless-tls-in|anytls-in)
                domain=$(prompt_tls_domain "$(jq -r .tls.server_name <<< "$old")")
                jq --argjson port "$port" --arg domain "$domain" '.listen_port = $port | .tls.server_name = $domain' <<< "$old"
                ;;
            *)
                ws_path=$(prompt_ws_path "$(jq -r .transport.path <<< "$old")")
                jq --argjson port "$port" --arg path "$ws_path" '.listen_port = $port | .transport.path = $path' <<< "$old"
                ;;
        esac
        exit 0
    fi
    params=$(jq -n --arg tag "$tag" --argjson port "$port" '{tag: $tag, port: $port}')
    case "$tag" in
        vless-in)
            domain=$(prompt_domain 'Reality SNI' itunes.apple.com)
            pair=$("$binary" generate reality-keypair)
            private_key=$(awk '/PrivateKey/ {print $2}' <<< "$pair")
            public_key=$(awk '/PublicKey/ {print $2}' <<< "$pair")
            if [ -z "$private_key" ] || [ -z "$public_key" ]; then echo '错误: Reality 密钥生成失败。' >&2; exit 1; fi
            printf '%s\n' "$public_key" | base64 > "$stage/public.key.b64"
            params=$(jq --arg uuid "$("$binary" generate uuid)" --arg private_key "$private_key" --arg short_id "$("$binary" generate rand --hex 8)" --arg domain "$domain" '. + {uuid: $uuid, private_key: $private_key, short_id: $short_id, server_name: $domain}' <<< "$params")
            ;;
        hy2-in)
            domain=$(prompt_domain 'Hysteria2 自签名证书域名' bing.com)
            mkdir -p "$stage/certs"
            openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
                -keyout "$stage/certs/private.key" -out "$stage/certs/cert.pem" -days 36500 -subj "/CN=$domain" >&2
            params=$(jq --arg password "$("$binary" generate rand --hex 16)" '. + {password: $password}' <<< "$params")
            ;;
        vless-tls-in|anytls-in)
            domain=$(prompt_tls_domain)
            params=$(jq --arg uuid "$("$binary" generate uuid)" --arg password "$("$binary" generate rand --hex 16)" --arg domain "$domain" '. + {uuid: $uuid, password: $password, server_name: $domain}' <<< "$params")
            ;;
        *)
            ws_path=$(prompt_ws_path "/$("$binary" generate rand --hex 6)")
            params=$(jq --arg uuid "$("$binary" generate uuid)" --arg path "$ws_path" '. + {uuid: $uuid, path: $path}' <<< "$params")
            ;;
    esac
    jq -f "$SCRIPT_DIR/lib/new-inbound.jq" <<< "$params"
)

validate_listeners() {
    local config="$1" caddy_port="$2"
    jq -e --argjson caddy_port "$caddy_port" '
      [.inbounds[] | select(.listen_port != null)
        | {port: .listen_port, network: (if .type == "hysteria2" then "udp" else "tcp" end)}] as $ports
      | (all($ports[]; .port >= 1 and .port <= 65535))
        and (($ports | unique | length) == ($ports | length))
        and (if any(.inbounds[]; .tag == "vmess-in" or .tag == "vless-ws-in") then
          all($ports[]; .network != "tcp" or .port != $caddy_port)
          and ([.inbounds[] | select(.tag == "vmess-in" or .tag == "vless-ws-in") | .transport.path] as $paths
            | all($paths[]; test("^/[a-zA-Z0-9_/-]+$")) and (($paths | unique | length) == ($paths | length)))
        else true end)' "$config" >/dev/null || {
        echo '错误: 端口冲突、端口不合法或 WebSocket 路径重复/不合法，请重新选择。' >&2
        return 1
    }
}

render_caddy_config() {
    local config="$1" port="$2"
    printf '{\n\tauto_https off\n\tadmin off\n}\n\n:%s {\n\tbind 127.0.0.1\n' "$port"
    jq -r '.inbounds[] | select(.tag == "vmess-in" or .tag == "vless-ws-in")
      | "\t handle \(.transport.path) {\n\t\treverse_proxy 127.0.0.1:\(.listen_port)\n\t}"' "$config"
    printf '\trespond 404\n}\n'
}

write_caddy_service() {
    cat <<'UNIT'
[Unit]
Description=Caddy Local Reverse Proxy
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
[Install]
WantedBy=multi-user.target
UNIT
}

write_cloudflared_service() {
    cat <<UNIT
[Unit]
Description=Cloudflared Tunnel
After=network.target caddy.service
[Service]
Type=simple
User=singbox
Group=singbox
ExecStartPre=/bin/sh -c 'truncate -s 0 /var/log/cloudflared.log; rm -f /etc/sing-box/argo.txt.b64'
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:$1 --no-autoupdate --edge-ip-version auto --protocol auto --logfile /var/log/cloudflared.log
ExecStartPost=/usr/local/bin/cloudflared-post-start.sh
Restart=on-failure
RestartSec=10
TimeoutStartSec=90
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/cloudflared.log /etc/sing-box
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM
[Install]
WantedBy=multi-user.target
UNIT
}
