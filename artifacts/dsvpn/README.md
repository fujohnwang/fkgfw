# DSVPN 部署制品

节点每次启动 DSVPN 时，把本机仓库 `artifacts/dsvpn/latest/` 中的制品同步到 root 管理的 `/opt/fkgfw-dsvpn`，校验 SHA-256 后一起启用 VPN 和配套下载。首次执行 `sudo ./install.sh` 的部署账号 UID 保存在 `/etc/fkgfw-dsvpn/deploy.uid`。该账号可在自己的 checkout 执行 `git pull`，再用 `sudo systemctl restart fkgfw-dsvpn` 启用新版。

## 目录

- `clients/<平台>/dsvpn` 包含 Linux 和 macOS 的 amd64、arm64 四个程序。Linux 为静态 musl 可执行文件，同一个文件用于服务端运行和客户端下载。macOS 最低版本为 11.0。
- `clients/SHA256SUMS` 记录四个客户端的 SHA-256，其摘要标识下载 URL 中的版本。下载入口还公开该目录下的三份许可证。
- `linux-amd64/`、`linux-arm64/` 保存各自的 darkhttpd 和 cloudflared 可执行文件。版本目录根部的 `SHA256SUMS` 校验这四份服务端工具。

## 本地发布新制品

在本地 DSVPN 源码仓库的 macOS 开发机上运行以下命令。需要 Zig 和 Xcode 命令行工具。

```bash
./releaseLocally.sh
# fkgfw checkout 在其他位置时
FKGFW_DIR=/path/to/fkgfw ./releaseLocally.sh
```

脚本交叉编译和校验四个平台的程序，将客户端、许可证及 SHA-256 清单同步到本地 fkgfw 的 `latest/`。下载服务使用该目录已有的 darkhttpd 和 cloudflared。检查变更后，在 fkgfw 仓库提交并推送。服务器首次部署时运行 `sudo bash install.sh dsvpn`，后续拉取 fkgfw 并执行 `sudo systemctl restart fkgfw-dsvpn` 即可启用新版。
## 2.2.0 的组件

- DSVPN 2.2.0 支持 v2 TCP 握手和同端口 KCP/UDP 回退，客户端接受 sudo 调用账号持有的私有密钥。新版之间按方向探测 UDP 负载上限，可通过 `--kcp-stats` 查看 RTT、重传和积压。KCP 采用 MIT 许可证。[KCP 上游提交](https://github.com/skywind3000/kcp/tree/b1a7a2101dcbb96017681a500d6b82bbe5a88766)
- darkhttpd v1.17 源码发布包的 SHA-256 为 `4fee9927e2d8bb0a302f0dd62f9ff1e075748fa9f5162c9481a7a58b41462b56`。在解压后的源码目录执行 `patch -p1 < /path/to/fkgfw/artifacts/dsvpn/darkhttpd-download-name.patch`，让浏览器保存客户端时使用文件名 `dsvpn`。然后用 `zig cc -target x86_64-linux-musl -Os -s -static darkhttpd.c -o darkhttpd` 构建 amd64，将目标替换为 `aarch64-linux-musl` 构建 arm64。[darkhttpd v1.17](https://github.com/emikulic/darkhttpd/releases/tag/v1.17)
- cloudflared 2026.11.2 使用官方 Linux 可执行文件，原始 SHA-256 为 amd64 的 `56f13335143ec0e22772963290683a84a04114a35ec64cbc794a4d39ff9bb8cf` 和 arm64 的 `04a7b7f08bce85d56b26ffe1fdbfbb21a074495a363d16f0783c40e25b5c5281`。[Cloudflare 官方发行版](https://github.com/cloudflare/cloudflared/releases/tag/2026.11.2)
