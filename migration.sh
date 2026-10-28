#!/bin/bash
# One-time preparation: back up and remove the old deployment before installing.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
if ! command -v python3 >/dev/null 2>&1; then
    echo '错误: 迁移准备脚本需要 Python 3.9+，请先安装 python3。' >&2
    exit 1
fi
exec python3 "$SCRIPT_DIR/lib/cleanup.py" "$@"
