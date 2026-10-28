#!/bin/bash
set -o pipefail
umask 077
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) || exit 1
source "$SCRIPT_DIR/lib/installer.sh" || exit 1
# Preserve the basic installer's default; every combination is selectable.
installer_main 3
