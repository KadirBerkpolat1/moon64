#!/usr/bin/env bash
# Sandbox test for install.sh prerequisite detection and --install-deps.
# PATH is a directory of stubs, so missing tools, missing headers, sudo and the
# package manager are all simulated; nothing is installed for real.
# shellcheck disable=SC2016  # stub bodies are expanded by the stubs, not here
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0

pass() { printf 'PASS [%s]\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

assert_rc() {
    local label="$1" expected="$2" actual="$3" out="${4:-}"
    if [ "$expected" -eq "$actual" ]; then pass "$label (rc=$actual)"; else fail "$label" "expected rc=$expected, got rc=$actual"$'\n'"$out"; fi
}

assert_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*) pass "$label" ;;
        *) fail "$label" "missing $(printf '%q' "$substr") in:"$'\n'"$text" ;;
    esac
}

assert_not_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*) fail "$label" "unexpected $(printf '%q' "$substr") in:"$'\n'"$text" ;;
        *) pass "$label" ;;
    esac
}

assert_absent() {
    if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpected file: $2"; fi
}

stub() {
    local dir="$1" name="$2" body="${3:-exit 0}"
    printf '#!%s\n%s\n' "$BASH_BIN" "$body" > "$dir/$name"
    chmod +x "$dir/$name"
}

# g++ stand-in: fails the syntax check for any header in $STUB_MISSING_HEADERS.
GXX_BODY='src=""
[ "${1:-}" = -x ] || exit 0
while IFS= read -r l; do src="$src$l"; done
for h in ${STUB_MISSING_HEADERS:-}; do case "$src" in *"$h"*) exit 1 ;; esac; done
exit 0'

ALL_TOOLS=(curl gcc make readelf file ldd git bsdtar)

# make_bin <name> [tool-to-omit...] — a PATH dir with every prerequisite but those.
make_bin() {
    local dir="$TMP_ROOT/$1" t skip o
    shift
    mkdir -p "$dir"
    for t in "${ALL_TOOLS[@]}" g++; do
        skip=0
        for o in "$@"; do [ "$o" = "$t" ] && skip=1; done
        [ "$skip" = 1 ] && continue
        if [ "$t" = g++ ]; then stub "$dir" g++ "$GXX_BODY"; else stub "$dir" "$t"; fi
    done
    # The package-manager stubs "install" a tool by writing an executable.
    ln -s "$(command -v chmod)" "$dir/chmod"
    printf '%s' "$dir"
}

# deps <bin> <install> <deps...> — check_deps from a sourced install.sh, PATH=<bin>.
deps() {
    local bin="$1"; shift
    (
        # shellcheck disable=SC1091
        source "$REPO_ROOT/install.sh"
        PATH="$bin"
        unset CXX
        check_deps "$@"
    ) 2>&1
}

REQ=(curl gcc g++ make readelf file ldd libcurl-headers openssl-headers git)

# --- (a) nothing missing --------------------------------------------------
bin="$(make_bin a-all)"
out="$(SLSM_PKG_MANAGER=pacman deps "$bin" 0 "${REQ[@]}" -- bsdtar)"; rc=$?
assert_rc "a1: all present passes" 0 "$rc" "$out"
assert_contains "a1: says so" "all prerequisites present" "$out"
assert_not_contains "a1: prints no install command" "sudo" "$out"

# --- (b) missing tools + headers: one list, exact commands, no sudo -------
bin="$(make_bin b-missing readelf file)"
stub "$bin" sudo "printf '%s\n' \"\$*\" >> '$TMP_ROOT/b-sudo.log'; exit 0"
export STUB_MISSING_HEADERS="curl/curl.h openssl/evp.h"
out="$(SLSM_PKG_MANAGER=pacman deps "$bin" 0 "${REQ[@]}")"; rc=$?
assert_rc "b1: missing required fails" 1 "$rc" "$out"
assert_contains "b1: one consolidated list" "missing prerequisites: readelf, file, libcurl-headers, openssl-headers" "$out"
assert_contains "b1: exact pacman command" "install with: sudo pacman -S --needed binutils file curl openssl" "$out"
assert_contains "b1: points at --install-deps" "re-run install.sh with --install-deps" "$out"
assert_absent "b1: sudo never run without the flag" "$TMP_ROOT/b-sudo.log"

