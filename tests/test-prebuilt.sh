#!/usr/bin/env bash
# Sandbox test for `install.sh --prebuilt`: download, digest / ELF-class /
# pattern-gate checks, fallback to the source build, and how the install
# summary and `moon64 doctor` report which path was used.
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

assert_not_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*) fail "$label" "unexpected $(printf '%q' "$substr") in:"$'\n'"$text" ;;
        *) pass "$label" ;;
    esac
}

assert_same() {
    if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$2 differs from $3"; fi
}

assert_absent() {
    if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpected file: $2"; fi
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

make_elf32() {
    mkdir -p "$(dirname "$1")"
    { printf '\177ELF\001\001\001'; head -c 9 /dev/zero; printf '\003\000\003\000\001\000\000\000'; head -c 28 /dev/zero; } > "$1"
}

COMPLETE=$'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready'
PENDING=$'arch=x86_64\nrequired=38\nresolved=21\npending=17\nrunipcframe_tail=ready'

# make_release <name> [no-sha|bad-sha|no-status|pending|elf32] — a release
# directory laid out like the project's GitHub release assets.
make_release() {
    local d="$TMP_ROOT/rel-$1" variant="${2:-}"
    mkdir -p "$d"
    if [ "$variant" = elf32 ]; then
        make_elf32 "$d/SLSsteam.so"
    else
        printf 'void sls_prebuilt_%s(void) {}\n' "${1//-/_}" | gcc -shared -fPIC -x c - -o "$d/SLSsteam.so"
    fi
    case "$variant" in
        no-sha) ;;
        bad-sha) printf '%064d  SLSsteam.so\n' 0 > "$d/SLSsteam.so.sha256" ;;
        *) printf '%s  SLSsteam.so\n' "$(sha "$d/SLSsteam.so")" > "$d/SLSsteam.so.sha256" ;;
    esac
    case "$variant" in
        no-status) ;;
        pending) printf '%s\n' "$PENDING" > "$d/pattern-status.txt" ;;
        *) printf '%s\n' "$COMPLETE" > "$d/pattern-status.txt" ;;
    esac
    printf '%s' "$d"
}

# make_sandbox <name> — throwaway HOME with an installed 32-bit SLSsteam (so
# install.sh saves it instead of downloading a rollback target) and a source
# tree whose Makefile records that it ran.
make_sandbox() {
    local sb="$TMP_ROOT/$1"
    mkdir -p "$sb/home/.steam" "$sb/home/.local/share/Steam/steamrt64" \
        "$sb/moon64" "$sb/tmp" "$sb/proc" "$sb/src/res" "$sb/stub-bin"
    make_elf32 "$sb/home/.local/share/SLSsteam/SLSsteam.so"
    cat > "$sb/src/Makefile" <<MK
all:
	: > '$sb/make-ran'
	mkdir -p bin
	printf 'void sls_built(void) {}\n' | gcc -shared -fPIC -x c - -o bin/SLSsteam.so
MK
    printf '%s\n' "$COMPLETE" > "$sb/src/res/pattern-status.txt"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/stub-bin/systemctl"
    chmod +x "$sb/stub-bin/systemctl"
    printf '%s' "$sb"
}

# in_sandbox <sb> <cmd...> — run with every path install.sh and moon64 touch
# redirected into the sandbox.
in_sandbox() {
    local sb="$1" h="$1/home"
    shift
    env -u MOON64_APPS_DIR -u MOON64_ENV_CONF -u MOON64_ENV_D_DIR -u SLSM_PREBUILT_URL \
        PATH="$sb/stub-bin:${SANDBOX_PATH:-$PATH}" HOME="$h" MOON64_DIR="$sb/moon64" SLS64_SRC="$sb/src" \
        XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_DATA_DIRS="$sb/none" \
        SLSM_PROC_ROOT="$sb/proc" TMPDIR="$sb/tmp" LUMEN_FIX_INSTALLS_DIR="$sb/none" \
        SLSM_SLS32_URL="file://$sb/no-rollback-download.7z" \
        "$@"
}

state_of() { sed -n "s/^$2=//p" "$1/moon64/slsteam64.state" 2>/dev/null; }

