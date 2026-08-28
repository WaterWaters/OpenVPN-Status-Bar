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
VERSION=0.0.2 ./build.sh           # bump version (Info.plist + DMG name)
```

CI (`.github/workflows/build.yml`): `swift test` and `swift build -c release` on `macos-latest`, no DMG step.

## Architecture

- `Package.swift:6-24` — two targets only: `VPNStatusBarCore` (library, `Sources/VPNStatusBarCore/`) + `VPNStatusBar` (executable, `Sources/VPNStatusBar/`, depends on Core). Test target `VPNStatusBarCoreTests`.
- `Sources/VPNStatusBarCore/` — pure logic, no UI/I/O (`VPNStatus.swift`, `EngineAuth.swift`). Keep it that way — this is what tests cover.
- `Sources/VPNStatusBar/` — SwiftUI panel, `VPNManager` state machine, `Keychain`, `App.swift` entrypoint.
- `Support/vpn-runner.sh` — openvpn launcher, bundled into `Contents/Resources/`. App passes `--openvpn/--ovpn/--auth/--log`; fallback probes brew paths + sudoers.
- `vendor/openvpn` — gitignored static binary; `build.sh` copies it to `Contents/Resources/openvpn` if present, else warns and falls back to system openvpn.
- `.app` bundle is assembled manually in `build.sh` (Info.plist, `icon.png`→`AppIcon.icns` via `sips`/`iconutil`, `codesign --force --deep --sign -` ad-hoc). `dist/` and `*.dmg`/`VPNStatusBar.app/`/`.build/` are gitignored. DMG uses `dist-src/gen-dmg-bg.swift` + `dist-src/dmg-layout.applescript` (requires Finder automation permission).

## Conventions

- New testable logic → `Sources/VPNStatusBarCore/` + test in `Tests/VPNStatusBarCoreTests/` (see `CONTRIBUTING.md`).
- Commits: Simplified Chinese, verb-led conventional prefix (`feat:`, `fix:`, `ci:`, `docs:`). No company names in code/docs.
- PR must pass `swift test` + `swift build -c release` per `.github/PULL_REQUEST_TEMPLATE.md`; UI changes need screenshots, connection changes need panel log.
- `Sources/VPNStatusBarCore` must stay free of imports beyond `Foundation`/`SwiftUI` types used as value types — no process/Keychain/sudo calls.

## Gotchas

- Always pass `--package-path . --scratch-path .build` — build dir is `.build/` at repo root (also holds `openvpn-cache`/`openvpn-embed`).
- This host has only CommandLineTools (`xcodebuild` fails). `swift test` and `ARCHS=universal` will fail locally — verify via `swift build` native or rely on CI.
- Do not commit `vendor/openvpn`, `VPNStatusBar.app/`, `dist/`, `*.dmg`, `design/`, `.build/` — all gitignored.
- `build.sh` DMG layout via `osascript` may fail with permission error — non-fatal, app still usable. Detaches `/Volumes/VPNStatusBar` before create.
- Engine auth installs to `/usr/local/vpnstatusbar/openvpn` + `/etc/sudoers.d/vpnstatusbar` at runtime — not part of build.
