# Changelog

本项目变更记录采用 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [3.1.0] - 2026-10-26

### Added

- 新增 `VPNStatusBarCore` 库目标与单元测试（`swift test`）：隧道状态、management 协议解析、日志会话判读、
  收敛兜底均有覆盖。
- 新增 `TunnelConvergence`/`WatchdogPolicy`（Core，带单测）：把「busy 状态必须有一个在飞的动作」写成显式判定，
  并规定看门狗节奏（busy 5 秒 / 已连接或期望连接 30 秒 / 空闲断开停表）。
- 安全加固：免密规则改为**只放行 root 属主的启动包装脚本** `/usr/local/vpnstatusbar/vpn-run.sh`，
  该脚本只接受 `validate/start/stop/status`、引擎路径写死，并拒绝 `up`/`down`/`plugin`/`script-security`
  等可提权执行外部程序的配置指令；从旧版升级时检测并提示残留的 Homebrew 免密规则。
- 面板改为固定高度卡片布局 + 概览/配置/设置/诊断分段页；新增「取消连接」、日志复制/打开、
  键盘焦点与「减少动态效果」适配。
- 通过 management 接口读取真实隧道状态与流量，并支持按需启停的秒级时钟。

### Fixed

- 修复「一直重连中、没有隧道、也不重试」的死状态：`refreshState` 不再在 `isWaitingRetry` 上直接 return，
  由收敛兜底改回可解释状态；重试计时器进 `.common` run-loop 模式（modal 循环期间也会触发）。
- 修复 busy 态空转 9% CPU：呼吸动效改为 CoreAnimation 层动画（app 不再逐帧参与；实测 8.6% → 0.04%），
  面板不可见时不呼吸；菜单栏忙碌态改为静态着色（不再逐帧重绘）。
- 修复重连倒计时不刷新（改为 `RetryCountdown` 订阅 1 秒时钟）。
- 修复凭据失效后无限重连：检测到本次会话的 `AUTH_FAILED` 即停止重连并提示更新密码。
- 修复非 `.app` 方式启动（`swift run`）时通知中心抛异常导致进程退出的问题。

### Changed

- 实时流量拆到 `TrafficStore`、日志读取只读文件末尾窗口并在后台解析、`profiles.json` 加进程内缓存 ——
  面板可见时的 1 Hz 推送不再牵动整块面板，主线程不再整读 512 KB 日志。
- 日志改为追加并写入会话分隔行，凭据判定只看本次会话，历史会话不再被覆盖。
- UI 文案改为代码内简体中文表（移除 `.lproj`/资源 bundle），避免资源缺失时界面退化成裸 key。
- 打包体积：`build.sh` 图标不再生成 512/1024 插值档位（519 KB → 约 54 KB）；
  `build-openvpn.sh` 追加 `strip -u -r`（引擎 4.88 MB → 4.50 MB），并按主机架构编译。
- 新增 tag 触发的发布工作流：CI 构建引擎 + DMG，校验版本号与 CHANGELOG 一致后自动创建 Release。

## [3.0.0] - 2026-08-18

### Added

- 内置自包含 openvpn 引擎（`build-openvpn.sh` 静态编译，ARM64），不再依赖用户安装 Homebrew。
- 设置页新增「授权 · VPN 引擎」：一键授权（一次性管理员密码写入 sudoers 免密）、授权状态机（已授权 / 未授权 / 授权中 / 异常）与修复按钮。
- 主面板新增未授权警示行；底部入口由「配置…」升级为「设置…」（授权 + 配置管理）。
- `.github/workflows/build.yml`：macOS 上编译校验并上传二进制产物。

### Changed

- `vpn-runner.sh` 参数化 `--openvpn/--ovpn/--auth/--log`，优先使用内置引擎，保留旧探测兜底。
- README 改为用户向文档。

## [2.0.0] - 2026-07

### Added

- 应用内初始化：面板内导入 `.ovpn` + 用户名/密码，不再依赖文件夹放置文件。
- 凭据存 Keychain，连接时临时生成 auth 文件、断开即删。
- 未配置状态与初始化向导。

## [1.0.0] - 2026-06

### Added

- 初始版本：菜单栏一键连接/断开、断线自动重连、日志展示。
