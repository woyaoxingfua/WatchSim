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
# Needs: git, curl (or wget), make, a C compiler.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPS="$ROOT/deps"
LVGL_TAG="v8.3.11"
LVGL_REPO="${WATCHSIM_LVGL_REPO:-https://github.com/lvgl/lvgl.git}"
LUA_VERSION="5.3.6"

mkdir -p "$DEPS"

# ---- LVGL -----------------------------------------------------------------
if [ -d "$DEPS/lvgl" ]; then
    echo "== deps/lvgl already present, skipping clone"
else
    # -c core.autocrlf=false keeps working-tree endings LF so the patch
    # applies cleanly even on Windows checkouts.
    git -c core.autocrlf=false clone --depth 1 --branch "$LVGL_TAG" \
        "$LVGL_REPO" "$DEPS/lvgl"
fi

if grep -q "\[watchsim\]" "$DEPS/lvgl/src/draw/lv_img_decoder.c" 2>/dev/null; then
    echo "== decoder patch already applied"
else
    git -C "$DEPS/lvgl" apply "$ROOT/patches/lvgl-decoder-fullread.patch"
    echo "== decoder patch applied (patches/lvgl-decoder-fullread.patch)"
fi

# ---- Lua ------------------------------------------------------------------
if [ -f "$DEPS/lua/liblua.a" ]; then
    echo "== deps/lua already built, skipping"
else
    if [ ! -d "$DEPS/lua" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fL "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz" \
                -o "$DEPS/lua.tar.gz"
        else
            wget -O "$DEPS/lua.tar.gz" \
                "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz"
        fi
        tar -xzf "$DEPS/lua.tar.gz" -C "$DEPS"
        mv "$DEPS/lua-${LUA_VERSION}" "$DEPS/lua"
        rm -f "$DEPS/lua.tar.gz"
    fi
    make -C "$DEPS/lua" generic    # builds src/liblua.a
    cp "$DEPS/lua/src/liblua.a" "$DEPS/lua/liblua.a"
    echo "== deps/lua built (liblua.a)"
fi

echo "All dependencies ready."
