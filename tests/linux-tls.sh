#!/bin/bash
# Container-only integration. A local trusted test certificate replaces ACME
# issuance in the launched process; installed/exported configs stay unmodified.
set -euo pipefail
[ "${FKGFW_CONTAINER_TEST:-}" = 1 ] && [ -f /.dockerenv ] && [ "$EUID" -eq 0 ] || exit 1
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$SCRIPT_DIR/lib/installer.sh"
test_binary=${SING_BOX_BINARY:-/usr/local/bin/sing-box}
mkdir -p /tmp/tls-test/mock
create_singbox_user
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout /tmp/tls-test/key.pem -out /tmp/tls-test/cert.pem -days 1 -subj /CN=tls.example.com \
    -addext subjectAltName=DNS:tls.example.com,DNS:other.example.com >/dev/null 2>&1
chown singbox:singbox /tmp/tls-test/key.pem
chmod 600 /tmp/tls-test/key.pem
cp /tmp/tls-test/cert.pem /usr/local/share/ca-certificates/fkgfw-test.crt
update-ca-certificates >/dev/null 2>&1
cat > /tmp/tls-test/mock/systemctl <<'SH'
#!/bin/bash
set -e
action=$1
pidfile=/tmp/tls-test/pid
case "$action" in
    is-active) [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2>/dev/null ;;
    is-enabled) [ -f /tmp/tls-test/enabled ] ;;
    enable) touch /tmp/tls-test/enabled ;;
    disable) rm -f /tmp/tls-test/enabled ;;
    daemon-reload) : ;;
    start|restart|stop)
        if [ -f "$pidfile" ]; then kill -- "-$(cat "$pidfile")" 2>/dev/null || true; rm -f "$pidfile"; sleep .3; fi
        if [ "$action" != stop ]; then
            jq 'del(.certificate_providers) | .inbounds |= map(if .tag == "vless-tls-in" or .tag == "anytls-in" then
              .tls |= (del(.certificate_provider) + {certificate_path:"/tmp/tls-test/cert.pem",key_path:"/tmp/tls-test/key.pem"}) else . end)' \
              /etc/sing-box/config.json > /tmp/tls-test/runtime.json
            chmod 644 /tmp/tls-test/runtime.json
            setsid runuser -u singbox -- /usr/local/bin/sing-box run -c /tmp/tls-test/runtime.json 9>&- >> /tmp/tls-test/server.log 2>&1 &
            echo $! > "$pidfile"
            sleep .3
        fi ;;
    *) exit 1 ;;
esac
SH
chmod +x /tmp/tls-test/mock/systemctl
export PATH="/tmp/tls-test/mock:$PATH"
fetch_binary() { cp "$test_binary" "$2"; }
verify_tls_domain() { :; }
openssl s_server -quiet -accept 18080 -cert /tmp/tls-test/cert.pem -key /tmp/tls-test/key.pem -www > /tmp/tls-test/origin.log 2>&1 &
origin_pid=$!
client_pid=""
finish() {
    [ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
    systemctl stop sing-box
    kill "$origin_pid" 2>/dev/null || true
}
trap finish EXIT

traffic() {
    local tag
    for tag in $(jq -r '.outbounds[].tag | select(startswith("sing-box-"))' /etc/sing-box/client.json); do
        jq --arg tag "$tag" '{inbounds:[{type:"mixed",listen:"127.0.0.1",listen_port:19080}],
          outbounds:[.outbounds[] | select(.tag == $tag) | .server="127.0.0.1"]}' /etc/sing-box/client.json > /tmp/tls-test/client.json
        "$test_binary" run -c /tmp/tls-test/client.json > /tmp/tls-test/client.log 2>&1 &
        client_pid=$!
        sleep .4
        curl -kfsS --max-time 10 --noproxy '' --socks5-hostname 127.0.0.1:19080 https://127.0.0.1:18080/ > /tmp/tls-test/response
        grep -q 's_server' /tmp/tls-test/response
        kill "$client_pid"; wait "$client_pid" || true; client_pid=""
        echo "PASS verified TLS proxy traffic: $tag"
        # Wrong SNI must fail; exports must never disable certificate validation.
        jq '.outbounds[0].tls.server_name="wrong.example.com"' /tmp/tls-test/client.json > /tmp/tls-test/bad.json
        "$test_binary" run -c /tmp/tls-test/bad.json > /tmp/tls-test/bad.log 2>&1 &
        client_pid=$!
        sleep .4
        if curl -kfsS --max-time 5 --noproxy '' --socks5-hostname 127.0.0.1:19080 https://127.0.0.1:18080/ >/dev/null 2>&1; then
            echo 'ERROR: mismatched certificate accepted'; exit 1
        fi
        kill "$client_pid"; wait "$client_pid" || true; client_pid=""
    done
}

for choice in 7 8 9; do
    answers=$'\ntls.example.com\n'
    [ "$choice" != 9 ] || answers+=$'\ntls.example.com\n'
    set +e
    installer_main 3 <<< "$choice"$'\n'"$answers" > /tmp/tls-test/install.log 2>&1
    result=$?
    set -e
    if [ "$result" -ne 0 ]; then cat /tmp/tls-test/install.log; exit 1; fi
    systemd-analyze verify /etc/systemd/system/sing-box.service
    "$test_binary" check -c /etc/sing-box/config.json
    "$test_binary" check -c /etc/sing-box/client.json
    traffic
    show_configuration > /tmp/tls-test/show.log
    grep -q 'Clash Meta / Mihomo 客户端配置（YAML' /tmp/tls-test/show.log
    # Include a domain edit and transition keeping the other node's credentials.
    if [ "$choice" = 9 ]; then
        cp /etc/sing-box/config.json /tmp/tls-test/before.json
        installer_main 5 <<< $'2\n6\n\nother.example.com\n' > /tmp/tls-test/edit.log
        jq -e --slurpfile old /tmp/tls-test/before.json '.inbounds[1].users == $old[0].inbounds[1].users and .inbounds[0] == $old[0].inbounds[0]' /etc/sing-box/config.json >/dev/null
        traffic
        installer_main 3 <<< $'1\n8\n' > /tmp/tls-test/transition.log
        traffic
    fi
    uninstall_managed <<< yes
    [ ! -f /etc/sing-box/config.json ]
done
echo 'PASS TLS-only/AnyTLS-only/combined installs, certificate rejection, menu exports, editing, transition and uninstall'
