#!/bin/bash

# Security warning
echo "=========================================="
echo "安全提示 / Security Notice"
echo "=========================================="
echo "此脚本将会："
echo "1. 下载并安装 sing-box 和 cloudflared 二进制文件"
echo "2. 创建系统服务并以专用用户运行"
echo "3. 生成加密密钥和证书"
echo "4. 启动 cloudflared tunnel (会暴露本地端口到公网)"
echo ""
echo "请确保："
echo "- 你信任此脚本的来源"
echo "- 你已经审查过脚本内容"
echo "- 你的系统已经做好备份"
echo "- 你了解 cloudflared tunnel 的安全风险"
echo "=========================================="
echo ""
read -p "是否继续安装? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "安装已取消"
    exit 0
fi
echo ""

# Function to print characters with delay
print_with_delay() {
    text="$1"
    delay="$2"
    for ((i = 0; i < ${#text}; i++)); do
        echo -n "${text:$i:1}"
        sleep $delay
    done
    echo
}
#notice
show_notice() {
    local message="$1"

    echo "#######################################################################################################################"
    echo "                                                                                                                       "
    echo "                                ${message}                                                                             "
    echo "                                                                                                                       "
    echo "#######################################################################################################################"
}
# Introduction animation
echo ""
echo ""

# Check root privileges FIRST
if [ "$EUID" -ne 0 ]; then 
    echo "错误: 此脚本需要 root 权限运行"
    echo "请使用: sudo bash $0"
    exit 1
fi

# install base
install_base(){
  # Check if jq is installed, and install it if not
  if ! command -v jq &> /dev/null; then
      echo "jq is not installed. Installing..."
      if [ -n "$(command -v apt)" ]; then
          apt update > /dev/null 2>&1
          apt install -y jq > /dev/null 2>&1
      elif [ -n "$(command -v yum)" ]; then
          yum install -y epel-release
          yum install -y jq
      elif [ -n "$(command -v dnf)" ]; then
          dnf install -y jq
      else
          echo "Cannot install jq. Please install jq manually and rerun the script."
          exit 1
      fi
  fi
}

# Create dedicated user for sing-box
create_singbox_user(){
  if ! id -u singbox &> /dev/null; then
      echo "创建 singbox 专用用户..."
      useradd -r -s /sbin/nologin -M singbox
      echo "singbox 用户创建完成"
  else
      echo "singbox 用户已存在"
  fi
}

# Verify file checksum
verify_checksum(){
  local file="$1"
  local expected_checksum="$2"
  
  if [ -z "$expected_checksum" ]; then
      echo "警告: 未提供校验和，跳过验证"
      return 0
  fi
  
  echo "验证文件完整性..."
  local actual_checksum=$(sha256sum "$file" | awk '{print $1}')
  
  if [ "$actual_checksum" = "$expected_checksum" ]; then
      echo "✓ 文件校验通过"
      return 0
  else
      echo "✗ 文件校验失败!"
      echo "期望: $expected_checksum"
      echo "实际: $actual_checksum"
      return 1
  fi
}

# Set secure file permissions
set_secure_permissions(){
  echo "设置安全文件权限..."
  
  # Create and protect sing-box config directory
  mkdir -p /etc/sing-box
  chown singbox:singbox /etc/sing-box
  chmod 755 /etc/sing-box
  
  # Protect configuration files
  if [ -f "/etc/sing-box/config.json" ]; then
      chmod 600 /etc/sing-box/config.json
      chown singbox:singbox /etc/sing-box/config.json
  fi
  
  # Protect key files
  if [ -f "/etc/sing-box/public.key.b64" ]; then
      chmod 600 /etc/sing-box/public.key.b64
      chown singbox:singbox /etc/sing-box/public.key.b64
  fi
  
  if [ -f "/etc/sing-box/argo.txt.b64" ]; then
      chmod 600 /etc/sing-box/argo.txt.b64
      chown singbox:singbox /etc/sing-box/argo.txt.b64
  fi
  
  # Protect certificate directory
  if [ -d "/etc/sing-box/certs" ]; then
      chmod 700 /etc/sing-box/certs
      chown -R singbox:singbox /etc/sing-box/certs
      chmod 600 /etc/sing-box/certs/*.pem 2>/dev/null || true
      chmod 600 /etc/sing-box/certs/*.key 2>/dev/null || true
  fi
  
  echo "文件权限设置完成"
}
# regenrate cloudflared argo using systemd
regenarte_cloudflared_argo(){
  echo "重启 cloudflared 服务..."
  systemctl restart cloudflared
  sleep 10
  
  # Read argo domain from file
  if [ -f "/etc/sing-box/argo.txt.b64" ]; then
      argo=$(base64 --decode /etc/sing-box/argo.txt.b64)
      echo "Cloudflared tunnel 地址: $argo"
  else
      echo "错误: 无法找到 argo 地址文件"
      echo "请检查日志: journalctl -u cloudflared -n 50"
      return 1
  fi
}
# download singbox and cloudflared
download_singbox(){
  arch=$(uname -m)
  echo "Architecture: $arch"
  # Map architecture names
  case ${arch} in
      x86_64)
          arch="amd64"
          ;;
      aarch64)
          arch="arm64"
          ;;
      armv7l)
          arch="armv7"
          ;;
  esac
  # Fetch the latest (including pre-releases) release version number from GitHub API
  # 正式版
  #latest_version_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | grep -Po '"tag_name": "\K.*?(?=")' | head -n 1)
  #beta版本
  latest_version_tag=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases" | grep -Po '"tag_name": "\K.*?(?=")' | sort -V | tail -n 1)
  latest_version=${latest_version_tag#v}  # Remove 'v' prefix from version number
  echo "Latest version: $latest_version"
  # Detect server architecture
  # Prepare package names
  package_name="sing-box-${latest_version}-linux-${arch}"
  # Prepare download URL
  url="https://github.com/SagerNet/sing-box/releases/download/${latest_version_tag}/${package_name}.tar.gz"
  checksum_url="https://github.com/SagerNet/sing-box/releases/download/${latest_version_tag}/${package_name}.tar.gz.sha256sum"
  
  echo "正在下载 sing-box..."
  # Download the latest release package (.tar.gz) from GitHub
  max_retries=3
  retry_count=0
  while [ $retry_count -lt $max_retries ]; do
      if curl -sL --fail --connect-timeout 30 --max-time 300 -o "/root/${package_name}.tar.gz" "$url"; then
          break
      else
          retry_count=$((retry_count + 1))
          if [ $retry_count -lt $max_retries ]; then
              echo "下载失败，重试 $retry_count/$max_retries..."
              sleep 3
          else
              echo "错误: sing-box 下载失败（已重试 $max_retries 次）"
              echo "URL: $url"
              exit 1
          fi
      fi
  done

  # Try to download and verify checksum
  echo "尝试验证文件完整性..."
  http_code=$(curl -sL -w "%{http_code}" -o "/root/${package_name}.tar.gz.sha256sum" "$checksum_url")
  
  if [ "$http_code" = "200" ] && [ -s "/root/${package_name}.tar.gz.sha256sum" ]; then
      # Check if file contains valid checksum (not HTML error page)
      expected_checksum=$(cat "/root/${package_name}.tar.gz.sha256sum" | awk '{print $1}')
      if [[ "$expected_checksum" =~ ^[a-f0-9]{64}$ ]]; then
          if ! verify_checksum "/root/${package_name}.tar.gz" "$expected_checksum"; then
              echo "错误: 文件校验失败，可能被篡改"
              rm -f "/root/${package_name}.tar.gz" "/root/${package_name}.tar.gz.sha256sum"
              exit 1
          fi
          echo "✓ 文件完整性验证通过"
      else
          echo "警告: 校验和文件格式无效，跳过验证"
      fi
      rm -f "/root/${package_name}.tar.gz.sha256sum"
  else
      echo "提示: sing-box 项目未提供校验和文件"
      echo "      已从官方 GitHub 仓库下载，风险相对较低"
      echo "      建议: 手动验证文件来源的可信度"
  fi

  # Extract the package and move the binary to /usr/local/bin
  echo "解压文件..."
  tar -xzf "/root/${package_name}.tar.gz" -C /root
  
  # Ensure /usr/local/bin exists
  mkdir -p /usr/local/bin
  
  mv "/root/${package_name}/sing-box" /usr/local/bin/sing-box

  # Cleanup the package
  rm -r "/root/${package_name}.tar.gz" "/root/${package_name}"

  # Set the permissions
  chown root:root /usr/local/bin/sing-box
  chmod 755 /usr/local/bin/sing-box
  
  # Set capabilities to allow binding privileged ports
  echo "设置 sing-box capabilities..."
  setcap 'cap_net_bind_service=+ep' /usr/local/bin/sing-box
  
  echo "sing-box 下载完成"
}

# download singbox and cloudflared
download_cloudflared(){
  arch=$(uname -m)
  # Map architecture names
  case ${arch} in
      x86_64)
          cf_arch="amd64"
          ;;
      aarch64)
          cf_arch="arm64"
          ;;
      armv7l)
          cf_arch="arm"
          ;;
  esac

  echo "正在下载 cloudflared..."
  
  # Ensure /usr/local/bin exists
  mkdir -p /usr/local/bin
  
  # Check if cloudflared is running and stop it
  if [ -f "/usr/local/bin/cloudflared" ]; then
      echo "检测到已存在的 cloudflared，停止相关进程..."
      systemctl stop cloudflared 2>/dev/null || true
      pkill -9 cloudflared 2>/dev/null || true
      sleep 2
      # Remove old file
      rm -f /usr/local/bin/cloudflared
  fi
  
  # install cloudflared linux
  cf_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"
  
  # Download to temp location first
  temp_file="/tmp/cloudflared.tmp.$$"
  
  # Try download with retry (show progress, not silent)
  max_retries=3
  retry_count=0
  while [ $retry_count -lt $max_retries ]; do
      echo "尝试下载 ($((retry_count + 1))/$max_retries)..."
      if curl -L --fail --connect-timeout 30 --max-time 300 --progress-bar -o "$temp_file" "$cf_url" 2>&1; then
          echo "✓ cloudflared 下载完成"
          # Move to final location
          mv "$temp_file" /usr/local/bin/cloudflared
          chown root:root /usr/local/bin/cloudflared
          chmod 755 /usr/local/bin/cloudflared
          echo ""
          return 0
      else
          retry_count=$((retry_count + 1))
          rm -f "$temp_file"
          if [ $retry_count -lt $max_retries ]; then
              echo "✗ 下载失败，3秒后重试..."
              sleep 3
          fi
      fi
  done
  
  echo ""
  echo "错误: cloudflared 下载失败（已重试 $max_retries 次）"
  echo "URL: $cf_url"
  echo ""
  echo "请尝试手动下载并放置到正确位置："
  echo "  sudo curl -L -o /usr/local/bin/cloudflared $cf_url"
  echo "  sudo chmod 755 /usr/local/bin/cloudflared"
  echo ""
  echo "然后重新运行脚本"
  exit 1
}

# Create cloudflared systemd service
create_cloudflared_service(){
  local vmess_port="$1"
  local vless_ws_port="$2"
  local vmess_path="$3"
  local vless_ws_path="$4"
  
  # Create directory for argo file
  mkdir -p /etc/sing-box

  # Ensure paths start with /
  [[ $vmess_path != /* ]] && vmess_path="/$vmess_path"
  [[ $vless_ws_path != /* ]] && vless_ws_path="/$vless_ws_path"

  # Create cloudflared ingress config (multi-path routing)
  cat > /etc/sing-box/cloudflared_config.yml <<CFEOF
ingress:
  - path: ${vmess_path}
    service: http://localhost:${vmess_port}
  - path: ${vless_ws_path}
    service: http://localhost:${vless_ws_port}
  - service: http_status:404
CFEOF
  chown singbox:singbox /etc/sing-box/cloudflared_config.yml
  chmod 600 /etc/sing-box/cloudflared_config.yml

  # Create a helper script for ExecStartPost to avoid escaping issues
  cat > /usr/local/bin/cloudflared-post-start.sh <<'SCRIPT'
#!/bin/bash
sleep 8
grep -oP "https://[a-z0-9-]+\.trycloudflare\.com" /var/log/cloudflared.log | head -1 | sed 's|https://||' | base64 > /etc/sing-box/argo.txt.b64
chown singbox:singbox /etc/sing-box/argo.txt.b64
chmod 600 /etc/sing-box/argo.txt.b64
SCRIPT
  chmod 755 /usr/local/bin/cloudflared-post-start.sh
  
  cat > /etc/systemd/system/cloudflared.service <<EOF
[Unit]
Description=Cloudflared Tunnel
After=network.target sing-box.service
Wants=network.target

[Service]
Type=simple
User=singbox
Group=singbox
ExecStartPre=/bin/sleep 3
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/sing-box/cloudflared_config.yml --no-autoupdate --edge-ip-version auto --protocol h2mux --logfile /var/log/cloudflared.log
ExecStartPost=/usr/local/bin/cloudflared-post-start.sh
Restart=on-failure
RestartSec=10
StandardOutput=append:/var/log/cloudflared.log
StandardError=append:/var/log/cloudflared.log
# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log /etc/sing-box
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF

  # Create log file with proper permissions
  touch /var/log/cloudflared.log
  chown singbox:singbox /var/log/cloudflared.log
  chmod 644 /var/log/cloudflared.log
  
  # Set permissions for sing-box config directory
  chown singbox:singbox /etc/sing-box
  chmod 755 /etc/sing-box
}


# client configuration
show_client_configuration() {
  # Get current listen port
  current_listen_port=$(jq -r '.inbounds[0].listen_port' /etc/sing-box/config.json)
  # Get current server name
  current_server_name=$(jq -r '.inbounds[0].tls.server_name' /etc/sing-box/config.json)
  # Get the UUID
  uuid=$(jq -r '.inbounds[0].users[0].uuid' /etc/sing-box/config.json)
  # Get the public key from the file, decoding it from base64
  public_key=$(base64 --decode /etc/sing-box/public.key.b64)
  # Get the short ID
  short_id=$(jq -r '.inbounds[0].tls.reality.short_id[0]' /etc/sing-box/config.json)
  # Retrieve the server IP address
  server_ip=$(curl -s4m8 ip.sb -k) || server_ip=$(curl -s6m8 ip.sb -k)
  echo ""
  echo ""
  show_notice "Reality 客户端通用链接" 
  echo ""
  echo ""
  server_link="vless://$uuid@$server_ip:$current_listen_port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$current_server_name&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#SING-BOX-Reality"
  echo ""
  echo ""
  echo "$server_link"
  echo ""
  echo ""
  # Print the server details
  show_notice "Reality 客户端通用参数" 
  echo ""
  echo ""
  echo "服务器ip: $server_ip"
  echo "监听端口: $current_listen_port"
  echo "UUID: $uuid"
  echo "域名SNI: $current_server_name"
  echo "Public Key: $public_key"
  echo "Short ID: $short_id"
  echo ""
  echo ""
  # Get current listen port
  hy_current_listen_port=$(jq -r '.inbounds[1].listen_port' /etc/sing-box/config.json)
  # Get current server name
  hy_current_server_name=$(openssl x509 -in /etc/sing-box/certs/cert.pem -noout -subject -nameopt RFC2253 | awk -F'=' '{print $NF}')
  # Get the password
  hy_password=$(jq -r '.inbounds[1].users[0].password' /etc/sing-box/config.json)
  # Generate the link
  
  hy2_server_link="hysteria2://$hy_password@$server_ip:$hy_current_listen_port?insecure=1&sni=$hy_current_server_name"

  show_notice "Hysteria2 客户端通用链接" 
  echo ""
  echo "官方 hysteria2通用链接格式"
  echo ""
  echo "$hy2_server_link"
  echo ""
  echo ""   
  # Print the server details
  show_notice "Hysteria2 客户端通用参数" 
  echo ""
  echo ""  
  echo "服务器ip: $server_ip"
  echo "端口号: $hy_current_listen_port"
  echo "password: $hy_password"
  echo "域名SNI: $hy_current_server_name"
  echo "跳过证书验证: True"
  echo ""
  echo ""


  argo=$(base64 --decode /etc/sing-box/argo.txt.b64)
  vmess_uuid=$(jq -r '.inbounds[2].users[0].uuid' /etc/sing-box/config.json)
  ws_path=$(jq -r '.inbounds[2].transport.path' /etc/sing-box/config.json | sed 's|^\/||')

  # VLESS-WS (inbounds[3])
  vless_ws_uuid=$(jq -r '.inbounds[3].users[0].uuid // empty' /etc/sing-box/config.json)
  vless_ws_path=$(jq -r '.inbounds[3].transport.path // empty' /etc/sing-box/config.json | sed 's|^\/||')

  show_notice "vmess ws 通用链接参数" 
  echo ""
  echo ""
  echo "以下为vmess链接，替换speed.cloudflare.com为自己的优选ip可获得极致体验"
  echo ""
  echo ""
  echo 'vmess://'$(echo '{"add":"speed.cloudflare.com","aid":"0","host":"'$argo'","id":"'$vmess_uuid'","net":"ws","path":"/'$ws_path'","port":"443","ps":"sing-box-vmess-tls","tls":"tls","type":"none","v":"2"}' | base64 -w 0)
  echo ""
  echo ""
  echo -e "端口 443 可改为 2053 2083 2087 2096 8443"
  echo ""
  echo ""
  echo 'vmess://'$(echo '{"add":"speed.cloudflare.com","aid":"0","host":"'$argo'","id":"'$vmess_uuid'","net":"ws","path":"/'$ws_path'","port":"80","ps":"sing-box-vmess","tls":"","type":"none","v":"2"}' | base64 -w 0)
  echo ""
  echo ""
  echo -e "端口 80 可改为 8080 8880 2052 2082 2086 2095" 
  echo ""
  echo ""

  if [ -n "$vless_ws_uuid" ]; then
    show_notice "VLESS WS 通用链接参数"
    echo ""
    echo "以下为vless ws链接，替换speed.cloudflare.com为自己的优选ip可获得极致体验"
    echo ""
    echo "vless://$vless_ws_uuid@speed.cloudflare.com:443?encryption=none&security=tls&sni=$argo&type=ws&host=$argo&path=%2F$vless_ws_path#sing-box-vless-ws-tls"
    echo ""
    echo -e "端口 443 可改为 2053 2083 2087 2096 8443"
    echo ""
    echo "vless://$vless_ws_uuid@speed.cloudflare.com:80?encryption=none&security=none&type=ws&host=$argo&path=%2F$vless_ws_path#sing-box-vless-ws"
    echo ""
    echo -e "端口 80 可改为 8080 8880 2052 2082 2086 2095"
    echo ""
    echo ""
  fi
  show_notice "clash-meta配置参数"
cat << EOF

port: 7890
allow-lan: true
mode: rule
log-level: info
unified-delay: true
global-client-fingerprint: chrome
ipv6: true
dns:
  enable: true
  listen: :53
  ipv6: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  default-nameserver: 
    - 223.5.5.5
    - 8.8.8.8
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  fallback:
    - https://1.0.0.1/dns-query
    - tls://dns.google
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4

proxies:        
  - name: Reality
    type: vless
    server: $server_ip
    port: $current_listen_port
    uuid: $uuid
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $current_server_name
    client-fingerprint: chrome
    reality-opts:
      public-key: $public_key
      short-id: $short_id

  - name: Hysteria2
    type: hysteria2
    server: $server_ip
    port: $hy_current_listen_port
    #  up和down均不写或为0则使用BBR流控
    # up: "30 Mbps" # 若不写单位，默认为 Mbps
    # down: "200 Mbps" # 若不写单位，默认为 Mbps
    password: $hy_password
    sni: $hy_current_server_name
    skip-cert-verify: true
    alpn:
      - h3
  - name: Vmess
    type: vmess
    server: speed.cloudflare.com
    port: 443
    uuid: $vmess_uuid
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    client-fingerprint: chrome  
    skip-cert-verify: true
    servername: $argo
    network: ws
    ws-opts:
      path: /$ws_path
      headers:
        Host: $argo
  - name: VLESS-WS
    type: vless
    server: speed.cloudflare.com
    port: 443
    uuid: $vless_ws_uuid
    udp: true
    tls: true
    client-fingerprint: chrome
    skip-cert-verify: true
    servername: $argo
    network: ws
    ws-opts:
      path: /$vless_ws_path
      headers:
        Host: $argo

proxy-groups:
  - name: 节点选择
    type: select
    proxies:
      - 自动选择
      - Reality
      - Hysteria2
      - Vmess
      - VLESS-WS
      - DIRECT

  - name: 自动选择
    type: url-test #选出延迟最低的机场节点
    proxies:
      - Reality
      - Hysteria2
      - Vmess
      - VLESS-WS
    url: "http://www.gstatic.com/generate_204"
    interval: 300
    tolerance: 50


rules:
    - GEOIP,LAN,DIRECT
    - GEOIP,CN,DIRECT
    - MATCH,节点选择

EOF

show_notice "sing-box客户端配置参数"
cat << EOF
{
    "dns": {
        "servers": [
            {
                "tag": "remote",
                "address": "https://1.1.1.1/dns-query",
                "detour": "select"
            },
            {
                "tag": "local",
                "address": "https://223.5.5.5/dns-query",
                "detour": "direct"
            },
            {
                "address": "rcode://success",
                "tag": "block"
            }
        ],
        "rules": [
            {
                "outbound": [
                    "any"
                ],
                "server": "local"
            },
            {
                "disable_cache": true,
                "geosite": [
                    "category-ads-all"
                ],
                "server": "block"
            },
            {
                "clash_mode": "global",
                "server": "remote"
            },
            {
                "clash_mode": "direct",
                "server": "local"
            },
            {
                "geosite": "cn",
                "server": "local"
            }
        ],
        "strategy": "prefer_ipv4"
    },
    "inbounds": [
        {
            "type": "tun",
            "inet4_address": "172.19.0.1/30",
            "inet6_address": "2001:0470:f9da:fdfa::1/64",
            "sniff": true,
            "sniff_override_destination": true,
            "domain_strategy": "prefer_ipv4",
            "stack": "mixed",
            "strict_route": true,
            "mtu": 9000,
            "endpoint_independent_nat": true,
            "auto_route": true
        },
        {
            "type": "socks",
            "tag": "socks-in",
            "listen": "127.0.0.1",
            "sniff": true,
            "sniff_override_destination": true,
            "domain_strategy": "prefer_ipv4",
            "listen_port": 2333,
            "users": []
        },
        {
            "type": "mixed",
            "tag": "mixed-in",
            "sniff": true,
            "sniff_override_destination": true,
            "domain_strategy": "prefer_ipv4",
            "listen": "127.0.0.1",
            "listen_port": 2334,
            "users": []
        }
    ],
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "secret": "",
      "store_selected": true
    }
  },
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "outbounds": [
    {
      "tag": "select",
      "type": "selector",
      "default": "urltest",
      "outbounds": [
        "urltest",
        "sing-box-reality",
        "sing-box-hysteria2",
        "sing-box-vmess",
        "sing-box-vless-ws"
      ]
    },
    {
      "type": "vless",
      "tag": "sing-box-reality",
      "uuid": "$uuid",
      "flow": "xtls-rprx-vision",
      "packet_encoding": "xudp",
      "server": "$server_ip",
      "server_port": $current_listen_port,
      "tls": {
        "enabled": true,
        "server_name": "$current_server_name",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        },
        "reality": {
          "enabled": true,
          "public_key": "$public_key",
          "short_id": "$short_id"
        }
      }
    },
    {
            "type": "hysteria2",
            "server": "$server_ip",
            "server_port": $hy_current_listen_port,
            "tag": "sing-box-hysteria2",
            
            "up_mbps": 100,
            "down_mbps": 100,
            "password": "$hy_password",
            "tls": {
                "enabled": true,
                "server_name": "$hy_current_server_name",
                "insecure": true,
                "alpn": [
                    "h3"
                ]
            }
        },
        {
            "server": "speed.cloudflare.com",
            "server_port": 443,
            "tag": "sing-box-vmess",
            "tls": {
                "enabled": true,
                "server_name": "$argo",
                "insecure": true,
                "utls": {
                    "enabled": true,
                    "fingerprint": "chrome"
                }
            },
            "transport": {
                "headers": {
                    "Host": [
                        "$argo"
                    ]
                },
                "path": "/$ws_path",
                "type": "ws"
            },
            "type": "vmess",
            "security": "auto",
            "uuid": "$vmess_uuid"
        },
        {
            "server": "speed.cloudflare.com",
            "server_port": 443,
            "tag": "sing-box-vless-ws",
            "tls": {
                "enabled": true,
                "server_name": "$argo",
                "insecure": true,
                "utls": {
                    "enabled": true,
                    "fingerprint": "chrome"
                }
            },
            "transport": {
                "headers": {
                    "Host": [
                        "$argo"
                    ]
                },
                "path": "/$vless_ws_path",
                "type": "ws"
            },
            "type": "vless",
            "uuid": "$vless_ws_uuid"
        },
    {
      "tag": "direct",
      "type": "direct"
    },
    {
      "tag": "block",
      "type": "block"
    },
    {
      "tag": "dns-out",
      "type": "dns"
    },
    {
      "tag": "urltest",
      "type": "urltest",
      "outbounds": [
        "sing-box-reality",
        "sing-box-hysteria2",
        "sing-box-vmess",
        "sing-box-vless-ws"
      ]
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "rules": [
      {
        "geosite": "category-ads-all",
        "outbound": "block"
      },
      {
        "outbound": "dns-out",
        "protocol": "dns"
      },
      {
        "clash_mode": "direct",
        "outbound": "direct"
      },
      {
        "clash_mode": "global",
        "outbound": "select"
      },
      {
        "geoip": [
          "cn",
          "private"
        ],
        "outbound": "direct"
      },
      {
        "geosite": "geolocation-!cn",
        "outbound": "select"
      },
      {
        "geosite": "cn",
        "outbound": "direct"
      }
    ],
    "geoip": {
            "download_detour": "select"
        },
    "geosite": {
            "download_detour": "select"
        }
  }
}
EOF

}
uninstall_singbox() {
          echo "Uninstalling..."
          # Stop and disable services
          systemctl stop sing-box cloudflared 2>/dev/null
          systemctl disable sing-box cloudflared > /dev/null 2>&1

          # Remove service files
          rm -f /etc/systemd/system/sing-box.service
          rm -f /etc/systemd/system/cloudflared.service
          systemctl daemon-reload
          
          # Remove binaries
          rm -f /usr/local/bin/sing-box
          rm -f /usr/local/bin/cloudflared
          
          # Remove configuration and data
          rm -rf /etc/sing-box/
          rm -f /var/log/cloudflared.log
          
          # Remove user (optional, commented out for safety)
          # userdel singbox 2>/dev/null
          
          echo "DONE!"
}
install_base

# Check if reality.json, sing-box, and sing-box.service already exist
if [ -f "/etc/sing-box/config.json" ] && [ -f "/usr/local/bin/sing-box" ] && [ -f "/etc/sing-box/public.key.b64" ] && [ -f "/etc/sing-box/argo.txt.b64" ] && [ -f "/etc/systemd/system/sing-box.service" ]; then

    echo "sing-box-reality-hysteria2已经安装"
    echo ""
    echo "请选择选项:"
    echo ""
    echo "1. 重新安装"
    echo "2. 修改配置"
    echo "3. 显示客户端配置"
    echo "4. 卸载"
    echo "5. 更新sing-box内核"
    echo "6. 手动重启cloudflared（vps重启之后需要执行一次这个来更新vmess）"
    echo ""
    read -p "Enter your choice (1-6): " choice

    case $choice in
        1)
          show_notice "Reinstalling..."
          # Uninstall previous installation
          systemctl stop sing-box cloudflared 2>/dev/null
          systemctl disable sing-box cloudflared > /dev/null 2>&1
          rm -f /etc/systemd/system/sing-box.service
          rm -f /etc/systemd/system/cloudflared.service
          rm -rf /etc/sing-box/
          rm -f /usr/local/bin/sing-box
          rm -f /usr/local/bin/cloudflared
          rm -f /var/log/cloudflared.log
          
          # Proceed with installation
        ;;
        2)
          #Reality modify
          show_notice "开始修改reality端口号和域名"
          # Get current listen port
          current_listen_port=$(jq -r '.inbounds[0].listen_port' /etc/sing-box/config.json)

          # Ask for listen port
          read -p "请输入想要修改的端口号 (当前端口号为 $current_listen_port): " listen_port
          listen_port=${listen_port:-$current_listen_port}

          # Get current server name
          current_server_name=$(jq -r '.inbounds[0].tls.server_name' /etc/sing-box/config.json)

          # Ask for server name (sni)
          read -p "请输入想要偷取的域名 (当前域名为 $current_server_name): " server_name
          server_name=${server_name:-$current_server_name}
          echo ""
          # modifying hysteria2 configuration
          show_notice "开始修改hysteria2端口号"
          echo ""
          # Get current listen port
          hy_current_listen_port=$(jq -r '.inbounds[1].listen_port' /etc/sing-box/config.json)
          
          # Ask for listen port
          read -p "请属于想要修改的端口号 (当前端口号为 $hy_current_listen_port): " hy_listen_port
          hy_listen_port=${hy_listen_port:-$hy_current_listen_port}

          # Modify reality.json with new settings
          jq --arg listen_port "$listen_port" --arg server_name "$server_name" --arg hy_listen_port "$hy_listen_port" '.inbounds[1].listen_port = ($hy_listen_port | tonumber) | .inbounds[0].listen_port = ($listen_port | tonumber) | .inbounds[0].tls.server_name = $server_name | .inbounds[0].tls.reality.handshake.server = $server_name' /etc/sing-box/config.json > /tmp/sb_modified.json
          mv /tmp/sb_modified.json /etc/sing-box/config.json
          chmod 600 /etc/sing-box/config.json
          chown singbox:singbox /etc/sing-box/config.json

          # Restart sing-box service
          systemctl restart sing-box
          # show client configuration
          show_client_configuration
          exit 0
        ;;
      3)  
          # show client configuration
          show_client_configuration
          exit 0
      ;;	
      4)
          uninstall_singbox
          exit 0
          ;;
      5)
          show_notice "Update Sing-box..."
          download_singbox
          # Check configuration and start the service
          if /usr/local/bin/sing-box check -c /etc/sing-box/config.json; then
              echo "Configuration checked successfully. Starting sing-box service..."
              systemctl daemon-reload
              systemctl enable sing-box > /dev/null 2>&1
              systemctl start sing-box
              systemctl restart sing-box
          fi
          echo ""  
          exit 1
          ;;
      6)
          regenarte_cloudflared_argo
          echo "重新启动完成，查看新的vmess客户端信息"
          show_client_configuration
          exit 1
          ;;
      *)
          echo "Invalid choice. Exiting."
          exit 1
          ;;
	esac
	fi

mkdir -p "/etc/sing-box"
mkdir -p "/etc/sing-box/certs"

# Create singbox user first (needed for services and permissions)
create_singbox_user

download_singbox

download_cloudflared

# reality
echo "开始配置Reality"
echo ""
# Generate key pair
echo "自动生成基本参数"
echo ""
key_pair=$(/usr/local/bin/sing-box generate reality-keypair)
echo "Key pair生成完成"
echo ""

# Extract private key and public key
private_key=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
public_key=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')

# Save the public key in a file using base64 encoding
echo "$public_key" | base64 > /etc/sing-box/public.key.b64

# Generate necessary values
uuid=$(/usr/local/bin/sing-box generate uuid)
short_id=$(/usr/local/bin/sing-box generate rand --hex 8)
echo "uuid和短id 生成完成"
echo ""
# Ask for listen port
read -p "请输入Reality端口号 (default: 443): " listen_port
listen_port=${listen_port:-443}

# Check if port is already in use
if netstat -tuln 2>/dev/null | grep -q ":${listen_port} " || ss -tuln 2>/dev/null | grep -q ":${listen_port} "; then
    echo ""
    echo "警告: 端口 $listen_port 已被占用"
    echo "正在检查占用进程..."
    lsof -i :${listen_port} 2>/dev/null || ss -tulnp | grep ":${listen_port} "
    echo ""
    read -p "是否要停止占用该端口的进程并继续? (yes/no): " kill_process
    if [ "$kill_process" = "yes" ]; then
        fuser -k ${listen_port}/tcp 2>/dev/null || true
        sleep 2
        echo "已尝试释放端口 $listen_port"
    else
        echo "请选择其他端口或手动停止占用进程后重试"
        exit 1
    fi
fi

echo ""
# Ask for server name (sni)
read -p "请输入想要偷取的域名 (default: itunes.apple.com): " server_name
server_name=${server_name:-itunes.apple.com}
echo ""
# hysteria2
echo "开始配置hysteria2"
echo ""
# Generate hysteria necessary values
hy_password=$(/usr/local/bin/sing-box generate rand --hex 8)

# Ask for listen port
read -p "请输入hysteria2监听端口 (default: 8443): " hy_listen_port
hy_listen_port=${hy_listen_port:-8443}
echo ""

# Ask for self-signed certificate domain
read -p "输入自签证书域名 (default: bing.com): " hy_server_name
hy_server_name=${hy_server_name:-bing.com}
mkdir -p /etc/sing-box/certs && openssl ecparam -genkey -name prime256v1 -out /etc/sing-box/certs/private.key && openssl req -new -x509 -days 36500 -key /etc/sing-box/certs/private.key -out /etc/sing-box/certs/cert.pem -subj "/CN=${hy_server_name}"
echo ""
echo "自签证书生成完成"
echo ""
# vmess ws
echo "开始配置vmess"
echo ""
# Generate hysteria necessary values
vmess_uuid=$(/usr/local/bin/sing-box generate uuid)
read -p "请输入vmess端口，默认为18443(和tunnel通信用不会暴露在外): " vmess_port
vmess_port=${vmess_port:-18443}
echo ""
read -p "vmess ws路径 (无需加斜杠,默认随机生成): " ws_path
ws_path=${ws_path:-$(/usr/local/bin/sing-box generate rand --hex 6)}
ws_path=$(echo "$ws_path" | sed 's|^\/||')

echo ""
# vless ws
echo "开始配置VLESS WS (Argo)"
echo ""
vless_ws_uuid=$(/usr/local/bin/sing-box generate uuid)
read -p "请输入vless ws端口，默认为18444(和tunnel通信用不会暴露在外): " vless_ws_port
vless_ws_port=${vless_ws_port:-18444}
echo ""
read -p "vless ws路径 (无需加斜杠,默认随机生成): " vless_ws_path
vless_ws_path=${vless_ws_path:-$(/usr/local/bin/sing-box generate rand --hex 6)}
vless_ws_path=$(echo "$vless_ws_path" | sed 's|^\/||')

# Stop any existing cloudflared process
systemctl stop cloudflared 2>/dev/null
pkill -f cloudflared 2>/dev/null

# Create cloudflared service (multi-path ingress)
create_cloudflared_service "$vmess_port" "$vless_ws_port" "$ws_path" "$vless_ws_path"

# Start cloudflared and wait for tunnel
echo "启动 cloudflared tunnel..."
systemctl daemon-reload
systemctl enable cloudflared > /dev/null 2>&1
systemctl start cloudflared

echo "等待 cloudflare argo 生成地址..."
sleep 10

# Read argo domain from file
if [ -f "/etc/sing-box/argo.txt.b64" ]; then
    argo=$(base64 --decode /etc/sing-box/argo.txt.b64)
    if [ -z "$argo" ]; then
        echo "警告: argo 地址为空，尝试从日志读取..."
        sleep 5
        argo=$(grep -oP "https://[a-z0-9-]+\.trycloudflare\.com" /var/log/cloudflared.log 2>/dev/null | head -1 | sed 's|https://||')
        if [ -n "$argo" ]; then
            echo "$argo" | base64 > /etc/sing-box/argo.txt.b64
            chmod 600 /etc/sing-box/argo.txt.b64
            chown singbox:singbox /etc/sing-box/argo.txt.b64
        else
            echo "错误: 无法获取 argo 地址"
            echo "请检查日志: tail -50 /var/log/cloudflared.log"
            exit 1
        fi
    fi
else
    echo "错误: 无法找到 argo 地址文件"
    exit 1
fi

echo "Cloudflared tunnel 地址: $argo"


# Retrieve the server IP address
server_ip=$(curl -s4m8 ip.sb -k) || server_ip=$(curl -s6m8 ip.sb -k)

# Create server config.json using jq
jq -n --arg listen_port "$listen_port" --arg vmess_port "$vmess_port" --arg vmess_uuid "$vmess_uuid" --arg ws_path "/$ws_path" --arg vless_ws_port "$vless_ws_port" --arg vless_ws_uuid "$vless_ws_uuid" --arg vless_ws_path "/$vless_ws_path" --arg server_name "$server_name" --arg private_key "$private_key" --arg short_id "$short_id" --arg uuid "$uuid" --arg hy_listen_port "$hy_listen_port" --arg hy_password "$hy_password" --arg server_ip "$server_ip" '{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ($listen_port | tonumber),
      "users": [
        {
          "uuid": $uuid,
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": $server_name,
          "reality": {
          "enabled": true,
          "handshake": {
            "server": $server_name,
            "server_port": 443
          },
          "private_key": $private_key,
          "short_id": [$short_id]
        }
      }
    },
    {
        "type": "hysteria2",
        "tag": "hy2-in",
        "listen": "::",
        "listen_port": ($hy_listen_port | tonumber),
        "users": [
            {
                "password": $hy_password
            }
        ],
        "tls": {
            "enabled": true,
            "alpn": [
                "h3"
            ],
            "certificate_path": "/etc/sing-box/certs/cert.pem",
            "key_path": "/etc/sing-box/certs/private.key"
        }
    },
    {
        "type": "vmess",
        "tag": "vmess-in",
        "listen": "::",
        "listen_port": ($vmess_port | tonumber),
        "users": [
            {
                "uuid": $vmess_uuid,
                "alterId": 0
            }
        ],
        "transport": {
            "type": "ws",
            "path": $ws_path
        }
    },
    {
        "type": "vless",
        "tag": "vless-ws-in",
        "listen": "::",
        "listen_port": ($vless_ws_port | tonumber),
        "users": [
            {
                "uuid": $vless_ws_uuid
            }
        ],
        "transport": {
            "type": "ws",
            "path": $vless_ws_path
        }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ]
}' > /etc/sing-box/config.json

# Set secure permissions for config file
chmod 600 /etc/sing-box/config.json
chown singbox:singbox /etc/sing-box/config.json

# Set permissions for keys and certs
set_secure_permissions

# Create sing-box.service with dedicated user
cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=singbox
Group=singbox
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=23
LimitNOFILE=infinity
# Capabilities for binding privileged ports
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/sing-box
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=false
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF


# Check configuration and start the service
if /usr/local/bin/sing-box check -c /etc/sing-box/config.json; then
    echo "Configuration checked successfully. Starting sing-box service..."
    systemctl daemon-reload
    systemctl enable sing-box > /dev/null 2>&1
    systemctl start sing-box
    
    # Wait for sing-box to start
    sleep 2
    
    # Check if services are running
    if systemctl is-active --quiet sing-box && systemctl is-active --quiet cloudflared; then
        echo "✓ 所有服务启动成功"
        show_client_configuration
    else
        echo "警告: 部分服务可能未正常启动"
        echo "sing-box 状态: $(systemctl is-active sing-box)"
        echo "cloudflared 状态: $(systemctl is-active cloudflared)"
        echo ""
        echo "请检查日志:"
        echo "  journalctl -u sing-box -n 50"
        echo "  journalctl -u cloudflared -n 50"
    fi
else
    echo "Error in configuration. Aborting"
    exit 1
fi
