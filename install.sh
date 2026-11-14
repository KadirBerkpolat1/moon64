#!/usr/bin/env bash
# moon64 installer — stage the 64-bit Steam client stack.
#
# Design contract: this script only *stages* the 64-bit pieces. It never changes
# which client Steam starts. `moon64 on` performs the switch and `moon64 off`
# undoes it, both by swapping already-installed files, so a failed migration is
# always one command away from the known-good 32-bit stack and never needs the
# network to recover.
#
# Layout it produces:
#   ~/.local/share/moon64/SLSsteam.so.64        staged 64-bit SLSsteam
#   ~/.local/share/moon64/netsock64.so          cert patch, built here
#   ~/.local/share/moon64/wrapper.64.sh         the 64-bit Steam wrapper
#   ~/.local/share/moon64/moon64                the switcher
#   ~/.local/share/SLSsteam/SLSsteam.so.32      saved 32-bit SLSsteam (rollback)
#   ~/.local/share/CloudRedirect/<f>.64/.32     staged CloudRedirect variants
#   ~/.local/share/Lumen/{lua,...}              LuaTools patches (optional)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOON_DIR="${MOON64_DIR:-$HOME/.local/share/moon64}"
SLS_DIR="$HOME/.local/share/SLSsteam"
CR_DIR="$HOME/.local/share/CloudRedirect"
SLS_REPO="AceSLS/SLSsteam"

c_grn=$'\033[38;5;114m'; c_red=$'\033[38;5;203m'; c_yel=$'\033[38;5;221m'
c_dim=$'\033[2m'; c_nc=$'\033[0m'
[ -t 1 ] || { c_grn=; c_red=; c_yel=; c_dim=; c_nc=; }
ok()   { printf '%s  ok  %s %s\n' "$c_grn" "$c_nc" "$*"; }
warn() { printf '%s warn %s %s\n' "$c_yel" "$c_nc" "$*"; }
bad()  { printf '%s fail %s %s\n' "$c_red" "$c_nc" "$*"; }
dim()  { printf '%s      %s%s\n' "$c_dim" "$*" "$c_nc"; }
die()  { bad "$*"; exit 1; }

with_cloudredirect=0
for arg in "$@"; do
    case "$arg" in
        --with-cloudredirect) with_cloudredirect=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown argument: $arg" ;;
    esac
done

[ "$(id -u)" -ne 0 ] || die "run as your desktop user, not root"
command -v curl >/dev/null || die "curl is required"
command -v gcc  >/dev/null || die "gcc is required to build netsock64"
command -v 7z >/dev/null || command -v 7zz >/dev/null || die "7z (p7zip) is required to unpack the SLSsteam release"

if [ -f "$HOME/.steam/steam.pid" ] && kill -0 "$(cat "$HOME/.steam/steam.pid" 2>/dev/null)" 2>/dev/null; then
    die "Steam is running. Close it completely, then re-run."
fi

mkdir -p "$MOON_DIR" || die "cannot create $MOON_DIR"

# is_elf64 <file> — true when the file exists and is a 64-bit ELF.
is_elf64() { [ -f "$1" ] && file -b "$1" 2>/dev/null | grep -q 'ELF 64-bit'; }

# --- 1. SLSsteam 64-bit (staged, not activated) -----------------------------
version="${SLSSTEAM_VERSION:-latest}"
if [ "$version" = latest ]; then
    version="$(curl -fsSL --max-time 30 "https://api.github.com/repos/$SLS_REPO/releases/latest" \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
fi
[ -n "$version" ] || die "could not determine the SLSsteam release version"
ok "SLSsteam release: $version"

tmp="$(mktemp -d)" || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/$SLS_REPO/releases/download/$version/SLSsteam-Any-release.7z"
dim "downloading $url"
curl -fsSL --max-time 300 -o "$tmp/sls.7z" "$url" || die "download failed"
(cd "$tmp" && 7z e -y sls.7z bin/SLSsteam.so >/dev/null 2>&1) || die "could not extract bin/SLSsteam.so"
is_elf64 "$tmp/SLSsteam.so" || die "release payload is not 64-bit"
install -m 755 "$tmp/SLSsteam.so" "$MOON_DIR/SLSsteam.so.64" || die "cannot stage SLSsteam.so.64"
ok "staged $MOON_DIR/SLSsteam.so.64"

