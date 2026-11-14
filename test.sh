#!/usr/bin/env bash
# Builds and runs the unit checks in Tests/ against Dorian's sources.
set -euo pipefail

cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 -target arm64-apple-macos13.0 -o build/tests \
  Sources/Dorian/Chrome.swift Sources/Dorian/Launchers.swift Tests/main.swift
build/tests
