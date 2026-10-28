#!/bin/bash
source "$SCRIPT_DIR/lib/releases.sh" || return 1
source "$SCRIPT_DIR/lib/protocols.sh" || return 1

create_singbox_user() {
    id -u singbox >/dev/null 2>&1 || useradd -r -s /sbin/nologin -M singbox
}

server_address() {
    local value="${SERVER_ADDRESS:-}"
    if [ -z "$value" ]; then
        value=$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org) ||
            value=$(curl -6fsS --connect-timeout 5 --max-time 8 https://api.ipify.org) || return 1
    fi
    [[ "$value" =~ ^[a-zA-Z0-9:._-]+$ ]] || { echo '错误: 无效服务器地址，请设置 SERVER_ADDRESS。' >&2; return 1; }
    printf '%s\n' "$value"
}

export_clients() (
    set -e
    export_address="${1:-}"
    if has_protocol /etc/sing-box/config.json vless-in || has_protocol /etc/sing-box/config.json hy2-in; then
        [ -n "$export_address" ] || export_address=$(server_address)
    fi
    export_stage=$(mktemp -d /etc/sing-box/.export.XXXXXX)
    trap 'rm -rf "$export_stage"' EXIT
    render_client_config /etc/sing-box/config.json "$export_address" > "$export_stage/client.json"
    jq -f "$SCRIPT_DIR/lib/clash.jq" "$export_stage/client.json" > "$export_stage/clash.json"
    chmod 600 "$export_stage/client.json" "$export_stage/clash.json"
    mv -f "$export_stage/client.json" /etc/sing-box/client.json
    mv -f "$export_stage/clash.json" /etc/sing-box/clash.json
)

show_configuration() (
    set -e
    if [ "${1:-}" != cached ]; then export_clients; fi
    echo '协议分享链接：'
    jq -r -f "$SCRIPT_DIR/lib/links.jq" /etc/sing-box/client.json
    echo 'sing-box 客户端配置（/etc/sing-box/client.json）：'
    cat /etc/sing-box/client.json
    echo 'Mihomo 客户端配置（/etc/sing-box/clash.json）：'
    cat /etc/sing-box/clash.json
)

