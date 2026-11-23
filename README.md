# fkgfw 服务端部署

支持 **Reality、Hysteria2、VMess WS、VLESS WS、VLESS TLS + Vision、AnyTLS、Shadowsocks 2022（AES-256-GCM）** 七种协议的任意非空组合，共 127 种。WebSocket 通过 Caddy + Cloudflare Quick Tunnel 接入。

也可单独部署 **DSVPN v2**，或将它追加到已有服务器。DSVPN 服务和配套客户端下载由独立的 systemd 单元运行。

## 安装

需要使用 systemd 的 Linux 服务器、root 权限，支持 x86_64、aarch64、armv7l。脚本自动补齐 curl、jq、openssl、flock 等依赖。

```bash
git clone https://github.com/fujohnwang/fkgfw
cd fkgfw
sudo bash install.sh
```

安装菜单：

| 选项 | 协议组合 |
| --- | --- |
| 1 | 仅 Reality |
| 2 | 仅 Hysteria2 |
| 3 | Reality + Hysteria2 |
| 4 | VMess WS + VLESS WS |
| 5 | 原四种：Reality + Hysteria2 + VMess WS + VLESS WS |
| 6 | 自定义多选 |
| 7 | 仅 VLESS TLS + Vision |
| 8 | 仅 AnyTLS |
| 9 | VLESS TLS + Vision + AnyTLS |
| 10 | 全部七种（含 Shadowsocks） |
| 11 | Shadowsocks 2022（AES-256-GCM）：新部署单独安装，已有部署追加 |
| 12 | 安装或管理 DSVPN 及其客户端下载 |

自定义模式中，`1=Reality`、`2=Hysteria2`、`3=VMess WS`、`4=VLESS WS`、`5=VLESS TLS + Vision`、`6=AnyTLS`、`7=Shadowsocks`。例如输入 `2,5,6,7` 安装 Hysteria2 + VLESS TLS + Vision + AnyTLS + Shadowsocks。原有默认组合和菜单 1–6 的含义保留。

两个入口都支持全部组合，也能管理对方创建的安装：

- `sudo bash install.sh`：新安装默认选项 3。
- `sudo bash reality_hy2_ws.sh`：新安装默认选项 5。

使用 `sudo sh install.sh` 或 `sudo sh reality_hy2_ws.sh` 时，入口会自动切换到 Bash。必须保留整个仓库的 `lib/` 目录，不能只复制入口脚本。

已有旧部署、准备切换到新版时，先运行下面的 `migration.sh` 完成一次性清理，再运行安装入口。

只安装直连协议时不下载、配置或启动 Caddy / cloudflared。只有 Reality 生成 Reality 密钥，只有 Hysteria2 生成自签名证书。涉及公网直连时会自动探测服务器地址；也可指定：

```bash
sudo env SERVER_ADDRESS=203.0.113.10 bash install.sh
```

### Shadowsocks 2022

选择安装选项 **11**，固定使用 `2022-blake3-aes-256-gcm`，自动生成 32 字节随机密钥并以 Base64 保存。只需填写端口，默认 **8388/TCP+UDP**；无需域名、证书、Caddy 或 Cloudflare Tunnel。请在服务器防火墙放行所选端口的 TCP 和 UDP，脚本不修改防火墙。

已有安装通过管理菜单 **1 → 11** 追加 Shadowsocks，保留全部已安装协议及其配置；SS 已安装时也保留原端口和密钥。选择组合 **10** 会安装全部七种协议，自定义组合 **6** 中可用编号 **7** 选择 SS。选择管理菜单 **2 → 7** 可以修改 Shadowsocks 端口并保留密钥，菜单 **3** 根据当前安装重新导出 `ss://` 链接、sing-box JSON、Mihomo JSON/YAML。

客户端需支持 Shadowsocks 2022；分享链接按 SIP002 对密钥进行百分号编码。该节点直接连接服务器，不经过 CDN。后续管理和卸载使用新版安装入口，无需再次运行一次性 `migration.sh`。

### 自有域名 TLS 协议

VLESS TLS + Vision 和 AnyTLS 均使用普通 TLS、受信任证书和服务器直连。安装时填写域名和端口，默认端口分别为 **9443/TCP、10443/TCP**，可以修改。两个协议可共用一个域名，但 TCP 端口必须不同；也可分别使用不同子域名。

