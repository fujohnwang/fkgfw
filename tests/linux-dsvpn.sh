#!/bin/bash
# Run only in a fresh disposable Linux VM with systemd, TUN and IPv4 forwarding.
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
# Exercise repository paths with spaces and a private parent directory.
mkdir "$work/test checkout"
tar -C "$repo" --exclude=.git -cf - . | tar --no-same-owner -C "$work/test checkout" -xf -
repo="$work/test checkout"
release="$repo/artifacts/dsvpn/latest"
old="$work/original"
cp -al "$release" "$old"
# The git history exists only in this disposable fixture.
git -C "$repo" init -q -b main
git -C "$repo" add artifacts/dsvpn/latest
fixture_commit() { git -C "$1" -c user.name=Fixture -c user.email=test@localhost commit -qm "$2"; }
fixture_commit "$repo" original
git clone -q "$repo" "$work/publisher"
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
    printf '%s\n' "$2" | bash "$repo/$1" "${@:3}" > "$work/log" 2>&1 || { cat "$work/log"; return 1; }
}
invoke install.sh $'12\n\n\n'
systemd-analyze verify "$service.service" "$download.service" "$tunnel.service"
for unit in "$service" "$download" "$tunnel"; do systemctl is-enabled --quiet "$unit"; systemctl is-active --quiet "$unit"; done
[[ ! -e /etc/sing-box/config.json && ! -e /opt/fkgfw-dsvpn ]]
[[ "/run/fkgfw-dsvpn/release/clients/SHA256SUMS" -ef "$release/clients/SHA256SUMS" ]]
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
    local pinned=$1 pid
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
        git -C "$work/publisher" add artifacts/dsvpn/latest
        fixture_commit "$work/publisher" update
        git -C "$repo" pull --ff-only "$work/publisher" main
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
        systemctl restart "$service"
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
cp "$work/good-client" "$release/clients/macos-arm64/dsvpn"
printf x >> "$release/clients/macos-arm64/dsvpn"
if systemctl restart "$service"; then exit 1; fi
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
echo 'PASS checkout-backed TCP/KCP, active connections survive checkout updates, restart switches server and downloads together, bad release rejected, uninstall and fresh install'