# This transaction owns only the project's configs, services and binaries.
# Snapshot before publishing; restore active/enabled states on any failure.
configure_protocols() (
    set -e
    umask 077
    selected="$1" edit_tag="${2:-}" stage="" backup="" activated=0 cloud_touched=0
    stage=$(mktemp -d)
    affected_services=(sing-box)
    snapshot_paths=(/etc/sing-box /etc/systemd/system/sing-box.service)
    finish_configuration() {
        result=$?
        trap - EXIT
        set +e
        if [ "$activated" -eq 1 ] && [ "$result" -ne 0 ]; then
            echo "错误: 配置应用失败，恢复备份 $backup" >&2
            for service in "${affected_services[@]}"; do
                if [ "$service" != cloudflared ] || [ "$cloud_touched" -eq 1 ]; then systemctl stop "$service" >/dev/null 2>&1; fi
            done
            for item in "${snapshot_paths[@]}"; do
                rm -rf "$item"
                if [ -e "$backup/files$item" ]; then
                    mkdir -p "$(dirname "$item")"
                    cp -a "$backup/files$item" "$item" || echo "错误: 恢复 $item 失败，请从 $backup 手动恢复。" >&2
                fi
            done
            systemctl daemon-reload
            for service in "${affected_services[@]}"; do
                if [ -f "$backup/$service.enabled" ]; then systemctl enable "$service" >/dev/null 2>&1
                else systemctl disable "$service" >/dev/null 2>&1; fi
                if [ -f "$backup/$service.active" ]; then
                    systemctl start "$service" || echo "错误: 恢复 $service 启动失败，请检查日志。" >&2
                fi
            done
        fi
        rm -rf "$stage"
        exit "$result"
    }
    trap finish_configuration EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    mkdir -p "$stage/bin"
    if [ -f /etc/sing-box/config.json ]; then
        jq -f "$SCRIPT_DIR/lib/migrate-server.jq" /etc/sing-box/config.json > "$stage/original.json"
    else
        printf '%s\n' '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$stage/original.json"
    fi
    binary=/usr/local/bin/sing-box
    if [ ! -x "$binary" ] || [ ! -f /etc/sing-box/config.json ]; then
        binary="$stage/bin/sing-box"
        fetch_binary sing-box "$binary"
    fi
    echo '保留仍选中协议的配置；仅新增协议需要填写参数。'
    printf '[]\n' > "$stage/additions.json"
    for tag in $(jq -r '.[]' <<< "$selected"); do
        if ! has_protocol "$stage/original.json" "$tag" || [ "$tag" = "$edit_tag" ]; then
            collect_inbound "$tag" "$stage/original.json" "$stage" "$binary" > "$stage/inbound.json"
            if [ "$tag" = "$edit_tag" ]; then
                jq --arg tag "$tag" --slurpfile inbound "$stage/inbound.json" '.inbounds |= map(if .tag == $tag then $inbound[0] else . end)' "$stage/original.json" > "$stage/edited.json"
                mv "$stage/edited.json" "$stage/original.json"
            else
                jq --slurpfile inbound "$stage/inbound.json" '. + $inbound' "$stage/additions.json" > "$stage/added.json"
                mv "$stage/added.json" "$stage/additions.json"
            fi
        fi
    done
    jq --argjson selected "$selected" --argjson additions "$(cat "$stage/additions.json")" \
        -f "$SCRIPT_DIR/lib/server.jq" "$stage/original.json" > "$stage/config.json"
    old_ws=0; new_ws=0
    has_ws "$stage/original.json" && old_ws=1
    has_ws "$stage/config.json" && new_ws=1
    caddy_port=28080
    if [ -f /etc/caddy/Caddyfile ]; then
        stored_port=$(sed -nE 's/^[[:space:]]*:([0-9]+)[[:space:]]*\{.*/\1/p' /etc/caddy/Caddyfile)
        if [[ "$stored_port" =~ ^[0-9]{1,5}$ ]]; then caddy_port="$stored_port"; fi
    fi
    if [ "$new_ws" -eq 1 ] && [ "$old_ws" -eq 0 ]; then
        caddy_port=$(prompt_port 'Caddy 本地反代' "$caddy_port")
    fi
    validate_listeners "$stage/config.json" "$caddy_port"
    if [ "$new_ws" -eq 1 ]; then
        for component in caddy cloudflared; do
            if [ ! -x "/usr/local/bin/$component" ] || [ ! -f /etc/sing-box/config.json ]; then
                fetch_binary "$component" "$stage/bin/$component"
            fi
        done
        render_caddy_config "$stage/config.json" "$caddy_port" > "$stage/Caddyfile"
        caddy_binary=/usr/local/bin/caddy
        [ ! -x "$stage/bin/caddy" ] || caddy_binary="$stage/bin/caddy"
        "$caddy_binary" validate --config "$stage/Caddyfile" --adapter caddyfile
        write_caddy_service > "$stage/caddy.service"
        write_cloudflared_service "$caddy_port" > "$stage/cloudflared.service"
    fi
    # Check new certificates at their staging paths before installing them.
    jq --arg cert "$stage/certs/cert.pem" --arg key "$stage/certs/private.key" \
        --argjson generated "$([ -f "$stage/certs/cert.pem" ] && echo true || echo false)" \
        '.inbounds |= map(if .tag == "hy2-in" and $generated then .tls.certificate_path = $cert | .tls.key_path = $key else . end)' \
        "$stage/config.json" > "$stage/check.json"
    "$binary" check -c "$stage/check.json"
    public_address=""
    if has_protocol "$stage/config.json" vless-in || has_protocol "$stage/config.json" hy2-in; then
        public_address=$(server_address)
    fi
    if [ "$old_ws" -eq 1 ] || [ "$new_ws" -eq 1 ]; then
        # Refuse to take over unrelated services using the same names.
        for component in caddy cloudflared; do
            unit="/etc/systemd/system/$component.service"
            if [ -f "$unit" ] && ! grep -qE '^Description=(Caddy Local Reverse Proxy|Cloudflared Tunnel)$' "$unit"; then
                echo "错误: $unit 不属于本项目，请先处理服务名称冲突。" >&2
                exit 1
            fi
        done
        affected_services+=(caddy cloudflared)
        snapshot_paths+=(/etc/caddy /etc/systemd/system/caddy.service /etc/systemd/system/cloudflared.service /usr/local/bin/cloudflared-post-start.sh)
    fi
    for component in sing-box caddy cloudflared; do
        [ ! -f "$stage/bin/$component" ] || snapshot_paths+=("/usr/local/bin/$component")
    done
    mkdir -p /var/backups/fkgfw
    backup=$(mktemp -d /var/backups/fkgfw/protocols.XXXXXX)
    for item in "${snapshot_paths[@]}"; do
        if [ -e "$item" ]; then
            mkdir -p "$backup/files$(dirname "$item")"
            cp -a "$item" "$backup/files$item"
        fi
    done
    for service in "${affected_services[@]}"; do
        if systemctl is-active --quiet "$service"; then touch "$backup/$service.active"; fi
        if systemctl is-enabled --quiet "$service"; then touch "$backup/$service.enabled"; fi
    done
    echo "配置备份: $backup"
    activated=1
    create_singbox_user
    install -d -m 755 /etc/sing-box /usr/local/bin
    for component in sing-box caddy cloudflared; do
        if [ -f "$stage/bin/$component" ]; then
            install -o root -g root -m 755 "$stage/bin/$component" "/usr/local/bin/.$component.new"
            mv -f "/usr/local/bin/.$component.new" "/usr/local/bin/$component"
        fi
    done
    if [ -f "$stage/public.key.b64" ]; then
        install -o root -g root -m 600 "$stage/public.key.b64" /etc/sing-box/public.key.b64
    fi
    if [ -d "$stage/certs" ]; then
        install -d -o singbox -g singbox -m 700 /etc/sing-box/certs
        install -o singbox -g singbox -m 600 "$stage/certs/cert.pem" /etc/sing-box/certs/cert.pem
        install -o singbox -g singbox -m 600 "$stage/certs/private.key" /etc/sing-box/certs/private.key
    fi
    install -o singbox -g singbox -m 600 "$stage/config.json" /etc/sing-box/config.json.new
    mv -f /etc/sing-box/config.json.new /etc/sing-box/config.json
    set_secure_permissions
    if [ ! -f /etc/systemd/system/sing-box.service ]; then write_singbox_service; fi
    if [ "$new_ws" -eq 1 ]; then
        install -d -m 755 /etc/caddy
        install -m 644 "$stage/Caddyfile" /etc/caddy/Caddyfile
        install -m 644 "$stage/caddy.service" /etc/systemd/system/caddy.service
        install -m 644 "$stage/cloudflared.service" /etc/systemd/system/cloudflared.service
        install -o root -g root -m 755 "$SCRIPT_DIR/lib/cloudflared-post-start.sh" /usr/local/bin/cloudflared-post-start.sh
        touch /var/log/cloudflared.log
        chown singbox:singbox /var/log/cloudflared.log /etc/sing-box
        chmod 600 /var/log/cloudflared.log
    fi
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null
    systemctl restart sing-box
    if [ "$new_ws" -eq 1 ]; then
        systemctl enable caddy cloudflared >/dev/null
        systemctl restart caddy
        # Changing only backend routes does not require a new tunnel hostname.
        if [ "$old_ws" -eq 0 ] || ! systemctl is-active --quiet cloudflared; then
            cloud_touched=1
            systemctl restart cloudflared
        fi
    elif [ "$old_ws" -eq 1 ]; then
        cloud_touched=1
        systemctl stop cloudflared caddy
        systemctl disable cloudflared caddy >/dev/null
    fi
    sleep 2
    systemctl is-active --quiet sing-box
    if [ "$new_ws" -eq 1 ]; then
        systemctl is-active --quiet caddy
        systemctl is-active --quiet cloudflared
    fi
    export_clients "$public_address"
    echo '✓ 协议组合已应用，客户端配置已更新。'
)

