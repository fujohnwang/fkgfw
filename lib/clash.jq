# Shared Clash Meta / Mihomo data; export both JSON and YAML from this object.
[.outbounds[] | select(.tag | startswith("sing-box-"))
 | {name: .tag, type: .type, server: .server, port: .server_port, udp: true}
   + (if .type == "hysteria2" then
       {password: .password, sni: .tls.server_name, "skip-cert-verify": .tls.insecure}
      elif .type == "anytls" then
       {password: .password, sni: .tls.server_name, "skip-cert-verify": false, "client-fingerprint": "chrome"}
      else
       {uuid: .uuid, tls: true, servername: .tls.server_name, "client-fingerprint": "chrome"}
       + (if .tls.reality then {flow: .flow, "reality-opts": {
           "public-key": .tls.reality.public_key, "short-id": .tls.reality.short_id}}
          elif .transport.type == "ws" then {network: "ws", "ws-opts": {path: .transport.path, headers: {Host: .tls.server_name}}}
          else {network: "tcp", flow: .flow, "skip-cert-verify": false}
          end)
       + (if .type == "vmess" then {alterId: 0, cipher: "auto"} else {} end)
      end)] as $proxies
| {"mixed-port": 7890, "allow-lan": false, mode: "rule", "log-level": "info",
   proxies: $proxies,
   "proxy-groups": [
     {name: "节点选择", type: "select", proxies: (["自动选择", "DIRECT"] + [$proxies[].name])},
     {name: "自动选择", type: "url-test", proxies: [$proxies[].name],
      url: "https://www.gstatic.com/generate_204", interval: 300, tolerance: 50}],
   rules: ["GEOIP,LAN,DIRECT", "GEOIP,CN,DIRECT", "MATCH,节点选择"]}
