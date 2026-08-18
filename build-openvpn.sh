#!/usr/bin/env bash
# build-openvpn.sh — 静态编译自包含 openvpn (arm64, macOS)
#
# 目标：产出可打进 app 的自包含 openvpn 二进制（不依赖 Homebrew dylib，
#       同事零安装即可运行）。方案：openvpn + OpenSSL + LZO + LZ4 全部静态编译。
#
# 产物：vendor/openvpn  （build.sh 会把它打进 Contents/Resources/openvpn）
# 用法：
#   ./build-openvpn.sh              # 增量（已有构建则跳过）
#   ./build-openvpn.sh --rebuild    # 强制全量重编
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR"
BUILD="$ROOT/.build/openvpn-embed"
CACHE="$ROOT/.build/openvpn-cache"
SRC="$BUILD/src"
PREFIX="$BUILD/prefix"
OUT_BIN="$ROOT/vendor/openvpn"

# ---------- 版本 / URL ----------
OPENSSL_VER=3.3.2
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz"

LZO_VER=2.10
LZO_URL="https://deb.debian.org/debian/pool/main/l/lzo2/lzo2_${LZO_VER}.orig.tar.gz"

LZ4_VER=1.10.0
LZ4_URL="https://github.com/lz4/lz4/archive/refs/tags/v${LZ4_VER}.tar.gz"

OPENVPN_VER=2.6.14
OPENVPN_URL="https://github.com/openvpn/openvpn/releases/download/v${OPENVPN_VER}/openvpn-${OPENVPN_VER}.tar.gz"

OPENSSL_PREFIX="$PREFIX/openssl"
LZO_PREFIX="$PREFIX/lzo"
LZ4_PREFIX="$PREFIX/lz4"

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
CFLAGS_EXT="-Os -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

mkdir -p "$SRC" "$CACHE" "$OPENSSL_PREFIX" "$LZO_PREFIX" "$LZ4_PREFIX" "$(dirname "$OUT_BIN")"

if [ "${1:-}" = "--rebuild" ]; then
  echo "==> 清空现有构建（--rebuild）"
  rm -rf "$BUILD"; mkdir -p "$SRC" "$CACHE" "$OPENSSL_PREFIX" "$LZO_PREFIX" "$LZ4_PREFIX"
fi

fetch(){
  local url="$1" file="$2"
  if [ ! -f "$CACHE/$file" ]; then
    echo "==> 下载 $file"
    curl -fL --retry 3 -o "$CACHE/$file" "$url"
  else
    echo "==> 命中缓存 $file"
  fi
}

# ---------- OpenSSL（静态） ----------
build_openssl(){
  [ -f "$OPENSSL_PREFIX/lib/libssl.a" ] && echo "==> OpenSSL 已构建，跳过" && return 0
  echo "==> 构建 OpenSSL $OPENSSL_VER (静态)"
  fetch "$OPENSSL_URL" "openssl-${OPENSSL_VER}.tar.gz"
  rm -rf "$SRC/openssl"; mkdir -p "$SRC/openssl"
  tar -xzf "$CACHE/openssl-${OPENSSL_VER}.tar.gz" -C "$SRC/openssl" --strip-components=1
  (
    cd "$SRC/openssl"
    ./Configure darwin64-arm64-cc no-shared no-tests no-docs --prefix="$OPENSSL_PREFIX" \
        -DOPENSSL_NO_ASM >/dev/null 2>&1 || \
    ./Configure darwin64-arm64-cc no-shared no-tests no-docs --prefix="$OPENSSL_PREFIX"
    make -j"$JOBS" CFLAGS="$CFLAGS_EXT" >/dev/null
    make install_sw >/dev/null
  )
  echo "    ✅ openssl .a: $(ls "$OPENSSL_PREFIX/lib"/*.a | tr '\n' ' ')"
}