out="$(SLSM_PKG_MANAGER=apt-get deps "$bin" 0 "${REQ[@]}")"
assert_contains "b2: exact apt-get command" "install with: sudo apt-get install -y binutils file libcurl4-openssl-dev libssl-dev" "$out"
out="$(SLSM_PKG_MANAGER=dnf deps "$bin" 0 "${REQ[@]}")"
assert_contains "b3: exact dnf command" "install with: sudo dnf install -y binutils file libcurl-devel openssl-devel" "$out"
unset STUB_MISSING_HEADERS

bin="$(make_bin b4-compiler g++ gcc ldd)"
out="$(SLSM_PKG_MANAGER=dnf deps "$bin" 0 "${REQ[@]}")"
assert_contains "b4: no compiler -> headers unverifiable, listed" "missing prerequisites: gcc, g++, ldd, libcurl-headers, openssl-headers" "$out"
assert_contains "b4: dnf package names" "sudo dnf install -y gcc gcc-c++ glibc-common libcurl-devel openssl-devel" "$out"

# --- (c) no supported package manager: all three commands -----------------
bin="$(make_bin c-nopm git)"
out="$(deps "$bin" 0 "${REQ[@]}")"; rc=$?
assert_rc "c1: fails" 1 "$rc" "$out"
assert_contains "c1: pacman line" "sudo pacman -S --needed git" "$out"
assert_contains "c1: apt-get line" "sudo apt-get install -y git" "$out"
assert_contains "c1: dnf line" "sudo dnf install -y git" "$out"
out="$(deps "$bin" 1 "${REQ[@]}")"; rc=$?
assert_rc "c2: --install-deps without a package manager fails" 1 "$rc" "$out"
assert_contains "c2: says why" "no supported package manager" "$out"

# --- (d) optional only: warn and continue --------------------------------
bin="$(make_bin d-opt bsdtar)"
out="$(SLSM_PKG_MANAGER=pacman deps "$bin" 0 "${REQ[@]}" -- bsdtar)"; rc=$?
assert_rc "d1: optional-only missing continues" 0 "$rc" "$out"
assert_contains "d1: warns about it" "missing optional: bsdtar" "$out"
assert_contains "d1: names the package" "sudo pacman -S --needed libarchive" "$out"
stub "$bin" 7z
out="$(SLSM_PKG_MANAGER=pacman deps "$bin" 0 "${REQ[@]}" -- bsdtar)"
assert_contains "d2: 7z satisfies the unpacker" "all prerequisites present" "$out"

# --- (e) --install-deps but sudo wants a password: say so, stop -----------
bin="$(make_bin e-pw file)"
stub "$bin" sudo "printf '%s\n' \"\$*\" >> '$TMP_ROOT/e-sudo.log'; [ \"\$1\" = -n ] || exit 99; exit 1"
stub "$bin" pacman ": > '$TMP_ROOT/e-pacman-ran'"
out="$(SLSM_PKG_MANAGER=pacman deps "$bin" 1 "${REQ[@]}")"; rc=$?
assert_rc "e1: password-protected sudo stops" 1 "$rc" "$out"
assert_contains "e1: says sudo needs a password" "sudo needs a password, and install.sh will not prompt for one" "$out"
assert_contains "e1: only probed with sudo -n true" "-n true" "$(cat "$TMP_ROOT/e-sudo.log")"
assert_absent "e1: package manager never ran" "$TMP_ROOT/e-pacman-ran"

bin="$(make_bin e2-nosudo file)"
out="$(SLSM_PKG_MANAGER=pacman deps "$bin" 1 "${REQ[@]}")"; rc=$?
assert_rc "e2: no sudo binary stops" 1 "$rc" "$out"
assert_contains "e2: says sudo not found" "sudo not found" "$out"

