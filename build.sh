#!/usr/bin/env bash
# 编译并打包 VPNStatusBar.app（Universal Binary：Apple Silicon + Intel）
set -euo pipefail

APP_NAME="VPNStatusBar"
# 版本号唯一来源：Info.plist 与 DMG 文件名都取自这里；发版时改这里，并打同名 tag（vX.Y.Z）。
# CI 发版（.github/workflows/release.yml）用 tag 值覆盖它，并校验 CHANGELOG 有对应段落。
VERSION="${VERSION:-3.1.0}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"

echo "==> 编译 Release..."
# 架构策略：
#   默认 native —— 编译本机架构（仅 CommandLineTools 时的选择）
#   ARCHS=universal —— 双架构（arm64 + x86_64），需完整 Xcode（含 xcbuild）
ARCH_FLAGS=""
if [ "${ARCHS:-native}" = "universal" ]; then
    echo "    （universal：arm64 + x86_64，需完整 Xcode）"
    ARCH_FLAGS="--arch arm64 --arch x86_64"
else
    echo "    （native：$(uname -m)）"
fi

# SDK 兼容：macOS 27 起 @State/@Environment 等改由宏实现，而宏的实现插件 SwiftUIMacros 只随
# 完整 Xcode 提供，只装 CommandLineTools 时会编译失败（报错是一堆 "self is immutable"）。
# 此时自动回退到仍用 propertyWrapper 实现的较旧 SDK —— 本项目不依赖新宏，编译/运行行为不变。
if [ -z "${SDKROOT:-}" ] && [ ! -e "$(xcode-select -p)/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
    for sdk in $(ls -dr /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null); do
        [ -d "$sdk" ] || continue
        if ! grep -q "macro State" \
            "$sdk"/System/Library/Frameworks/SwiftUICore.framework/Versions/A/Modules/SwiftUICore.swiftmodule/*.swiftinterface \
            2>/dev/null; then
            export SDKROOT="$sdk"
            echo "    ⚠️ 工具链缺 SwiftUIMacros 插件（该插件随完整 Xcode 提供）；回退 SDKROOT=$(basename "$sdk")"
            break
        fi
    done
    if [ -z "${SDKROOT:-}" ]; then
        echo "    ❌ 未找到可用的旧 SDK。请安装完整 Xcode，或手动指定 SDKROOT=/path/to/MacOSX*.sdk"
        exit 1
    fi
fi

swift build -c release \
    $ARCH_FLAGS \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -Osize \
    -Xlinker -dead_strip \
    --package-path "$SCRIPT_DIR" \
    --scratch-path "$BUILD_DIR"

BIN="$BUILD_DIR/release/$APP_NAME"
if [ ! -f "$BIN" ]; then
    echo "❌ 编译产物不存在: $BIN"
    exit 1
fi
# 去除非必要符号（保留 codesign 所需）
strip -S -x "$BIN" 2>/dev/null || true

echo "==> 组装 .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp -f "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# 参数化 vpn-runner.sh（app 内置副本，自包含；运行时通过资源目录调用）
cp -f "$SCRIPT_DIR/Support/vpn-runner.sh" "$APP_BUNDLE/Contents/Resources/vpn-runner.sh"
# root 属主启动包装脚本：授权时由 app 安装到 /usr/local/vpnstatusbar/（sudoers 只放行它）
cp -f "$SCRIPT_DIR/Support/vpn-run.sh" "$APP_BUNDLE/Contents/Resources/vpn-run.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/vpn-run.sh"

# 内置自包含 openvpn（build-openvpn.sh 静态编译产物；v3：不再依赖用户 brew 安装）
if [ -f "$SCRIPT_DIR/vendor/openvpn" ]; then
    cp -f "$SCRIPT_DIR/vendor/openvpn" "$APP_BUNDLE/Contents/Resources/openvpn"
    chmod +x "$APP_BUNDLE/Contents/Resources/openvpn"
    ENGINE_ARCHS="$(lipo -archs "$APP_BUNDLE/Contents/Resources/openvpn" 2>/dev/null | tr '\n' ' ')"
    echo "    ✅ 已内置 openvpn ($ENGINE_ARCHS)"
    if [ "${ARCHS:-native}" = "universal" ] && ! echo "$ENGINE_ARCHS" | grep -q x86_64; then
        echo "    ⚠️ 内置引擎只有 $ENGINE_ARCHS，Intel 机器上无法运行；universal 包请先在 Intel 上构建引擎或用 lipo 合并"
    fi
else
    echo "    ⚠️ 未找到 vendor/openvpn，跳过内置引擎（连接将依赖本机 openvpn）"
fi

# app 图标：icon.png → AppIcon.icns
# 档位只保留 16/32/128 与其 @2x（64/256）：源图 icon.png 只有 200px，再往上的 512/1024
# 只是 sips 插值放大出来的 —— 既不清晰又占体积（实测这三档就吃掉 465 KB / 519 KB）。
ICON_PNG="$SCRIPT_DIR/icon.png"
if [ -f "$ICON_PNG" ]; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    for s in 16 32 128; do
        sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET_DIR/icon_${s}x${s}.png" >/dev/null 2>&1
    done
    for s in 64 256; do
        h=$((s/2))
        sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET_DIR/icon_${h}x${h}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET_DIR")"
    echo "    ✅ 已生成 AppIcon.icns（$(du -h "$APP_BUNDLE/Contents/Resources/AppIcon.icns" | cut -f1)）"
    SRC_PX="$(sips -g pixelWidth "$ICON_PNG" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    if [ -n "$SRC_PX" ] && [ "$SRC_PX" -lt 512 ] 2>/dev/null; then
        echo "    ⚠️ 源图 icon.png 只有 ${SRC_PX}px：大尺寸档位只能是插值图（换 ≥512px 源图会更清晰）"
    fi
fi

# SwiftPM 资源 bundle：当前已无（UI 文案是代码内中文表，不产出 .lproj）。
# 保留这段拷贝逻辑，以便将来再加资源文件时能自动带上，避免"打包漏资源 → 启动即退出"。
for b in "$BUILD_DIR/release/"*.bundle; do
    if [ -d "$b" ]; then
        cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
        echo "    ✅ 已内置资源 bundle $(basename "$b")"
    fi
done

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VPNStatusBar</string>
    <key>CFBundleDisplayName</key>
    <string>VPNStatusBar</string>
    <key>CFBundleIdentifier</key>
    <string>io.vpnstatusbar</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>VPNStatusBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> 代码签名（ad-hoc）..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ 完成: $APP_BUNDLE"

# 生成分发包（dist/）：仅 app + 使用说明（v2 起不再需要外置脚本/.user 模板）
DIST_DIR="$SCRIPT_DIR/dist"
echo ""
echo "==> 生成分发包 $DIST_DIR ..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R "$APP_BUNDLE" "$DIST_DIR/"
# 打开指引（dist-src/ 不入库；缺失则跳过，不影响分发）
if [ -f "$SCRIPT_DIR/dist-src/打开指引.html" ]; then
    cp -f "$SCRIPT_DIR/dist-src/打开指引.html" "$DIST_DIR/"
fi

# 使用说明（合并版：安装 + 使用 + 常见问题 + 安全提示）
cat > "$DIST_DIR/使用说明.md" <<'MD'
# VPNStatusBar — 状态栏工具

菜单栏一键连接/断开 VPN，断线自动重连（应对远端定时断开）。
**openvpn 已内置进 app，无需安装任何东西；只需在设置里授权一次。支持任意标准 .ovpn 配置。**

## 安装（每台电脑只需两分钟）

### 1. 启动 & 导入配置（首次）

双击 `VPNStatusBar.app` → 显示「未配置」→ 点「导入配置…」→ 选择 `.ovpn` 文件 → 输入用户名/密码 → 保存。
配置复制进应用私有目录，密码存入钥匙串（Keychain）。

### 2. 授权 VPN 引擎（关键，一次即可）

面板底部 →「设置…」→「授权 VPN…」→ 输入一次系统开机密码 → 变为「已授权」。
此时 openvpn 已安装到系统并完成免密授权，之后连接**不再需要密码**。


> 若授权弹窗被误关，或在设置里状态显示「未授权 / 异常」，点「授权 VPN… / 修复并重新授权…」再次发起即可。

### 3. 连接

双击 `VPNStatusBar.app`（若提示"无法验证开发者"，见「常见问题」）。点「连接 VPN」。

## 使用

| 操作 | 方式 |
|---|---|
| 连接 | 菜单栏图标 → 「连接 VPN」 |
| 断开 | 菜单栏图标 → 「断开 VPN」 |
| 取消卡住的连接 | 连接超过 8 秒后主按钮变「取消连接」 |
| 授权引擎 / 修改配置 / 清除配置 | 面板「设置」标签页 |
| 自动重连开关 | 「概览」标签页的「断线自动重连」 |
| 发日志给管理员 | 「诊断」标签页 → 「复制日志」/「打开日志文件」 |

图标颜色：🟢 已连接 / 🟠 连接中·重连中 / ⚪ 已断开·未配置

## 要求

- macOS 13.0+（Ventura 及以上）
- 架构：本包为 Apple 芯片版（arm64）。Intel 同事请用源码编译：
  ```bash
  cd VPNStatusBar
  ./build.sh
  ```
  （源码会自动编译对应当前架构的内置引擎）

## 常见问题

| 问题 | 解决 |
|---|---|
| "无法打开/无法验证开发者" | 右键点 app → 打开 → 再点「打开」；或终端执行 `xattr -dr com.apple.quarantine VPNStatusBar.app` 后重开 |
| 点连接提示"引擎未授权" | 面板底部「设置…」→「授权 VPN…」→ 输一次开机密码 |
| 设置显示"引擎异常" | 「设置…」→「修复并重新授权…」（重装引擎并补授权） |
| 连接报错 sudo 需要密码 | 到「设置…」重新「授权 VPN…」，确保授权弹窗完成 |
| 反复重连后停下，事件行提示"用户名或密码错误" | app 检测到 AUTH_FAILED 已停止重连：到「设置…」→「修改当前配置…」更新密码（不必重选 .ovpn） |
| 点连接没反应 | 「诊断」标签页 → 「复制日志」后反馈（日志保留历史会话） |
MD

echo "✅ 分发包已生成: $DIST_DIR"

# 生成 DMG 安装镜像（含 Applications 拖拽快捷方式 + 背景图 + 布局）
echo ""
echo "==> 生成 DMG 安装镜像 ..."
DMG_STAGING="$SCRIPT_DIR/.dmg-staging"
DMG_NAME="VPNStatusBar-${VERSION}.dmg"
# 注意：hdiutil create 对无 .dmg 后缀的输出路径会自动补后缀，这里直接带后缀 + 先删旧
DMG_TEMPLATE="$SCRIPT_DIR/.dmg-template.dmg"
# 清理上次残留挂载（同名卷），避免 create/attach 冲突
hdiutil detach "/Volumes/VPNStatusBar" >/dev/null 2>&1 || true
hdiutil detach "/Volumes/VPNStatusBar 1" >/dev/null 2>&1 || true
rm -rf "$DMG_STAGING" "$DIST_DIR/$DMG_NAME" "$DMG_TEMPLATE"
mkdir -p "$DMG_STAGING/.background"

# 内容：app + 文档 + Applications 快捷方式（拖拽安装用）
cp -R "$APP_BUNDLE" "$DMG_STAGING/VPNStatusBar.app"
cp -f "$DIST_DIR/使用说明.md" "$DMG_STAGING/"
if [ -f "$SCRIPT_DIR/dist-src/打开指引.html" ]; then
    cp -f "$SCRIPT_DIR/dist-src/打开指引.html" "$DMG_STAGING/"
fi
ln -sf /Applications "$DMG_STAGING/Applications"

# 生成背景图（AppKit 绘制，含标题/说明/两个放置框）
BG_SCRIPT="$SCRIPT_DIR/dist-src/gen-dmg-bg.swift"
if command -v swift >/dev/null 2>&1 && [ -f "$BG_SCRIPT" ]; then
    swift "$BG_SCRIPT" "$DMG_STAGING/.background/background.png" >/dev/null 2>&1 || \
        echo "    ⚠️ 背景图生成失败（跳过，不影响使用）"
else
    echo "    ⚠️ 未找到 swift，跳过背景图（不影响使用）"
fi

# 先做可写模板（UDRW），挂载后用 AppleScript 设置布局，再转压缩格式
if hdiutil create -volname "VPNStatusBar" -srcfolder "$DMG_STAGING" \
        -fs HFS+ -format UDRW -ov "$DMG_TEMPLATE" >/dev/null 2>&1; then
    MOUNT_POINT="$(hdiutil attach -nobrowse -readwrite "$DMG_TEMPLATE" \
        | grep -o '/Volumes/VPNStatusBar[^ ]*' | head -1)"
    if [ -n "$MOUNT_POINT" ]; then
        # 布局：图标视图 + 无工具栏 + 背景图 + 图标位置
        # 用挂载点路径操作窗口（比 tell disk 卷名更稳）；失败时打印真实原因
        # 注：命令替换加 || true，避免 osascript 权限违例时 set -e 中断整个构建
        LAYOUT_ERR="$(osascript "$SCRIPT_DIR/dist-src/dmg-layout.applescript" "$MOUNT_POINT" 2>&1 || true)"
        if [ "$LAYOUT_ERR" = "OK" ]; then
            echo "    ✅ 窗口布局已设置（图标位置 + 背景）"
        else
            echo "    ⚠️ 布局设置失败：$(echo "$LAYOUT_ERR" | head -1)"
            echo "      ➤ 若提示权限违例，请先授权：系统设置 → 隐私与安全性 → 自动化 → 允许终端控制 Finder，再重跑 ./build.sh"
            echo "      ➤ 不影响使用：同事仍可直接拖拽 app 到 Applications 完成安装"
        fi
        hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1
    fi
    # 转为压缩只读格式
    hdiutil convert "$DMG_TEMPLATE" -format UDZO -o "$DIST_DIR/$DMG_NAME" >/dev/null 2>&1
    rm -rf "$DMG_STAGING" "$DMG_TEMPLATE"
    if [ -f "$DIST_DIR/$DMG_NAME" ]; then
        echo "✅ DMG 已生成: $DIST_DIR/$DMG_NAME"
    else
        echo "⚠️ DMG 转换失败（app 仍可直接使用）"
    fi
else
    echo "⚠️ DMG 创建失败（app 仍可直接使用）"
    rm -rf "$DMG_STAGING"
fi

echo ""
echo "启动: open \"$APP_BUNDLE\""
