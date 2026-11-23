#!/bin/bash
# Validate the checkout at install and synchronize the root-owned release before startup.
set -euo pipefail
umask 077
fail() { echo "DSVPN: $*" >&2; exit 1; }

# Allow a group-writable checkout when the deployer's private primary group
# contains no other accounts. Named ACLs are checked separately on each path.
private_deploy_group() {
    local record members member
    record=$(getent group "$deploy_gid") || return 1
    members=${record##*:}
    for member in ${members//,/ }; do
        [[ "$member" = "$deploy_name" || "$member" = root ]] || return 1
    done
    getent passwd | awk -F: -v gid="$deploy_gid" -v uid="$deploy_uid" \
        '$4 == gid && $3 != uid && $3 != 0 { shared=1 } END { exit shared+0 }'
}

trusted_path() {
    local path=$1 owner group mode permissions
    while [ "$path" != / ]; do
        [[ ! -L "$path" && -e "$path" ]] || fail "制品路径无效：$path"
        read -r owner group mode < <(stat -c '%u %g %a' -- "$path") || return 1
        [[ "$owner" = 0 || "$owner" = "$deploy_uid" ]] ||
            fail "路径所有者 UID $owner 未获部署授权（部署 UID $deploy_uid）：$path"
        if [[ "$owner" != 0 ]]; then read_uid=$deploy_uid; fi
        if (( (8#$mode & 0022) != 0 )) && ! { [[ -d "$path" ]] && (( (8#$mode & 01000) != 0 )); }; then
            [[ "$group" = "$private_gid" ]] && (( (8#$mode & 0002) == 0 )) ||
                fail "其他账号可写入制品路径：$path"
            permissions=$(LC_ALL=C ls -ldn -- "$path") || return 1
            [[ ${permissions%% *} != *+ ]] || fail "制品路径带有可写的扩展 ACL：$path"
            read_uid=$deploy_uid
        fi
        path=${path%/*}; path=${path:-/}
    done
}

runtime=/run/fkgfw-dsvpn
cfg=/etc/fkgfw-dsvpn
store=/opt/fkgfw-dsvpn
if [[ -e /opt || -L /opt ]]; then
    read -r owner mode < <(stat -c '%u %a' /opt)
    [[ ! -L /opt && -d /opt && $owner = 0 ]] && (( (8#$mode & 0022) == 0 )) ||
        fail '/opt 必须由 root 管理。'
fi
if [[ -e "$store" || -L "$store" ]]; then
    [[ ! -L "$store" && -d "$store" && $(stat -c '%u:%a' "$store") = 0:700 &&
        -f "$store/.managed-by-fkgfw" && ! -L "$store/.managed-by-fkgfw" ]] ||
        fail "安装目录归属不明：$store"
fi
case "$1" in
    check-store) exit 0 ;;
    verify) artifacts=$2; deploy_uid=${3:-0} ;;
    activate)
        artifacts=$(readlink "$cfg/artifacts")
        deploy_uid=0
        if [[ -f "$cfg/deploy.uid" ]]; then deploy_uid=$(cat "$cfg/deploy.uid"); fi ;;
    *) exit 2 ;;
esac
[[ "$artifacts" = /* ]] || fail '仓库制品路径必须是绝对路径。'
[[ "$deploy_uid" =~ ^(0|[1-9][0-9]*)$ ]] || fail '部署账号 UID 无效。'
read_uid=0
private_gid=''
if [[ "$deploy_uid" != 0 ]]; then
    deploy_name=$(id -nu "$deploy_uid") || fail "部署账号 UID $deploy_uid 已不存在。"
    deploy_gid=$(id -g "$deploy_uid")
    if private_deploy_group; then private_gid=$deploy_gid; fi
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
[[ -x "$release/clients/$arch/dsvpn" && -x "$release/$arch/darkhttpd" && -x "$release/$arch/cloudflared" ]] ||
    fail '仓库中的 Linux 制品需要可执行权限。'

if [[ "$1" = activate ]]; then
    [[ -f "$store/.managed-by-fkgfw" ]] || fail "缺少受管安装目录：$store"
    reader=()
    if [[ "$read_uid" != 0 ]]; then
        reader=(setpriv --reuid="$deploy_uid" --regid="$deploy_gid" --init-groups --no-new-privs --)
    fi
    # Copy only allowlisted paths. Open the source with the deployer's access,
    # and create the destination as root with known modes.
    stage="$store/.next"
    rm -rf -- "$stage"
    mkdir -m 700 "$stage"
    trap 'rm -rf -- "$stage"' EXIT
    for file in "${files[@]}"; do
        mkdir -p "$(dirname -- "$stage/$file")"
        "${reader[@]}" cat -- "$release/$file" > "$stage/$file"
        case "$file" in
            */darkhttpd|*/cloudflared|*/dsvpn) chmod 755 "$stage/$file" ;;
            *) chmod 644 "$stage/$file" ;;
        esac
    done
    release=$stage
fi
(cd "$release" && sha256sum "${tools[@]}") | cmp -s - "$release/SHA256SUMS" ||
    fail '服务制品 SHA-256 校验失败。'
(cd "$release/clients" && sha256sum "${clients[@]}") | cmp -s - "$release/clients/SHA256SUMS" ||
    fail '客户端制品 SHA-256 校验失败。'

if [[ "$1" = verify ]]; then printf '%s\n' "$arch"; exit 0; fi
digest=$(sha256sum < "$stage/clients/SHA256SUMS")
# Switch the root-private release link atomically. Alternating slots keep the
# previous set available until every file in its replacement passes verification.
slot=a
if [[ $(readlink "$store/release" || :) = a ]]; then slot=b; fi
rm -rf -- "$store/$slot"
mv -T -- "$stage" "$store/$slot"
ln -sfnT -- "$slot" "$store/.release-link"
mv -Tf -- "$store/.release-link" "$store/release"
if [[ $slot = a ]]; then rm -rf -- "$store/b"; else rm -rf -- "$store/a"; fi
printf 'BUNDLE=%s\n' "${digest%% *}" > "$runtime/download.env"
ln -sfnT -- "$store/release" "$runtime/release"
echo "DSVPN 已从仓库同步到 $store，客户端清单 SHA-256 为 ${digest%% *}。"
