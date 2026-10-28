# Current sing-box client schema; each managed inbound is optional.
[.inbounds[] | select(.tag == "vless-in" or .tag == "hy2-in" or .tag == "vmess-in" or .tag == "vless-ws-in")
 | if .tag == "vless-in" then
     if $public_key == "" or $server_ip == "" then error("Missing Reality public key or server address") else . end
     | {type: "vless", tag: "sing-box-reality", server: $server_ip,
        server_port: .listen_port, uuid: .users[0].uuid, flow: .users[0].flow, packet_encoding: "xudp",
        tls: {enabled: true, server_name: .tls.server_name,
              utls: {enabled: true, fingerprint: "chrome"},
              reality: {enabled: true, public_key: $public_key, short_id: .tls.reality.short_id[0]}}}
   elif .tag == "hy2-in" then
     if $certificate_name == "" or $server_ip == "" then error("Missing Hysteria2 certificate name or server address") else . end
     | {type: "hysteria2", tag: "sing-box-hysteria2", server: $server_ip,
        server_port: .listen_port, password: .users[0].password, up_mbps: 100, down_mbps: 100,
        tls: {enabled: true, server_name: $certificate_name, insecure: true, alpn: ["h3"]}}
   else
     if $argo == "" then error("Missing Cloudflare tunnel hostname") else . end
     | {type: .type, tag: (if .type == "vmess" then "sing-box-vmess" else "sing-box-vless-ws" end),
        server: "104.16.128.1", server_port: 443, uuid: .users[0].uuid,
        tls: {enabled: true, server_name: $argo, utls: {enabled: true, fingerprint: "chrome"}},
        transport: {type: "ws", path: .transport.path, headers: {Host: $argo}}}
       + (if .type == "vmess" then {security: "auto"} else {} end)
   end] as $proxies
| if ($proxies | length) == 0 then error("No supported protocols selected") else . end
| {
    log: {level: "info", timestamp: true},
    dns: {
      servers: [
        {type: "https", tag: "remote", server: "1.1.1.1", path: "/dns-query", detour: "select"},
        {type: "https", tag: "local", server: "223.5.5.5", path: "/dns-query"}
      ],
      rules: [
        {rule_set: ["geosite-category-ads-all"], action: "predefined", rcode: "NOERROR"},
        {clash_mode: "global", server: "remote"},
        {clash_mode: "direct", server: "local"},
        {rule_set: ["geosite-cn"], server: "local"}
      ],
      final: "remote", strategy: "prefer_ipv4"
    },
    inbounds: [
      {type: "tun", address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
       auto_route: true, strict_route: true, stack: "mixed", mtu: 9000},
      {type: "socks", tag: "socks-in", listen: "127.0.0.1", listen_port: 2333},
      {type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2334}
    ],
    experimental: {cache_file: {enabled: true},
      clash_api: {external_controller: "127.0.0.1:9090", secret: ""}},
    outbounds: ([
      {type: "selector", tag: "select", default: "urltest", outbounds: (["urltest"] + [$proxies[].tag])}
    ] + $proxies + [
      {type: "direct", tag: "direct"},
      {type: "urltest", tag: "urltest", outbounds: [$proxies[].tag]}
    ]),
    route: {
      auto_detect_interface: true, default_domain_resolver: "local", final: "select",
      rules: [
        {action: "sniff"},
        {protocol: "dns", action: "hijack-dns"},
        {rule_set: ["geosite-category-ads-all"], action: "reject"},
        {clash_mode: "direct", outbound: "direct"},
        {clash_mode: "global", outbound: "select"},
        {ip_is_private: true, outbound: "direct"},
        {rule_set: ["geosite-cn", "geoip-cn"], outbound: "direct"}
      ],
      rule_set: [
        {type: "remote", tag: "geosite-cn", format: "binary",
         url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs", download_detour: "select"},
        {type: "remote", tag: "geosite-category-ads-all", format: "binary",
         url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads-all.srs", download_detour: "select"},
        {type: "remote", tag: "geoip-cn", format: "binary",
         url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs", download_detour: "select"}
      ]
    }
  }