- 域名的公网 A/AAAA 记录须全部指向这台服务器。Cloudflare 记录必须为灰云「仅 DNS」，普通橙云代理不适用于这两个协议。没有可用 IPv6 时请删除 AAAA 记录。
- 脚本检查公网 DNS 与本机公网 IP；公网地址探测受限或使用 NAT 时可用 `SERVER_ADDRESS` 指定真实公网 IP。
- 必须放行公网 **TCP 80** 和所选代理端口。TCP 80 用于 HTTP-01 证书申请及续期，不能被其他服务或代理占用；脚本不修改防火墙。
- 使用 sing-box **1.14+（with_acme）** 的共享 ACME provider 自动申请和续期 Let's Encrypt 证书，不需要上传证书或提供 Cloudflare Token。已有旧版程序请先用管理菜单 5 更新。
- 两个协议共用 `/etc/sing-box/acme` 中的证书缓存，目录权限为 `700`。服务仅增加该目录的写入权限。移除协议时保留缓存，完整卸载或迁移清理时随 `/etc/sing-box` 清理；备份含证书和账户私钥。
- 初次申请可能需要等待。脚本验证证书域名、信任链和本地 TLS 监听后才显示成功，超过 180 秒或验证失败会恢复原配置；可用 `journalctl -u sing-box` 排查 DNS、CAA 或端口问题。
- 客户端 JSON、Mihomo YAML/JSON 和分享链接均使用真实证书校验。Cloudflare Origin CA 证书不能替代这里的公开受信任证书。

本选项不配置 Xray 的静态网站 fallback；VLESS TLS + Vision 与 Reality 为独立可选节点。

## 管理已有安装

再次运行任意入口：

| 选项 | 操作 |
| --- | --- |
| 1 | 调整协议组合 |
| 2 | 修改已安装协议的端口 / SNI / 证书域名 / WS 路径 |
| 3 | 显示客户端配置和分享链接 |
| 4 | 卸载 |
| 5 | 更新当前组合所需的服务端程序 |
| 6 | 重启 Quick Tunnel，仅在安装了 WS 协议时显示 |
| 7 | 安装或管理 DSVPN；移除 DSVPN 请使用其独立菜单 |

调整组合时，输入**最终希望保留的所有协议**：仍选中的协议保留端口、用户、密钥和其他 inbound 参数，只询问新增协议的参数。选项 **11** 专门用于追加 Shadowsocks，不移除已有协议。移除后重新添加的协议会生成新的认证信息。

移除最后一个 WS 协议会停止并禁用 Caddy 和 cloudflared，保留程序及配置以便以后重用。Caddy 路由及辅助服务定义会按当前 WS 选择重新生成。只修改 WS 后端时保留正在运行的隧道；重启隧道可能改变公网域名，需要更新客户端链接。

组合变更先检查候选配置，再备份到 `/var/backups/fkgfw/protocols.*` 后应用。启动或客户端配置导出失败会恢复原文件和服务的 active/enabled 状态。备份包含密钥，请妥善保管。自定义 inbound 和无关设置保留；若自定义 logical rule 引用了被移除的协议，会要求先处理规则，避免改变其含义。

同一传输层的监听端口不能重复；TCP 与 UDP 可以使用相同端口。WS 路径必须不同，且不能与 Caddy 本地监听端口冲突。

## 部署 DSVPN 和客户端下载

用部署账号把 fkgfw 克隆到服务器的长期目录。首次安装会记录执行 sudo 的账号 UID，systemd 此后允许该账号或 root 维护制品。该账号可以决定下次启动运行的 VPN 程序，请保留 checkout 路径，并限制其他账号的写权限。服务器采用 x86_64 或 aarch64 Linux、systemd 和 TUN，需支持 IPv6 接口配置。安装器会自动开启 IPv4 转发（`net.ipv4.ip_forward=1`），DSVPN 服务每次启动时也会检查并按需开启。Linux 使用 iproute2 和 iptables。

```bash
git clone https://github.com/fujohnwang/fkgfw.git ~/fkgfw
cd ~/fkgfw
sudo bash install.sh dsvpn
# 有固定域名或 NAT 公网地址时，可以指定交互默认值
sudo env SERVER_ADDRESS=vpn.example.org bash reality_hy2_ws.sh dsvpn
```

