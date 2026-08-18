#!/usr/bin/env bash
# 编译并打包 VPNStatusBar.app（Universal Binary：Apple Silicon + Intel）
set -euo pipefail

APP_NAME="VPNStatusBar"
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

swift build -c release \
    $ARCH_FLAGS \
    --package-path "$SCRIPT_DIR" \
    --scratch-path "$BUILD_DIR"

BIN="$BUILD_DIR/release/$APP_NAME"
if [ ! -f "$BIN" ]; then
    echo "❌ 编译产物不存在: $BIN"
    exit 1
fi

echo "==> 组装 .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp -f "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# 参数化 vpn-runner.sh（app 内置副本，自包含；运行时通过资源目录调用）
cp -f "$SCRIPT_DIR/Support/vpn-runner.sh" "$APP_BUNDLE/Contents/Resources/vpn-runner.sh"

# 内置自包含 openvpn（build-openvpn.sh 静态编译产物；v3：不再依赖用户 brew 安装）
if [ -f "$SCRIPT_DIR/vendor/openvpn" ]; then
    cp -f "$SCRIPT_DIR/vendor/openvpn" "$APP_BUNDLE/Contents/Resources/openvpn"
    chmod +x "$APP_BUNDLE/Contents/Resources/openvpn"
    echo "    ✅ 已内置 openvpn ($(lipo -archs "$APP_BUNDLE/Contents/Resources/openvpn" 2>/dev/null | tr '\n' ' '))"
else
    echo "    ⚠️ 未找到 vendor/openvpn，跳过内置引擎（连接将依赖本机 openvpn）"
fi

# app 图标：icon.png → AppIcon.icns（含全部标准尺寸）
ICON_PNG="$SCRIPT_DIR/icon.png"
if [ -f "$ICON_PNG" ]; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET_DIR"
    for s in 16 32 64 128 256 512; do
        sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET_DIR/icon_${s}x${s}.png" >/dev/null 2>&1
    done
    for s in 32 64 128 256 512 1024; do
        h=$((s/2))
        sips -z "$s" "$s" "$ICON_PNG" --out "$ICONSET_DIR/icon_${h}x${h}@2x.png" >/dev/null 2>&1
    done
    iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$(dirname "$ICONSET_DIR")"
    echo "    ✅ 已生成 AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>VPNStatusBar</string>
    <key>CFBundleDisplayName</key>
    <string>VPNStatusBar</string>
    <key>CFBundleIdentifier</key>
    <string>local.zhongtang.vpnstatusbar</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
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
cp -f "$SCRIPT_DIR/dist-src/打开指引.html" "$DIST_DIR/"

# 使用说明（合并版：安装 + 使用 + 常见问题 + 安全提示）
cat > "$DIST_DIR/使用说明.md" <<'MD'
# VPNStatusBar — 中唐 VPN 状态栏工具

菜单栏一键连接/断开公司 VPN，断线自动重连（应对远端 30 分钟强制断开）。
**v3 起 openvpn 已内置进 app，无需安装任何东西；只需在设置里授权一次。**

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
| 授权引擎 / 修改配置 / 清除配置 | 面板底部 → 「设置…」 |
| 自动重连开关 | 面板内「断线自动重连」 |

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
| 点连接没反应 | 看面板「日志」，把日志发管理员 |
MD

echo "✅ 分发包已生成: $DIST_DIR"

# 生成 DMG 安装镜像（含 Applications 拖拽快捷方式 + 背景图 + 布局）
echo ""
echo "==> 生成 DMG 安装镜像 ..."
DMG_STAGING="$SCRIPT_DIR/.dmg-staging"
DMG_NAME="VPNStatusBar-2.0.dmg"
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
cp -f "$SCRIPT_DIR/dist-src/打开指引.html" "$DMG_STAGING/"
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
