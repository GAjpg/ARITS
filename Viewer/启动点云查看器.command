#!/bin/bash
set -eu
viewer_directory=$(cd "$(dirname "$0")" && pwd)
project_directory=$(cd "$viewer_directory/.." && pwd)
cd "$viewer_directory"
if [ ! -x "$project_directory/.venv/bin/python" ]; then
  printf '%s\n' '首次运行需要 Python 3.10–3.12 和 Open3D。正在建立本项目虚拟环境…'
  bash "$project_directory/Tools/setup_lidar.sh"
fi
if ! "$project_directory/.venv/bin/python" -c 'import flask' >/dev/null 2>&1; then
  "$project_directory/.venv/bin/python" -m pip install 'flask==3.1.3'
fi
export PYTHONDONTWRITEBYTECODE=1
exec "$project_directory/.venv/bin/python" "$viewer_directory/server.py" "$@"
