# Input: parameters collected only for a newly selected protocol.
if .tag == "vless-in" then
  {type: "vless", tag: .tag, listen: "::", listen_port: .port,
   users: [{uuid: .uuid, flow: "xtls-rprx-vision"}],
   tls: {enabled: true, server_name: .server_name, reality: {
     enabled: true, handshake: {server: .server_name, server_port: 443},
     private_key: .private_key, short_id: [.short_id]}}}
elif .tag == "hy2-in" then
  {type: "hysteria2", tag: .tag, listen: "::", listen_port: .port,
   users: [{password: .password}], tls: {enabled: true, alpn: ["h3"],
     certificate_path: "/etc/sing-box/certs/cert.pem", key_path: "/etc/sing-box/certs/private.key"}}
elif .tag == "vmess-in" or .tag == "vless-ws-in" then
  {type: (if .tag == "vmess-in" then "vmess" else "vless" end), tag: .tag,
   listen: "127.0.0.1", listen_port: .port, users: [{uuid: .uuid}],
   transport: {type: "ws", path: .path}}
else error("Unknown protocol tag") end
