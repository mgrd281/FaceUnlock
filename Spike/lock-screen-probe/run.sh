#!/usr/bin/env bash
# Builds and runs the lock-screen camera probe. Nothing is installed and no
# administrator rights are needed; Ctrl-C stops it and prints the verdict.
set -euo pipefail
cd "$(dirname "$0")"
echo "Building…"
swiftc -O -o lock-probe main.swift
echo
exec ./lock-probe
