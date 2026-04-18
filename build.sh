#!/bin/bash
# Thin wrapper so `./build.sh [BUILD_VERSION]` still works. The build script
# auto-resolves the upstream tip SHA itself — no ghostty version is supplied.
./build_ghostty_debian.sh "${1:-1}"
