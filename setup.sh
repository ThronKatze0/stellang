#!/usr/bin/env bash
# Toolchain for building and testing stellang: Rust (frontend), clang (LLVM backend + C runtime), Boehm GC.
set -euo pipefail

SUDO=$([ "$(id -u)" -eq 0 ] || echo sudo)
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq clang libgc-dev build-essential curl

if ! command -v cargo >/dev/null; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    . "$HOME/.cargo/env"
fi

clang --version | head -1
cargo --version
