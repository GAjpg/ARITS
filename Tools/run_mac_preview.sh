#!/bin/bash
set -eu
tool_directory=$(cd "$(dirname "$0")" && pwd)
project_directory=$(cd "$tool_directory/.." && pwd)
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
build_directory="$project_directory/work/mac-build"
app_destination="$project_directory/artifacts/LiDARProbe-Mac.app"
mkdir -p "$project_directory/artifacts"
xcodebuild -project "$project_directory/LiDARProbe.xcodeproj" -scheme LiDARProbe -configuration Debug \
  -sdk macosx -destination "platform=macOS,variant=Mac Catalyst,arch=$(uname -m)" \
  -derivedDataPath "$build_directory" CODE_SIGNING_ALLOWED=NO build
# Local ad-hoc signature only; no Apple account or distribution certificate.
# Replace this generated bundle, rather than merging obsolete Debug dylibs.
# The app's sandbox documents live elsewhere and are preserved.
rm -rf "$app_destination"
ditto "$build_directory/Build/Products/Debug-maccatalyst/LiDARProbe.app" "$app_destination"
codesign --force --deep --sign - --entitlements "$project_directory/App/MacPreview.entitlements" "$app_destination"
open "$app_destination"
