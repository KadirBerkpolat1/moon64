#!/usr/bin/env bash
# Sandbox test for the self-provisioned 32-bit rollback target (install.sh)
# and its reporting in `moon64 doctor` / use by `moon64 off`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"; fi
}

assert_same() {
    if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$2 differs from $3"; fi
}

assert_absent() {
    if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpected file: $2"; fi
}

make_elf() {
    local bits="$1" out="$2"
    mkdir -p "$(dirname "$out")"
    if [ "$bits" = 32 ]; then
        { printf '\177ELF\001\001\001'; head -c 9 /dev/zero; printf '\003\000\003\000\001\000\000\000'; head -c 28 /dev/zero; } > "$out"
    else
        { printf '\177ELF\002\001\001'; head -c 9 /dev/zero; printf '\003\000\076\000\001\000\000\000'; head -c 40 /dev/zero; } > "$out"
    fi
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

# make_release <bits> <out.7z> — an upstream-shaped archive with bin/SLSsteam.so.
make_release() {
    local bits="$1" out="$2" tree
    tree="$(mktemp -d "$TMP_ROOT/tree.XXXXXX")"
    make_elf "$bits" "$tree/bin/SLSsteam.so"
    printf '#!/bin/bash\n' > "$tree/setup.sh"
    if command -v 7z >/dev/null 2>&1; then
        (cd "$tree" && 7z a -t7z "$out" bin setup.sh >/dev/null)
    else
        (cd "$tree" && bsdtar --format 7zip -cf "$out" bin setup.sh)
    fi
}

if ! command -v 7z >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
    printf 'FAIL [setup]: need 7z or bsdtar to build release fixtures\n' >&2
    exit 1
fi

REL32="$TMP_ROOT/rel32.7z"; make_release 32 "$REL32"
REL64="$TMP_ROOT/rel64.7z"; make_release 64 "$REL64"

make_sandbox() {
    local sb="$TMP_ROOT/$1"
    mkdir -p "$sb/home/.steam" "$sb/home/.local/share/Steam/steamrt64" "$sb/moon64" "$sb/tmp" "$sb/proc"
    printf '%s' "$sb"
}

# provision <sandbox> — run provision_rollback32 from a sourced install.sh.
provision() {
    local sb="$1"
    (
        export HOME="$sb/home" MOON64_DIR="$sb/moon64" TMPDIR="$sb/tmp"
        # shellcheck disable=SC1091
        source "$REPO_ROOT/install.sh"
        provision_rollback32
    ) 2>&1
}

export SLSM_SLS32_VERSION="20990101000000"

# --- (a) clean machine: the pinned release is fetched, checked, recorded ----
sb="$(make_sandbox a-fetch)"; dst="$sb/home/.local/share/SLSsteam/SLSsteam.so.32"
out="$(SLSM_SLS32_URL="file://$REL32" SLSM_SLS32_SHA256="$(sha "$REL32")" provision "$sb")"; rc=$?
assert_rc "a1: provisioning succeeds" 0 "$rc" "$out"
assert_contains "a1: reports the saved target" "rollback target: upstream SLSsteam 20990101000000 (32-bit) saved as $dst" "$out"
assert_contains "a1: saved .32 is a 32-bit ELF" "ELF 32-bit" "$(file -b "$dst")"
state="$sb/moon64/rollback32.state"
assert_eq "a1: state records the URL" "file://$REL32" "$(sed -n 's/^url=//p' "$state")"
assert_eq "a1: state records the version" "20990101000000" "$(sed -n 's/^version=//p' "$state")"
assert_eq "a1: state records the archive sha256" "$(sha "$REL32")" "$(sed -n 's/^archive_sha256=//p' "$state")"
assert_eq "a1: state records the library sha256" "$(sha "$dst")" "$(sed -n 's/^sha256=//p' "$state")"
assert_eq "a1: no temp files left in SLSsteam dir" "SLSsteam.so.32" "$(ls -A "$sb/home/.local/share/SLSsteam")"
assert_eq "a1: temp dir cleaned" "" "$(ls -A "$sb/tmp")"

HOME_A="$sb/home" MOON_A="$sb/moon64"
doc="$(HOME="$HOME_A" MOON64_DIR="$MOON_A" XDG_DATA_DIRS="$sb/none" XDG_DATA_HOME="$HOME_A/.local/share" \
    XDG_CONFIG_HOME="$HOME_A/.config" LUMEN_FIX_INSTALLS_DIR="$sb/none" bash "$REPO_ROOT/bin/moon64" doctor 2>&1)"
assert_contains "a2: doctor names the fetched target" "$dst: upstream SLSsteam 20990101000000, fetched by install.sh" "$doc"

printf 'tampered' >> "$dst"
doc="$(HOME="$HOME_A" MOON64_DIR="$MOON_A" XDG_DATA_DIRS="$sb/none" XDG_DATA_HOME="$HOME_A/.local/share" \
    XDG_CONFIG_HOME="$HOME_A/.config" LUMEN_FIX_INSTALLS_DIR="$sb/none" bash "$REPO_ROOT/bin/moon64" doctor 2>&1)"
assert_contains "a3: doctor notices a changed target" "no longer matches the upstream download" "$doc"

# --- (b) an existing .32 is never replaced, and nothing is downloaded -------
sb="$(make_sandbox b-keep)"; dst="$sb/home/.local/share/SLSsteam/SLSsteam.so.32"
make_elf 32 "$dst"; printf 'user-original' >> "$dst"; cp -a "$dst" "$sb/pristine"
out="$(SLSM_SLS32_URL="file://$sb/does-not-exist.7z" SLSM_SLS32_SHA256=0 provision "$sb")"; rc=$?
assert_rc "b1: existing target accepted" 0 "$rc" "$out"
assert_contains "b1: reports it present" "rollback target present: $dst" "$out"
assert_same "b1: existing .32 untouched" "$dst" "$sb/pristine"
assert_absent "b1: no state file written" "$sb/moon64/rollback32.state"

# --- (c) no network: warn, rollback unavailable, nothing saved -------------
sb="$(make_sandbox c-offline)"; dst="$sb/home/.local/share/SLSsteam/SLSsteam.so.32"
out="$(SLSM_SLS32_URL="file://$sb/does-not-exist.7z" SLSM_SLS32_SHA256="$(sha "$REL32")" provision "$sb")"; rc=$?
assert_rc "c1: download failure is soft" 1 "$rc" "$out"
assert_contains "c1: warns rollback is unavailable" "'moon64 off' will have no 32-bit stack to restore" "$out"
assert_absent "c1: nothing saved" "$dst"

# --- (d) digest mismatch: hard failure, nothing saved ----------------------
sb="$(make_sandbox d-digest)"; dst="$sb/home/.local/share/SLSsteam/SLSsteam.so.32"
out="$(SLSM_SLS32_URL="file://$REL32" SLSM_SLS32_SHA256="$(printf '0%.0s' {1..64})" provision "$sb")"; rc=$?
assert_rc "d1: digest mismatch is a verification failure" 2 "$rc" "$out"
assert_contains "d1: names the mismatch" "does not match the pinned" "$out"
assert_absent "d1: nothing saved" "$dst"

# --- (e) right digest, wrong ELF class: refused ----------------------------
sb="$(make_sandbox e-class)"; dst="$sb/home/.local/share/SLSsteam/SLSsteam.so.32"
out="$(SLSM_SLS32_URL="file://$REL64" SLSM_SLS32_SHA256="$(sha "$REL64")" provision "$sb")"; rc=$?
assert_rc "e1: 64-bit payload is a verification failure" 2 "$rc" "$out"
assert_contains "e1: says it is not 32-bit" "is not a 32-bit i386 ELF" "$out"
assert_absent "e1: nothing saved" "$dst"

# --- (f) no 7z/bsdtar: warn and continue ----------------------------------
sb="$(make_sandbox f-nounpack)"; dst="$sb/home/.local/share/SLSsteam/SLSsteam.so.32"
NOX_BIN="$TMP_ROOT/nox-bin"; mkdir -p "$NOX_BIN"
for cmd in bash cat curl cut date dirname file head install mkdir mktemp mv rm sed sha256sum tail; do
    p="$(command -v "$cmd")" && ln -sf "$p" "$NOX_BIN/$cmd"
done
out="$(PATH="$NOX_BIN" SLSM_SLS32_URL="file://$REL32" SLSM_SLS32_SHA256="$(sha "$REL32")" provision "$sb")"; rc=$?
assert_rc "f1: missing unpacker is soft" 1 "$rc" "$out"
assert_contains "f1: names the missing tools" "neither 7z nor bsdtar" "$out"
assert_absent "f1: nothing saved" "$dst"

# --- (g) end to end: clean machine -> install.sh -> on -> off ---------------
sb="$(make_sandbox g-e2e)"; h="$sb/home"
mkdir -p "$sb/src/res" "$sb/stub-bin"
cat > "$sb/src/Makefile" <<'MK'
all:
	mkdir -p bin
	printf 'void sls_dummy(void) {}\n' | gcc -shared -fPIC -x c - -o bin/SLSsteam.so
MK
printf 'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready\n' > "$sb/src/res/pattern-status.txt"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/stub-bin/systemctl"; chmod +x "$sb/stub-bin/systemctl"

sandbox_env=(env -u MOON64_APPS_DIR -u MOON64_ENV_CONF -u MOON64_ENV_D_DIR
    PATH="$sb/stub-bin:$PATH" HOME="$h" MOON64_DIR="$sb/moon64" SLS64_SRC="$sb/src"
    XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_DATA_DIRS="$sb/none"
    SLSM_PROC_ROOT="$sb/proc" TMPDIR="$sb/tmp" LUMEN_FIX_INSTALLS_DIR="$sb/none"
    SLSM_SLS32_URL="file://$REL32" SLSM_SLS32_SHA256="$(sha "$REL32")")

out="$("${sandbox_env[@]}" bash "$REPO_ROOT/install.sh" 2>&1)"; rc=$?
assert_rc "g1: install.sh succeeds on a clean machine" 0 "$rc" "$out"
assert_contains "g1: install fetched the rollback target" "rollback target: upstream SLSsteam 20990101000000 (32-bit) saved as" "$out"

out="$("${sandbox_env[@]}" bash "$sb/moon64/moon64" on 2>&1)"; rc=$?
assert_rc "g2: on succeeds" 0 "$rc" "$out"
out="$("${sandbox_env[@]}" bash "$sb/moon64/moon64" off 2>&1)"; rc=$?
assert_rc "g3: off succeeds on a machine that never had 32-bit SLSsteam" 0 "$rc" "$out"
assert_contains "g3: off restored the fetched 32-bit library" "SLSsteam.so: 32-bit restored (byte-exact)" "$out"
assert_same "g3: active library is the fetched one" "$h/.local/share/SLSsteam/SLSsteam.so" "$h/.local/share/SLSsteam/SLSsteam.so.32"

# g4: offline install still completes, with the warning
sb2="$(make_sandbox g4-offline)"
out="$("${sandbox_env[@]}" HOME="$sb2/home" MOON64_DIR="$sb2/moon64" TMPDIR="$sb2/tmp" \
    XDG_CONFIG_HOME="$sb2/home/.config" XDG_DATA_HOME="$sb2/home/.local/share" \
    SLSM_SLS32_URL="file://$sb2/does-not-exist.7z" bash "$REPO_ROOT/install.sh" 2>&1)"; rc=$?
assert_rc "g4: offline install still completes" 0 "$rc" "$out"
assert_contains "g4: offline install warns about rollback" "'moon64 off' will have no 32-bit stack to restore" "$out"

# g5: a tampered download stops the install
sb3="$(make_sandbox g5-tampered)"
out="$("${sandbox_env[@]}" HOME="$sb3/home" MOON64_DIR="$sb3/moon64" TMPDIR="$sb3/tmp" \
    XDG_CONFIG_HOME="$sb3/home/.config" XDG_DATA_HOME="$sb3/home/.local/share" \
    SLSM_SLS32_SHA256="$(sha "$REL64")" bash "$REPO_ROOT/install.sh" 2>&1)"; rc=$?
assert_rc "g5: digest mismatch stops install.sh" 1 "$rc" "$out"
assert_contains "g5: says why" "refusing to continue with an unverified rollback download" "$out"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
