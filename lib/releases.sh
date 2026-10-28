#!/bin/bash
# Shared by both entry points. Keep downloads separate from service activation.

install_base() {
    local command missing=0
    for command in curl jq openssl tar sha256sum flock; do
        command -v "$command" >/dev/null 2>&1 || missing=1
    done
    if [ "$missing" -eq 1 ]; then
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y curl jq openssl tar coreutils util-linux ca-certificates || return 1
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl jq openssl tar coreutils util-linux ca-certificates || return 1
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl jq openssl tar coreutils util-linux ca-certificates || return 1
        else
            echo "错误: 请先安装 curl、jq、openssl、tar、coreutils、util-linux 和 CA 证书" >&2
            return 1
        fi
    fi
    for command in curl jq openssl tar sha256sum flock; do
        command -v "$command" >/dev/null 2>&1 || return 1
    done
}

set_secure_permissions() {
    local file
    chmod 755 /etc/sing-box || return 1
    chown singbox:singbox /etc/sing-box/config.json || return 1
    chmod 600 /etc/sing-box/config.json || return 1
    if [ -d /etc/sing-box/certs ]; then
        chown singbox:singbox /etc/sing-box/certs || return 1
        chmod 700 /etc/sing-box/certs || return 1
        for file in /etc/sing-box/certs/cert.pem /etc/sing-box/certs/private.key; do
            if [ -f "$file" ]; then chown singbox:singbox "$file" && chmod 600 "$file" || return 1; fi
        done
    fi
    if [ -f /etc/sing-box/public.key.b64 ]; then chmod 600 /etc/sing-box/public.key.b64 || return 1; fi
    if [ -f /etc/sing-box/client.json ]; then chmod 600 /etc/sing-box/client.json || return 1; fi
}

fetch_binary() (
    set -e
    # Subshell variables deliberately are not local: Bash 3 can unwind locals
    # before running an EXIT trap after an explicit exit.
    component="$1" destination="$2" arch="" repo="" tag="" version="" asset="" member="" url="" digest="" actual="" work=""
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l) arch=armv7 ;;
        *) echo "错误: 不支持的架构 $(uname -m)" >&2; exit 1 ;;
    esac
    case "$component" in
        sing-box) repo=SagerNet/sing-box ;;
        cloudflared) repo=cloudflare/cloudflared ;;
        caddy) repo=caddyserver/caddy ;;
        *) echo "错误: 未知组件 $component" >&2; exit 1 ;;
    esac
    work=$(mktemp -d) || exit 1
    trap 'rm -rf "$work"' EXIT
    curl -fLSs --retry 3 --connect-timeout 15 --max-time 120 \
        "https://api.github.com/repos/$repo/releases/latest" -o "$work/release.json" || exit 1
    tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string")' "$work/release.json") || exit 1
    [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "错误: 无效的稳定版版本号 $tag" >&2; exit 1; }
    version=${tag#v}
    case "$component" in
        sing-box)
            asset="sing-box-$version-linux-$arch.tar.gz"
            member="sing-box-$version-linux-$arch/sing-box"
            ;;
        caddy) asset="caddy_${version}_linux_${arch}.tar.gz"; member=caddy ;;
        cloudflared)
            [ "$arch" != armv7 ] || arch=arm
            asset="cloudflared-linux-$arch"
            ;;
    esac
    url=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' "$work/release.json") || exit 1
    [ "$url" = "https://github.com/$repo/releases/download/$tag/$asset" ] || { echo "错误: 发布文件地址不匹配" >&2; exit 1; }
    digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest | select(type == "string")' "$work/release.json") || exit 1
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo "错误: 发布文件缺少有效 SHA256，取消下载" >&2; exit 1; }
    echo "下载 $component 稳定版 $tag ($arch)..." >&2
    curl -fLSs --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$work/package" || exit 1
    actual=$(sha256sum "$work/package") || exit 1
    [ "${actual%% *}" = "${digest#sha256:}" ] || { echo "错误: $component SHA256 校验失败" >&2; exit 1; }
    if [ "$component" = cloudflared ]; then
        cp "$work/package" "$destination" || exit 1
    else
        # Extract only the expected executable, never arbitrary archive paths.
        tar -xzOf "$work/package" "$member" > "$destination" || exit 1
    fi
    chmod 755 "$destination" || exit 1
    case "$component" in
        cloudflared) "$destination" --version ;;
        *) "$destination" version ;;
    esac
)