update_selected_components() (
    set -e
    update_component sing-box
    if has_ws /etc/sing-box/config.json; then
        update_component caddy
        update_component cloudflared
    fi
    show_configuration
)

uninstall_managed() {
    local confirm component
    read -r -p '卸载本项目服务与配置？输入 yes 确认: ' confirm || return 1
    [ "$confirm" = yes ] || return 0
    for component in cloudflared caddy; do
        if [ -f "/etc/systemd/system/$component.service" ] && grep -qE '^Description=(Caddy Local Reverse Proxy|Cloudflared Tunnel)$' "/etc/systemd/system/$component.service"; then
            systemctl stop "$component" || return 1
            systemctl disable "$component" >/dev/null || return 1
            rm -f "/etc/systemd/system/$component.service" "/usr/local/bin/$component"
            if [ "$component" = caddy ]; then rm -f /etc/caddy/Caddyfile; fi
            if [ "$component" = cloudflared ]; then rm -f /var/log/cloudflared.log; fi
        fi
    done
    systemctl stop sing-box || return 1
    systemctl disable sing-box >/dev/null || return 1
    rm -f /etc/systemd/system/sing-box.service /usr/local/bin/sing-box /usr/local/bin/cloudflared-post-start.sh
    rm -rf /etc/sing-box
    systemctl daemon-reload
    echo '卸载完成。升级备份和旧 /root 原始文件保留。'
}

