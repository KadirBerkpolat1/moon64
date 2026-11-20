#!/usr/bin/env bash
# Build CloudRedirect for the 64-bit Steam client and optionally install it.
#
# The pinned tree is our cloudredirect-moon fork, which absorbs jayool's
# maintained 64-bit line (v2.6.6-linux64.3: the x86_64 steamclient hooks, the
# 5-minute steamclient.so wait with unload signaling, AutoCloud library-root
# prefixes) on top of the swwayps fork's steamrt64 bootstrapper fix. Configure
# with LINUX_X86_64=ON; curl/OpenSSL link statically when the checkout has
# deps/install64, dynamically otherwise (the client's sniper runtime provides
# libcurl.so.4, and the build host is the glibc ceiling). Pinned commit for
# reproducible builds and one obvious place to pick up future upstream changes.
#
#   build-cloudredirect.sh              build into ./out
#   build-cloudredirect.sh --install    also install to ~/.local/share/CloudRedirect
set -uo pipefail

CLOUD_REDIRECT_REPO="${CLOUD_REDIRECT_REPO:-https://github.com/KadirBerkpolat1/cloudredirect-moon}"
CLOUD_REDIRECT_COMMIT="${CLOUD_REDIRECT_COMMIT:-8b5bd2625a6c2f56f0eb3af374dcada0de92a757}"

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

command -v git     >/dev/null || die "git is required"
command -v cmake   >/dev/null || die "cmake is required"
command -v g++     >/dev/null || die "g++ is required"
command -v file    >/dev/null || die "file is required"
command -v readelf >/dev/null || die "readelf (binutils) is required"
command -v ldd     >/dev/null || die "ldd is required"

# --- source -----------------------------------------------------------------
if [ ! -d "$WORK/.git" ]; then
    mkdir -p "$(dirname "$WORK")"
    dim "cloning $CLOUD_REDIRECT_REPO"
    git clone -q "$CLOUD_REDIRECT_REPO" "$WORK" || die "clone failed"
fi
# A clone left by an older pin may point at another repository.
( cd "$WORK" && git remote set-url origin "$CLOUD_REDIRECT_REPO" && git fetch -q origin 2>/dev/null || true )
( cd "$WORK" && git checkout -q "$CLOUD_REDIRECT_COMMIT" 2>/dev/null ) \
    || die "commit $CLOUD_REDIRECT_COMMIT not available in $WORK"
ok "source at $( cd "$WORK" && git rev-parse --short HEAD )"

# --- build ------------------------------------------------------------------
# Drop a stale build tree: a configure from an older pin (different CMake
# switch) would otherwise be reused and the class check below would mislead.
if [ -d "$WORK/build64" ]; then
    cmake_out="$(cmake -LA -N "$WORK/build64" 2>/dev/null || true)"
    case "$cmake_out" in *'LINUX_X86_64:BOOL=ON'*) ;; *) rm -rf "$WORK/build64" ;; esac
fi
cmake -S "$WORK" -B "$WORK/build64" -DCMAKE_BUILD_TYPE=Release -DLINUX_X86_64=ON -DCR_GIT_SHA="${CLOUD_REDIRECT_COMMIT:0:7}" >/tmp/moon64-cr-configure.log 2>&1 \
    || { tail -20 /tmp/moon64-cr-configure.log; die "cmake configure failed"; }
cmake --build "$WORK/build64" --target cloud_redirect cloud_redirect_cli -j"$(nproc)" \
    >/tmp/moon64-cr-build.log 2>&1 \
    || { tail -30 /tmp/moon64-cr-build.log; die "build failed"; }
ok "built cloud_redirect.so + cloud_redirect_cli"

# --- verify -----------------------------------------------------------------
mkdir -p "$OUT"
for f in cloud_redirect.so cloud_redirect_cli; do
    [ -f "$WORK/build64/$f" ] || die "$f missing from the build tree"
    f_info="$(file -b "$WORK/build64/$f" 2>/dev/null || true)"
    case "$f_info" in *'ELF 64-bit'*) ;; *) die "$f is not ELF 64-bit" ;; esac
    install -m 755 "$WORK/build64/$f" "$OUT/$f"
done
ok "artifacts in $OUT"
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }
dim "cloud_redirect.so     $(size_of "$OUT/cloud_redirect.so") B"
dim "cloud_redirect_cli    $(size_of "$OUT/cloud_redirect_cli") B"

# The hook is LD_PRELOADed into the client, which runs on this host (not inside
# the sniper container), so the local glibc is the ceiling that matters.
local_glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
[ -n "$local_glibc" ] || local_glibc="$(LC_ALL=C ldd --version 2>/dev/null | awk 'NR==1{for(i=NF;i>=1;i--) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')"
need_glibc="$(LC_ALL=C readelf -V "$OUT/cloud_redirect.so" 2>/dev/null \
    | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -uV | tail -1)"
if [ -n "$local_glibc" ] && [ -n "$need_glibc" ]; then
    if [ "$(printf '%s\n%s\n' "$need_glibc" "$local_glibc" | sort -V | tail -1)" != "$local_glibc" ]; then
        die "needs glibc $need_glibc but this host has $local_glibc"
    fi
    ok "glibc requirement $need_glibc <= host $local_glibc"
fi

# Capture the ldd output once, then inspect it. Piping ldd into `grep -q` under
# `set -o pipefail` lets grep exit early, SIGPIPE kills ldd, and a clean library
# looks like it has unresolved symbols.
ldd_out="$(ldd -r "$OUT/cloud_redirect.so" 2>&1 || true)"
case "$ldd_out" in
    *'undefined symbol'*)
        grep 'undefined symbol' <<<"$ldd_out" >&2
        die "unresolved symbols"
        ;;
esac
ok "symbols resolve"

# --- install ----------------------------------------------------------------
if [ "$install_artifacts" = 1 ]; then
    mkdir -p "$DEST"
    for f in cloud_redirect.so cloud_redirect_cli; do
        if [ -f "$DEST/$f.32.bak" ]; then
            if [ ! -f "$DEST/$f.32" ]; then
                mv -f "$DEST/$f.32.bak" "$DEST/$f.32" || die "cannot migrate $DEST/$f.32.bak"
                dim "migrated $f.32.bak -> $f.32"
            elif cmp -s "$DEST/$f.32.bak" "$DEST/$f.32"; then
                rm -f "$DEST/$f.32.bak"
            fi
        fi
        d_info=""
        [ -f "$DEST/$f" ] && d_info="$(file -b "$DEST/$f" 2>/dev/null || true)"
        if [ -f "$DEST/$f" ] && ! case "$d_info" in *'ELF 64-bit'*) true ;; *) false ;; esac; then
            if [ ! -f "$DEST/$f.32" ]; then
                cp -a "$DEST/$f" "$DEST/$f.32" || die "cannot back up $DEST/$f"
                dim "saved the 32-bit $f as $f.32"
            fi
        fi
        install -m 755 "$OUT/$f" "$DEST/$f" || die "cannot install $f"
    done
    ok "installed 64-bit CloudRedirect into $DEST"
fi

printf '\n'
dim "activate with: install.sh --with-cloudredirect && moon64 on"
