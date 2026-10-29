#!/bin/bash
# No network/root required: real core validation, exports and isolated rollback.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_DIR="$repo"
source "$SCRIPT_DIR/lib/protocols.sh"
real_binary=${SING_BOX_BINARY:-sing-box}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$work/base.json"
[ "$(choose_protocols 3 <<< 11)" = '["ss-in"]' ]
[ "$(choose_protocols 3 '["hy2-in","anytls-in"]' <<< 11)" = '["hy2-in","anytls-in","ss-in"]' ]
[ "$(choose_protocols 3 '["hy2-in","ss-in"]' <<< 11)" = '["hy2-in","ss-in"]' ]
choose_protocols 3 <<< 10 | jq -e 'length == 7 and index("ss-in") != null' >/dev/null
[ "$(choose_protocols 3 <<< $'6\n2,7')" = '["hy2-in","ss-in"]' ]
[ "$(choose_protocols 3 <<< '')" = '["vless-in","hy2-in"]' ]
[ "$(choose_protocols 5 <<< '')" = '["vless-in","hy2-in","vmess-in","vless-ws-in"]' ]
collect_inbound ss-in "$work/base.json" "$work" "$real_binary" <<< '' > "$work/inbound.json"
jq -e '.type == "shadowsocks" and .method == "2022-blake3-aes-256-gcm" and .listen_port == 8388
  and (has("tls")|not) and (has("network")|not)' "$work/inbound.json" >/dev/null
[ "$(jq -r .password "$work/inbound.json" | base64 --decode | wc -c | tr -d ' ')" = 32 ]
collect_inbound ss-in "$work/base.json" "$work" "$real_binary" <<< '' > "$work/second.json"
jq -e --slurpfile other "$work/second.json" '.password != $other[0].password' "$work/inbound.json" >/dev/null
jq --slurpfile inbound "$work/inbound.json" '.inbounds=$inbound' "$work/base.json" > "$work/server.json"
collect_inbound ss-in "$work/server.json" "$work" "$real_binary" <<< 18388 > "$work/edited.json"
jq -e --slurpfile old "$work/inbound.json" '.listen_port == 18388 and del(.listen_port) == ($old[0]|del(.listen_port))' "$work/edited.json" >/dev/null
"$real_binary" check -c "$work/server.json"
[ "$(managed_tags "$work/server.json")" = '["ss-in"]' ]

# Fixed public fixture covers +, /, = in SIP002; never use a real deployment key.
test_key='YctPZ6U7xPPcU+gp3u+0tx/tRizJN9K8y+uKlW2qjlI='
jq --arg key "$test_key" '.inbounds[0].password=$key' "$work/server.json" > "$work/fixture.json"
for address in 192.0.2.1 2001:db8::1; do
    jq --arg server_ip "$address" --arg public_key '' --arg certificate_name '' --arg argo '' \
        -f "$repo/lib/client.jq" "$work/fixture.json" > "$work/client.json"
    "$real_binary" check -c "$work/client.json"
    jq -f "$repo/lib/clash.jq" "$work/client.json" > "$work/clash.json"
    jq -r -f "$repo/lib/yaml.jq" "$work/clash.json" > "$work/clash.yaml"
    jq -e --arg key "$test_key" --arg address "$address" '
      (.proxies|length) == 1 and (.proxies[0] == {name:"sing-box-shadowsocks", type:"ss",
        server:$address, port:8388, udp:true, cipher:"2022-blake3-aes-256-gcm", password:$key})
      and ."proxy-groups"[1].proxies == ["sing-box-shadowsocks"]' "$work/clash.json" >/dev/null
    grep -Fq "\"password\": \"$test_key\"" "$work/clash.yaml"
    host="$address"; [[ "$address" != *:* ]] || host="[$address]"
    expected="ss://2022-blake3-aes-256-gcm:YctPZ6U7xPPcU%2Bgp3u%2B0tx%2FtRizJN9K8y%2BuKlW2qjlI%3D@$host:8388#Shadowsocks-2022"
    [ "$(jq -r -f "$repo/lib/links.jq" "$work/client.json")" = "$expected" ]