download_component() (
    set -e
    component="$1" staged=""
    mkdir -p /usr/local/bin || exit 1
    staged=$(mktemp "/usr/local/bin/.$component.XXXXXX") || exit 1
    trap 'rm -f "$staged"' EXIT
    fetch_binary "$component" "$staged" || exit 1
    chown root:root "$staged" || exit 1
    mv -f "$staged" "/usr/local/bin/$component"
)

download_singbox() { download_component sing-box; }
download_sing_box() { download_component sing-box; }
download_cloudflared() { download_component cloudflared; }
download_caddy() { download_component caddy; }

# A failed check never replaces the installed binary/configuration. A failed
# restart restores all files touched by this component's update.
update_component() (
    set -e
    umask 077
    component="$1" work="" backup="" config="" unit="" was_active=0 activated=0
    work=$(mktemp -d)
    finish_update() {
        local result=$?
        trap - EXIT
        if [ "$activated" -eq 1 ] && [ "$result" -ne 0 ]; then
            echo "错误: $component 升级失败，恢复升级前文件 ($backup)" >&2
            cp -p "$backup/binary" "/usr/local/bin/.$component.restore" &&
                mv -f "/usr/local/bin/.$component.restore" "/usr/local/bin/$component"
            [ -z "$config" ] || cp -p "$backup/config" "$config"
            [ ! -f "$backup/unit" ] || cp -p "$backup/unit" "$unit"
            [ ! -f "$backup/helper" ] || cp -p "$backup/helper" /usr/local/bin/cloudflared-post-start.sh
            systemctl daemon-reload
            if [ "$was_active" -eq 1 ]; then
                systemctl restart "$component" || echo "错误: 旧服务恢复启动失败，请检查 journalctl -u $component" >&2
            else
                systemctl stop "$component" || true
            fi
        fi
        rm -rf "$work"
        exit "$result"
    }
    trap finish_update EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    fetch_binary "$component" "$work/$component"
    unit="/etc/systemd/system/$component.service"
    case "$component" in
        sing-box)
            config=/etc/sing-box/config.json
            jq -f "$SCRIPT_DIR/lib/migrate-server.jq" "$config" > "$work/config"
            "$work/$component" check -c "$work/config"
            ;;
        caddy)
            "$work/$component" validate --config /etc/caddy/Caddyfile --adapter caddyfile
            ;;
        cloudflared)
            # Existing installations must also stop using the removed h2mux.
            sed -e 's/--protocol h2mux/--protocol auto/g' \
                -e 's@ExecStartPre=/bin/sleep 3@ExecStartPre=/bin/sh -c '\''truncate -s 0 /var/log/cloudflared.log; rm -f /etc/sing-box/argo.txt.b64'\''@' \
                "$unit" > "$work/unit"
            ;;
    esac
    mkdir -p /var/backups/fkgfw
    backup=$(mktemp -d "/var/backups/fkgfw/$component.XXXXXX")
    cp -p "/usr/local/bin/$component" "$backup/binary"
    [ -z "$config" ] || cp -p "$config" "$backup/config"
    [ ! -f "$work/unit" ] || cp -p "$unit" "$backup/unit"
    if [ "$component" = cloudflared ]; then
        cp -p /usr/local/bin/cloudflared-post-start.sh "$backup/helper"
    fi
    systemctl is-active --quiet "$component" && was_active=1
    echo "升级备份: $backup"
    activated=1
    # Move on the target filesystem, so readers see either complete version.
    install -o root -g root -m 755 "$work/$component" "/usr/local/bin/.$component.new"
    mv -f "/usr/local/bin/.$component.new" "/usr/local/bin/$component"
    if [ -n "$config" ]; then
        install -o singbox -g singbox -m 600 "$work/config" "$config.new"
        mv -f "$config.new" "$config"
    fi
    if [ -f "$work/unit" ]; then
        install -o root -g root -m 644 "$work/unit" "$unit"
        install -o root -g root -m 755 "$SCRIPT_DIR/lib/cloudflared-post-start.sh" /usr/local/bin/cloudflared-post-start.sh
    fi
    if systemctl daemon-reload && systemctl restart "$component" && sleep 2 && systemctl is-active --quiet "$component"; then
        echo "✓ $component 升级成功"
    else
        exit 1
    fi
)