新装时也可在两个入口选 `12`，已有 sing-box 管理菜单选 `7`。填写 VPN 服务器公网域名或 IP。在安全组和主机入站防火墙放行 VPN 端口（默认 **1959/TCP 和 1959/UDP**）。下载源站默认监听 `127.0.0.1:1960`，1960/TCP 的公网入站可以关闭。DSVPN 自行管理隧道转发和 NAT，可与 sing-box 独立安装及卸载。

从 2.1.0 起，客户端优先连接 TCP。TCP 连接失败或握手超时后，客户端在同一端口通过 KCP/UDP 重新认证，使用同一份 `vpn.key`。日志中的 `Connected (TCP)` 或 `Connected (KCP/UDP)` 表示实际传输方式。

VPS 上的独立 cloudflared 服务向 Cloudflare 建立出站连接。隧道就绪后，安装器打印四个平台的 HTTPS 下载链接及 SHA-256。客户端只需能访问这个网页，文件由部署的 VPS 提供。Quick Tunnel 自动分配 `trycloudflare.com` 临时域名，连接器重启后请在 DSVPN 管理菜单选 `1` 获取当前链接。路径中的版本取自本次 VPN 启动时选定的客户端校验清单。

服务器需要 DNS、访问 Cloudflare 注册接口的出站 HTTPS，以及到 Tunnel 边缘的出站 7844（QUIC 使用 UDP，HTTP/2 使用 TCP）。如果安装时隧道尚未连通，VPN 可独立使用；连接器会重试，菜单 `1` 在隧道就绪后显示链接。Quick Tunnel 无可用性保证。[Cloudflare Quick Tunnels](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)

**用 SCP 一次取回程序和密钥。** 在服务器运行 `sudo sh install.sh dsvpn`，选 `4` 并选择客户端平台。安装器把本次运行版本的 `dsvpn` 和同一份 `vpn.key` 导出到 SSH 账号主目录里的私有目录。将终端打印的三行命令复制到客户端，即可取回整个目录、进入目录并连接。SCP 保留可执行权限和密钥的 `600` 权限。取回后可按提示删除服务器上的导出副本。从 2.1.0 更新的节点，请先执行 `sudo systemctl restart fkgfw-dsvpn`，使导出的客户端支持普通登录账号持有的密钥。

**通过浏览器下载程序。** 选择与客户端 `uname -s`、`uname -m` 相符的文件，核对安装终端打印的 SHA-256。请获准访问服务器的管理员通过私有渠道交付密钥，将其保存为程序旁的 `vpn.key`，再在该目录执行以下命令。macOS 程序使用 ad-hoc 签名，未经 Apple 公证。

```bash
shasum -a 256 ./dsvpn   # Linux 也可用 sha256sum
chmod +x ./dsvpn
chmod 600 ./vpn.key
sudo ./dsvpn client ./vpn.key vpn.example.org 1959
```

节点执行 `git pull` 后，当前 VPN 连接和客户端下载继续使用运行中的版本。执行 `sudo systemctl restart fkgfw-dsvpn` 即可启用新版。每次启动（包括开机）都会把本地 `artifacts/dsvpn/latest/` 同步到 root 管理的 `/opt/fkgfw-dsvpn`，校验 SHA-256 后切换 VPN 和客户端下载。重启后可在菜单 `1` 获取当前四个 HTTPS 链接和 SHA-256。

管理菜单的 `1` 查看连接和下载信息，`2` 修改地址或端口，`3` 卸载 VPN、下载源站及下载隧道，`4` 私有导出客户端和密钥。卸载保留仓库、密钥与端口配置。可用 `journalctl -u fkgfw-dsvpn -u fkgfw-dsvpn-download -u fkgfw-dsvpn-tunnel` 查看日志。下载服务以独立的非特权账户读取公开目录。服务器原始密钥位于 `/etc/fkgfw-dsvpn/vpn.key`，由 root 持有。

## 稳定版与升级

安装及菜单 `5` 通过官方 GitHub Release API 获取最新稳定版，排除 alpha/beta 等预发布版，强制核对 SHA256。下载、校验失败不会替换旧程序。

2026-10-28 核对的版本：sing-box **1.14.4**、cloudflared **2026.10.5**、Caddy **2.11.7**。脚本不固定这些版本。

升级只处理当前组合使用的组件。各组件独立备份与回滚；后续组件失败不撤销前面已经成功的升级。自定义配置不被新版本接受时终止该组件升级。

