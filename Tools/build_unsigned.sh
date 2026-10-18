#!/bin/bash
set -eu
tool_directory=$(cd "$(dirname "$0")" && pwd)
project_directory=$(cd "$tool_directory/.." && pwd)
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version; then
  printf '%s\n' '缺少完整 Xcode。请先完成安装，再重新运行。'
  exit 1
fi
xcodebuild -project "$project_directory/LiDARProbe.xcodeproj" -scheme LiDARProbe -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$project_directory/work/ios-build" CODE_SIGNING_ALLOWED=NO build
