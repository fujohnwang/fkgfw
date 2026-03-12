# 简介
- Reality Hysteria2 vmess ws一键安装脚本（安全增强版）
  
## 功能

- 无脑回车一键安装或者自定义安装
- 完全无需域名，使用自签证书部署hy2，使用cloudflared tunnel支持vmess ws优选ip
- 支持修改reality端口号和域名，hysteria2端口号
- 无脑生成sing-box，clash-meta，v2rayN，nekoray等通用链接格式

## 安全增强特性

本版本在原版基础上增加了以下安全特性：

- ✅ **文件完整性验证**: 下载文件时验证 SHA256 校验和（如果可用）
- ✅ **专用用户运行**: 创建 `singbox` 专用用户运行服务，而非 root
- ✅ **严格文件权限**: 配置文件和密钥文件设置为 600 权限
- ✅ **Systemd 安全加固**: 启用多项 systemd 安全选项（NoNewPrivileges, ProtectSystem 等）
- ✅ **改进进程管理**: cloudflared 使用 systemd 管理，而非后台进程
- ✅ **安装前确认**: 脚本执行前需要用户明确确认
- ✅ **Root 权限检查**: 确保脚本以正确权限运行
- ✅ **错误处理增强**: 更完善的错误检查和提示

## 安全建议

⚠️ **重要安全提示**:

1. **不要直接通过管道执行脚本** - 先下载并审查脚本内容
2. **定期更新** - 及时更新 sing-box 和 cloudflared 到最新版本
3. **防火墙配置** - 只开放必要的端口
4. **监控日志** - 定期检查服务日志是否有异常
5. **备份配置** - 保存好配置文件和密钥的备份

## 需求

- Linux operating system
- Bash shell
- Internet connection
- Root 权限

## 使用教程

```bash
sudo bash reality_hy2_ws.sh
```


## 服务管理

### sing-box 服务

|项目||
|:--|:--|
|程序|**/root/sbox/sing-box**|
|服务端配置|**/root/sbox/sbconfig_server.json**|
|运行用户|**singbox** (非 root)|
|重启|`systemctl restart sing-box`|
|状态|`systemctl status sing-box`|
|查看日志|`journalctl -u sing-box -o cat -e`|
|实时日志|`journalctl -u sing-box -o cat -f`|

### cloudflared 服务

|项目||
|:--|:--|
|程序|**/root/sbox/cloudflared-linux**|
|运行用户|**singbox** (非 root)|
|重启|`systemctl restart cloudflared`|
|状态|`systemctl status cloudflared`|
|查看日志|`journalctl -u cloudflared -o cat -e`|
|日志文件|**/var/log/cloudflared.log**|

## 高级配置

### WARP 解锁

如需解锁 IPv4/IPv6，可使用 warp-go 脚本：

```bash
wget -N https://gitlab.com/fscarmen/warp/-/raw/main/warp-go.sh && bash warp-go.sh
```

### 文件权限说明

安全增强版会自动设置以下文件权限：

- 配置文件 (`sbconfig_server.json`): 600 (仅所有者可读写)
- 密钥文件 (`*.key`, `*.b64`): 600
- 证书目录 (`/root/self-cert`): 700
- 二进制文件 (`sing-box`, `cloudflared-linux`): 755

### 故障排查

如果服务无法启动，请检查：

1. 用户权限: `id singbox`
2. 文件权限: `ls -la /root/sbox/`
3. 服务日志: `journalctl -u sing-box -n 50`
4. 配置验证: `/root/sbox/sing-box check -c /root/sbox/sbconfig_server.json`


## Credit
- [sing-box](https://github.com/SagerNet/sing-box)
