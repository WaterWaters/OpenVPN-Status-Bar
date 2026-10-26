#!/usr/bin/env bash
# 工具链兼容判断（被 build.sh 与 scripts/dev.sh 共用）。
#
# 背景：macOS 27 起 @State/@Environment 等改由宏实现，宏的实现插件 SwiftUIMacros 只随完整 Xcode 提供。
# 只装 CommandLineTools 时直接 swift build 会失败（报一堆 "self is immutable"）。
# 此时回退到仍用 propertyWrapper 实现的较旧 SDK —— 本项目不依赖新宏，编译/运行行为不变。

vpnstatusbar_needs_sdk_fallback() {
    [ -z "${SDKROOT:-}" ] || return 1
    [ ! -e "$(xcode-select -p)/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]
}

# 输出可用的旧 SDK 路径；无需回退时输出空串并返回 0；需要回退但找不到时返回 1。
vpnstatusbar_fallback_sdkroot() {
    vpnstatusbar_needs_sdk_fallback || return 0
    local sdk
    for sdk in $(ls -dr /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null); do
        [ -d "$sdk" ] || continue
        if ! grep -q "macro State" \
            "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*.swiftinterface \
            2>/dev/null; then
            echo "$sdk"
            return 0
        fi
    done
    return 1
}
