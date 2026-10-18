#!/bin/bash
set -eu
tool_directory=$(cd "$(dirname "$0")" && pwd)
project_directory=$(cd "$tool_directory/.." && pwd)
python_executable=${LIDAR_PYTHON:-python3}
"$python_executable" -m venv "$project_directory/.venv"
"$project_directory/.venv/bin/python" -m pip install -r "$tool_directory/lidar-requirements.txt"
printf '%s\n' '已就绪。运行 .venv/bin/python Tools/lidar_validate.py --help'
