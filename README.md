# sing-box 协议组合安装脚本

支持 **Reality、Hysteria2、VMess WS、VLESS WS** 四种协议的任意非空组合，共 15 种。WebSocket 通过 Caddy + Cloudflare Quick Tunnel 接入。

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
| 5 | 全部四种 |
| 6 | 自定义多选 |

自定义模式中，`1=Reality`、`2=Hysteria2`、`3=VMess WS`、`4=VLESS WS`。例如输入 `1,4` 安装 Reality + VLESS WS；输入 `3` 仅安装 VMess WS。

两个入口都支持全部组合，也能管理对方创建的安装：

- `sudo bash install.sh`：新安装默认选项 3。
- `sudo bash reality_hy2_ws.sh`：新安装默认选项 5。

必须保留整个仓库的 `lib/` 目录，不能只复制入口脚本。

只安装直连协议时不下载、配置或启动 Caddy / cloudflared。只有 Reality 生成 Reality 密钥，只有 Hysteria2 生成自签名证书。涉及公网直连时会自动探测服务器地址；也可指定：

```bash
sudo env SERVER_ADDRESS=203.0.113.10 bash install.sh
```

## 管理已有安装

再次运行任意入口：

| 选项 | 操作 |
| --- | --- |
| 1 | 调整协议组合 |
| 2 | 修改已安装协议的端口 / SNI / WS 路径 |
| 3 | 显示客户端配置和分享链接 |
| 4 | 卸载 |
| 5 | 更新当前组合所需的服务端程序 |
| 6 | 重启 Quick Tunnel，仅在安装了 WS 协议时显示 |

调整组合时，输入**最终希望保留的所有协议**：仍选中的协议保留端口、用户、密钥和其他 inbound 参数，只询问新增协议的参数。移除后重新添加的协议会生成新的认证信息。

移除最后一个 WS 协议会停止并禁用 Caddy 和 cloudflared，保留程序及配置以便以后重用。Caddy 路由及辅助服务定义会按当前 WS 选择重新生成。只修改 WS 后端时保留正在运行的隧道；重启隧道可能改变公网域名，需要更新客户端链接。

组合变更先检查候选配置，再备份到 `/var/backups/fkgfw/protocols.*` 后应用。启动或客户端配置导出失败会恢复原文件和服务的 active/enabled 状态。备份包含密钥，请妥善保管。自定义 inbound 和无关设置保留；若自定义 logical rule 引用了被移除的协议，会要求先处理规则，避免改变其含义。

同一传输层的监听端口不能重复；TCP 与 UDP 可以使用相同端口。WS 路径必须不同，且不能与 Caddy 本地监听端口冲突。

## 稳定版与升级

安装及菜单 `5` 通过官方 GitHub Release API 获取最新稳定版，排除 alpha/beta 等预发布版，强制核对 SHA256。下载、校验失败不会替换旧程序。

2026-10-28 核对的版本：sing-box **1.14.4**、cloudflared **2026.10.5**、Caddy **2.11.7**。脚本不固定这些版本。

升级只处理当前组合使用的组件。各组件独立备份与回滚；后续组件失败不撤销前面已经成功的升级。自定义配置不被新版本接受时终止该组件升级。

旧 `/root` 安装会迁移到 `/etc/sing-box` 和 `/usr/local/bin`，保留原文件及服务备份。成功标记位于 `/var/backups/fkgfw/legacy-migrated`，避免卸载后自动重新迁入。

## 客户端与日志

- 服务端：`/etc/sing-box/config.json`
- sing-box 客户端：`/etc/sing-box/client.json`
- Mihomo / Clash Meta 客户端：`/etc/sing-box/clash.json`（JSON 格式，可由 YAML 解析器读取）
- 分享链接与客户端节点只包含当前已选协议，菜单 `3` 可重新生成。
- sing-box 客户端采用新版 DNS、TUN、rule-set 与 route action 格式；当前验证版本为 1.14.4。首次使用需下载 SagerNet 分流规则。
- Hysteria2 使用自签名证书，客户端保留 `insecure: true`。

```bash
journalctl -u sing-box -n 50
journalctl -u caddy -n 50
journalctl -u cloudflared -n 50
```

## 验证

```bash
bash -n install.sh reality_hy2_ws.sh lib/*.sh
python3 tests/test-updates.py
python3 tests/test-combinations.py
SING_BOX_BINARY=/path/to/sing-box python3 tests/check-configs.py
```

配置测试使用真实 sing-box 检查 15 种组合，并检查 225 种切换的参数保留、分享链接和 Mihomo 节点。故障测试使用隔离目录和模拟服务。

最终 Linux 安装与本地流量测试（需要 Docker）：

```bash
docker build -t fkgfw-smoke:local -f tests/Dockerfile .
docker run --rm --init -e FKGFW_CONTAINER_TEST=1 \
  --mount type=bind,src="$PWD",dst=/repo,readonly \
  --workdir /repo fkgfw-smoke:local python3 tests/linux-smoke.py
```

该测试使用真实程序完成所有组合的新安装、组合调整、参数修改和本地代理请求。systemd 调度及 Quick Tunnel 域名采用模拟实现，服务文件另经 `systemd-analyze verify` 检查；不建立公网隧道，不覆盖真实 systemd 隔离行为。
