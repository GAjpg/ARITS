#!/bin/bash
set -eu
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version; then
  printf '%s\n' '尚未找到可用的完整 Xcode。请先安装、启动 Xcode，并完成 iOS 平台组件安装。'
  exit 1
fi
xcrun --sdk iphoneos --show-sdk-path
printf '%s\n' '已找到 iOS 构建 SDK。真机安装还需在 Xcode 选择签名团队并连接 iPhone。'