# Keep the 32-bit original next to the active file, so `moon64 off` can restore
# it without re-downloading. Only the first run needs to save it.
mkdir -p "$SLS_DIR"
if [ -f "$SLS_DIR/SLSsteam.so" ] && ! is_elf64 "$SLS_DIR/SLSsteam.so" && [ ! -f "$SLS_DIR/SLSsteam.so.32" ]; then
    cp -a "$SLS_DIR/SLSsteam.so" "$SLS_DIR/SLSsteam.so.32" || die "cannot save the 32-bit SLSsteam"
    ok "saved the 32-bit SLSsteam.so for rollback"
fi

# --- 2. netsock64 -----------------------------------------------------------
if [ -f "$HERE/patches/netsock64/steamclient_audit64.c" ]; then
    gcc -O2 -Wall -Wextra -shared -fPIC \
        -o "$MOON_DIR/netsock64.so" \
        "$HERE/patches/netsock64/steamclient_audit64.c" -ldl || die "netsock64 build failed"
    ok "built $MOON_DIR/netsock64.so"
else
    warn "patches/netsock64 missing; the P2P cert patch will be inactive"
fi

# --- 3. wrapper + switcher -------------------------------------------------
[ -f "$HERE/bin/wrapper.64.sh" ] || die "bin/wrapper.64.sh missing from the checkout"
install -m 755 "$HERE/bin/wrapper.64.sh" "$MOON_DIR/wrapper.64.sh" || die "cannot install wrapper"
ok "installed $MOON_DIR/wrapper.64.sh"
[ -f "$HERE/bin/moon64" ] || die "bin/moon64 missing from the checkout"
install -m 755 "$HERE/bin/moon64" "$MOON_DIR/moon64" || die "cannot install switcher"
ok "installed $MOON_DIR/moon64"

# --- 4. CloudRedirect (optional, needs a build) ----------------------------
if [ "$with_cloudredirect" = 1 ]; then
    if [ -x "$HERE/bin/build-cloudredirect.sh" ]; then
        CLOUD_REDIRECT_OUT="$MOON_DIR/cloudredirect" \
            bash "$HERE/bin/build-cloudredirect.sh" || die "CloudRedirect 64-bit build failed"
        [ -f "$MOON_DIR/cloudredirect/cloud_redirect.so" ] || die "CloudRedirect build produced nothing"
        # Stage both variants so the switcher can swap instead of rebuild.
        mkdir -p "$CR_DIR"
        for f in cloud_redirect.so cloud_redirect_cli; do
            if [ -f "$CR_DIR/$f" ] && ! is_elf64 "$CR_DIR/$f" && [ ! -f "$CR_DIR/$f.32" ]; then
                cp -a "$CR_DIR/$f" "$CR_DIR/$f.32" || die "cannot save the 32-bit $f"
                dim "saved the 32-bit $f"
            fi
            install -m 755 "$MOON_DIR/cloudredirect/$f" "$CR_DIR/$f.64" || die "cannot stage $f.64"
        done
        ok "staged the 64-bit CloudRedirect pair in $CR_DIR"
    else
        warn "bin/build-cloudredirect.sh missing; skipping CloudRedirect"
    fi
else
    dim "CloudRedirect not requested; pass --with-cloudredirect to include it"
fi

# --- 5. Lumen / LuaTools patches -------------------------------------------
if [ -d "$HERE/patch/lumen" ] && [ -d "$HOME/.local/share/Lumen/lua" ]; then
    stamp="$MOON_DIR/lumen-patch.backup-$(date +%Y%m%d-%H%M%S)"
    changed=0
    while IFS= read -r -d '' src; do
        rel="${src#$HERE/patch/lumen/}"
        dst="$HOME/.local/share/Lumen/$rel"
        [ -f "$dst" ] || continue
        cmp -s "$src" "$dst" && continue
        mkdir -p "$stamp/$(dirname "$rel")" 2>/dev/null || true
        cp -a "$dst" "$stamp/$rel" 2>/dev/null || true
        install -m 644 "$src" "$dst" || die "cannot patch $dst"
        changed=$((changed+1))
        dim "patched ~/${dst#$HOME/}"
    done < <(find "$HERE/patch/lumen" -type f -print0)
    [ "$changed" -gt 0 ] && ok "applied $changed Lumen patch(es) (backup: $stamp)" \
                         || ok "Lumen already patched"
else
    dim "Lumen not installed or no patches present; skipping"
fi

# --- 6. report -------------------------------------------------------------
printf '\n'
ok "staging complete; nothing has been activated"
dim "verify:  $MOON_DIR/moon64 doctor"
dim "switch:  $MOON_DIR/moon64 on     (undo: $MOON_DIR/moon64 off)"
