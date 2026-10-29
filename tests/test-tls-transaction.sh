#!/bin/bash
# Exercise real configuration/export transactions in a disposable directory.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
real_binary=${SING_BOX_BINARY:-sing-box}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
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
unit="$work/etc/systemd/system/sing-box.service"
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$config"
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
ss() { :; }
create_singbox_user() { :; }
verify_tls_domain() { [ "${FAIL_DNS:-0}" = 0 ]; }
wait_for_tls() { [ "${FAIL_TLS:-0}" = 0 ]; }
cp "$config" "$work/before.json"
cp "$unit" "$work/before.service"

set +e
FAIL_DNS=1 configure_protocols '["vless-tls-in","anytls-in"]' <<< $'\none.example.com\n\none.example.com'
result=$?
set -e
[ "$result" -ne 0 ]
cmp "$config" "$work/before.json"
[ ! -d "$work/var/backups/fkgfw" ]
echo 'PASS DNS failure before activation'

set +e
FAIL_TLS=1 configure_protocols '["vless-tls-in","anytls-in"]' <<< $'\none.example.com\n\none.example.com'
result=$?
set -e
[ "$result" -ne 0 ]
cmp "$config" "$work/before.json"
cmp "$unit" "$work/before.service"
[ ! -d "$work/etc/sing-box/acme" ]
[ -f "$work/active" ] && [ -f "$work/enabled" ]
echo 'PASS failed certificate readiness restores config, unit and service state'

configure_protocols '["vless-tls-in","anytls-in"]' <<< $'\none.example.com\n\none.example.com'
grep -Fxq "ReadWritePaths=$work/etc/sing-box/acme" "$unit"
[ -f "$work/etc/sing-box/clash.yaml" ]
jq -e '.certificate_providers[0].domain == ["one.example.com"] and (.inbounds|length) == 2' "$config" >/dev/null
cp "$config" "$work/both.json"
configure_protocols '["vless-tls-in","anytls-in"]' anytls-in <<< $'\ntwo.example.com'
jq -e --slurpfile old "$work/both.json" '
  .certificate_providers[0].domain == ["one.example.com","two.example.com"] and
  (.inbounds[1].users == $old[0].inbounds[1].users) and .inbounds[0] == $old[0].inbounds[0]' "$config" >/dev/null
configure_protocols '["anytls-in"]'
jq -e '.certificate_providers[0].domain == ["two.example.com"] and (.inbounds|length) == 1' "$config" >/dev/null
echo 'PASS shared certificate config, domain editing without credential rotation, removal and exports'