旧 `/root` 安装会迁移到 `/etc/sing-box` 和 `/usr/local/bin`，保留原文件及服务备份。成功标记位于 `/var/backups/fkgfw/legacy-migrated`，避免卸载后自动重新迁入。

## 从旧部署切换到新版（只做一次）

在新版仓库目录运行 `migration.sh`。它会列出已有部署，输入 `yes` 后先备份，再停止旧服务、清理旧程序、残留进程和配置；不要求已经安装新版。`cleanup.sh` 是同一流程的兼容入口。

```bash
sudo bash migration.sh              # 也可以用 sudo bash cleanup.sh；按提示输入 yes
sudo bash install.sh                # 清理成功后，两个安装入口任选其一
# sudo bash reality_hy2_ws.sh
```

清理覆盖本项目历史 `/root`、`/root/sbox` 和 `/etc/sing-box` 部署，包括相关程序、配置、证书、密钥、服务定义、Tunnel 日志和安装包。旧配置从原位置移除，避免新版入口继续管理或自动迁入旧部署。随后按新版菜单重新选择协议和参数，生成新的认证信息，并更新客户端。

**完成这次切换后，不需要再运行迁移脚本。** 日后的升级、协议调整、重启或卸载，都通过 `install.sh` 或 `reality_hy2_ws.sh` 管理。再次确认执行迁移脚本也会清理已安装的新部署。

需要仅查看范围时可用 `sudo bash migration.sh --dry-run`；自动化可用 `--yes` 跳过交互确认。此前的 `--reset --apply` 写法仍可执行相同清理流程。

迁移准备需要 Linux、root 权限和 Python 3.9+；检查服务使用 systemd，终止残留进程需要内核支持 pidfd。请保留整个仓库。

删除前全部备份到权限为 `700` 的 `/var/backups/fkgfw/cleanup.*`：`files/` 按原绝对路径保存文件及其权限、所有者，`manifest.json` 记录服务原 active/enabled 状态。已有升级备份和迁移标记始终保留。恢复时可按清单用 `cp -a` 将所需文件放回原路径，再 reload systemd 并按原状态启用服务。

脚本核对可执行文件路径、启动参数、配置和服务控制组；也支持旧的 `cloudflared-vmess.service` / `cloudflared-vless.service` 独立隧道，需日志路径及目标 WS 端口与已识别配置匹配。同名的其他程序、自定义服务覆盖、命名/token 隧道及无法确认归属的项目会保留并说明原因。清理前会检查计划执行后的残留，有冲突即返回失败，不会先停止部分服务；处理提示项后再运行。`--dry-run` 检查不通过也返回非零状态。若提示 systemd 尚未加载磁盘变更，先核对服务文件，再执行 `sudo systemctl daemon-reload` 并重新预览。

独立进程使用 pidfd 发送 SIGTERM，10 秒未退出就停止删除。备份失败不会停止服务；执行中发生的停止失败或进程重新启动会保留待删文件和备份，但已经停止的服务不会自动重启。清理与安装、升级共用锁，避免同时修改。

## 客户端与日志

- 服务端：`/etc/sing-box/config.json`
- sing-box 客户端：`/etc/sing-box/client.json`
- Mihomo / Clash Meta 客户端：`/etc/sing-box/clash.json`（JSON 格式，可由 YAML 解析器读取）
- Clash Meta / Mihomo YAML 客户端：`/etc/sing-box/clash.yaml`，包含节点、策略组和规则，可直接导入支持这些协议的客户端。
- 分享链接与客户端节点只包含当前已选协议，菜单 `3` 可重新生成。
- 安装完成时同时显示 sing-box JSON、Clash JSON 和 Clash YAML。已有安装更新脚本后，运行任意安装入口并选择菜单 `3` 即可补充生成 YAML，无需重新安装。YAML 与 Clash JSON 从同一份数据生成，保留相同凭据，文件权限均为 `600`。
- sing-box 客户端采用新版 DNS、TUN、rule-set 与 route action 格式；当前验证版本为 1.14.4。首次使用需下载 SagerNet 分流规则。
- Hysteria2 使用自签名证书，客户端保留 `insecure: true`。

```bash
journalctl -u sing-box -n 50
journalctl -u caddy -n 50
journalctl -u cloudflared -n 50
```

## 验证

