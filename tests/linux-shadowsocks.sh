#!/bin/bash
# Disposable-container integration with real SS TCP/UDP traffic; no Internet.
set -euo pipefail
[ "${FKGFW_CONTAINER_TEST:-}" = 1 ] && [ -f /.dockerenv ] && [ "$EUID" -eq 0 ] || exit 1
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$SCRIPT_DIR/lib/installer.sh"
test_binary=${SING_BOX_BINARY:-/test-bin/sing-box}
work=/tmp/ss-test
mkdir -p "$work/mock"
cat > "$work/mock/systemctl" <<'SH'
#!/bin/bash
set -e
action=$1
pidfile=/tmp/ss-test/pid
case "$action" in
    is-active) [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null ;;
    is-enabled) [ -f /tmp/ss-test/enabled ] ;;
    enable) touch /tmp/ss-test/enabled ;;
    disable) rm -f /tmp/ss-test/enabled ;;
    daemon-reload) : ;;
    start|restart|stop)
        if [ -f "$pidfile" ]; then kill -- "-$(cat "$pidfile")" 2>/dev/null || true; rm -f "$pidfile"; sleep .3; fi
        if [ "$action" != stop ]; then
            setsid runuser -u singbox -- /usr/local/bin/sing-box run -c /etc/sing-box/config.json 9>&- >> /tmp/ss-test/server.log 2>&1 &
            echo $! > "$pidfile"
            sleep .3
        fi ;;
    *) exit 1 ;;
esac
SH
chmod +x "$work/mock/systemctl"
export PATH="$work/mock:$PATH"
export SERVER_ADDRESS=127.0.0.1
fetch_binary() { [ "$1" = sing-box ]; cp "$test_binary" "$2"; }
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" -days 1 -subj /CN=localhost >/dev/null 2>&1
openssl s_server -quiet -accept 18080 -cert "$work/cert.pem" -key "$work/key.pem" -www > "$work/origin.log" 2>&1 &
origin_pid=$!
cat > "$work/dns.json" <<'JSON'
{"inbounds":[{"type":"direct","listen":"127.0.0.1","listen_port":18081,"network":"udp"}],
 "route":{"rules":[{"action":"hijack-dns"}]},
 "dns":{"servers":[{"type":"hosts","tag":"fixture","predefined":{"ss.test":["192.0.2.123"]}}],"final":"fixture"}}
JSON
"$test_binary" check -c "$work/dns.json"
"$test_binary" run -c "$work/dns.json" > "$work/dns.log" 2>&1 &
dns_pid=$!
client_pid=""
finish() {
    [ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
    systemctl stop sing-box
    kill "$origin_pid" "$dns_pid" 2>/dev/null || true
}
trap finish EXIT
invoke() {
    local result
    set +e
    installer_main "$1" <<< "$2" > "$work/installer.log" 2>&1
    result=$?
    set -e
    if [ "$result" -ne 0 ]; then cat "$work/installer.log"; return "$result"; fi
}
stop_client() {
    kill "$client_pid"
    wait "$client_pid" || true
    client_pid=""
}
traffic() {
    local tag="${1:-sing-box-shadowsocks}"
    jq --arg tag "$tag" '{inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:19080},
        {type:"direct",listen:"127.0.0.1",listen_port:19081,network:"udp",override_address:"127.0.0.1",override_port:18081}],
      outbounds:[.outbounds[] | select(.tag == $tag)]}' /etc/sing-box/client.json > "$work/client.json"
    "$test_binary" run -c "$work/client.json" > "$work/client.log" 2>&1 &
    client_pid=$!
    sleep .4
    curl -kfsS --max-time 10 --noproxy '' --socks5-hostname 127.0.0.1:19080 https://127.0.0.1:18080/ > "$work/response"
    grep -q s_server "$work/response"
    reply=$(timeout 5 bash -c '
        exec 3<>/dev/udp/127.0.0.1/19081
        printf "\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x02ss\x04test\x00\x00\x01\x00\x01" >&3
        dd bs=512 count=1 <&3 2>/dev/null' | od -An -v -tx1 | tr -d ' \n')
    [[ "$reply" = 1234* && "$reply" = *c000027b ]]
    stop_client
    echo "PASS real TCP and UDP traffic: $tag"
    jq --arg key "$("$test_binary" generate rand --base64 32)" '.outbounds[0].password=$key' "$work/client.json" > "$work/bad.json"
    "$test_binary" run -c "$work/bad.json" > "$work/bad.log" 2>&1 &
    client_pid=$!
    sleep .4
    if curl -kfsS --max-time 3 --noproxy '' --socks5-hostname 127.0.0.1:19080 https://127.0.0.1:18080/ >/dev/null 2>&1; then
        echo "ERROR: wrong key accepted: $tag"; exit 1
    fi
    stop_client
    echo "PASS wrong key rejected: $tag"
}

for preset in 3 5; do
    invoke "$preset" $'11\n\n'
    systemd-analyze verify /etc/systemd/system/sing-box.service
    "$test_binary" check -c /etc/sing-box/config.json
    "$test_binary" check -c /etc/sing-box/client.json
    [ ! -e /etc/caddy/Caddyfile ] && [ ! -e /etc/sing-box/acme ] && [ ! -e /etc/sing-box/certs ]
    [ ! -e /usr/local/bin/caddy ] && [ ! -e /usr/local/bin/cloudflared ]
    for file in config.json client.json clash.json clash.yaml; do
        [ "$(stat -c %a "/etc/sing-box/$file")" = 600 ]
    done
    traffic
    cp /etc/sing-box/config.json "$work/before.json"
    invoke "$preset" $'2\n7\n18388'
    jq -e --slurpfile old "$work/before.json" '.inbounds[0].listen_port == 18388
      and .inbounds[0].password == $old[0].inbounds[0].password' /etc/sing-box/config.json >/dev/null
    traffic
    invoke "$preset" 3
    grep -q '^ss://2022-blake3-aes-256-gcm:' "$work/installer.log"
    grep -q 'Clash Meta / Mihomo 客户端配置（YAML' "$work/installer.log"
    invoke "$preset" $'4\nyes'
    [ ! -e /etc/sing-box ] && [ ! -e /usr/local/bin/sing-box ]
    echo "PASS entry preset $preset: SS-only install, edit, show and uninstall"
done

# The add-SS shortcut must retain working protocols and credentials, including
# when selected again. Only an explicit custom selection removes a protocol.
invoke 3 $'2\n\n\n'
cp /etc/sing-box/config.json "$work/hy2-before.json"
invoke 5 $'1\n11\n\n'
jq -e --slurpfile old "$work/hy2-before.json" '(.inbounds|length) == 2
  and .inbounds[0] == $old[0].inbounds[0] and .inbounds[1].tag == "ss-in"' /etc/sing-box/config.json >/dev/null
cp /etc/sing-box/config.json "$work/combined.json"
traffic
traffic sing-box-hysteria2
invoke 3 $'1\n11'
cmp /etc/sing-box/config.json "$work/combined.json"
invoke 3 $'1\n6\n2'
jq -e --slurpfile old "$work/hy2-before.json" '.inbounds == $old[0].inbounds' /etc/sing-box/config.json >/dev/null
jq -e 'all(.proxies[]; .type != "ss")' /etc/sing-box/clash.json >/dev/null
traffic sing-box-hysteria2
invoke 5 $'4\nyes'
echo 'PASS append/reselect SS preserves existing nodes; explicit custom removal retains Hysteria2'
