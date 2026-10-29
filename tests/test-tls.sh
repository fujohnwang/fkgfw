#!/bin/bash
# No network or root required; real core checks plus isolated DNS/TLS regressions.
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$SCRIPT_DIR/lib/protocols.sh"
source "$SCRIPT_DIR/lib/tls.sh"
binary=${SING_BOX_BINARY:-sing-box}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "$work/key.pem" -out "$work/cert.pem" -days 1 -subj /CN=example.com 2>/dev/null
pair=$("$binary" generate reality-keypair)
private_key=$(awk '/PrivateKey/ {print $2}' <<< "$pair")
public_key=$(awk '/PublicKey/ {print $2}' <<< "$pair")
uuid=$("$binary" generate uuid)
tags='["vless-in","hy2-in","vmess-in","vless-ws-in","vless-tls-in","anytls-in","ss-in"]'
ss_key=$("$binary" generate rand --base64 32)
jq -n --argjson tags "$tags" --arg uuid "$uuid" --arg key "$private_key" --arg ss_key "$ss_key" '
  range(0;7) as $i | {tag:$tags[$i],port:(12000+$i),uuid:$uuid,private_key:$key,
  server_name:"example.com",short_id:"0123456789abcdef",password:(if $i == 6 then $ss_key else "00@a:# /?" end),path:("/ws"+($i|tostring))}' |
  jq -f "$SCRIPT_DIR/lib/new-inbound.jq" | jq -s --arg cert "$work/cert.pem" --arg key "$work/key.pem" \
  'map(if .tag == "hy2-in" then .tls.certificate_path=$cert | .tls.key_path=$key else . end)' > "$work/inbounds.json"
printf '%s\n' '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$work/base.json"
for mask in $(seq 1 127); do
    selected=$(jq -cn --argjson tags "$tags" --argjson mask "$mask" \
        '[range(0;7) as $i | select(($mask / pow(2;$i) | floor) % 2 == 1) | $tags[$i]]')
    jq --argjson selected "$selected" --argjson additions "$(cat "$work/inbounds.json")" \
        -f "$SCRIPT_DIR/lib/server.jq" "$work/base.json" | jq -f "$SCRIPT_DIR/lib/acme.jq" > "$work/server.json"
    validate_listeners "$work/server.json" 28080
    "$binary" check -c "$work/server.json"
    jq --arg server_ip 2001:db8::1 --arg public_key "$public_key" --arg certificate_name example.com \
        --arg argo test.trycloudflare.com -f "$SCRIPT_DIR/lib/client.jq" "$work/server.json" > "$work/client.json"
    "$binary" check -c "$work/client.json"
    jq -f "$SCRIPT_DIR/lib/clash.jq" "$work/client.json" > "$work/clash.json"
    jq -r -f "$SCRIPT_DIR/lib/yaml.jq" "$work/clash.json" > "$work/clash.yaml"
    jq -r -f "$SCRIPT_DIR/lib/links.jq" "$work/client.json" > "$work/links.txt"
    count=$(jq length <<< "$selected")
    [ "$(wc -l < "$work/links.txt" | tr -d ' ')" = "$count" ]
    jq -e --argjson count "$count" --arg uuid "$uuid" --arg ss_key "$ss_key" '
      (.proxies|length) == $count and all(.proxies[];
        if .type == "ss" then .password == $ss_key and .cipher == "2022-blake3-aes-256-gcm" and .udp and (has("tls")|not)
        elif .type == "anytls" then .password == "00@a:# /?" and .sni == "example.com" and ."skip-cert-verify" == false
        elif .name == "sing-box-vless-tls" then .uuid == $uuid and .flow == "xtls-rprx-vision" and .network == "tcp" and ."skip-cert-verify" == false and (has("reality-opts")|not)
        else true end)' "$work/clash.json" >/dev/null
    if has_protocol "$work/server.json" anytls-in; then
        grep -Fq 'anytls://00%40a%3A%23%20%2F%3F@example.com:12005/?sni=example.com&insecure=0' "$work/links.txt"
    fi
    if has_managed_tls "$work/server.json"; then
        jq -e '.certificate_providers | length == 1 and .[0].domain == ["example.com"] and .[0].disable_tls_alpn_challenge' "$work/server.json" >/dev/null
    fi
    # Add all protocols then remove the new ones: retained inbound data stays exact.
    jq --argjson selected "$tags" --argjson additions "$(cat "$work/inbounds.json")" \
        -f "$SCRIPT_DIR/lib/server.jq" "$work/server.json" | jq -f "$SCRIPT_DIR/lib/acme.jq" > "$work/all.json"
    jq -e --slurpfile old "$work/server.json" '. as $new | all($old[0].inbounds[]; . as $i | any($new.inbounds[]; . == $i))' "$work/all.json" >/dev/null
    jq --argjson selected '["vless-in"]' --argjson additions '[]' -f "$SCRIPT_DIR/lib/server.jq" "$work/all.json" |
        jq -f "$SCRIPT_DIR/lib/acme.jq" | jq -e 'has("certificate_providers")|not' >/dev/null
done
echo 'PASS 127 server/client configurations, shared ACME, exports and protocol transitions'

normalize_selection '6,5 6' | jq -e '. == ["vless-tls-in","anytls-in"]' >/dev/null
normalize_selection '7,2 7' | jq -e '. == ["hy2-in","ss-in"]' >/dev/null
if normalize_selection 8 >/dev/null 2>&1; then exit 1; fi
[ "$(prompt_tls_domain <<< $'\n127.0.0.1\n*.example.com\nTLS.Example.COM')" = tls.example.com ]
[ "$(printf '%s\n' 2001:0db8:0:0:0:0:0:1 | ip_key)" = "$(printf '%s\n' 2001:db8::1 | ip_key)" ]

# Stub just the public resolvers/address service; mismatched AAAA must also fail.
curl() {
    case "$*" in
        *type=AAAA*) printf '%s\n' "$DNS_AAAA" ;;
        *type=A*) printf '%s\n' "$DNS_A" ;;
        *-4fsS*) echo 192.0.2.1 ;;
        *-6fsS*) echo 2001:db8::1 ;;
        *) return 1 ;;
    esac
}
DNS_A='{"Status":0,"Answer":[{"type":1,"data":"192.0.2.1"}]}'
DNS_AAAA='{"Status":0}'
verify_tls_domain example.com
DNS_AAAA='{"Status":0,"Answer":[{"type":28,"data":"2001:0db8:0:0:0:0:0:1"}]}'
verify_tls_domain example.com
DNS_AAAA='{"Status":0,"Answer":[{"type":28,"data":"2001:db8::2"}]}'
if verify_tls_domain example.com >/dev/null 2>&1; then exit 1; fi
DNS_AAAA='{"Status":2}'
if verify_tls_domain example.com >/dev/null 2>&1; then exit 1; fi
DNS_AAAA='{"Status":0}'
DNS_A='{"Status":0,"Answer":[{"type":1,"data":"104.16.128.1"}]}'
if verify_tls_domain example.com >/dev/null 2>&1; then exit 1; fi
DNS_A='{"Status":0}'
if verify_tls_domain example.com >/dev/null 2>&1; then exit 1; fi
echo 'PASS domain validation, DNS-only requirement and stale IPv6 rejection'
