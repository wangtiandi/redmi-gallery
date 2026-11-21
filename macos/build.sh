#!/bin/bash
# 一键编译 RedmiGallery.app（不需要 Xcode 工程，只用系统自带的 Swift 工具链）
#
# 用法：
#   ./build.sh              # 编译为通用二进制（arm64 + x86_64），就地更新 ./RedmiGallery.app
#   ./build.sh --native     # 只编译当前机器架构（更快）
#   ./build.sh --install    # 编译后安装到 ~/Applications 并建命令软链接
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP="RedmiGallery.app"
BIN="$APP/Contents/MacOS/RedmiGallery"
mkdir -p "$APP/Contents/MacOS"

compile() {   # $1 = 目标架构或空
    local tgt="$1" out="$2"
    if [[ -n "$tgt" ]]; then
        xcrun swiftc -O -target "$tgt" -o "$out" main.swift -framework Cocoa -framework AVKit
    else
        xcrun swiftc -O -o "$out" main.swift -framework Cocoa -framework AVKit
    fi
}

if [[ "${1:-}" == "--native" ]]; then
    echo "==> 编译（当前架构）"
    compile "" "$BIN"
else
    echo "==> 编译 arm64"
    compile "arm64-apple-macos12.0" /tmp/rg-arm64-$$
    echo "==> 编译 x86_64"
    compile "x86_64-apple-macos12.0" /tmp/rg-x86_64-$$
    echo "==> 合并通用二进制"
    lipo -create /tmp/rg-arm64-$$ /tmp/rg-x86_64-$$ -output "$BIN"
    rm -f /tmp/rg-arm64-$$ /tmp/rg-x86_64-$$
fi
chmod +x "$BIN"

echo "==> ad-hoc 签名"
codesign --force -s - "$APP" 2>/dev/null || echo "   (签名失败，仍可本机运行)"

echo "==> 自检"
"$BIN" --filter-test    | tail -1
"$BIN" --wheel-zoom-test | tail -1
"$BIN" --zoom-test      | tail -1

if [[ "${1:-}" == "--install" ]]; then
    echo "==> 安装到 ~/Applications"
    mkdir -p ~/Applications ~/.local/bin
    rm -rf ~/Applications/"$APP"
    cp -R "$APP" ~/Applications/
    ln -sf ~/Applications/"$APP"/Contents/MacOS/RedmiGallery ~/.local/bin/redmi-gallery
    echo "完成：~/Applications/$APP  命令：redmi-gallery"
fi

echo "OK  $(lipo -archs "$BIN")"
