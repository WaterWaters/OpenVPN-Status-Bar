#!/usr/bin/env bash
# 本地开发入口：统一 SDK 回退，避免"第一条命令就红"。
#
#   ./scripts/dev.sh build     编译（调试）
#   ./scripts/dev.sh test      单元测试（需要完整 Xcode 的 XCTest；只有 CLT 时会失败）
#   ./scripts/dev.sh release   打包 .app + DMG（等价 ./build.sh）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/sdk.sh
source "$SCRIPT_DIR/sdk.sh"

SDK="$(vpnstatusbar_fallback_sdkroot)" || true
if [ -n "$SDK" ]; then
    export SDKROOT="$SDK"
    echo "⚠️ 工具链缺 SwiftUIMacros 插件（随完整 Xcode 提供）；回退 SDKROOT=$(basename "$SDK")" >&2
fi

cd "$ROOT"
TASK="${1:-build}"
shift || true

case "$TASK" in
    build)   exec swift build --package-path . --scratch-path .build "$@" ;;
    test)    exec swift test  --package-path . --scratch-path .build "$@" ;;
    release) exec ./build.sh "$@" ;;
    *)
        echo "用法: scripts/dev.sh [build|test|release] [额外参数…]" >&2
        exit 2
        ;;
esac
