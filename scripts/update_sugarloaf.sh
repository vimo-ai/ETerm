#!/usr/bin/env bash
set -euo pipefail
ROOT="/Users/higuaifan/Desktop/hi/小工具/english"
FFI_DIR="$ROOT/sugarloaf-ffi"
ETERM_DIR="$ROOT/ETerm"

cd "$FFI_DIR"
cargo build --release

cp "$FFI_DIR/target/release/libsugarloaf_ffi.dylib" "$ETERM_DIR/ETerm/libsugarloaf_ffi.dylib"
cp "$FFI_DIR/target/release/libsugarloaf_ffi.a" "$ETERM_DIR/Sugarloaf/libSugarloafFFI.a"
cp "$FFI_DIR/target/release/libsugarloaf_ffi.dylib" "$FFI_DIR/target/release/deps/libsugarloaf_ffi.dylib"
