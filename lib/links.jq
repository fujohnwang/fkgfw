def host: if contains(":") then "[" + . + "]" else . end;
.outbounds[]
| if .tag == "sing-box-reality" then
    "vless://\(.uuid)@\(.server | host):\(.server_port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\(.tls.server_name | @uri)&fp=chrome&pbk=\(.tls.reality.public_key | @uri)&sid=\(.tls.reality.short_id | @uri)&type=tcp#Reality"
  elif .tag == "sing-box-hysteria2" then
    "hysteria2://\(.password | @uri)@\(.server | host):\(.server_port)?insecure=1&sni=\(.tls.server_name | @uri)#Hysteria2"
  elif .tag == "sing-box-vmess" then
    "vmess://" + ({v: "2", ps: "VMess-WS", add: .server, port: (.server_port | tostring),
      id: .uuid, aid: "0", net: "ws", type: "none", host: .tls.server_name,
      path: .transport.path, tls: "tls", sni: .tls.server_name} | tojson | @base64)
  elif .tag == "sing-box-vless-ws" then
    "vless://\(.uuid)@\(.server | host):\(.server_port)?encryption=none&security=tls&sni=\(.tls.server_name | @uri)&type=ws&host=\(.tls.server_name | @uri)&path=\(.transport.path | @uri)#VLESS-WS"
  else empty end
