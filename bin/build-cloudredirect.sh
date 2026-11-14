#!/usr/bin/env bash
# Build CloudRedirect for the 64-bit Steam client and optionally install it.
#
# Upstream ships prebuilt 32-bit binaries and build.sh hard-asserts `ELF 32-bit`,
# so it cannot be reused for this port. What we do instead is build the CMake
# project natively with LINUX_32BIT=OFF, which is the branch upstream already
# has for 64-bit hosts (it skips -m32, libatomic and the i686 include hacks).
#
# Pinned upstream commit: reproducible builds, and an obvious place to look when
# a future upstream change must be picked up.
#
#   build-cloudredirect.sh              build into ./out
#   build-cloudredirect.sh --install    also install to ~/.local/share/CloudRedirect
set -uo pipefail

CLOUD_REDIRECT_REPO="${CLOUD_REDIRECT_REPO:-https://github.com/swwayps/cloudredirect-moon}"
CLOUD_REDIRECT_COMMIT="${CLOUD_REDIRECT_COMMIT:-19da05507dc8294a744d74c04ba875d4ca3cf2f7}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${CLOUD_REDIRECT_WORKDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/moon64/cloudredirect}"
OUT="${CLOUD_REDIRECT_OUT:-$HERE/out}"
DEST="$HOME/.local/share/CloudRedirect"

c_grn=$'\033[38;5;114m'; c_red=$'\033[38;5;203m'; c_yel=$'\033[38;5;221m'
c_dim=$'\033[2m'; c_nc=$'\033[0m'
[ -t 1 ] || { c_grn=; c_red=; c_yel=; c_dim=; c_nc=; }
ok()   { printf '%s  ok  %s %s\n' "$c_grn" "$c_nc" "$*"; }
warn() { printf '%s warn %s %s\n' "$c_yel" "$c_nc" "$*"; }
bad()  { printf '%s fail %s %s\n' "$c_red" "$c_nc" "$*"; }
dim()  { printf '%s      %s%s\n' "$c_dim" "$*" "$c_nc"; }
die()  { bad "$*"; exit 1; }

install_artifacts=0
for arg in "$@"; do
    case "$arg" in
        --install) install_artifacts=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown argument: $arg" ;;
    esac
done

command -v git   >/dev/null || die "git is required"
command -v cmake >/dev/null || die "cmake is required"
command -v g++   >/dev/null || die "g++ is required"

# --- source -----------------------------------------------------------------
if [ ! -d "$WORK/.git" ]; then
    mkdir -p "$(dirname "$WORK")"
    dim "cloning $CLOUD_REDIRECT_REPO"
    git clone -q "$CLOUD_REDIRECT_REPO" "$WORK" || die "clone failed"
fi
( cd "$WORK" && git fetch -q origin 2>/dev/null || true )
( cd "$WORK" && git checkout -q "$CLOUD_REDIRECT_COMMIT" 2>/dev/null ) \
    || die "commit $CLOUD_REDIRECT_COMMIT not available in $WORK"
ok "source at $( cd "$WORK" && git rev-parse --short HEAD )"

# --- build ------------------------------------------------------------------
# Drop a stale build tree: a 32-bit configure would otherwise be reused and the
# class check below would fail with a confusing message.
if [ -d "$WORK/build64" ]; then
    cmake -LA -N "$WORK/build64" 2>/dev/null | grep -q 'LINUX_32BIT:BOOL=OFF'         || rm -rf "$WORK/build64"
fi
cmake -S "$WORK" -B "$WORK/build64" -DCMAKE_BUILD_TYPE=Release -DLINUX_32BIT=OFF >/tmp/moon64-cr-configure.log 2>&1 \
    || { tail -20 /tmp/moon64-cr-configure.log; die "cmake configure failed"; }
cmake --build "$WORK/build64" --target cloud_redirect cloud_redirect_cli -j"$(nproc)" \
    >/tmp/moon64-cr-build.log 2>&1 \
    || { tail -30 /tmp/moon64-cr-build.log; die "build failed"; }
ok "built cloud_redirect.so + cloud_redirect_cli"

# --- verify -----------------------------------------------------------------
mkdir -p "$OUT"
for f in cloud_redirect.so cloud_redirect_cli; do
    [ -f "$WORK/build64/$f" ] || die "$f missing from the build tree"
    file -b "$WORK/build64/$f" | grep -q 'ELF 64-bit' || die "$f is not ELF 64-bit"
    install -m 755 "$WORK/build64/$f" "$OUT/$f"
done
ok "artifacts in $OUT"
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }
dim "cloud_redirect.so     $(size_of "$OUT/cloud_redirect.so") B"
dim "cloud_redirect_cli    $(size_of "$OUT/cloud_redirect_cli") B"

# The hook is LD_PRELOADed into the client, which runs on this host (not inside
# the sniper container), so the local glibc is the ceiling that matters.
local_glibc="$(ldd --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+$' | head -1)"
need_glibc="$(readelf -V "$OUT/cloud_redirect.so" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -uV | tail -1)"
if [ -n "$local_glibc" ] && [ -n "$need_glibc" ]; then
    if [ "$(printf '%s\n%s\n' "$need_glibc" "$local_glibc" | sort -V | tail -1)" != "$local_glibc" ]; then
        die "needs glibc $need_glibc but this host has $local_glibc"
    fi
    ok "glibc requirement $need_glibc <= host $local_glibc"
fi

ldd -r "$OUT/cloud_redirect.so" 2>&1 | grep -q 'undefined symbol' \
    && { ldd -r "$OUT/cloud_redirect.so" 2>&1 | grep 'undefined symbol'; die "unresolved symbols"; }
ok "symbols resolve"

# --- install ----------------------------------------------------------------
if [ "$install_artifacts" = 1 ]; then
    mkdir -p "$DEST"
    for f in cloud_redirect.so cloud_redirect_cli; do
        if [ -f "$DEST/$f" ] && ! file -b "$DEST/$f" | grep -q 'ELF 64-bit'; then
            if [ ! -f "$DEST/$f.32.bak" ]; then
                cp -a "$DEST/$f" "$DEST/$f.32.bak" || die "cannot back up $DEST/$f"
                dim "saved the 32-bit $f as $f.32.bak"
            fi
        fi
        install -m 755 "$OUT/$f" "$DEST/$f" || die "cannot install $f"
    done
    ok "installed 64-bit CloudRedirect into $DEST"
fi

printf '\n'
dim "activate with: install.sh --with-cloudredirect && moon64 on"