done
if jq --arg server_ip '' --arg public_key '' --arg certificate_name '' --arg argo '' \
    -f "$repo/lib/client.jq" "$work/fixture.json" >/dev/null 2>&1; then exit 1; fi

# SS binds TCP and UDP: sharing either one must be rejected before activation.
validate_listeners "$work/server.json" 28080
for kind in vless hysteria2; do
    jq --arg kind "$kind" '.inbounds += [{type:$kind,tag:"custom",listen_port:8388}]' "$work/server.json" > "$work/conflict.json"
    if validate_listeners "$work/conflict.json" 28080 >/dev/null 2>&1; then exit 1; fi
done
jq '.inbounds += [{type:"vmess",tag:"vmess-in",listen_port:18443,transport:{path:"/ws"}}]' "$work/server.json" > "$work/conflict.json"
if validate_listeners "$work/conflict.json" 8388 >/dev/null 2>&1; then exit 1; fi
echo 'PASS SS-2022 AES-256 keys, retained credentials, exports, IPv6 links and dual-network conflicts'

# Exercise configure_protocols and export_clients against private remapped paths.
mkdir -p "$work/project/lib" "$work/etc/sing-box" "$work/etc/systemd/system" "$work/usr/local/bin"
for file in "$repo"/lib/*; do
    sed -e "s@/etc/sing-box@$work/etc/sing-box@g" \
        -e "s@/etc/systemd/system@$work/etc/systemd/system@g" \
        -e "s@/usr/local/bin@$work/usr/local/bin@g" \
        -e "s@/var/backups/fkgfw@$work/var/backups/fkgfw@g" "$file" > "$work/project/lib/$(basename "$file")"
done
SCRIPT_DIR="$work/project"
source "$SCRIPT_DIR/lib/installer.sh"
cp "$real_binary" "$work/usr/local/bin/sing-box"
config="$work/etc/sing-box/config.json"
cp "$work/base.json" "$config"
write_singbox_service
touch "$work/active" "$work/enabled"
systemctl() {
    case "$1" in
        is-active) [ -f "$work/active" ] ;;
        is-enabled) [ -f "$work/enabled" ] ;;
        start|restart) touch "$work/active" ;;
        stop) rm -f "$work/active" ;;
        enable) touch "$work/enabled" ;;
        disable) rm -f "$work/enabled" ;;
        daemon-reload) : ;;
        *) return 1 ;;
    esac
}
install() {
    local args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    command install "${args[@]}"
}
chown() { :; }
sleep() { :; }
create_singbox_user() { :; }
server_address() { echo 192.0.2.1; }
fetch_binary() { echo 'Unexpected auxiliary dependency' >&2; return 1; }
configure_protocols '["ss-in"]' <<< ''
cp "$config" "$work/installed.json"
cp "$work/etc/sing-box/clash.yaml" "$work/installed.yaml"
configure_protocols '["ss-in"]' ss-in <<< 18388
jq -e --slurpfile old "$work/installed.json" '.inbounds[0].listen_port == 18388
  and .inbounds[0].password == $old[0].inbounds[0].password' "$config" >/dev/null
cp "$config" "$work/before-failure.json"
cp "$work/etc/sing-box/clash.yaml" "$work/before-failure.yaml"
(
    export_clients() { return 1; }
    set +e
    configure_protocols '["ss-in"]' ss-in <<< 19388
    result=$?
    [ "$result" -ne 0 ]
)
cmp "$config" "$work/before-failure.json"
cmp "$work/etc/sing-box/clash.yaml" "$work/before-failure.yaml"
[ -f "$work/active" ] && [ -f "$work/enabled" ]
show_configuration > "$work/show.txt"
grep -q '^ss://2022-blake3-aes-256-gcm:' "$work/show.txt"
grep -q 'Clash Meta / Mihomo 客户端配置（YAML' "$work/show.txt"
echo 'PASS SS-only install, edit, existing-config exports and rollback without auxiliary services'
