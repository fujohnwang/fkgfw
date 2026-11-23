#!/bin/bash
# Invoked by installer_main while holding the shared fkgfw lock.
set -euo pipefail
umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$SCRIPT_DIR/lib/installer.sh"

app=/opt/fkgfw-dsvpn
cfg=/etc/fkgfw-dsvpn
units=/etc/systemd/system
services=(fkgfw-dsvpn fkgfw-dsvpn-download)
platforms=(linux-amd64 linux-arm64 macos-amd64 macos-arm64)
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
    if exists "$app"; then
        [[ -d "$app" && ! -L "$app" && -f "$app/.managed" ]] &&
            grep -Fxq "$marker" "$app/.managed" || fail "程序目录归属不明：$app"
        [ -f "$cfg/server.env" ] || fail '已有程序缺少私有配置；请恢复备份。'
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
            [[ -f "$unit" && ! -L "$unit" && -d "$app" ]] &&
                grep -Fxq "$marker" "$unit" || fail "服务文件归属不明：$unit"
        fi
    done
}

public_host() {
    local host=$1
    if [[ "$host" == *:* ]]; then printf '[%s]' "$host"; else printf '%s' "$host"; fi
}

show_clients() {
    local host port download bundle hash path
    host=$(setting SERVER_HOST); port=$(setting VPN_PORT); download=$(setting DOWNLOAD_PORT)
    bundle=$(setting BUNDLE)
    [[ "$bundle" =~ ^[0-9a-f]{64}$ ]] || fail '已安装的制品标识无效。'
    echo "DSVPN v2，服务端 TCP ${port}，客户端下载 TCP ${download}。请放行这两个 TCP 端口。"
    echo '通过可信渠道核对下列 SHA-256，校验通过后再运行客户端。'
    while read -r hash path; do
        printf '%-12s http://%s:%s/%s/%s  SHA-256 %s\n' "${path%/dsvpn}" "$(public_host "$host")" "$download" "$bundle" "$path" "$hash"
    done < "$app/public/$bundle/SHA256SUMS"
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
    local port=$1 sockets pid name
    sockets=$(ss -H -ltnp "sport = :$port")
    [ -n "$sockets" ] || return 0
    for name in "${services[@]}"; do
        pid=$(systemctl show "$name.service" -p MainPID --value)
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
            sockets=$(awk -v token="pid=$pid," 'index($0,token)==0' <<< "$sockets")
        fi
    done
    [ -z "$sockets" ] || fail "TCP $port 已被其他进程使用。"
}

prepare_bundle() {
    local arch platform name digest file src="$SCRIPT_DIR/artifacts/dsvpn"
    case "$(uname -m)" in
        x86_64) arch=linux-amd64 ;;
        aarch64|arm64) arch=linux-arm64 ;;
        *) fail "当前 DSVPN 制品不支持 $(uname -m)" ;;
    esac
    mkdir "$work/package"
    local files=()
    for platform in "${platforms[@]}"; do
        files+=("$platform/dsvpn")
    done
    files+=(linux-amd64/darkhttpd linux-arm64/darkhttpd)
    for file in "${files[@]}"; do
        install -D -m 644 "$src/$file" "$work/package/$file"
    done
    (cd "$work/package" && sha256sum "${files[@]}") > "$work/digests"
    cmp -s "$src/SHA256SUMS" "$work/digests" || fail '制品 SHA-256 校验失败。'
    head -n "${#platforms[@]}" "$work/digests" > "$work/clients.sha256"
    digest=$(sha256sum "$work/clients.sha256"); bundle=${digest%% *}
    install -d -m 755 "$work/app" "$work/app/public" "$work/app/public/$bundle"
    for platform in "${platforms[@]}"; do
        install -d -m 755 "$work/app/public/$bundle/$platform"
        install -m 644 "$work/package/$platform/dsvpn" "$work/app/public/$bundle/$platform/dsvpn"
    done
    install -m 644 "$work/clients.sha256" "$work/app/public/$bundle/SHA256SUMS"
    for name in LICENSE Monocypher-LICENCE.md; do
        install -m 644 "$src/$name" "$work/app/public/$bundle/$name"
    done
    install -m 755 "$work/package/$arch/dsvpn" "$work/app/server"
    install -m 755 "$work/package/$arch/darkhttpd" "$work/app/darkhttpd"
    install -m 644 "$src/darkhttpd-LICENSE" "$work/app/darkhttpd-LICENSE"
    printf '%s\n' "$marker" > "$work/app/.managed"
}

