#!/bin/bash
# Invoked by installer_main while holding the shared fkgfw lock.
set -euo pipefail
umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
source "$SCRIPT_DIR/lib/installer.sh"

cfg=/etc/fkgfw-dsvpn
store=/opt/fkgfw-dsvpn
runtime=/run/fkgfw-dsvpn
units=/etc/systemd/system
tunnel=fkgfw-dsvpn-tunnel
services=(fkgfw-dsvpn fkgfw-dsvpn-download "$tunnel")
marker='# Managed by fkgfw (DSVPN)'
fail() { echo "DSVPN: $*" >&2; exit 1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
setting() { sed -n "s/^$1=//p" "$cfg/server.env"; }

check_ownership() {
    local name unit state fragment dropins path
    if exists "$cfg"; then
        [[ -d "$cfg" && ! -L "$cfg" && $(stat -c '%u:%a' "$cfg") == 0:700 ]] &&
            [[ -f "$cfg/server.env" && ! -L "$cfg/server.env" ]] &&
            grep -Fxq "$marker" "$cfg/server.env" || fail "配置目录归属不明：$cfg"
        [[ -f "$cfg/vpn.key" && ! -L "$cfg/vpn.key" &&
            $(stat -c '%u:%a:%s' "$cfg/vpn.key") == 0:600:32 ]] || fail '已有密钥的类型、权限或长度不正确。'
    fi
    for name in "${services[@]}"; do
        unit="$units/$name.service"
        state=$(systemctl show "$name.service" -p FragmentPath -p DropInPaths)
        fragment=$(sed -n 's/^FragmentPath=//p' <<< "$state")
        dropins=$(sed -n 's/^DropInPaths=//p' <<< "$state")
        [[ -z "$fragment" || "$fragment" == "$unit" ]] || fail "检测到其他 $name 单元。"
        # Global service.d policy applies to every unit, including new services.
        for path in $dropins; do
            case "$path" in */systemd/system/service.d/*.conf) ;; *) fail "检测到 $name 专用 drop-in：$path" ;; esac
        done
        if exists "$unit"; then
            [[ -f "$unit" && ! -L "$unit" && -d "$cfg" ]] &&
                grep -Fxq "$marker" "$unit" || fail "服务文件归属不明：$unit"
        fi
    done
}

tunnel_url() {
    local pid endpoint hostname
    pid=$(systemctl show "$tunnel.service" -p MainPID --value) || return 1
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    # Each connector opens its own loopback metrics socket on an ephemeral port.
    endpoint=$(ss -H -ltnp | awk -v token="pid=$pid," '$4 ~ /^127\.0\.0\.1:[0-9]+$/ && index($0,token) { print $4 }') || return 1
    [[ "$endpoint" =~ ^127\.0\.0\.1:[0-9]+$ ]] || return 1
    curl -fsS --noproxy '*' --max-time 2 "http://$endpoint/ready" >/dev/null 2>&1 || return 1
    hostname=$(curl -fsS --noproxy '*' --max-time 2 "http://$endpoint/quicktunnel" 2>/dev/null | jq -er '.hostname | strings') || return 1
    hostname=${hostname#https://}
    [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.trycloudflare\.com$ ]] || return 1
    printf 'https://%s\n' "$hostname"
}

show_clients() {
    local host port download bundle manifest hash path base='' attempts=${1:-1} i
    host=$(setting SERVER_HOST); port=$(setting VPN_PORT); download=$(setting DOWNLOAD_PORT)
    echo "DSVPN 优先使用 TCP，连不上时自动尝试 KCP。请放行 VPN ${port}/TCP 和 ${port}/UDP。"
    echo "客户端下载通过 Cloudflare HTTPS 提供。源站端口 127.0.0.1:$download 仅供本机使用。"
    if ! systemctl is-active --quiet fkgfw-dsvpn ||
            ! manifest=$(realpath -e "$runtime/release/clients/SHA256SUMS" 2>/dev/null) ||
            ! bundle=$(sha256sum < "$manifest"); then
        echo 'VPN 服务尚未就绪，可用 journalctl -u fkgfw-dsvpn 排查。'
    elif ! curl -fsS --noproxy '*' --max-time 3 "http://127.0.0.1:$download/${bundle%% *}/SHA256SUMS" 2>/dev/null |
            cmp -s - "$manifest"; then
        echo '下载源站尚未就绪，可用 journalctl -u fkgfw-dsvpn-download 排查。'
    else
        for ((i=1; i<=attempts; i++)); do
            if base=$(tunnel_url); then break; fi
            if (( i < attempts )); then sleep 1; fi
        done
        if [ -z "$base" ]; then
            echo "下载隧道尚未就绪。稍后在菜单 1 查看链接，可用 journalctl -u $tunnel 排查。"
        else
            echo '新域名可能需要片刻才能访问。下载隧道重启后，可在菜单 1 查看当前链接。'
        fi
    fi
    if [ -n "$base" ]; then
        echo '通过可信渠道核对下列 SHA-256，校验通过后再运行客户端。'
        while read -r hash path; do
            printf '%-12s %s/%s/%s  SHA-256 %s\n' "${path%/dsvpn}" "$base" "${bundle%% *}" "$path" "$hash"
        done < "$manifest"
    fi
    echo
    echo '连接前还需要 vpn.key。客户端和服务端必须使用同一份密钥才能完成认证。'
    echo "管理员请从服务器取出 $cfg/vpn.key，通过 SFTP 等保密渠道单独交给获准连接的用户。"
    echo '这份密钥可用于冒充任一端，请勿放入公开下载目录。'
    echo '客户端收到 vpn.key 后，在该文件所在目录执行：'
    echo '  sudo install -d -m 700 /etc/dsvpn'
    echo '  sudo install -o root -m 600 ./vpn.key /etc/dsvpn/vpn.key'
    printf '客户端启动命令：sudo ./dsvpn client /etc/dsvpn/vpn.key %s %s\n' "$host" "$port"
}

check_port() {
    local port=$1 protocol=$2 sockets pid name
    if [ "$protocol" = UDP ]; then sockets=$(ss -H -uanp "sport = :$port")
    else sockets=$(ss -H -ltnp "sport = :$port"); fi
    [ -n "$sockets" ] || return 0
    for name in "${services[@]}"; do
        pid=$(systemctl show "$name.service" -p MainPID --value)
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
            sockets=$(awk -v token="pid=$pid," 'index($0,token)==0' <<< "$sockets")
        fi
    done
    [ -z "$sockets" ] || fail "$protocol $port 已被其他进程使用。"
}

read_settings() {
    local old_host='' default_vpn=1959 default_download=1960
    if [ -f "$cfg/server.env" ]; then
        old_host=$(setting SERVER_HOST); default_vpn=$(setting VPN_PORT); default_download=$(setting DOWNLOAD_PORT)
    fi
    old_host=${SERVER_ADDRESS:-$old_host}
    if [ -z "$old_host" ]; then old_host=$(server_address) || old_host=''; fi
    read -r -p "客户端访问此服务器的域名或 IP [$old_host]: " host
    host=${host:-$old_host}
    vpn=$(prompt_port DSVPN "$default_vpn")
    download=$(prompt_port 'DSVPN 下载源站（仅本机）' "$default_download")
    [[ "$host" =~ ^[[:alnum:]][[:alnum:].-]*$ || "$host" =~ ^[[:xdigit:]:]+:[[:xdigit:].:]*$ ]] || fail '请输入有效公网域名或 IP。'
    [[ "$vpn" =~ ^[1-9][0-9]{0,4}$ && "$download" =~ ^[1-9][0-9]{0,4}$ &&
        "$vpn" -le 65535 && "$download" -le 65535 && "$vpn" != "$download" ]] || fail 'VPN 和下载必须使用两个不同的有效 TCP 端口。'
    check_port "$vpn" TCP; check_port "$download" TCP
    check_port "$vpn" UDP
    if [ -f /etc/sing-box/config.json ]; then
        local caddy_port=28080
        if [ -f /etc/caddy/Caddyfile ]; then
            caddy_port=$(sed -nE 's/^[[:space:]]*:([0-9]+)[[:space:]]*\{.*/\1/p' /etc/caddy/Caddyfile)
            caddy_port=${caddy_port:-28080}
        fi
        validate_listeners /etc/sing-box/config.json "$caddy_port" "$(dsvpn_listeners "$vpn" "$download")"
    fi
}

check_prerequisites() {
    [ -c /dev/net/tun ] || fail '需要 Linux TUN 设备 /dev/net/tun。'
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || fail '请先以管理员身份开启 net.ipv4.ip_forward=1，再运行安装。'
    if ! command -v iptables >/dev/null; then
        if command -v apt-get >/dev/null; then apt-get update && apt-get install -y iptables
        elif command -v dnf >/dev/null; then dnf install -y iptables
        elif command -v yum >/dev/null; then yum install -y iptables
        else fail '请安装 iptables。'; fi
    fi
    command -v ip >/dev/null && command -v iptables >/dev/null || fail '需要 iproute2 和 iptables。'
}

snapshot() {
    local path name
    for path in "${paths[@]}"; do
        if exists "$path"; then mkdir -p "$work/old$(dirname "$path")"; cp -a "$path" "$work/old$path"; fi
    done
    for name in "${services[@]}"; do
        if systemctl is-active --quiet "$name"; then touch "$work/$name.active"; fi
        if systemctl is-enabled --quiet "$name" 2>/dev/null; then touch "$work/$name.enabled"; fi
    done
}

finish() {
    local rc=$? name path failed=0
    trap - EXIT INT TERM
    set +e
    if [ "$changed" = 1 ] && [ "$rc" -ne 0 ]; then
        echo '部署失败，正在恢复 DSVPN 配置、密钥及服务状态。' >&2
        for name in "${services[@]}"; do
            if [ -f "$units/$name.service" ]; then systemctl disable --now "$name" >/dev/null 2>&1; fi
        done
        for path in "${paths[@]}"; do
            rm -rf -- "$path" || failed=1
            if exists "$work/old$path"; then cp -a "$work/old$path" "$path" || failed=1; fi
        done
        systemctl daemon-reload || failed=1
        for name in "${services[@]}"; do
            if [ -f "$work/$name.enabled" ]; then systemctl enable "$name" || failed=1; fi
            if [ -f "$work/$name.active" ]; then systemctl start "$name" || failed=1; fi
        done
    fi
    if [ "$failed" = 1 ]; then echo "恢复未完成，私有备份保留在 $work/old" >&2
    else rm -rf -- "$work"; fi
    exit "$rc"
}

check_ready() {
    local name port pid i bundle manifest
    for name in "${services[@]}"; do
        [ "$name" != "$tunnel" ] || continue
        if [ "$name" = fkgfw-dsvpn ]; then port=$vpn; else port=$download; fi
        for ((i=0;i<60;i++)); do
            pid=$(systemctl show "$name.service" -p MainPID --value)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ss -H -ltnp "sport = :$port" | grep -F "pid=$pid," >/dev/null; then
                if [ "$name" != fkgfw-dsvpn ] ||
                    ss -H -lunp "sport = :$port" | grep -F "pid=$pid," >/dev/null; then break; fi
            fi
            sleep 0.25
        done
        [ "$i" -lt 60 ] || fail "$name 的端口 $port 尚未就绪，请检查 journalctl -u $name。"
    done
    manifest=$(realpath -e "$runtime/release/clients/SHA256SUMS")
    bundle=$(sha256sum < "$manifest")
    curl -fsS --noproxy '*' --max-time 5 "http://127.0.0.1:$download/${bundle%% *}/SHA256SUMS" | cmp - "$manifest"
}

check_ownership
action=install
if [ -f "$units/fkgfw-dsvpn.service" ]; then
    echo 'DSVPN：1. 查看客户端下载及连接信息  2. 修改地址或端口  3. 卸载 DSVPN'
    read -r -p '选择操作 [默认 1]: ' choice
    case "${choice:-1}" in
        1) show_clients; exit ;;
        2) action=edit ;;
        3) read -r -p '卸载 DSVPN 及下载服务，保留私有密钥与端口配置？输入 yes: ' answer
           [ "$answer" = yes ] || exit 0; action=remove ;;
        *) fail '无效操作。' ;;
    esac
