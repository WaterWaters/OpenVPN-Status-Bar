# AGENTS.md

## Project

SwiftPM macOS menu-bar app (`LSUIElement`), no Xcode project. Swift 5.9+, macOS 13+. Pure Swift — no lint/typecheck/formatter config beyond `.editorconfig` (UTF-8, LF, trim trailing WS, 4 spaces for `*.swift`/`*.sh`, 2 for `*.html`/`*.css`).

## Build & Test — exact commands

```bash
swift test --package-path . --scratch-path .build          # unit tests (requires macOS SDK; fails with bare CommandLineTools — CI uses macos-latest)
swift build -c release --package-path . --scratch-path .build  # compile only
./build-openvpn.sh                 # builds static self-contained openvpn → vendor/openvpn (network + ~1-2 min, cached in .build/openvpn-cache)
./build-openvpn.sh --rebuild       # force full rebuild
./build.sh                         # assembles VPNStatusBar.app + dist/ + DMG (calls swift build internally)
ARCHS=universal ./build.sh         # dual arm64+x86_64 — requires full Xcode (xcbuild); default is native arch
VERSION=3.1.0 ./build.sh           # override version (Info.plist + DMG name; default already 3.1.0 in build.sh)
```

CI (`.github/workflows/build.yml`) on `macos-latest`: `swift test` + `swift build -c release` + a packaging job
(`VERSION=9.9.9 ./build.sh`, then asserts bundle contents / icon / version / `codesign --verify --deep --strict`)
+ a manual (`workflow_dispatch`) `engine` job that runs `./build-openvpn.sh` and `./vendor/openvpn --version`.
Release (`.github/workflows/release.yml`) runs on a `v*` tag: builds the engine, asserts tag == CHANGELOG section,
packages the DMG on an arm64 runner, writes `SHA256SUMS.txt`, and creates the GitHub Release.

### Release

1. `build.sh` default `VERSION` + `CHANGELOG.md` `## [X.Y.Z] - YYYY-MM-DD` + README download filename must agree.
2. Merge to `main`, then `git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin main vX.Y.Z`.
3. The workflow fails if the tag has no matching CHANGELOG section, so docs and release cannot drift silently.
4. Artifact is arm64 (engine is built for the runner arch); Intel users build from source.

## Architecture

- `Package.swift:6-24` — two targets only: `VPNStatusBarCore` (library, `Sources/VPNStatusBarCore/`) + `VPNStatusBar` (executable, `Sources/VPNStatusBar/`, depends on Core). Test target `VPNStatusBarCoreTests`.
- `Sources/VPNStatusBarCore/` — pure logic, no UI/I/O (`VPNStatus.swift`, `EngineAuth.swift`). Keep it that way — this is what tests cover.
- `Sources/VPNStatusBar/` — SwiftUI panel, `VPNManager` state machine, `Keychain`, `App.swift` entrypoint.
- `Support/vpn-runner.sh` — openvpn launcher, bundled into `Contents/Resources/`. App passes `--openvpn/--ovpn/--auth/--log/--session-note`; fallback probes brew paths + sudoers. Logs are **appended** (`--log-append`): each start first writes a `--session-note` separator line, and the app only judges credential failures from the current session (`OpenVPNLog.currentSession`) — do not reintroduce truncation without revisiting that.
  **日志读取只读末尾窗口**（展示 16 KB / 凭据判定 64 KB，见 `Sources/VPNStatusBar/LogFile.swift`），切片走 `OpenVPNLog.currentSessionFromTail(_:tailIsWholeFile:)`；窗口里没有分隔行**且文件更长**时必须回落整文件读（拿窗口内容当"本次会话"会把上一轮的 AUTH_FAILED 误判成本轮，`OpenVPNLogTailTests` 锁的就是这条）。
- `Sources/VPNStatusBar/` 高频状态一律单独发布，**不要**塞进 `VPNManager` 的 `@Published`：1 Hz 流量走 `TrafficStore`（只有 `TrafficInline` 订阅）、秒级时钟走 `TickProvider`（只有 `DurationText`/`RetryCountdown` 订阅）。挂在 `VPNManager` 上会让每个 `@EnvironmentObject` 视图（整块面板 + 菜单栏 label）跟着重算。
- `vendor/openvpn` — gitignored static binary; `build.sh` copies it to `Contents/Resources/openvpn` if present, else warns and falls back to system openvpn.
- `.app` bundle is assembled manually in `build.sh` (Info.plist, `icon.png`→`AppIcon.icns` via `sips`/`iconutil`, `codesign --force --deep --sign -` ad-hoc). `dist/` and `*.dmg`/`VPNStatusBar.app/`/`.build/` are gitignored. DMG uses `dist-src/gen-dmg-bg.swift` + `dist-src/dmg-layout.applescript` (requires Finder automation permission).

## Conventions

- New testable logic → `Sources/VPNStatusBarCore/` + test in `Tests/VPNStatusBarCoreTests/` (see `CONTRIBUTING.md`).
- **UI 文案是单语言简体中文，写在代码内的表里**：`Sources/VPNStatusBar/L10n.swift` 与 `Sources/VPNStatusBarCore/L10nCore.swift`。**不要**再引入 `.lproj`/`Bundle.module`/资源 bundle —— 资源缺失或 strings 文件损坏时界面会整个退化成裸 key（如 `status.retry`），真机上出现过一次；`L10n.tr` 遇到未登记的 key 会返回 key 本身并写日志。
- Commits: Simplified Chinese, verb-led conventional prefix (`feat:`, `fix:`, `ci:`, `docs:`). No company names in code/docs.
- PR must pass `swift test` + `swift build -c release` per `.github/PULL_REQUEST_TEMPLATE.md`; UI changes need screenshots, connection changes need panel log.
- `Sources/VPNStatusBarCore` must stay free of imports beyond `Foundation`/`SwiftUI` types used as value types — no process/Keychain/sudo calls.