# --- (a) published release with .sha256: staged, nothing built -------------
rel="$(make_release a)"
sb="$(make_sandbox a)"
out="$(in_sandbox "$sb" SLSM_PREBUILT_URL="file://$rel/SLSsteam.so" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "a1: --prebuilt install succeeds" 0 "$rc" "$out"
assert_contains "a1: digest verified" "prebuilt sha256 matches file://$rel/SLSsteam.so.sha256" "$out"
assert_contains "a1: pattern gate ran on the release" "x86_64 pattern table complete" "$out"
assert_same "a1: staged the downloaded library" "$rel/SLSsteam.so" "$sb/moon64/SLSsteam.so.64"
assert_absent "a1: did not build" "$sb/make-ran"
assert_not_contains "a1: no build step" "building the 64-bit SLSsteam" "$out"
assert_contains "a1: summary names the prebuilt path" "SLSsteam.so.64: prebuilt (file://$rel/SLSsteam.so)" "$out"
assert_contains "a1: state records the source" "prebuilt" "$(state_of "$sb" source)"
assert_contains "a1: state records the URL" "file://$rel/SLSsteam.so" "$(state_of "$sb" url)"
assert_contains "a1: state records the digest check" "yes" "$(state_of "$sb" sha256_published)"
assert_contains "a1: state records the staged sha256" "$(sha "$rel/SLSsteam.so")" "$(state_of "$sb" sha256)"
assert_absent "a1: temporary download removed" "$(compgen -G "$sb/tmp/moon64-prebuilt.*")"

out="$(in_sandbox "$sb" bash "$sb/moon64/moon64" doctor 2>&1)"
assert_contains "a2: doctor names the staged prebuilt" "staged SLSsteam.so.64: prebuilt, downloaded from file://$rel/SLSsteam.so" "$out"
assert_not_contains "a2: doctor does not call the 32-bit stack the staged binary" "active SLSsteam.so is the staged binary" "$out"

out="$(in_sandbox "$sb" bash "$sb/moon64/moon64" on 2>&1)"; rc=$?
assert_rc "a3: on activates the prebuilt" 0 "$rc" "$out"
out="$(in_sandbox "$sb" bash "$sb/moon64/moon64" doctor 2>&1)"
assert_contains "a3: doctor says the active binary is the prebuilt" "active SLSsteam.so is the staged binary (prebuilt, downloaded from file://$rel/SLSsteam.so)" "$out"

printf 'void sls_other(void) {}\n' | gcc -shared -fPIC -x c - -o "$sb/other.so"
cp "$sb/other.so" "$sb/home/.local/share/SLSsteam/SLSsteam.so"
out="$(in_sandbox "$sb" bash "$sb/moon64/moon64" doctor 2>&1)"
assert_contains "a4: doctor flags an active binary that is not the staged one" "active 64-bit SLSsteam.so differs from the staged $sb/moon64/SLSsteam.so.64" "$out"

# --- (b) no .sha256 published: staged, says the digest is unverified ------
rel="$(make_release b no-sha)"
sb="$(make_sandbox b)"
out="$(in_sandbox "$sb" SLSM_PREBUILT_URL="file://$rel/SLSsteam.so" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "b1: install succeeds without a .sha256" 0 "$rc" "$out"
assert_contains "b1: warns the digest is unverified" "no file://$rel/SLSsteam.so.sha256 published; the prebuilt's digest is not verified" "$out"
assert_same "b1: staged the downloaded library" "$rel/SLSsteam.so" "$sb/moon64/SLSsteam.so.64"
assert_contains "b1: state records no published digest" "no" "$(state_of "$sb" sha256_published)"
out="$(in_sandbox "$sb" bash "$sb/moon64/moon64" doctor 2>&1)"
assert_contains "b2: doctor repeats it" "(no published sha256 to verify against)" "$out"

# --- (c) failed checks stop the install; nothing staged, nothing built -----
for variant in bad-sha elf32 pending; do
    rel="$(make_release "c-$variant" "$variant")"
    sb="$(make_sandbox "c-$variant")"
    out="$(in_sandbox "$sb" SLSM_PREBUILT_URL="file://$rel/SLSsteam.so" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
    assert_rc "c-$variant: install.sh stops" 1 "$rc" "$out"
    case "$variant" in
        bad-sha) assert_contains "c-$variant: says why" "does not match the published 0000" "$out" ;;
        elf32)   assert_contains "c-$variant: says why" "prebuilt SLSsteam.so is not a 64-bit x86-64 shared object" "$out" ;;
        pending) assert_contains "c-$variant: says why" "refusing the prebuilt: its pattern table is incomplete" "$out" ;;
    esac
    assert_contains "c-$variant: refuses instead of falling back" "refusing to stage an unverified prebuilt SLSsteam.so" "$out"
    assert_absent "c-$variant: nothing staged" "$sb/moon64/SLSsteam.so.64"
    assert_absent "c-$variant: did not build" "$sb/make-ran"
    assert_not_contains "c-$variant: stopped before stopping Steam" "Steam is not running" "$out"
done