```bash
bash -n install.sh reality_hy2_ws.sh migration.sh cleanup.sh lib/*.sh
python3 tests/test-updates.py
python3 tests/test-combinations.py
python3 tests/test-cleanup.py
python3 tests/test-client-exports.py
SING_BOX_BINARY=/path/to/sing-box python3 tests/check-configs.py
SING_BOX_BINARY=/path/to/sing-box bash tests/test-tls.sh
SING_BOX_BINARY=/path/to/sing-box bash tests/test-tls-transaction.sh
SING_BOX_BINARY=/path/to/sing-box bash tests/test-shadowsocks.sh
```

配置测试使用真实 sing-box 检查 15 种组合，并检查 225 种切换的参数保留、分享链接、Mihomo 节点及 YAML/JSON 内容一致性。客户端导出与配置测试需要 PyYAML（Debian/Ubuntu 开发环境可安装 `python3-yaml`，下面的测试镜像已包含）；服务器导出仅使用已有 jq。故障测试使用隔离目录和模拟服务。

新增 Bash 测试覆盖七种协议的 127 种配置、共享证书 provider、域名/DNS 校验、新节点导出，以及证书失败的事务回滚和保留凭据的域名修改。

Shadowsocks 的 Bash 测试覆盖 256 位密钥生成、双网络端口冲突、IPv4/IPv6 分享链接、JSON/YAML 导出、修改端口保留密钥及导出失败回滚。

最终 Linux 安装与本地流量测试（需要 Docker）：

```bash
docker build -t fkgfw-smoke:local -f tests/Dockerfile .
docker run --rm --init -e FKGFW_CONTAINER_TEST=1 \
  --mount type=bind,src="$PWD",dst=/repo,readonly \
  --workdir /repo fkgfw-smoke:local python3 tests/linux-smoke.py
```

该测试先验证旧 `/root` 和 `/root/sbox` 部署清理后分别进入两个新版安装入口，再使用真实程序完成原四种协议的 15 种组合安装、组合调整、参数修改和本地代理请求。systemd 调度及 Quick Tunnel 域名采用模拟实现，服务文件另经 `systemd-analyze verify` 检查；不建立公网隧道，不覆盖真实 systemd 隔离行为。

新增两个协议的 Linux 流量测试（将官方 Linux sing-box 可执行文件放入本地 `test-bin/`）：

```bash
docker run --rm --init --network none -e FKGFW_CONTAINER_TEST=1 \
  -e SING_BOX_BINARY=/test-bin/sing-box \
  --mount type=bind,src="$PWD",dst=/repo,readonly \
  --mount type=bind,src="$PWD/test-bin",dst=/test-bin,readonly \
  --workdir /repo fkgfw-smoke:local bash tests/linux-tls.sh
```

该测试使用本地受信任测试证书替代公网 ACME 签发，检查单独/组合安装、实际 VLESS Vision/AnyTLS 流量、错误证书拒绝、查看配置、域名修改、移除节点与卸载。公网 DNS、Let's Encrypt 签发/续期和真实 systemd 隔离需在实际服务器验证。

使用相同 Docker 命令，将末尾的 `bash tests/linux-tls.sh` 换为 `bash tests/linux-shadowsocks.sh`，验证两个入口的 Shadowsocks 安装、追加时保留已有协议、真实 TCP/UDP 代理流量、错误密钥拒绝、端口修改、查看和卸载；无需公网连接。

清理脚本的最终 Linux 集成测试使用同一镜像，验证真实 `/proc` 识别、pidfd 终止进程、锁、备份和保留范围；systemd 调度模拟。只在一次性容器内运行：

```bash
docker run --rm --init --network none -e FKGFW_CONTAINER_TEST=1 \
  --mount type=bind,src="$PWD",dst=/repo,readonly \
  --workdir /repo fkgfw-smoke:local python3 tests/linux-cleanup.py
```

DSVPN 回归使用带 systemd 和 TUN 的全新可丢弃 Linux 虚拟机，需事先安装 git 和 iputils-ping。运行 `sudo env FKGFW_DSVPN_TEST=1 bash tests/linux-dsvpn.sh`，验证四个平台的源站文件、HTTPS 链接生成、隧道断线提示、VPN 流量、拉取制品时保留连接、重启后服务端与下载同步切版、损坏制品拒绝启动、卸载重装及安装失败回滚。默认使用本机模拟的连接器状态；要实际经公网 HTTPS 下载四份制品，可同时设置 `FKGFW_DSVPN_LIVE_TUNNEL=1`，测试期间 Cloudflare 会公开该虚拟机上的客户端文件。