fi
work=$(mktemp -d)
changed=0
paths=("$cfg" "$store")
for name in "${services[@]}"; do paths+=("$units/$name.service"); done
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$action" = remove ]; then
    bash "$SCRIPT_DIR/lib/dsvpn-release.sh" check-store
else
    if [ "$action" = edit ]; then
        artifacts=$(readlink "$cfg/artifacts")
        deploy_uid=0
        if [ -f "$cfg/deploy.uid" ]; then deploy_uid=$(cat "$cfg/deploy.uid"); fi
    else
        artifacts="$SCRIPT_DIR/artifacts/dsvpn"
        deploy_uid=${SUDO_UID:-0}
    fi
    arch=$(bash "$SCRIPT_DIR/lib/dsvpn-release.sh" verify "$artifacts" "$deploy_uid")
    check_prerequisites
    read_settings
fi
snapshot
changed=1
for name in "${services[@]}"; do
    if [ -f "$units/$name.service" ]; then systemctl stop "$name"; fi
done
if [ "$action" = remove ]; then
    systemctl disable "${services[@]}"
    for name in "${services[@]}"; do rm -f "$units/$name.service"; done
    rm -f -- "$cfg/artifacts" "$cfg/deploy.uid" "$cfg/select-release" "$cfg/tunnel.yml"
    rm -rf -- "$store"
    systemctl daemon-reload
    echo "DSVPN 已卸载。密钥和配置保留在 $cfg。"
    exit 0
fi
install -d -m 700 "$cfg"
if [[ ! -d "$store" ]]; then
    install -d -m 700 "$store"
    touch "$store/.managed-by-fkgfw"
fi
if [ "$action" = install ]; then
    printf '%s\n' "$deploy_uid" > "$cfg/deploy.uid"
    ln -sfnT -- "$artifacts" "$cfg/artifacts"
    printf '{}\n' > "$cfg/tunnel.yml"
    chmod 644 "$cfg/tunnel.yml"
fi
install -m 700 "$SCRIPT_DIR/lib/dsvpn-release.sh" "$cfg/select-release"
for name in "${services[@]}"; do
    sed "s/@ARCH@/$arch/g" "$SCRIPT_DIR/services/$name.service" > "$work/$name.service"
    install -m 644 "$work/$name.service" "$units/$name.service"
done
if [ ! -f "$cfg/vpn.key" ]; then head -c 32 /dev/urandom > "$cfg/vpn.key"; fi
printf '%s\nVPN_PORT=%s\nDOWNLOAD_PORT=%s\nSERVER_HOST=%s\n' "$marker" "$vpn" "$download" "$host" > "$cfg/server.env"
systemctl daemon-reload
systemctl enable --now "${services[@]}"
check_ready
show_clients 30
