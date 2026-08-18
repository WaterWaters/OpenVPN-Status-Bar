# VPNStatusBar v3 · 内置 openvpn + 一次性授权设计说明

> 设计稿：`design/mockup-v3.html`（含设置页 / 授权流程交互演示，浏览器直接打开）
> Token：沿用 `design/tokens.css`（颜色语义 reuse：ok / busy / danger / focus / switch）
> 状态：**设计稿待批准 → 通过后落地 SwiftUI**

## 目标与背景

**现状（v2.1）**：openvpn 依赖用户本机安装，`vpn-runner.sh` 探测 brew 路径 + 依赖用户手动配置
sudoers NOPASSWD 免密。痛点：

1. **安装方式不对** —— 有的机器没装、装错前缀（`/opt/homebrew` vs `/usr/local`）、sbin 未链接。
2. **权限不足 / 授权弹窗被误关** —— 首次授权要用户手动 shell 或点弹窗，容易漏掉、关错，之后连不上一头雾水。
3. **没有一处「授权到底是什么、是否成功」的可见状态**。

**目标（v3）**：**把 openvpn 直接打包进 app**（自带引擎，不再依赖用户安装），**打开 app 时一次性授权**
（弹一次管理员密码 → 写入 sudoers 免密），并把授权状态与配置集中到**独立设置页**，提供兜底按钮
（误关弹窗后可在设置里重新发起）。

## 核心架构

### 1. 自带 openvpn 二进制

- `build.sh` 把预构建的 **openvpn（Universal：arm64 + x86_64）** 打进
  `VPNStatusBar.app/Contents/Resources/openvpn`。
- **不再探测 brew 路径、不再要求 `brew install openvpn`。**
- 前置依赖（分发前准备）：需先产出一个 macOS Universal 的 openvpn 静态/自包含二进制放入 `Support/` 或构建目录；
  推荐 `brew install openvpn` 后取 `$(brew --prefix openvpn)/sbin/openvpn` 并 `lipo` 合成，或直接编译自包含二进制。

### 2. 一次性能动到稳定路径（关键设计）

`.app` 包内的路径随用户放置位置变动（桌面 / Applications / 下载…），若 sudoers 直指 `.app` 内路径，
**移动 app 会导致授权失效**。因此：

- 首次授权时，把内置二进制**同步到稳定路径** `/usr/local/vpnstatusbar/openvpn`（`install -m 755`）。
- sudoers 免密规则**永远指向这个稳定路径** → 移动 app / app 更新都不失效。
- app 每次启动做一次「同步校验」：若稳定路径二进制不存在或版本落后 → 用 admin 权限覆盖更新
  （路径不变 → **无需重新授权**）。

### 3. 一次性授权（弹一次管理员密码）

首次使用时触发 `osascript do shell script … with administrator privileges`（系统管理员密码弹窗），
一次性完成三件事后即免密：

1. 创建 `/usr/local/vpnstatusbar/` 并安装二进制；
2. 写入 `/etc/sudoers.d/vpnstatusbar`：`<user> ALL=(root) NOPASSWD: /usr/local/vpnstatusbar/openvpn`；
3. 记录授权时间（UserDefaults）。

> 用户取消/关掉弹窗 → 进入**未授权**态 → 主面板提示 + 设置页可再次发起（兜底）。

## 授权状态机

| 状态 | 判定 | 表现 |
| --- | --- | --- |
| `authorized` 已授权 | 稳定路径二进制存在 **且** `sudo -n -l /usr/local/vpnstatusbar/openvpn` 退出码 0 | 设置页显示引擎版本 · 路径 · 授权时间；可「重新授权」修复 |
| `unauthorized` 未授权 | 二进制存在但 sudo 未授权（sudoers 未写 / 被删 / 用户换了） | 主面板警示行 + 设置页「授权 VPN…」主按钮 |
| `authorizing` 授权中 | 弹窗处理中 / 写规则中 | 按钮转加载态，禁防重复 |
| `broken` 异常 | sudoers 授权正确但二进制缺失/被移动（升级残留 / 被安全软件清理） | 设置页「修复并重新授权…」（重装二进制 + 补授权） |

## 主面板（保持简洁，minimal 改动）

