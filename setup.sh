#!/usr/bin/env bash
# Toolchain for building and testing stellang: Rust (frontend), clang (LLVM backend + C runtime), Boehm GC,
# and for `stellang --web`: the WASI C library and clang's wasm32 runtime (wasm-ld comes with lld).
set -euo pipefail

SUDO=$([ "$(id -u)" -eq 0 ] || echo sudo)
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq clang libgc-dev build-essential curl
$SUDO apt-get install -y -qq lld wasi-libc "libclang-rt-$(clang --version | sed -n 's/.*version \([0-9]*\).*/\1/p')-dev-wasm32" ||
    echo "note: no WASI libc packages here; \`stellang --web\` won't work (everything else does)" >&2

if ! command -v cargo >/dev/null; then
    curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
    . "$HOME/.cargo/env"
fi

clang --version | head -1
cargo --version