# The original basic installer stored service files under /root, which is
# inaccessible to User=singbox + ProtectHome=true. Keep those originals intact.
migrate_legacy_install() (
    set -e
    [ ! -f /var/backups/fkgfw/legacy-migrated ] || exit 0
    [ -f /root/sbconfig_server.json ] && [ ! -f /etc/sing-box/config.json ] || exit 0
    work="" backup="" activated=0 was_active=0
    work=$(mktemp -d)
    mkdir -p /var/backups/fkgfw
    backup=$(mktemp -d /var/backups/fkgfw/legacy.XXXXXX)
    cp -p /etc/systemd/system/sing-box.service "$backup/unit"
    if [ -f /usr/local/bin/sing-box ]; then cp -p /usr/local/bin/sing-box "$backup/binary"; fi
    finish_migration() {
        local result=$?
        trap - EXIT
        if [ "$result" -ne 0 ] && [ "$activated" -eq 1 ]; then
            cp -p "$backup/unit" /etc/systemd/system/sing-box.service
            rm -f /etc/sing-box/config.json
            if [ -f "$backup/binary" ]; then
                cp -p "$backup/binary" /usr/local/bin/.sing-box.restore && mv -f /usr/local/bin/.sing-box.restore /usr/local/bin/sing-box
            else
                rm -f /usr/local/bin/sing-box
            fi
            systemctl daemon-reload
            if [ "$was_active" -eq 1 ]; then systemctl restart sing-box; else systemctl stop sing-box; fi
            echo "旧版迁移失败，原始文件仍保留在 /root，服务备份: $backup" >&2
        fi
        rm -rf "$work"
        exit "$result"
    }
    trap finish_migration EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    echo "迁移旧版 /root 安装，保留原始文件..."
    fetch_binary sing-box "$work/sing-box"
    install -d -m 755 /etc/sing-box /usr/local/bin
    install -d -o singbox -g singbox -m 700 /etc/sing-box/certs
    install -o singbox -g singbox -m 600 /root/self-cert/cert.pem /etc/sing-box/certs/cert.pem
    install -o singbox -g singbox -m 600 /root/self-cert/private.key /etc/sing-box/certs/private.key
    install -o root -g root -m 600 /root/public.key.b64 /etc/sing-box/public.key.b64
    jq -f "$SCRIPT_DIR/lib/migrate-server.jq" /root/sbconfig_server.json |
        jq 'walk(if type == "string" then sub("^/root/self-cert/"; "/etc/sing-box/certs/") else . end)' > "$work/config"
    "$work/sing-box" check -c "$work/config"
    systemctl is-active --quiet sing-box && was_active=1
    activated=1
    install -o root -g root -m 755 "$work/sing-box" /usr/local/bin/.sing-box.new
    mv -f /usr/local/bin/.sing-box.new /usr/local/bin/sing-box
    install -o singbox -g singbox -m 600 "$work/config" /etc/sing-box/config.json
    write_singbox_service
    systemctl daemon-reload
    systemctl restart sing-box
    sleep 2
    systemctl is-active --quiet sing-box
    printf '%s\n' "$backup" > /var/backups/fkgfw/legacy-migrated
    echo "✓ 旧版迁移完成，原服务备份: $backup"
)

write_singbox_service() {
    cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=singbox
Group=singbox
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
UNIT
}

render_client_config() {
    local config="$1" server_ip="$2" public_key="" certificate_name="" certificate_path argo=""
    if jq -e 'any(.inbounds[]?; .tag == "vless-in")' "$config" >/dev/null; then
        public_key=$(base64 --decode /etc/sing-box/public.key.b64) || return 1
    fi
    if jq -e 'any(.inbounds[]?; .tag == "hy2-in")' "$config" >/dev/null; then
        certificate_path=$(jq -er '.inbounds[] | select(.tag == "hy2-in") | .tls.certificate_path' "$config") || return 1
        certificate_name=$(openssl x509 -in "$certificate_path" -noout -subject -nameopt RFC2253 | sed 's/.*CN=//') || return 1
    fi
    if jq -e 'any(.inbounds[]?; .tag == "vmess-in" or .tag == "vless-ws-in")' "$config" >/dev/null; then
        argo=$(base64 --decode /etc/sing-box/argo.txt.b64) || return 1
    fi
    jq --arg server_ip "$server_ip" --arg public_key "$public_key" \
        --arg certificate_name "$certificate_name" --arg argo "$argo" \
        -f "$SCRIPT_DIR/lib/client.jq" "$config"
}
