# VPNStatusBar — 中唐 VPN 状态栏工具

macOS 菜单栏状态栏工具：一键连接/断开公司 VPN，**断线自动重连**（应对远端 30 分钟强制断开）。
**v3 起内置 openvpn 引擎，不再依赖用户安装 Homebrew / 手动配 sudoers。**

## 功能

- 🔌 **菜单栏图标控制**：点击图标 → 连接/断开 VPN
- 📶 **实时状态显示**：图标颜色区分（🟢 已连接 / 🟠 连接中·重连中 / ⚪ 已断开·未配置），面板内显示连接时长、重连次数、最近事件、openvpn 日志
- 🧩 **内置引擎（v3）**：openvpn 静态编译打进 app（`Contents/Resources/openvpn`），**无需安装 brew**
- 🔐 **一键授权（v3）**：设置页「授权 VPN…」弹一次系统管理员密码即写入免密规则，此后免密连接；授权状态（已授权/未授权/授权中/异常）与兜底按钮都在设置里
- 📥 **应用内初始化**：首次启动「未配置」，导入 .ovpn + 用户名/密码即可；配置进私有目录、密码存钥匙串
- 🔁 **断线自动重连**：远端断开后自动重连，指数退避（5s → 10s → 20s → 40s → 60s 封顶），可开关
- 🧹 **残留清理**：app 异常退出后残留的 openvpn 会在下次连接时自动清理接管
- ⌨️ **命令行控制**：`VPNStatusBar --connect` / `--disconnect`

## 安装

### 1. 编译打包

```bash
cd ~/Documents/VPN/zhongTang/VPNStatusBar
./build.sh
```

产物：`VPNStatusBar/VPNStatusBar.app`（已内置自包含 openvpn 引擎，无需任何前置安装）

### 2. 启动

```bash
open ~/Documents/VPN/zhongTang/VPNStatusBar/VPNStatusBar.app
```

首次运行显示「未配置」→ 点「导入配置…」→ 选择 `.ovpn` 文件 → 输入用户名/密码 → 保存。

**连接前需授权引擎一次**：面板底部 →「设置…」→「授权 VPN…」→ 输入一次系统开机密码 → 变为「已授权」→ 回主面板点「连接 VPN」。
（若授权弹窗被误关，在设置页点「授权 VPN…」可随时再次发起。）

### 3. 开机自启（可选）

系统设置 → 通用 → 登录项 → 添加 `VPNStatusBar.app`。

## 使用

| 操作 | 方式 |
|---|---|
| 连接 | 点击菜单栏图标 → 「连接 VPN」 |
| 断开 | 点击菜单栏图标 → 「断开 VPN」 |
| 授权引擎 / 修改配置 / 清除配置 | 面板底部 → 「设置…」 |
| 开关自动重连 | 菜单内「断线自动重连」开关 |
| 退出 | 菜单内「退出 VPNStatusBar」（自动断开连接） |

## 自动重连机制

- **双层保障**：
  1. openvpn 自身参数：`--connect-retry 5`、`--ping 15 --ping-restart 60`（死连接检测）
  2. app watchdog：检测 openvpn 进程退出（远端 30min 强制断开 → 进程退出）→ 指数退避自动重启
- 手动断开不触发重连；重连成功后退避重置为 5s
- 状态检测：`netstat` 检查 `10.8/16 → utun` 路由

## 技术要点

- **内置引擎 + 一次性授权（v3）**：openvpn 静态编译为自包含 ARM64 二进制打进 `Contents/Resources/openvpn`；首次授权时同步到稳定路径 `/usr/local/vpnstatusbar/openvpn` 并写入 `/etc/sudoers.d/vpnstatusbar` 免密规则（`<user> ALL=(root) NOPASSWD: <稳定路径>`）。因 sudoers 指向稳定路径而非 `.app` 内路径，**移动 / 升级 app 授权不失效**。
- **授权状态机**：`已授权 / 未授权 / 授权中 / 异常`，由 `sudo -n -l` 检测判定；设置页展示状态与版本/路径/架构，提供「授权 / 重新授权 / 修复并重新授权」。
- **root 处理**：openvpn 以 root 运行（创建 tun 需要），普通用户无法 kill → 通过 `--management 127.0.0.1 7505` 管理接口发送 `signal SIGTERM` 实现优雅断开，无需额外 sudo 权限。
- **配置存储（v2）**：ovpn 复制到 `~/Library/Application Support/VPNStatusBar/`；密码存 Keychain；连接时由 app 生成 `.auth.tmp`（0600），断开/退出自动删除。
- **日志**：`Application Support/VPNStatusBar/vpn.log`（启动前预创建并 chmod 644）。
- **架构**：MenuBarExtra (SwiftUI) `.window` 弹窗样式；`VPNManager` 管理连接状态机 + 引擎授权 + 配置读写；`vpn-runner.sh` 参数化调用（`--openvpn/--ovpn/--auth/--log`），app 内置副本。

## 开发

```bash
# 构建内置引擎（静态自包含 openvpn，ARM64；首次需联网下载源码）
./build-openvpn.sh

# 编译（仅 Swift）
swift build -c release --scratch-path .build

# 编译 + 打包 .app + DMG
./build.sh
```

修改源码后**必须重新编译**才生效（`build.sh` 会覆盖 .app 并重新签名）。

## 文件

| 文件 | 说明 |
|---|---|
| `build-openvpn.sh` | 静态编译自包含 openvpn（OpenSSL/LZO/LZ4 全静态）→ `vendor/openvpn` |
| `vendor/openvpn` | 内置引擎产物（build.sh 打进 `Contents/Resources/openvpn`） |
| `Support/vpn-runner.sh` | openvpn 启动脚本（参数化：--openvpn/--ovpn/--auth/--log，app 内置副本） |
| `Sources/VPNStatusBar/App.swift` | 入口（MenuBarExtra + 状态栏图标 + SIGTERM 清理） |
| `Sources/VPNStatusBar/VPNManager.swift` | 核心：引擎授权状态机 + 配置读写 + 连接状态机 + 自动重连 + management 通信 |
| `Sources/VPNStatusBar/ContentView.swift` | 面板 UI + 设置页 + 初始化向导（对应 design/mockup-v3.html） |
| `Sources/VPNStatusBar/Keychain.swift` | 密码安全存储（钥匙串封装） |
| `Sources/VPNStatusBar/DesignTokens.swift` | 设计 Token（浅色/深色自适应） |
| `build.sh` | 编译打包脚本（打包引擎 + .app + 签名 + DMG） |
