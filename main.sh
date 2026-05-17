#!/usr/bin/env bash
set -e

ZIG_VERSION="0.14.0"
ZIG_DIR="$HOME/.local/zig"
ZIG_BIN="$ZIG_DIR/zig"

if [ ! -x "$ZIG_BIN" ]; then
    echo "Zig not found. Installing Zig $ZIG_VERSION..."
    mkdir -p "$HOME/.local"
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz
    tar -xJf /tmp/zig.tar.xz -C "$HOME/.local/"
    mv "$HOME/.local/zig-linux-x86_64-${ZIG_VERSION}" "$ZIG_DIR"
    echo "Zig $($ZIG_BIN version) installed."
fi

export PATH="$ZIG_DIR:$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="/nix/store/xb4h083j02mr2ix7pgj7iawxh2hk100l-postgresql-15.7-lib/lib:/nix/store/8b9bdqwjxahgyl8yns92cva6b6j8kirz-hiredis-1.2.0/lib:/nix/store/gp504m4dvw5k2pdx6pccf1km79fkcwgf-openssl-3.0.13/lib:/nix/store/lv6nackqis28gg7l2ic43f6nk52hb39g-zlib-1.3.1/lib:$LD_LIBRARY_PATH"

# Use Replit's built-in PostgreSQL if POSTGRES_DSN is not explicitly set
export POSTGRES_DSN="${POSTGRES_DSN:-${DATABASE_URL:-postgresql://postgres:password@helium/heliumdb?sslmode=disable}}"

echo "Building search-platform with Zig $ZIG_VERSION..."
zig build 2>&1

echo "Build complete. Starting server..."
exec ./zig-out/bin/search-platform
