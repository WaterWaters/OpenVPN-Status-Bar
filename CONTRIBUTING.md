# 参与贡献

感谢你愿意为 VPNStatusBar 贡献代码。以下是参与开发的约定，请先读一遍。

## 开发环境

- macOS 13.0+，Swift 5.9+（完整 Xcode 或 CommandLineTools）。
- 单元测试需要完整 Xcode（SDK 含 XCTest）。

## 本地构建

```bash
cd VPNStatusBar

# 构建内置 openvpn 引擎（静态自包含；首次需联网下载源码）
./build-openvpn.sh

# 编译 + 打包 .app / DMG
./build.sh
```

## 代码结构

| 目录 | 说明 |
|---|---|
| `Sources/VPNStatusBarCore/` | 可测试的纯逻辑（枚举、状态、格式化），**无 UI / 无 I/O** |
| `Sources/VPNStatusBar/` | app 本体：SwiftUI 面板、VPNManager 状态机、Keychain |
| `Support/vpn-runner.sh` | openvpn 启动脚本（app 内置副本） |
| `Tests/VPNStatusBarCoreTests/` | 单元测试 |

## 提交流程

1. 先跑测试与编译，保证通过：

   ```bash
   swift test --package-path . --scratch-path .build
   swift build -c release --package-path . --scratch-path .build
   ```

2. 从新分支发起 PR（描述改动、截图/行为变化、验证方式）。
3. 走 [PR 模板](https://github.com/WaterWaters/OpenVPN-Status-Bar/blob/main/.github/PULL_REQUEST_TEMPLATE.md)。

## 约定

- **纯逻辑放 Core**，方便加测试；UI / 系统调用留在 app 层。
- 新增可测逻辑请补 `Tests/VPNStatusBarCoreTests/` 用例。
- 文案统一用简体中文；不出现公司名。
- 提交信息用简体中文、动词开头（如 `feat:` `fix:` `ci:` `docs:`）。
- 改动 UI 前可参考 `design/`（本地）设计稿。

## 开发工具（可选）：DeepSeek Harness

本项目在部分功能开发 / 重构 / 文档过程中使用了 **DeepSeek Harness**（一个 AI 编码辅助环境，提供可编排的自动编码代理）。它同样欢迎贡献者使用，示例场景：

- 拆分子任务并行实现（如抽 Core 库、补单元测试、CI 编排）。
- 自动审查 / 补测试 / 修复编译错误。
- 生成或修订文档（README、CHANGELOG、模板）。

如果使用 DeepSeek Harness，建议遵循「纯逻辑进 `Sources/VPNStatusBarCore/`、可测逻辑补单测」的约定，并让代理产出可本地 `swift build` / CI `swift test` 通过的提交，再人工 review。

## 问题反馈

- Bug / 功能建议走 [Issue](https://github.com/WaterWaters/OpenVPN-Status-Bar/issues)，用模板填写，附上 app 面板「日志」内容更利于排查。
