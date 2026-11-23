#!/bin/bash
# Validate before installation and before every server start. Only activation writes runtime state.
set -euo pipefail
umask 077
fail() { echo "DSVPN: $*" >&2; exit 1; }

# systemd will execute these files in place, including the privileged VPN server.
trusted_path() {
    local path=$1 owner mode
    while [ "$path" != / ]; do
        [[ ! -L "$path" && -e "$path" ]] || fail "制品路径无效：$path"
        read -r owner mode < <(stat -c '%u %a' -- "$path") || return 1
        [[ "$owner" = 0 ]] && { (( (8#$mode & 0022) == 0 )) ||
            { [[ -d "$path" ]] && (( (8#$mode & 01000) != 0 )); }; } ||
            fail "服务直接执行仓库制品，请使用 root 管理且普通用户不可改写的路径：$path"
        path=${path%/*}; path=${path:-/}
    done
}

runtime=/run/fkgfw-dsvpn
case "$1" in
    verify) artifacts=$2 ;;
    activate|deactivate) artifacts=$(readlink /etc/fkgfw-dsvpn/artifacts) ;;
    *) exit 2 ;;
esac
[[ "$artifacts" = /* ]] || fail '仓库制品路径必须是绝对路径。'
trusted_path "$artifacts"
active="$artifacts/.fkgfw-dsvpn-running"
if [[ -e "$active" || -L "$active" ]]; then
    [[ ! -L "$active" && -d "$active" && $(stat -c '%u:%a' "$active") = 0:700 &&
       -f "$active/.managed-by-fkgfw" ]] || fail "运行目录归属不明：$active"
fi
if [[ "$1" = deactivate ]]; then
    rm -rf -- "$active"
    exit 0
fi

clients=(linux-amd64/dsvpn linux-arm64/dsvpn macos-amd64/dsvpn macos-arm64/dsvpn)
tools=(linux-amd64/darkhttpd linux-arm64/darkhttpd linux-amd64/cloudflared linux-arm64/cloudflared)
case "$(uname -m)" in
    x86_64) arch=linux-amd64 ;;
    aarch64|arm64) arch=linux-arm64 ;;
    *) fail "当前 DSVPN 制品不支持 $(uname -m)" ;;
esac
release="$artifacts/latest"
files=("${tools[@]}" SHA256SUMS clients/SHA256SUMS clients/LICENSE clients/KCP-LICENSE clients/Monocypher-LICENCE.md)
for file in "${clients[@]}"; do files+=("clients/$file"); done
for file in "${files[@]}"; do
    trusted_path "$release/$file"
    [[ -f "$release/$file" ]] || fail "缺少制品：$file"
done
if [[ "$1" = activate ]]; then
    # Keep the exact inodes across git pull and independent download service restarts.
    mkdir -p -m 700 "$active"
    touch "$active/.managed-by-fkgfw"
    for file in "${files[@]}"; do
        mkdir -p "$(dirname -- "$active/$file")"
        [[ "$release/$file" -ef "$active/$file" ]] || ln -fT -- "$release/$file" "$active/$file"
    done
    release=$active
fi
[[ -x "$release/clients/$arch/dsvpn" && -x "$release/$arch/darkhttpd" && -x "$release/$arch/cloudflared" ]] ||
    fail '仓库中的 Linux 制品需要可执行权限。'
(cd "$release" && sha256sum "${tools[@]}") | cmp -s - "$release/SHA256SUMS" ||
    fail '服务制品 SHA-256 校验失败。'
(cd "$release/clients" && sha256sum "${clients[@]}") | cmp -s - "$release/clients/SHA256SUMS" ||
    fail '客户端制品 SHA-256 校验失败。'

if [ "$1" = activate ]; then
    digest=$(sha256sum < "$release/clients/SHA256SUMS")
    printf 'BUNDLE=%s\n' "${digest%% *}" > "$runtime/download.env"
    ln -sfnT -- "$release" "$runtime/release"
    echo "DSVPN 已加载 latest，客户端清单 SHA-256 为 ${digest%% *}。"
else
    printf '%s\n' "$arch"
fi
