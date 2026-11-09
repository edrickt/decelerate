#!/bin/bash
# Build all Decelerate research probes (single-file swiftc builds).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
swiftc -O -o bin/hidprobe hidprobe.swift
swiftc -O -o bin/tapmeasure tapmeasure.swift 2>/dev/null || echo "tapmeasure not built"
swiftc -O -o bin/virtmouse  virtmouse.swift  2>/dev/null || echo "virtmouse not built"
echo "built: $(ls bin)"
