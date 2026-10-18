#!/bin/bash
# Builds the space-route tool from the shared ProbeCore sources (release optimisation).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/tools
swiftc -O Sources/ProbeCore/*.swift Tools/SpaceRoute/main.swift -o .build/tools/space-route
echo ".build/tools/space-route"
