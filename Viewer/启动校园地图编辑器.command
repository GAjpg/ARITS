#!/bin/bash
set -eu
viewer_directory=$(cd "$(dirname "$0")" && pwd)
exec bash "$viewer_directory/启动点云查看器.command" --outdoor "$@"
