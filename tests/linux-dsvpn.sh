#!/bin/bash
# Run only in a fresh disposable Linux VM with systemd and TUN.
set -euo pipefail
[[ ${FKGFW_DSVPN_TEST:-} = 1 && $EUID = 0 && $(ps -p 1 -o comm=) = systemd ]] || exit 2
[[ ! -e /etc/fkgfw-dsvpn && ! -e /opt/fkgfw-dsvpn && ! -e /etc/sing-box ]] || exit 2
repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
export SERVER_ADDRESS=127.0.0.1
cfg=/etc/fkgfw-dsvpn
service=fkgfw-dsvpn
download=fkgfw-dsvpn-download
tunnel=fkgfw-dsvpn-tunnel
live=${FKGFW_DSVPN_LIVE_TUNNEL:-0}
metrics_dir=''
ns=fkgfw-dsvpn-test
peer_pid=''
operator=()
deploy_uid=${SUDO_UID:-0}
if [[ "$deploy_uid" != 0 ]]; then
    operator=(setpriv --reuid="$deploy_uid" --regid="$(id -g "$deploy_uid")" --init-groups --)
    chmod 711 "$work"
fi
finish() {
    if [[ -n $peer_pid ]]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" || true; fi
    ip netns del "$ns" 2>/dev/null || true
    ip link del dsvpn-e2e-host 2>/dev/null || true
    if systemctl cat "$service" >/dev/null 2>&1; then
        printf '3\nyes\n' | bash "$repo/install.sh" dsvpn >/dev/null || true
    fi
    rm -rf "$work"
    if [ -n "$metrics_dir" ]; then rm -rf "$metrics_dir"; fi
}
trap finish EXIT
# Clone as the invoking account. All Git history here is local to the fixture.
mkdir "$work/publisher"
tar -C "$repo" --exclude=.git -cf - . | tar --no-same-owner -C "$work/publisher" -xf -
chown -R "$deploy_uid:$(id -g "$deploy_uid")" "$work/publisher"
project_git() { "${operator[@]}" git -C "$1" "${@:2}"; }
fixture_commit() { project_git "$1" -c user.name=Fixture -c user.email=test@localhost commit -qm "$2"; }
project_git "$work/publisher" init -q -b main
project_git "$work/publisher" add .
fixture_commit "$work/publisher" original
repo="$work/test checkout"
install -d -m 700 -o "$deploy_uid" -g "$(id -g "$deploy_uid")" "$repo"
"${operator[@]}" git clone -q --no-local "$work/publisher" "$repo"
release="$repo/artifacts/dsvpn/latest"
old="$work/original"
cp -al "$release" "$old"
candidate="$work/publisher/artifacts/dsvpn/latest"
if [ "$live" != 1 ]; then
    # A local connector status fixture keeps private development builds off the public Internet.
    metrics_dir=$(mktemp -d /run/fkgfw-dsvpn-test.XXXXXX)
    chmod 755 "$metrics_dir"
    printf 'ready\n' > "$metrics_dir/ready"
    printf '{"hostname":"fixture.trycloudflare.com"}\n' > "$metrics_dir/quicktunnel"
    chmod 644 "$metrics_dir/"*
    cat >> "$repo/services/$tunnel.service" <<EOF

[Service]
ExecStart=
BindReadOnlyPaths=/run/fkgfw-dsvpn/release/@ARCH@/darkhttpd:/run/fkgfw-dsvpn-tunnel/test-httpd
ExecStart=/usr/bin/env /run/fkgfw-dsvpn-tunnel/test-httpd $metrics_dir --addr 127.0.0.1 --port 31829 --no-listing
EOF
fi
invoke() {
    printf '%s\n' "$2" | sh "$repo/$1" "${@:3}" > "$work/log" 2>&1 || { cat "$work/log"; return 1; }
}
license="$release/clients/LICENSE"
original_mode=$(stat -c %a "$license")
chmod o+w "$license"
if bash "$repo/lib/dsvpn-release.sh" verify "$repo/artifacts/dsvpn" "$deploy_uid" > "$work/path.log" 2>&1; then exit 1; fi
grep -Fq '其他账号可写入' "$work/path.log"
chmod "$original_mode" "$license"
if [[ "$deploy_uid" != 0 ]]; then
    chown nobody "$license"
    if bash "$repo/lib/dsvpn-release.sh" verify "$repo/artifacts/dsvpn" "$deploy_uid" > "$work/path.log" 2>&1; then exit 1; fi
    grep -Fq '未获部署授权' "$work/path.log"
    # Mixed ownership also occurs after a sudo git pull.
    chown root:root "$license"
    chmod 644 "$license"
