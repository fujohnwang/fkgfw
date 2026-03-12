# 安全说明 / Security Notice

## 安全增强版改进内容

本项目的安全增强版本针对原始脚本发现的安全问题进行了全面改进。

### 已修复的安全问题

#### 1. 文件完整性验证 ✅

**问题**: 原版直接从 GitHub 下载二进制文件，未验证文件完整性

**改进**:
- 尝试下载并验证 SHA256 校验和文件
- 如果校验失败，拒绝安装并提示用户
- 如果校验和文件不可用，给出警告提示

**代码位置**: `download_sing_box()` 和 `download_singbox()` 函数

#### 2. 非特权用户运行 ✅

**问题**: 原版以 root 用户运行所有服务

**改进**:
- 创建专用的 `singbox` 用户（无登录权限）
- sing-box 和 cloudflared 服务均以 singbox 用户运行
- 使用 Linux Capabilities 授予必要的网络权限

**代码位置**: `create_singbox_user()` 函数和 systemd 服务文件

#### 3. 严格文件权限 ✅

**问题**: 配置文件和密钥文件权限过于宽松

**改进**:
- 配置文件: 600 (仅所有者可读写)
- 密钥文件: 600
- 证书目录: 700
- 二进制文件: 755

**代码位置**: `set_secure_permissions()` 函数

#### 4. Systemd 安全加固 ✅

**问题**: systemd 服务未启用安全选项

**改进**:
- `NoNewPrivileges=true` - 禁止提升权限
- `ProtectSystem=strict` - 保护系统目录
- `ProtectHome=true` - 保护用户主目录
- `PrivateTmp=true` - 使用私有临时目录
- `ProtectKernelTunables=true` - 保护内核参数
- `ProtectKernelModules=true` - 禁止加载内核模块
- `RestrictNamespaces=true` - 限制命名空间
- `SystemCallFilter=@system-service` - 限制系统调用
- 更多安全选项...

**代码位置**: systemd 服务文件

#### 5. 改进进程管理 ✅

**问题**: cloudflared 使用 `pgrep` 和 `kill` 管理，不够健壮

**改进**:
- 为 cloudflared 创建独立的 systemd 服务
- 自动重启和日志管理
- 与 sing-box 服务协同工作

**代码位置**: `create_cloudflared_service()` 函数

#### 6. 安装前确认 ✅

**问题**: 脚本直接执行，无安全提示

**改进**:
- 脚本开头显示安全警告
- 列出将要执行的操作
- 要求用户明确输入 "yes" 确认

**代码位置**: 脚本开头的安全提示部分

#### 7. Root 权限检查 ✅

**问题**: 未检查运行权限

**改进**:
- 检查是否以 root 运行
- 如果不是，提示正确的运行方式

**代码位置**: `install_base` 之后的权限检查

#### 8. 错误处理增强 ✅

**问题**: 下载失败等错误未妥善处理

**改进**:
- 检查下载是否成功
- 验证服务是否正常启动
- 提供详细的错误信息和排查建议

**代码位置**: 各个函数中的错误检查

## 仍需注意的安全风险

### 1. 自签名证书

Hysteria2 使用自签名证书，客户端配置为跳过证书验证 (`insecure: true`)。

**风险**: 容易受到中间人攻击

**建议**: 
- 如果可能，使用正式的 TLS 证书（如 Let's Encrypt）
- 或者手动验证证书指纹

### 2. Cloudflared Tunnel

Cloudflared tunnel 会将本地端口暴露到公网。

**风险**: 如果配置不当，可能暴露敏感服务

**建议**:
- 确保只暴露必要的端口
- 定期检查 tunnel 状态
- 考虑使用 Cloudflare Access 进行访问控制

### 3. 配置文件存储

配置文件仍存储在 `/root` 目录下。

**风险**: 如果系统被入侵，配置可能被读取

**建议**:
- 考虑使用加密文件系统
- 定期备份并安全存储配置
- 使用强密码和密钥

### 4. 网络暴露

服务监听在 `::` (所有接口)。

**风险**: 服务暴露在公网

**建议**:
- 配置防火墙规则
- 只开放必要的端口
- 考虑使用 fail2ban 等工具防止暴力破解

## 安全最佳实践

### 安装前

1. ✅ 审查脚本内容
2. ✅ 确保从可信来源下载
3. ✅ 备份重要数据
4. ✅ 了解脚本将执行的操作

### 安装后

1. ✅ 检查服务状态: `systemctl status sing-box cloudflared`
2. ✅ 验证文件权限: `ls -la /root/sbox/`
3. ✅ 检查用户创建: `id singbox`
4. ✅ 查看日志: `journalctl -u sing-box -n 50`
5. ✅ 配置防火墙规则
6. ✅ 保存配置备份

### 日常维护

1. ✅ 定期更新 sing-box: 使用脚本选项 5
2. ✅ 监控服务日志
3. ✅ 检查异常连接
4. ✅ 定期更新系统补丁
5. ✅ 审查访问日志

### 卸载

如需卸载，使用脚本选项 4，它会：
- 停止并禁用所有服务
- 删除服务文件
- 删除配置和二进制文件
- 清理日志文件

注意: 卸载脚本不会删除 `singbox` 用户（出于安全考虑）

## 报告安全问题

如果您发现安全问题，请：

1. 不要公开披露
2. 通过私密渠道联系维护者
3. 提供详细的问题描述和复现步骤

## 免责声明

本脚本按"原样"提供，不提供任何明示或暗示的保证。使用本脚本的风险由用户自行承担。

维护者不对因使用本脚本而导致的任何直接或间接损失负责。

## 许可证

请参阅 LICENSE 文件了解详细信息。

## 参考资源

- [sing-box 官方文档](https://sing-box.sagernet.org/)
- [systemd 安全加固指南](https://www.freedesktop.org/software/systemd/man/systemd.exec.html)
- [Linux Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [Cloudflare Tunnel 文档](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/)