## Gotchas

- Always pass `--package-path . --scratch-path .build` — build dir is `.build/` at repo root (also holds `openvpn-cache`/`openvpn-embed`).
- This host has only CommandLineTools (`xcodebuild` fails). `swift test` and `ARCHS=universal` will fail locally — verify via `swift build` native or rely on CI.
- `build-openvpn.sh` 按 `uname -m` 编译引擎（arm64 / x86_64），`--rebuild` 前先删 `.build/openvpn-embed`；
  `ARCHS=universal ./build.sh` 不会改变引擎架构，`build.sh` 会警告。
- Do not commit `vendor/openvpn`, `VPNStatusBar.app/`, `dist/`, `*.dmg`, `design/`, `.build/` — all gitignored.
- `build.sh` DMG layout via `osascript` may fail with permission error — non-fatal, app still usable. Detaches `/Volumes/VPNStatusBar` before create.
- **不要在面板根视图（或任何会改变面板高度的状态上）加 `.animation(_:value:)` / `withAnimation`**：`MenuBarExtra` 的窗口高度跟随内容，动画化高度变化会让窗口在中间态反复改尺寸，错位会卡在半路。尺寸变化一律瞬时；要动效只对颜色/透明度做。
- **面板是固定高度（`PanelMetrics.height`），不要引入任何会改变面板高度的东西**：
  `MenuBarExtra(.window)` 在内容变矮时**不会回收窗口高度**，而 SwiftUI 内容视图钉在窗口**左下角** ——
  两者叠加会让"面板高度变化"变成"面板整体下移"；再叠加"切换瞬间窗口尺寸与内容不同步"，就是"闪一下"；
  事后按内容高度去手动对齐窗口（曾经有 `PanelWindowFitter`）只能在"错位一帧"和"裁掉一帧"之间二选一。
  所以现在的做法是：**面板高度恒定**（360pt，卡片式布局把信息压进这个高度内，放不下就标签内滚动），
  窗口尺寸从头到尾不变 ⇒ 错位/闪烁/下方吞点击的透明区域三类问题一并消失，也不需要任何窗口对齐代码。
  要加内容就往卡片里加、或让该标签内部滚动，**不要**改成自适应高度。
- **busy 态（连接中/重连中）里不要用 SwiftUI 做持续动效 —— 一律 CoreAnimation**：真机 + 探针实测（同一条件：
  面板内容渲染过一次、窗口不可见、25 秒 CPU 增量）—— SwiftUI `.repeatForever` 插值动画 ≈ 8.6%；
  改成"每秒改 5 次 @State 的低频阶跃"≈ 9.8%（**降频没用**：只要让 SwiftUI 在 busy 态反复改状态，
  整块面板的视图树就要跟着重算）；两处都换成静态 ≈ 0.9%；改成 CA 层动画（`Pulse.swift` 的 `PulsingDot`）≈ 0.04%。
  另外 `MenuBarExtra` 的面板窗口**不可见时也照跑**（这正是不动就有 9% 空转的来源），所以动画还必须
  按 `PanelVisibility.isVisible` 开关。菜单栏 label 里不做动画（label 不能可靠承载 NSViewRepresentable，
  忙碌只靠颜色 + 无障碍文案表达）；想加持续动效，先把上面这组数复测一遍再动手。
- 测量这类"空转能耗"的现成办法：`ps -p <pid> -o time=` 取两次差值（20–30 秒窗口）比 `top` 的瞬时值稳；
  `sample <pid> 3 -file /tmp/x.txt` 看 `Call graph` 里 `ViewGraphRootValueUpdater.render` / `NSHostingView.layout`。
- **状态机不允许出现"busy 但没有在飞的动作"**：`connecting/reconnecting` 必须至少满足其一 —— 有 openvpn 进程、
  启动序列在飞（`isStarting` 且在 `TunnelConvergence.startGrace` 内）、重试已武装（`retryTimer != nil`）。
  收敛兜底在 `VPNManager.refreshState` 里按 `TunnelConvergence.verdict`（Core，带单测）执行；
  看门狗节奏由 `WatchdogPolicy` 决定：busy 5 秒 / 已连接或期望连接 30 秒 / **空闲断开完全停表**。
  这条不变量是真机故障换来的：曾出现"一直重连中、无隧道、无重试、图标一直呼吸、9% CPU"且永不恢复。
  新增计时器时：一律 `RunLoop.main.add(_, forMode: .common)`（默认模式在 modal 循环里不触发，是上述故障的成因之一）
  并设 `tolerance`（让系统合并唤醒）。
- Engine auth installs to `/usr/local/vpnstatusbar/openvpn` + `/usr/local/vpnstatusbar/vpn-run.sh` +
  `/etc/sudoers.d/vpnstatusbar` at runtime — not part of build. **sudoers only authorizes the wrapper**
  (`vpn-run.sh`), never the openvpn binary: the wrapper validates the config (directive denylist) and only
  accepts `validate/start/stop/status`. Changing the wrapper requires re-authorization (it is root-owned
  and installed at authorize time); keep app-side logic in the user-owned `vpn-runner.sh` instead.
