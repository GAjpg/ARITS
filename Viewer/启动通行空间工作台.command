#!/bin/bash
set -eu
viewer_directory=$(cd "$(dirname "$0")" && pwd)
project_directory=$(cd "$viewer_directory/.." && pwd)
cd "$project_directory"
needs_build=false
if [ ! -x .build/tools/space-route ]; then
  needs_build=true
else
  for source in Sources/ProbeCore/*.swift Tools/SpaceRoute/*.swift; do
    if [ "$source" -nt .build/tools/space-route ]; then needs_build=true; break; fi
  done
fi
if [ "$needs_build" = true ]; then
  printf '%s\n' '正在编译共享空间路网工具，首次启动可能需要几分钟…'
  bash Tools/build_space_route.sh
fi
exec bash "$viewer_directory/启动点云查看器.command" --space "$@"
