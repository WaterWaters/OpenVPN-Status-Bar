# vendor/openvpn

内置自包含 openvpn 引擎（ARM64，静态编译，不依赖 Homebrew dylib）。

**本目录的二进制不提交到 git**（架构相关、可再生）。拿到源码后需先构建一次：

```bash
./build-openvpn.sh
```

产物为 `vendor/openvpn`，随后 `./build.sh` 会把它打进
`VPNStatusBar.app/Contents/Resources/openvpn`。

- 需要联网（下载 openvpn / OpenSSL / LZO / LZ4 源码；国内网络建议走代理）。
- 静态编译：OpenSSL + LZO + LZ4 全 `no-shared`，最终二进制动态依赖仅剩系统库。
- 增量可重跑；`./build-openvpn.sh --rebuild` 强制全量。