fi
sysctl -qw net.ipv4.ip_forward=0
invoke install.sh $'12\n\n\n'
[[ $(< /proc/sys/net/ipv4/ip_forward) = 1 ]]
[[ $(cat "$cfg/deploy.uid") = "$deploy_uid" && $(stat -c '%u:%a' "$cfg/deploy.uid") = 0:600 ]]
[[ $(stat -c '%u:%a' /opt/fkgfw-dsvpn) = 0:700 && ! -e "$repo/artifacts/dsvpn/.fkgfw-dsvpn-running" ]]
cmp "$license" /run/fkgfw-dsvpn/release/clients/LICENSE
systemd-analyze verify "$service.service" "$download.service" "$tunnel.service"
for unit in "$service" "$download" "$tunnel"; do systemctl is-enabled --quiet "$unit"; systemctl is-active --quiet "$unit"; done
[[ ! -e /etc/sing-box/config.json && "/run/fkgfw-dsvpn/release" -ef /opt/fkgfw-dsvpn/release ]]
[[ ! "/run/fkgfw-dsvpn/release/clients/SHA256SUMS" -ef "$release/clients/SHA256SUMS" ]]
key=$(sha256sum "$cfg/vpn.key")
[[ $(stat -c '%u:%a:%s' "$cfg/vpn.key") = 0:600:32 ]]
bundle=$(sha256sum < "$release/clients/SHA256SUMS" | cut -d' ' -f1)
for platform in linux-amd64 linux-arm64 macos-amd64 macos-arm64; do
    url=$(awk -v platform="$platform" '$1 == platform { print $2 }' "$work/log")
    [[ "$url" =~ ^https://[a-z0-9-]+\.trycloudflare\.com/ && "$url" == */"$bundle/$platform/dsvpn" ]]
    if [ "$live" = 1 ]; then
        curl --retry 5 --retry-all-errors --max-time 20 -fsS "$url" -o "$work/$platform"
    else
        curl --noproxy '*' -fsS "http://127.0.0.1:1960/$bundle/$platform/dsvpn" -o "$work/$platform"
    fi
    cmp "$work/$platform" "$release/clients/$platform/dsvpn"
done
[[ $(ss -H -ltn 'sport = :1960' | awk '{print $4}') = 127.0.0.1:1960 ]]
if [ "$live" != 1 ]; then
    printf '{"hostname":"renewed.trycloudflare.com"}\n' > "$metrics_dir/quicktunnel"
    invoke install.sh 1 dsvpn
    grep -Fq "https://renewed.trycloudflare.com/$bundle/" "$work/log"
fi
systemctl stop "$tunnel"
invoke install.sh 1 dsvpn
grep -Fq '下载隧道尚未就绪' "$work/log"
if grep -q 'trycloudflare.com/' "$work/log"; then exit 1; fi
systemctl is-active --quiet "$service"
systemctl start "$tunnel"
systemctl stop "$download"
invoke install.sh 1 dsvpn
grep -Fq '下载源站尚未就绪' "$work/log"
if grep -q 'trycloudflare.com/' "$work/log"; then exit 1; fi
systemctl start "$download"
[[ $(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1960/vpn.key) = 404 ]]
case "$(uname -m)" in x86_64) arch=linux-amd64 ;; aarch64) arch=linux-arm64 ;; *) exit 2 ;; esac
check_inodes() {
    local expected=$1 pinned=/opt/fkgfw-dsvpn/release pid
    cmp "$expected/clients/SHA256SUMS" "$pinned/clients/SHA256SUMS"
    cmp "$expected/clients/$arch/dsvpn" "$pinned/clients/$arch/dsvpn"
    [[ $(stat -c '%u:%a' "$pinned/clients/$arch/dsvpn") = 0:755 ]]
    pid=$(systemctl show "$service" -p MainPID --value)
    [[ $(stat -Lc '%d:%i' "/proc/$pid/exe") = "$(stat -Lc '%d:%i' "$pinned/clients/$arch/dsvpn")" ]]
    pid=$(systemctl show "$download" -p MainPID --value)
    [[ $(stat -Lc '%d:%i' "/proc/$pid/exe") = "$(stat -Lc '%d:%i' "$pinned/$arch/darkhttpd")" ]]
    [[ $(stat -Lc '%d:%i' "/proc/$pid/root/run/fkgfw-dsvpn-download/public/$bundle/$arch/dsvpn") = "$(stat -Lc '%d:%i' "$pinned/clients/$arch/dsvpn")" ]]
    pid=$(systemctl show "$tunnel" -p MainPID --value)
    [[ $(stat -Lc '%d:%i' "/proc/$pid/root/run/fkgfw-dsvpn-tunnel/cloudflared") = "$(stat -Lc '%d:%i' "$pinned/$arch/cloudflared")" ]]
}
check_inodes "$release"
chmod 755 "$work/$arch"
ip netns add "$ns"
ip link add dsvpn-e2e-host type veth peer name dsvpn-e2e-peer
ip link set dsvpn-e2e-peer netns "$ns"
ip addr add 198.18.75.1/30 dev dsvpn-e2e-host
ip link set dsvpn-e2e-host up
ip -n "$ns" addr add 198.18.75.2/30 dev dsvpn-e2e-peer
ip -n "$ns" link set dsvpn-e2e-peer up
ip -n "$ns" link set lo up
ip -n "$ns" route add default via 198.18.75.1
ip -n "$ns" rule show > "$work/before4"
ip -n "$ns" -6 rule show > "$work/before6"
ip netns exec "$ns" "$work/$arch" client "$cfg/vpn.key" 198.18.75.1 1959 > "$work/client.log" 2>&1 &
peer_pid=$!
for transport in TCP KCP/UDP; do
    if [ "$transport" = KCP/UDP ]; then
        old_pid=$(systemctl show "$service" -p MainPID --value)
        if [ "$live" != 1 ]; then
            # A harmless ELF trailer gives this local fixture distinct downloadable bytes.
            printf 'next' >> "$candidate/clients/$arch/dsvpn"
            (cd "$candidate/clients" && sha256sum linux-{amd64,arm64}/dsvpn macos-{amd64,arm64}/dsvpn > SHA256SUMS)
        else
            printf '\n' >> "$candidate/clients/LICENSE"
        fi
        project_git "$work/publisher" add artifacts/dsvpn/latest
        fixture_commit "$work/publisher" update
        project_git "$repo" pull --ff-only
        next_bundle=$(sha256sum < "$release/clients/SHA256SUMS" | cut -d' ' -f1)
        old_bundle=$bundle
        [[ "$live" = 1 || "$old_bundle" != "$next_bundle" ]]
        systemctl restart "$download" "$tunnel"
        check_inodes "$old"
        invoke install.sh 1 dsvpn
        if [[ "$live" != 1 ]]; then grep -Fq ".trycloudflare.com/$bundle/" "$work/log"; fi
        curl -fsS --noproxy '*' "http://127.0.0.1:1960/$bundle/$arch/dsvpn" | cmp - "$old/clients/$arch/dsvpn"
        [[ $(systemctl show "$service" -p MainPID --value) = "$old_pid" ]]
        ip netns exec "$ns" ping -c 1 -W 2 192.168.192.254
        ip netns exec "$ns" iptables -A OUTPUT -p tcp --syn -d 198.18.75.1 --dport 1959 -j DROP
        sysctl -qw net.ipv4.ip_forward=0
        systemctl restart "$service"
        [[ $(< /proc/sys/net/ipv4/ip_forward) = 1 ]]
        bundle=$next_bundle
    fi
    for ((i=0;i<100;i++)); do grep -Fq "Connected ($transport)" "$work/client.log" && break; sleep .2; done
    grep -Fq "Connected ($transport)" "$work/client.log" || { cat "$work/client.log"; exit 1; }
    ip netns exec "$ns" ping -s 4000 -c 2 -W 4 192.168.192.254
