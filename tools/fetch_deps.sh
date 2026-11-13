#!/usr/bin/env bash
# Fetch the pinned third-party dependencies into deps/ and apply the
# watchsim decoder patch. Run once before the first cmake configure:
#
#     bash tools/fetch_deps.sh
#
# Produces:
#     deps/lvgl   LVGL v8.3.11 (+ patches/lvgl-decoder-fullread.patch)
#     deps/lua    Lua 5.3.6 source tree with liblua.a at its root
#
# The script is idempotent: already-fetched/built parts are skipped.
# Needs: curl (or wget), tar, patch, make/mingw32-make, a C compiler.
#
# Network notes: git clone is tried first; on networks that reset git's
# smart-protocol transfers (common in CN), the codeload tarball endpoint
# is used as a fallback for both sources.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
LVGL_TAG="v8.3.11"
LUA_VERSION="5.3.6"

fetch_tarball() {  # fetch_tarball <url> <outfile>
    for _ in 1 2 3; do
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 2 --max-time 180 -o "$2" "$1" && return 0
        else
            wget -O "$2" "$1" && return 0
        fi
        sleep 2
    done
    return 1
}

fetch_lvgl() {  # fetch_lvgl <destdir>  — fills $1 with LVGL $LVGL_TAG
    local dst="$1"
    if git -c core.autocrlf=false clone --depth 1 --single-branch \
            --branch "$LVGL_TAG" https://github.com/lvgl/lvgl.git "$dst"; then
        return 0
    fi
    rm -rf "$dst"
    echo "git clone failed, falling back to codeload tarball..."
    local tgz="$DEPS/lvgl.tgz"
    fetch_tarball "https://codeload.github.com/lvgl/lvgl/tar.gz/refs/tags/${LVGL_TAG}" "$tgz"
    mkdir -p "$dst.tmp"
    tar -xzf "$tgz" -C "$dst.tmp"
    mv "$dst.tmp"/lvgl-* "$dst"
    rm -rf "$dst.tmp" "$tgz"
}

mkdir -p "$DEPS"

# ---- LVGL -----------------------------------------------------------------
if [ -d "$DEPS/lvgl" ]; then
    echo "== deps/lvgl already present, skipping download"
else
    fetch_lvgl "$DEPS/lvgl"
fi

if grep -q "\[watchsim\]" "$DEPS/lvgl/src/draw/lv_img_decoder.c" 2>/dev/null; then
    echo "== decoder patch already applied"
else
    patch -p1 -d "$DEPS/lvgl" --quiet < "$ROOT/patches/lvgl-decoder-fullread.patch"
    echo "== decoder patch applied (patches/lvgl-decoder-fullread.patch)"
fi

# ---- Lua ------------------------------------------------------------------
if [ -f "$DEPS/lua/liblua.a" ]; then
    echo "== deps/lua already built, skipping"
else
    if [ ! -d "$DEPS/lua" ]; then
        # Official tarball first; Debian's pristine .orig.tar.gz mirrors it
        # for networks where lua.org is unreachable.
        for url in \
            "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz" \
            "https://deb.debian.org/debian/pool/main/l/lua5.3/lua5.3_${LUA_VERSION}.orig.tar.gz"; do
            if fetch_tarball "$url" "$DEPS/lua.tar.gz"; then break; fi
            rm -f "$DEPS/lua.tar.gz"
        done
        if [ ! -f "$DEPS/lua.tar.gz" ]; then
            echo "error: cannot download lua-${LUA_VERSION}" >&2
            exit 1
        fi
        mkdir -p "$DEPS/lua.tmp"
        tar -xzf "$DEPS/lua.tar.gz" -C "$DEPS/lua.tmp"
        mv "$DEPS/lua.tmp"/lua-* "$DEPS/lua"
        rm -rf "$DEPS/lua.tmp" "$DEPS/lua.tar.gz"
    fi
    MAKE_BIN="$(command -v make || command -v mingw32-make)"
    if [ -z "$MAKE_BIN" ]; then
        echo "error: need 'make' (or 'mingw32-make') to build liblua.a" >&2
        exit 1
    fi
    # Build only the static library; the lua/luac executables are not needed
    # and their link step drags in toolchain bits (readline/ld) we don't want.
    "$MAKE_BIN" -C "$DEPS/lua/src" liblua.a
    cp "$DEPS/lua/src/liblua.a" "$DEPS/lua/liblua.a"
    echo "== deps/lua built (liblua.a)"
fi

echo "All dependencies ready."