read_settings() {
    local old_host='' default_vpn=1959 default_download=1960
    if [ -f "$cfg/server.env" ]; then
        old_host=$(setting SERVER_HOST); default_vpn=$(setting VPN_PORT); default_download=$(setting DOWNLOAD_PORT)
    fi
    if [ "$action" = update ]; then
        host=$old_host; vpn=$default_vpn; download=$default_download
    else
        old_host=${SERVER_ADDRESS:-$old_host}
        if [ -z "$old_host" ]; then old_host=$(server_address) || old_host=''; fi
        read -r -p "客户端访问此服务器的域名或 IP [$old_host]: " host
        host=${host:-$old_host}
        vpn=$(prompt_port DSVPN "$default_vpn")
        download=$(prompt_port 'DSVPN 客户端 HTTP 下载' "$default_download")
    fi
    [[ "$host" =~ ^[[:alnum:]][[:alnum:].-]*$ || "$host" =~ ^[[:xdigit:]:]+:[[:xdigit:].:]*$ ]] || fail '请输入有效公网域名或 IP。'
    [[ "$vpn" =~ ^[1-9][0-9]{0,4}$ && "$download" =~ ^[1-9][0-9]{0,4}$ &&
        "$vpn" -le 65535 && "$download" -le 65535 && "$vpn" != "$download" ]] || fail 'VPN 和下载必须使用两个不同的有效 TCP 端口。'
    check_port "$vpn"; check_port "$download"
    if [ -f /etc/sing-box/config.json ]; then
        local caddy_port=28080
        if [ -f /etc/caddy/Caddyfile ]; then
            caddy_port=$(sed -nE 's/^[[:space:]]*:([0-9]+)[[:space:]]*\{.*/\1/p' /etc/caddy/Caddyfile)
            caddy_port=${caddy_port:-28080}
        fi
        validate_listeners /etc/sing-box/config.json "$caddy_port" "[$vpn,$download]"
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
        echo '部署失败，正在恢复 DSVPN 程序、密钥及服务状态。' >&2
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
    local name port pid i
    for name in "${services[@]}"; do
        if [ "$name" = fkgfw-dsvpn ]; then port=$vpn; else port=$download; fi
        for ((i=0;i<60;i++)); do
            pid=$(systemctl show "$name.service" -p MainPID --value)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && ss -H -ltnp "sport = :$port" | grep -F "pid=$pid," >/dev/null; then break; fi
            sleep 0.25
        done
        [ "$i" -lt 60 ] || fail "$name 未监听 TCP $port，请检查 journalctl -u $name。"
    done
    curl -fsS --noproxy '*' --max-time 5 "http://127.0.0.1:$download/$bundle/SHA256SUMS" | cmp - "$work/clients.sha256"
}

check_ownership
action=install
if [ -f "$units/fkgfw-dsvpn.service" ]; then
    echo 'DSVPN：1. 查看客户端下载及连接信息  2. 修改地址或端口  3. 用仓库制品升级  4. 卸载 DSVPN'
    read -r -p '选择操作 [默认 1]: ' choice
    case "${choice:-1}" in
        1) show_clients; exit ;;
        2) action=edit ;; 3) action=update ;;
        4) read -r -p '卸载 DSVPN 及下载服务，保留私有密钥与端口配置？输入 yes: ' answer
           [ "$answer" = yes ] || exit 0; action=remove ;;
        *) fail '无效操作。' ;;
    esac
fi
work=$(mktemp -d)
changed=0
paths=("$app" "$cfg" "$units/fkgfw-dsvpn.service" "$units/fkgfw-dsvpn-download.service")
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$action" != remove ]; then
    if [ "$action" = edit ]; then
        bundle=$(setting BUNDLE)
        [[ "$bundle" =~ ^[0-9a-f]{64}$ ]] || fail '已安装的制品标识无效。'
        cp "$app/public/$bundle/SHA256SUMS" "$work/clients.sha256"
    else
        prepare_bundle
    fi
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
    rm -f "$units/fkgfw-dsvpn.service" "$units/fkgfw-dsvpn-download.service"
    rm -rf -- "$app"
    systemctl daemon-reload
    echo "DSVPN 已卸载。密钥和配置保留在 $cfg。"
    exit 0
fi
if [ "$action" != edit ]; then
    install -d -m 755 /opt
    rm -rf -- "$app"
    cp -a "$work/app" "$app"
    for name in "${services[@]}"; do install -m 644 "$SCRIPT_DIR/services/$name.service" "$units/$name.service"; done
fi
install -d -m 700 "$cfg"
if [ ! -f "$cfg/vpn.key" ]; then head -c 32 /dev/urandom > "$cfg/vpn.key"; fi
printf '%s\nVPN_PORT=%s\nDOWNLOAD_PORT=%s\nSERVER_HOST=%s\nBUNDLE=%s\n' "$marker" "$vpn" "$download" "$host" "$bundle" > "$cfg/server.env"
systemctl daemon-reload
systemctl enable --now "${services[@]}"
check_ready
show_clients