done
check_inodes "$release"
for platform in linux-amd64 linux-arm64 macos-amd64 macos-arm64; do
    curl -fsS --noproxy '*' "http://127.0.0.1:1960/$bundle/$platform/dsvpn" | cmp - "$release/clients/$platform/dsvpn"
done
if [[ "$old_bundle" != "$bundle" ]]; then
    [[ $(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:1960/$old_bundle/$arch/dsvpn") = 404 ]]
fi
kill "$peer_pid"
client_rc=0; wait "$peer_pid" || client_rc=$?
peer_pid=''
if [ "$client_rc" -ne 0 ]; then cat "$work/client.log"; echo "客户端退出码 $client_rc"; exit 1; fi
# Verify the namespace has its original policy rules after the downloaded client exits.
ip -n "$ns" -o link show | grep -q 'tun[0-9]' && exit 1
ip -n "$ns" rule show | cmp - "$work/before4"
ip -n "$ns" -6 rule show | cmp - "$work/before6"
invoke reality_hy2_ws.sh $'2\n\n2959\n2960' dsvpn
grep -Fq ".trycloudflare.com/$bundle/" "$work/log"
[[ $(ss -H -ltn 'sport = :2960' | awk '{print $4}') = 127.0.0.1:2960 ]]
[[ $(sha256sum "$cfg/vpn.key") = "$key" ]]
check_inodes "$release"
curl -fsS --noproxy '*' "http://127.0.0.1:2960/$bundle/$arch/dsvpn" | cmp - "$release/clients/$arch/dsvpn"
invoke install.sh $'3\nno' dsvpn
systemctl is-active --quiet "$service"
mv "$release/clients/macos-arm64/dsvpn" "$work/good-client"
install -m 755 -o "$deploy_uid" -g "$(id -g "$deploy_uid")" "$work/good-client" "$release/clients/macos-arm64/dsvpn"
printf x >> "$release/clients/macos-arm64/dsvpn"
if systemctl restart "$service"; then exit 1; fi
(cd /opt/fkgfw-dsvpn/release/clients && sha256sum --quiet -c SHA256SUMS)
[[ $(sha256sum < /opt/fkgfw-dsvpn/release/clients/SHA256SUMS | cut -d' ' -f1) = "$bundle" ]]
invoke install.sh 1 dsvpn
if grep -q 'trycloudflare.com/' "$work/log" || systemctl is-active --quiet "$download"; then exit 1; fi
invoke install.sh $'3\nyes' dsvpn
[[ ! -e /opt/fkgfw-dsvpn && ! -L "$cfg/artifacts" && ! -e /etc/systemd/system/fkgfw-dsvpn.service && ! -e /etc/systemd/system/fkgfw-dsvpn-download.service && ! -e "/etc/systemd/system/$tunnel.service" ]]
[[ $(sha256sum "$cfg/vpn.key") = "$key" && -x "$release/clients/$arch/dsvpn" ]]
if printf '\n\n\n' | bash "$repo/install.sh" dsvpn > "$work/bad.log" 2>&1; then exit 1; fi
grep -Fq 'SHA-256' "$work/bad.log"
mv "$work/good-client" "$release/clients/macos-arm64/dsvpn"
cp "$repo/services/$download.service" "$work/good.service"
sed -i 's|^ExecStart=.*|ExecStart=/bin/false|' "$repo/services/$download.service"
if printf '\n\n\n' | bash "$repo/install.sh" dsvpn > "$work/bad.log" 2>&1; then exit 1; fi
grep -Fq '正在恢复' "$work/bad.log"
[[ ! -e "/etc/systemd/system/$service.service" && ! -L "$cfg/artifacts" && $(sha256sum "$cfg/vpn.key") = "$key" ]]
cp "$work/good.service" "$repo/services/$download.service"
invoke reality_hy2_ws.sh $'12\n\n\n'
grep -Fq ".trycloudflare.com/$bundle/" "$work/log"
[[ $(sha256sum "$cfg/vpn.key") = "$key" ]]
check_inodes "$release"
echo 'PASS deployment UID, root-owned TCP/KCP binaries and downloads, git pull, restart sync, corrupt update rejection and uninstall'
