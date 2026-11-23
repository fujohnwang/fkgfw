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
ns=fkgfw-dsvpn-test
peer_pid=''
finish() {
    if [[ -n $peer_pid ]]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" || true; fi
    ip netns del "$ns" 2>/dev/null || true
    ip link del dsvpn-e2e-host 2>/dev/null || true
    if systemctl cat "$service" >/dev/null 2>&1; then
        printf '4\nyes\n' | bash "$repo/install.sh" dsvpn >/dev/null || true
    fi
    rm -rf "$work"
}
trap finish EXIT
invoke() {
    printf '%s\n' "$2" | bash "$repo/$1" "${@:3}" > "$work/log" 2>&1 || { cat "$work/log"; return 1; }
}
invoke install.sh $'12\n\n\n'
systemd-analyze verify "$service.service" "$download.service"
for unit in "$service" "$download"; do systemctl is-enabled --quiet "$unit"; systemctl is-active --quiet "$unit"; done
[[ ! -e /etc/sing-box/config.json ]]
key=$(sha256sum "$cfg/vpn.key")
[[ $(stat -c '%u:%a:%s' "$cfg/vpn.key") = 0:600:32 ]]
bundle=$(sed -n 's/^BUNDLE=//p' "$cfg/server.env")
for platform in linux-amd64 linux-arm64 macos-amd64 macos-arm64; do
    url="http://127.0.0.1:1960/$bundle/$platform/dsvpn"
    grep -Fq "$url" "$work/log"
    curl --noproxy '*' -fsS "$url" -o "$work/$platform"
    cmp "$work/$platform" "$repo/artifacts/dsvpn/$platform/dsvpn"
done
[[ $(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' http://127.0.0.1:1960/vpn.key) = 404 ]]
case "$(uname -m)" in x86_64) arch=linux-amd64 ;; aarch64) arch=linux-arm64 ;; *) exit 2 ;; esac
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
for ((i=0;i<50;i++)); do grep -Fq Connected "$work/client.log" && break; sleep .2; done
grep -Fq Connected "$work/client.log" || { cat "$work/client.log"; exit 1; }
ip netns exec "$ns" ping -c 2 -W 2 192.168.192.254
kill "$peer_pid"
client_rc=0; wait "$peer_pid" || client_rc=$?
peer_pid=''
if [ "$client_rc" -ne 0 ]; then cat "$work/client.log"; echo "客户端退出码 $client_rc"; exit 1; fi
# Verify the namespace has its original policy rules after the downloaded client exits.
ip -n "$ns" -o link show | grep -q 'tun[0-9]' && exit 1
ip -n "$ns" rule show | cmp - "$work/before4"
ip -n "$ns" -6 rule show | cmp - "$work/before6"
invoke reality_hy2_ws.sh $'2\n\n2959\n2960' dsvpn
grep -Fq "http://127.0.0.1:2960/$bundle/" "$work/log"
invoke install.sh 3 dsvpn
[[ $(sha256sum "$cfg/vpn.key") = "$key" ]]
cp -R "$repo" "$work/bad"
printf x >> "$work/bad/artifacts/dsvpn/macos-arm64/dsvpn"
if printf '3\n' | bash "$work/bad/install.sh" dsvpn > "$work/bad.log" 2>&1; then exit 1; fi
grep -Fq 'SHA-256' "$work/bad.log"
cp "$repo/artifacts/dsvpn/macos-arm64/dsvpn" "$work/bad/artifacts/dsvpn/macos-arm64/dsvpn"
sed -i 's|^ExecStart=.*|ExecStart=/bin/false|' "$work/bad/services/$download.service"
if printf '3\n' | bash "$work/bad/install.sh" dsvpn > "$work/bad.log" 2>&1; then exit 1; fi
grep -Fq '正在恢复' "$work/bad.log"
curl --noproxy '*' -fsS "http://127.0.0.1:2960/$bundle/linux-arm64/dsvpn" | cmp - "$repo/artifacts/dsvpn/linux-arm64/dsvpn"
[[ $(sha256sum "$cfg/vpn.key") = "$key" ]]
systemctl is-active --quiet "$service"
invoke install.sh $'4\nyes' dsvpn
[[ ! -e /opt/fkgfw-dsvpn && ! -e /etc/systemd/system/fkgfw-dsvpn.service && ! -e /etc/systemd/system/fkgfw-dsvpn-download.service ]]
[[ $(sha256sum "$cfg/vpn.key") = "$key" ]]
invoke reality_hy2_ws.sh $'12\n\n\n'
grep -Fq "http://127.0.0.1:2960/$bundle/" "$work/log"
[[ $(sha256sum "$cfg/vpn.key") = "$key" ]]
echo 'PASS DSVPN deployment, four downloads, tunnel, settings, upgrade, rollback, removal and reinstall'