- **新增**：未授权/异常时，在主操作下方显示一条**警示行**「⚠️ VPN 引擎未授权 · 去设置授权」，
  点击 → 打开设置页（定位到授权卡）。已授权时不显示，界面与 v2 一致。
- 底部入口由「配置…」改为 **「设置…」**（齿轮）→ 打开独立设置页。
- 其余（状态块 / 主操作 / 自动重连 / 事件 / 日志 / 退出）保持不变。

## 设置页（独立子视图，面板内展开）

头部：返回 chevron + 「设置」

### A. 授权 · VPN 引擎
- **状态卡**：图标 + 主状态文案（已授权 / 未授权 / 授权中 / 异常）+ 说明行
  - 已授权：`openvpn 2.7.x · arm64 · /usr/local/vpnstatusbar/openvpn · 授权于 2025-03-14`
  - 未授权：`需要一次授权，以系统管理员身份建立 VPN 隧道。只弹一次，密码仅用于写入免密规则。`
- **按钮**：
  - 未授权 → `授权 VPN…`（绿，主）
  - 已授权 → `重新授权…`（中性，次，用于修复/重置）
  - 异常 → `修复并重新授权…`（danger，主）
  - 授权中 → 按钮转加载（禁用）
- 说明行（始终）：若授权弹窗被误关，可点此按钮再次发起，不会重复扣权限。

### B. 连接配置
- 配置卡：配置文件（dev-ai.ovpn）· 服务器地址 · 用户名（脱敏）
- 按钮：
  - 已配置 → `修改配置…`（复用 v2 向导，edit 模式）
  - 未配置 → `导入配置…`（复用 v2 向导，import 模式）
  - `清除配置…`（danger，二次确认）→ 回未配置

## 与现状的差异（交互）

| 现状（v2.1） | 新设计（v3） |
| --- | --- |
| 依赖 `brew install openvpn` + 手动 sudoers | **自带二进制**，一次性授权（弹一次管理员密码） |
| openvpn 环境行直接散在主面板 | 独立**设置页**集中管理授权 + 配置 |
| 「配置…」只进导入/修改向导 | 底部「设置…」→ 设置页（授权 + 配置两区） |
| 授权失败/误关无兜底入口 | 主面板警示行 + 设置页「授权 VPN…」按钮可重发 |
| 无授权可见状态 | 授权状态机（已授权/未授权/授权中/异常）+ 版本/路径/时间 |

## SwiftUI 落地计划（设计通过后执行）

**修改文件：**

1. `build.sh`
   - 新增：把预构建 `openvpn`（Universal）打进 `Contents/Resources/openvpn`（保留原 Resources/vpn-runner.sh）。
2. `Sources/VPNStatusBar/VPNManager.swift`
   - 新增 `enum EngineAuthState`（authorized / unauthorized / authorizing / broken）+ `@Published engineAuth`
   - 引擎授权：`syncBundledBinary()`（同步稳定路径）+ `authorize()`（osascript admin 弹窗写 sudoers）
     + `refreshEngineAuth()`（判 定）+ `repair()`（重装 + 重授权）
   - 替换 `OpenVPNCheck` 探测逻辑：不再探测 brew，只校验稳定路径二进制 + `sudo -n -l`
   - `connect()`：未授权时给事件提示并引导去设置
3. `Sources/VPNStatusBar/ContentView.swift`
   - 底部「配置…」→「设置…」；新增 `SettingsView`（授权卡 + 配置卡 + 各按钮）
   - 主面板：未授权警示行
   - 复用 v2 `SetupWizard`（edit / import 模式不变）
4. `Support/vpn-runner.sh`
   - 参数化：`--openvpn <稳定路径>`，移除 brew 探测；仍走 `sudo -n` + management 接口
   - 保留 `--ovpn / --auth / --log`

**验证：**
- 全新安装（无 brew openvpn）→ 主面板警示「未授权」→ 设置 →「授权 VPN…」→ 弹一次密码 →
  已授权 → 连接成功；重启 app 后仍已授权（无需再授权）
- 授权弹窗点「取消」→ 未授权 → 设置按钮可再次发起（兜底）
- 移动 app / 升级 app → 授权不失效（稳定路径 + 每次启动同步校验）
- 删掉稳定路径二进制 → broken →「修复并重新授权…」恢复
- 浅色/深色下对比度达标