installer_main() {
    local preset="$1" choice selected tag
    if [ "$EUID" -ne 0 ] || [ "$(uname -s)" != Linux ]; then
        echo '错误: 请在 Linux 服务器上以 root 权限运行。' >&2
        return 1
    fi
    command -v systemctl >/dev/null || { echo '错误: 需要 systemd。' >&2; return 1; }
    install_base || return 1
    mkdir -p /run/lock || return 1
    exec 9>/run/lock/fkgfw.lock
    flock -n 9 || { echo '另一个安装/管理进程正在运行。' >&2; return 1; }
    if [ -f /root/sbconfig_server.json ] && [ ! -f /etc/sing-box/config.json ]; then
        create_singbox_user || return 1
        migrate_legacy_install
        [ "$?" -eq 0 ] || return 1
    fi
    if [ ! -f /etc/sing-box/config.json ]; then
        selected=$(choose_protocols "$preset") || return 1
        configure_protocols "$selected"
        [ "$?" -eq 0 ] || return 1
        show_configuration cached
        return
    fi
    if [ ! -x /usr/local/bin/sing-box ] || [ ! -f /etc/systemd/system/sing-box.service ]; then
        echo '错误: 已有安装不完整，请恢复程序或服务文件；现有配置已保留。' >&2
        return 1
    fi
    echo '当前协议：'
    jq -r '.inbounds[].tag' /etc/sing-box/config.json | while read -r tag; do protocol_name "$tag"; done
    echo '1. 调整协议组合（保留仍选中协议的配置）'
    echo '2. 修改已安装协议的端口 / SNI / WS 路径'
    echo '3. 显示客户端配置与分享链接'
    echo '4. 卸载'
    echo '5. 更新所选协议使用的服务端程序'
    if has_ws /etc/sing-box/config.json; then echo '6. 重启 Cloudflare Tunnel 并显示新链接'; fi
    read -r -p '选择操作: ' choice || return 1
    case "$choice" in
        1)
            selected=$(choose_protocols "$preset") || return 1
            configure_protocols "$selected"
            [ "$?" -eq 0 ] || return 1
            show_configuration cached
            ;;
        2)
            echo '1=Reality  2=Hysteria2  3=VMess WS  4=VLESS WS'
            read -r -p '选择一个已安装协议: ' choice || return 1
            tag=$(normalize_selection "$choice" | jq -er 'select(length == 1) | .[0]') || return 1
            has_protocol /etc/sing-box/config.json "$tag" || { echo '该协议未安装。' >&2; return 1; }
            selected=$(jq -c '[.inbounds[].tag | select(. == "vless-in" or . == "hy2-in" or . == "vmess-in" or . == "vless-ws-in")]' /etc/sing-box/config.json)
            configure_protocols "$selected" "$tag"
            [ "$?" -eq 0 ] || return 1
            show_configuration cached
            ;;
        3) show_configuration ;;
        4) uninstall_managed ;;
        5) update_selected_components ;;
        6)
            has_ws /etc/sing-box/config.json || { echo '未安装 WebSocket 协议，无需启动 Tunnel。' >&2; return 1; }
            systemctl restart cloudflared || return 1
            show_configuration
            ;;
        *) echo '无效选项。' >&2; return 1 ;;
    esac
}