# --- (f) --install-deps with passwordless sudo installs and re-checks -----
bin="$(make_bin f-install readelf file bsdtar)"
stub "$bin" sudo '[ "$1" = -n ] || exit 99; shift; [ "$1" = true ] && exit 0; exec "$@"'
stub "$bin" pacman "printf '%s\n' \"\$*\" > '$TMP_ROOT/f-pacman.log'
for t in readelf file bsdtar; do printf '#!%s\nexit 0\n' '$BASH_BIN' > '$bin'/\$t; chmod +x '$bin'/\$t; done"
out="$(SLSM_PKG_MANAGER=pacman deps "$bin" 1 "${REQ[@]}" -- bsdtar)"; rc=$?
assert_rc "f1: --install-deps succeeds" 0 "$rc" "$out"
assert_contains "f1: announces the exact command" "running: sudo -n pacman -S --needed --noconfirm binutils file libarchive" "$out"
assert_contains "f1: package manager got every package once" "-S --needed --noconfirm binutils file libarchive" "$(cat "$TMP_ROOT/f-pacman.log")"
assert_contains "f1: reports the install" "installed binutils file libarchive" "$out"

bin="$(make_bin f2-still file)"
stub "$bin" sudo '[ "$1" = -n ] || exit 99; shift; [ "$1" = true ] && exit 0; exec "$@"'
stub "$bin" apt-get 'exit 0'
out="$(SLSM_PKG_MANAGER=apt-get deps "$bin" 1 "${REQ[@]}")"; rc=$?
assert_rc "f2: still missing after install fails" 1 "$rc" "$out"
assert_contains "f2: names what is still missing" "still missing after installing file: file" "$out"

bin="$(make_bin f3-pmfail file)"
stub "$bin" sudo '[ "$1" = -n ] || exit 99; shift; [ "$1" = true ] && exit 0; exec "$@"'
stub "$bin" dnf 'exit 1'
out="$(SLSM_PKG_MANAGER=dnf deps "$bin" 1 "${REQ[@]}")"; rc=$?
assert_rc "f3: package manager failure stops" 1 "$rc" "$out"
assert_contains "f3: names the failed command" "'dnf install -y file' failed" "$out"

# --- (g) install.sh end to end --------------------------------------------
# Only what install.sh runs before the prerequisite check is added to PATH; a
# pattern table with pending entries stops it right after, before any build.
e2e_bin="$(make_bin g-e2e file)"
for t in dirname id mkdir; do ln -s "$(command -v "$t")" "$e2e_bin/$t"; done
sb="$TMP_ROOT/g-sandbox"
mkdir -p "$sb/home" "$sb/moon64" "$sb/src/res"
printf 'all:\n\t@echo SHOULD_NOT_RUN; exit 99\n' > "$sb/src/Makefile"
printf 'arch=x86_64\nrequired=38\nresolved=21\npending=17\nrunipcframe_tail=ready\n' > "$sb/src/res/pattern-status.txt"
run_install() {
    env -i PATH="$e2e_bin" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLS64_SRC="$sb/src" \
        SLSM_PKG_MANAGER=pacman "$BASH_BIN" "$REPO_ROOT/install.sh" "$@" 2>&1
}

out="$(run_install)"; rc=$?
assert_rc "g1: install.sh stops on a missing prerequisite" 1 "$rc" "$out"
assert_contains "g1: lists it" "missing prerequisites: file" "$out"
assert_contains "g1: prints the command" "sudo pacman -S --needed file" "$out"
assert_not_contains "g1: stops before the pattern gate" "pattern table" "$out"

stub "$e2e_bin" sudo '[ "$1" = -n ] || exit 99; shift; [ "$1" = true ] && exit 0; exec "$@"'
stub "$e2e_bin" pacman "printf '#!%s\nexit 0\n' '$BASH_BIN' > '$e2e_bin/file'; chmod +x '$e2e_bin/file'"
out="$(run_install --install-deps)"; rc=$?
assert_rc "g2: --install-deps continues to the next step" 1 "$rc" "$out"
assert_contains "g2: installed the package" "installed file" "$out"
assert_contains "g2: reached the pattern gate" "refusing to stage an incomplete build" "$out"
assert_not_contains "g2: did not build" "SHOULD_NOT_RUN" "$out"

out="$(run_install)"; rc=$?
assert_contains "g3: complete host says so once" "all prerequisites present" "$out"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
