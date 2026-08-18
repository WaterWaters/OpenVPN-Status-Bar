# Changelog

本项目变更记录采用 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- 新增 `VPNStatusBarCore` 库目标与单元测试（`swift test`）。
- 新增 GitHub Actions 测试任务与 CI 徽章。

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