# --- (d) unavailable prebuilt: says so, builds from source ----------------
sb="$(make_sandbox d1)"
out="$(in_sandbox "$sb" SLSM_PREBUILT_URL="file://$sb/missing/SLSsteam.so" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "d1: missing prebuilt falls back and succeeds" 0 "$rc" "$out"
assert_contains "d1: names the failed download" "cannot download file://$sb/missing/SLSsteam.so" "$out"
assert_contains "d1: says it builds from source" "no usable prebuilt SLSsteam.so; building from source instead" "$out"
assert_contains "d1: states the glibc consequence" "the result only runs on hosts with at least that glibc" "$out"
assert_contains "d1: built" "building the 64-bit SLSsteam from $sb/src" "$out"
assert_contains "d1: summary names the built path" "SLSsteam.so.64: built from source ($sb/src @ unknown)" "$out"
assert_contains "d1: state records a build" "built" "$(state_of "$sb" source)"
assert_same "d1: staged the build output" "$sb/src/bin/SLSsteam.so" "$sb/moon64/SLSsteam.so.64"

rel="$(make_release d2 no-status)"
sb="$(make_sandbox d2)"
out="$(in_sandbox "$sb" SLSM_PREBUILT_URL="file://$rel/SLSsteam.so" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "d2: release without pattern-status.txt falls back" 0 "$rc" "$out"
assert_contains "d2: says the gate needs it" "the pattern gate needs it to accept a prebuilt" "$out"
assert_contains "d2: built instead" "SLSsteam.so.64: built from source" "$out"

# --- (e) default path is the source build, reported as such ---------------
sb="$(make_sandbox e)"
out="$(in_sandbox "$sb" bash "$REPO_ROOT/install.sh" 2>&1)"; rc=$?
assert_rc "e1: plain install builds" 0 "$rc" "$out"
assert_not_contains "e1: no download attempted" "downloading the prebuilt" "$out"
assert_contains "e1: summary names the built path" "SLSsteam.so.64: built from source ($sb/src @ unknown)" "$out"
out="$(in_sandbox "$sb" bash "$sb/moon64/moon64" doctor 2>&1)"
assert_contains "e2: doctor names the build" "staged SLSsteam.so.64: built from source at $sb/src @ unknown" "$out"
rm -f "$sb/moon64/slsteam64.state"
out="$(in_sandbox "$sb" bash "$sb/moon64/moon64" doctor 2>&1)"
assert_contains "e3: doctor copes with an older install" "staged SLSsteam.so.64: of unrecorded origin" "$out"

# --- (f) --prebuilt needs no C++ toolchain --------------------------------
# PATH without g++/c++/make: directories holding them are mirrored minus those
# names, every other directory is kept as is (version-manager shims refuse to
# run through a symlink).
notc=""
n=0
IFS=: read -ra path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
    [ -d "$d" ] || continue
    if [ -e "$d/g++" ] || [ -e "$d/c++" ] || [ -e "$d/make" ]; then
        n=$((n + 1))
        m="$TMP_ROOT/no-toolchain-$n"
        mkdir -p "$m"
        for f in "$d"/*; do
            case "${f##*/}" in g++|c++|make|*-g++|*-c++) continue ;; esac
            [ -x "$f" ] && ln -s "$f" "$m/${f##*/}"
        done
        d="$m"
    fi
    notc="${notc:+$notc:}$d"
done

rel="$(make_release f)"
sb="$(make_sandbox f1)"
out="$(SANDBOX_PATH="$notc" in_sandbox "$sb" SLSM_PREBUILT_URL="file://$rel/SLSsteam.so" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "f1: --prebuilt installs without g++ or make" 0 "$rc" "$out"
assert_not_contains "f1: does not ask for the toolchain" "missing prerequisites" "$out"

sb="$(make_sandbox f2)"
out="$(SANDBOX_PATH="$notc" in_sandbox "$sb" bash "$REPO_ROOT/install.sh" 2>&1)"; rc=$?
assert_rc "f2: a source build without g++ or make stops" 1 "$rc" "$out"
assert_contains "f2: names them" "missing prerequisites: g++, make" "$out"

sb="$(make_sandbox f3)"
out="$(SANDBOX_PATH="$notc" in_sandbox "$sb" SLSM_PREBUILT_URL="file://$sb/missing/SLSsteam.so" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "f3: fallback without a toolchain stops" 1 "$rc" "$out"
assert_contains "f3: names what the fallback needs" "missing build prerequisites" "$out"
assert_absent "f3: nothing staged" "$sb/moon64/SLSsteam.so.64"

# --- (g) the documented default ------------------------------------------
assert_contains "g1: default points at the project's release asset" \
    "https://github.com/KadirBerkpolat1/slsteam-moon-64/releases/" \
    "$(sed -n 's/^SLS64_PREBUILT_URL="\(.*\)"$/\1/p' "$REPO_ROOT/versions.env")"
assert_contains "g2: --help documents the flag" "--prebuilt" "$(bash "$REPO_ROOT/install.sh" --help)"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