# ---------- LZO（静态） ----------
build_lzo(){
  [ -f "$LZO_PREFIX/lib/liblzo2.a" ] && echo "==> LZO 已构建，跳过" && return 0
  echo "==> 构建 LZO $LZO_VER (静态)"
  fetch "$LZO_URL" "lzo-${LZO_VER}.tar.gz"
  rm -rf "$SRC/lzo"; mkdir -p "$SRC/lzo"
  tar -xzf "$CACHE/lzo-${LZO_VER}.tar.gz" -C "$SRC/lzo" --strip-components=1
  (
    cd "$SRC/lzo"
    ./configure --prefix="$LZO_PREFIX" --disable-shared --enable-static \
        CFLAGS="$CFLAGS_EXT" >/dev/null
    make -j"$JOBS" >/dev/null
    make install >/dev/null
  )
  echo "    ✅ liblzo2.a"
}

# ---------- LZ4（静态） ----------
build_lz4(){
  [ -f "$LZ4_PREFIX/lib/liblz4.a" ] && echo "==> LZ4 已构建，跳过" && return 0
  echo "==> 构建 LZ4 $LZ4_VER (静态)"
  fetch "$LZ4_URL" "lz4-${LZ4_VER}.tar.gz"
  rm -rf "$SRC/lz4"; mkdir -p "$SRC/lz4"
  tar -xzf "$CACHE/lz4-${LZ4_VER}.tar.gz" -C "$SRC/lz4" --strip-components=1
  (
    cd "$SRC/lz4"
    make -C lib -j"$JOBS" BUILD_SHARED=no CFLAGS="$CFLAGS_EXT" liblz4.a >/dev/null
    make -C lib install BUILD_SHARED=no PREFIX="$LZ4_PREFIX" >/dev/null
  )
  echo "    ✅ liblz4.a"
}

# ---------- openvpn（静态，链接上面的静态库） ----------
build_openvpn(){
  [ -f "$OUT_BIN" ] && echo "==> openvpn 已产出，跳过" && return 0
  echo "==> 构建 openvpn $OPENVPN_VER (静态)"
  fetch "$OPENVPN_URL" "openvpn-${OPENVPN_VER}.tar.gz"
  rm -rf "$SRC/openvpn"; mkdir -p "$SRC/openvpn"
  tar -xzf "$CACHE/openvpn-${OPENVPN_VER}.tar.gz" -C "$SRC/openvpn" --strip-components=1
  (
    cd "$SRC/openvpn"
    # 屏蔽 Homebrew 的 pkg-config，防止误连系统动态库
    PKG_CONFIG_PATH= \
    ./configure \
        --prefix="$PREFIX/openvpn" \
        --disable-shared --enable-static \
        --disable-plugins \
        --disable-pkcs11 \
        --disable-debug \
        --disable-silent-rules \
        --with-crypto-library=openssl \
        --with-ssl="$OPENSSL_PREFIX" \
        --with-lzo-headers="$LZO_PREFIX/include" --with-lzo-lib="$LZO_PREFIX/lib" \
        CPPFLAGS="-I$OPENSSL_PREFIX/include -I$LZO_PREFIX/include -I$LZ4_PREFIX/include" \
        LDFLAGS="-L$OPENSSL_PREFIX/lib -L$LZO_PREFIX/lib -L$LZ4_PREFIX/lib" \
        CFLAGS="$CFLAGS_EXT" \
        >/dev/null
    make -j"$JOBS" >/dev/null
    mkdir -p "$(dirname "$OUT_BIN")"
    cp -f src/openvpn/openvpn "$OUT_BIN"
  )
  # 精简 + 固定架构与部署目标
  strip -x "$OUT_BIN"
  echo "    ✅ 产物: $OUT_BIN"
}

build_openssl
build_lzo
build_lz4
build_openvpn

echo ""
echo "========== 校验 =========="
file "$OUT_BIN"
echo "--- 架构 ---"
lipo -info "$OUT_BIN" 2>/dev/null || true
echo "--- 动态依赖(应只剩系统库) ---"
otool -L "$OUT_BIN"
echo "--- 版本 ---"
chmod +x "$OUT_BIN"; "$OUT_BIN" --version 2>&1 | head -3 || echo "(无法直接运行，可能需权限，正常)"
echo ""
echo "✅ 完成：$OUT_BIN"
