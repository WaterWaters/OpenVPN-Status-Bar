# VPNStatusBar

[![Build](https://github.com/WaterWaters/OpenVPN-Status-Bar/actions/workflows/build.yml/badge.svg)](https://github.com/WaterWaters/OpenVPN-Status-Bar/actions/workflows/build.yml)

中唐 VPN 的 macOS 菜单栏小工具：点一下菜单栏图标就能连接 / 断开公司 VPN，断线自动重连，全程无需命令行。

**内置 openvpn 引擎，开箱即用** —— 不需要安装 Homebrew，也无需手动配置任何权限。

## ✨ 功能

- 🔌 **一键连接 / 断开**：菜单栏图标点一下就连上，再点一下断开
- 📶 **状态一目了然**：🟢 已连接（显示时长）· 🟠 连接中 / 重连中 · ⚪ 已断开 / 未配置
- 🔁 **断线自动重连**：远端强制断开后自动恢复，不打断你干活
- 🧩 **内置引擎**：openvpn 已打进 app，无需自己安装、版本一致，避开各种安装坑
- 🔐 **授权一次，之后免密**：首次输一次系统密码授权，之后连接不再要密码
- 📥 **配置自己管**：导入 `.ovpn` 文件 + 输入账号密码即可，密码安全存进系统钥匙串
- 🧹 **自动清理**：异常退出后下次连接自动接管，不留残留进程

## 系统要求

- macOS 13.0+（Ventura 及以上）
- Apple 芯片（M 系列）与 Intel 均可

## 安装

### 方式一：拖拽安装（推荐）

1. 打开 `VPNStatusBar-2.0.dmg`
2. 把 `VPNStatusBar.app` 拖进「应用程序（Applications）」文件夹
3. 首次打开若提示“无法验证开发者”，见 [常见问题](#常见问题)

### 方式二：从源码构建（开发者）

```bash
cd VPNStatusBar
./build-openvpn.sh   # 构建内置 openvpn 引擎（需联网 + 编译，约 1-2 分钟）
./build.sh           # 编译并打包 .app / DMG
```

## 首次使用（约 1 分钟）

1. **导入配置**：打开 app →「导入配置…」→ 选 `.ovpn` 文件 → 输入用户名和密码 → 保存
2. **授权引擎**（只需一次）：面板底部「设置…」→「授权 VPN…」→ 输入一次系统开机密码 → 显示「已授权」
3. **连接**：点「连接 VPN」，绿点 + 时长走表即连接成功

> 授权弹窗被误关？回「设置…」再点一次「授权 VPN…」即可，不影响使用。

## 使用

| 操作 | 方式 |
|---|---|
| 连接 | 菜单栏图标 →「连接 VPN」 |
| 断开 | 菜单栏图标 →「断开 VPN」 |
| 授权引擎 / 修改配置 / 清除配置 | 面板底部「设置…」 |
| 开关自动重连 | 面板内「断线自动重连」开关 |
| 退出 | 菜单内「退出 VPNStatusBar」（自动断开连接） |

图标颜色：🟢 已连接 / 🟠 连接中·重连中 / ⚪ 已断开·未配置

## 安全与隐私

- 密码只存**系统钥匙串（Keychain）**，不落明文文件；连接时临时生成认证文件，断开即删。
- 内置自带的 openvpn 引擎，无需安装第三方软体。
- “授权”仅用于以系统管理员身份建立 VPN 隧道，写完免密规则后日常使用不再需要密码。

## 常见问题

| 问题 | 解决 |
|---|---|
| 提示“无法验证开发者”/“已损坏” | 右键点 app →「打开」；或终端执行 `xattr -dr com.apple.quarantine /Applications/VPNStatusBar.app` 后重开 |
| 点连接提示“引擎未授权” | 「设置…」→「授权 VPN…」→ 输一次开机密码 |
| 设置页显示“引擎异常” | 「设置…」→「修复并重新授权…」 |
| 连接报错 sudo 需要密码 | 到「设置…」重新「授权 VPN…」，确保授权弹窗完成 |
| 连接一会儿就断开 | 属正常：远端约 30 分钟强制断开一次，app 会自动重连 |
| 点连接没反应 | 看面板「日志」，把内容发给管理员 |

## 卸载

1. 菜单栏图标 →「退出 VPNStatusBar」
2. 把 `VPNStatusBar.app` 拖进废纸篓
3. （可选）移除授权免密规则与配置：

   ```bash
   sudo rm /etc/sudoers.d/vpnstatusbar
   rm -rf ~/Library/Application\ Support/VPNStatusBar
   ```

## 开发

```bash
cd VPNStatusBar
./build-openvpn.sh   # 构建内置 openvpn 引擎（静态自包含，ARM64）
./build.sh           # 编译 + 打包 .app + DMG
```

- 修改源码后需重新 `./build.sh` 才生效（覆盖并重新签名）。
- CI：`.github/workflows/build.yml` 在 macOS 上编译校验并产出二进制。

## License

[MIT](LICENSE) · Copyright (c) 2026 Water Wang
