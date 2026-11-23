# DSVPN 部署制品

本目录随 fkgfw 分发。安装器按 SHA256SUMS 验证本地文件。Linux 两种架构的 dsvpn 均是静态 musl 可执行文件，同时支持 server 和 client。macOS 两种架构为最低系统版本 11.0 的 Mach-O 客户端。当前四份 DSVPN 程序均从 2.0.1 源码构建，使用 v2 握手协议。

升级时，在同一版 DSVPN 源码中执行 `make linux-release`，将两个 `zig-out/linux-*/bin/dsvpn` 放回对应 Linux 目录。macOS 使用 Xcode 命令行工具和相同源码，分别以 `-arch arm64` 和 `-arch x86_64` 构建：

```bash
xcrun clang -arch arm64 -mmacosx-version-min=11.0 -Os -Wl,-dead_strip \
  -Iinclude -Ivendor/monocypher src/vpn.c src/os.c src/charm.c src/handshake.c \
  vendor/monocypher/monocypher.c -o dsvpn-macos-arm64
strip -x dsvpn-macos-arm64
codesign --force --sign - --identifier org.fkgfw.dsvpn dsvpn-macos-arm64
```

下载服务采用上游 darkhttpd v1.17。源码发布包的 SHA-256 为 `4fee9927e2d8bb0a302f0dd62f9ff1e075748fa9f5162c9481a7a58b41462b56`。两份 darkhttpd 通过 `zig cc -target x86_64-linux-musl -Os -s -static darkhttpd.c -o darkhttpd` 和对应的 `aarch64-linux-musl` 命令构建。更新 DSVPN 时可以继续使用仓库随附的下载服务。上游来源见 [darkhttpd v1.17](https://github.com/emikulic/darkhttpd/releases/tag/v1.17)。

替换制品及相应许可证后，在本目录按固定顺序刷新校验清单，再执行 Linux 集成验证：

```bash
shasum -a 256 linux-amd64/dsvpn linux-arm64/dsvpn macos-amd64/dsvpn macos-arm64/dsvpn \
  linux-amd64/darkhttpd linux-arm64/darkhttpd > SHA256SUMS
```
