#!/usr/bin/env bash
# Sandbox test for the binary install: a clean machine whose PATH has no git,
# gcc, cc, g++, c++, make or clang runs `install.sh --prebuilt` against a
# complete release (SLSsteam.so and netsock64.so, each with a .sha256 and bound
# by pattern-status.txt), then `moon64 on`, and launches Steam through its
# desktop entry with both libraries on LD_AUDIT. Then the netsock64 refusals
# (nothing staged) and the fallbacks when a release has no netsock64.so.
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
    if [ ! -e "$2" ] && [ ! -L "$2" ]; then pass "$1"; else fail "$1" "unexpected file: $2"; fi
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

if ! command -v 7z >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
    printf 'FAIL [setup]: need 7z or bsdtar to build the rollback release fixture\n' >&2
    exit 1
fi

make_so() { printf 'void %s(void) {}\n' "$1" | gcc -shared -fPIC -x c - -o "$2"; }
make_elf32() {
    mkdir -p "$(dirname "$1")"
    { printf '\177ELF\001\001\001'; head -c 9 /dev/zero; printf '\003\000\003\000\001\000\000\000'; head -c 28 /dev/zero; } > "$1"
}

# --- a PATH without any compiler, git or make -------------------------------
# Directories holding one of them are mirrored without it; every other
# directory is kept as is (version-manager shims refuse to run via a symlink).
NO_TOOLCHAIN=(git gcc cc g++ c++ make clang clang++ tcc)
is_toolchain() {
    case "$1" in
        git|gcc|cc|g++|c++|make|gmake|clang|clang++|tcc|*-gcc|*-g++|*-c++|*-cc|gcc-[0-9]*|g++-[0-9]*|*-gcc-[0-9]*|clang-[0-9]*) return 0 ;;
    esac
    return 1
}
nocc=""
n=0
IFS=: read -ra path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
    [ -d "$d" ] || continue
    hit=0
    for t in "${NO_TOOLCHAIN[@]}"; do [ -e "$d/$t" ] && hit=1; done
    if [ "$hit" = 1 ]; then
        n=$((n + 1))
        m="$TMP_ROOT/no-toolchain-$n"
        mkdir -p "$m"
        for f in "$d"/*; do
            is_toolchain "${f##*/}" && continue
            [ -x "$f" ] && ln -s "$f" "$m/${f##*/}"
        done
        d="$m"
    fi
    nocc="${nocc:+$nocc:}$d"
done

# Upstream's 32-bit release, the rollback target on a machine without one.
REL32="$TMP_ROOT/rel32"
make_elf32 "$REL32/tree/bin/SLSsteam.so"
if command -v 7z >/dev/null 2>&1; then
    (cd "$REL32/tree" && 7z a -t7z "$REL32/SLSsteam-Any-release.7z" bin >/dev/null)
else
    (cd "$REL32/tree" && bsdtar --format 7zip -cf "$REL32/SLSsteam-Any-release.7z" bin)
fi
REL32_SHA="$(sha "$REL32/SLSsteam-Any-release.7z")"

STATUS=$'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready'

# make_release <name> [variant] — the project's release assets. Variants change
# only netsock64: mismatch, unbound, repeated, bad-sha, elf32, no-sha, absent.
make_release() {
    local d="$TMP_ROOT/rel-$1" variant="${2:-}" ns_line
    mkdir -p "$d"
    make_so "slsteam_prebuilt_${1//-/_}" "$d/SLSsteam.so"
    printf '%s  SLSsteam.so\n' "$(sha "$d/SLSsteam.so")" > "$d/SLSsteam.so.sha256"
    if [ "$variant" = elf32 ]; then
        make_elf32 "$d/netsock64.so"
    else
        make_so "netsock64_prebuilt_${1//-/_}" "$d/netsock64.so"
    fi
    case "$variant" in
        bad-sha) printf '%064d  netsock64.so\n' 0 > "$d/netsock64.so.sha256" ;;
        no-sha|absent) ;;
        *) printf '%s  netsock64.so\n' "$(sha "$d/netsock64.so")" > "$d/netsock64.so.sha256" ;;
    esac
    ns_line="netsock64_sha256=$(sha "$d/netsock64.so")"
    case "$variant" in
        mismatch) ns_line="netsock64_sha256=$(sha "$d/SLSsteam.so")" ;;
        unbound|absent) ns_line="" ;;
        repeated) ns_line="$ns_line"$'\n'"$ns_line" ;;
    esac
    printf '%s\nbinary_sha256=%s\n%s' "$STATUS" "$(sha "$d/SLSsteam.so")" "${ns_line:+$ns_line$'\n'}" > "$d/pattern-status.txt"
    [ "$variant" != absent ] || rm -f "$d/netsock64.so"
    printf '%s' "$d"
}

# make_sandbox <name> — a throwaway HOME on a machine that has only native Steam
# (already started once) and its distribution desktop entry. steam.sh records
# what a launch hands it instead of starting a client.
make_sandbox() {
    local sb="$TMP_ROOT/$1" steam
    steam="$sb/home/.local/share/Steam"
    mkdir -p "$sb/home/.steam" "$steam/steamrt64" "$sb/usr-share/applications" \
        "$sb/moon64" "$sb/tmp" "$sb/proc" "$sb/stub-bin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$steam/steamrt64/steam"
    make_so steamclient_stub "$steam/steamrt64/steamclient.so"
    cat > "$steam/steam.sh" <<SH
#!/usr/bin/env bash
{
    printf 'ARGS=%s\n' "\$*"
    printf 'STEAM_FORCE_CLIENT=%s\n' "\${STEAM_FORCE_CLIENT-<UNSET>}"
    printf 'LD_AUDIT=%s\n' "\${LD_AUDIT-<UNSET>}"
} > '$sb/launch.log'
SH
    chmod +x "$steam/steamrt64/steam" "$steam/steam.sh"
    printf '[Desktop Entry]\nName=Steam\nExec=/usr/bin/steam %%U\nType=Application\n' \
        > "$sb/usr-share/applications/steam.desktop"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/stub-bin/systemctl"
    chmod +x "$sb/stub-bin/systemctl"
    printf '%s' "$sb"
}

# run <sb> <release> <cmd...> — run with every path install.sh and moon64 touch
# in the sandbox, on the compiler-free PATH unless SANDBOX_PATH says otherwise.
run() {
    local sb="$1" rel="$2" h="$1/home"
    shift 2
    env -u MOON64_APPS_DIR -u MOON64_ENV_CONF -u MOON64_ENV_D_DIR -u SLSM_PREBUILT_URL -u SLS64_SRC \
        -u LD_AUDIT -u LD_PRELOAD -u STEAM_FORCE_CLIENT -u CXX \
        PATH="$sb/stub-bin:${SANDBOX_PATH:-$nocc}" HOME="$h" MOON64_DIR="$sb/moon64" \
        XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_DATA_DIRS="$sb/usr-share" \
        SLSM_PROC_ROOT="$sb/proc" TMPDIR="$sb/tmp" LUMEN_FIX_INSTALLS_DIR="$sb/none" \
        SLSM_PREBUILT_URL="file://$rel/SLSsteam.so" \
        SLSM_SLS32_URL="file://$REL32/SLSsteam-Any-release.7z" SLSM_SLS32_SHA256="$REL32_SHA" \
        SLSM_SLS32_VERSION=20990101000000 \
        "$@"
}

# --- (a) complete release, no toolchain at all ------------------------------
rel="$(make_release a)"
sb="$(make_sandbox a)"
SLS="$sb/home/.local/share/SLSsteam"
for t in "${NO_TOOLCHAIN[@]}"; do
    found="$(run "$sb" "$rel" bash -c "command -v $t" 2>/dev/null)"
    if [ -z "$found" ]; then pass "a0: $t is not on the install PATH"; else fail "a0: $t is not on the install PATH" "found $found"; fi
done

out="$(run "$sb" "$rel" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "a1: --prebuilt installs with no git, gcc, cc, g++, make on PATH" 0 "$rc" "$out"
assert_contains "a1: nothing is missing" "all prerequisites present" "$out"
assert_contains "a1: SLSsteam.so digest verified" "prebuilt sha256 matches file://$rel/SLSsteam.so.sha256" "$out"
assert_contains "a1: SLSsteam.so bound" "pattern-status.txt was measured on this SLSsteam.so (binary_sha256 $(sha "$rel/SLSsteam.so"))" "$out"
assert_contains "a1: netsock64.so digest verified" "prebuilt netsock64.so sha256 matches file://$rel/netsock64.so.sha256" "$out"
assert_contains "a1: netsock64.so bound" "pattern-status.txt names this netsock64.so (netsock64_sha256 $(sha "$rel/netsock64.so"))" "$out"
assert_same "a1: SLSsteam.so staged byte-exact" "$rel/SLSsteam.so" "$sb/moon64/SLSsteam.so.64"
assert_same "a1: netsock64.so staged byte-exact" "$rel/netsock64.so" "$sb/moon64/netsock64.so"
assert_not_contains "a1: nothing compiled" "built $sb/moon64/netsock64.so" "$out"
assert_contains "a1: summary: SLSsteam prebuilt" "SLSsteam.so.64: prebuilt (file://$rel/SLSsteam.so)" "$out"
assert_contains "a1: summary: netsock64 prebuilt" "netsock64.so: prebuilt (file://$rel/netsock64.so)" "$out"
assert_contains "a1: state records netsock64 as prebuilt" "source=prebuilt" "$(cat "$sb/moon64/netsock64.state" 2>/dev/null)"
assert_same "a1: rollback target fetched" "$REL32/tree/bin/SLSsteam.so" "$SLS/SLSsteam.so.32"
assert_absent "a1: temporary download removed" "$(compgen -G "$sb/tmp/moon64-prebuilt.*")"

out="$(run "$sb" "$rel" bash "$sb/moon64/moon64" doctor 2>&1)"; rc=$?
assert_rc "a2: doctor finds no blocking problem" 0 "$rc" "$out"
assert_contains "a2: doctor names the netsock64 origin" "netsock64.so present (prebuilt, downloaded from file://$rel/netsock64.so)" "$out"

out="$(run "$sb" "$rel" bash "$sb/moon64/moon64" on 2>&1)"; rc=$?
assert_rc "a3: on succeeds without a toolchain" 0 "$rc" "$out"
entry="$sb/home/.local/share/applications/steam.desktop"
exec_cmd="$(sed -n 's/^Exec=//p' "$entry" 2>/dev/null | head -1)"
assert_contains "a3: desktop entry starts the wrapper" "$SLS/path/steam %U" "$exec_cmd"
read -ra launch <<< "$exec_cmd"
launch=("${launch[@]/\%U/steam://open/main}")
run "$sb" "$rel" "${launch[@]}" >/dev/null 2>&1; rc=$?
assert_rc "a4: the desktop entry's command reaches steam.sh" 0 "$rc"
audit="$(sed -n 's/^LD_AUDIT=//p' "$sb/launch.log" 2>/dev/null)"
for lib in "$sb/moon64/netsock64.so" "$SLS/SLSsteam.so"; do
    case ":$audit:" in
        *":$lib:"*) pass "a4: LD_AUDIT carries ${lib##*/} ($audit)" ;;
        *) fail "a4: LD_AUDIT carries ${lib##*/}" "got: $audit" ;;
    esac
done
assert_contains "a4: client is steamrt64" "STEAM_FORCE_CLIENT=steamrt64" "$(cat "$sb/launch.log" 2>/dev/null)"

# --- (b) netsock64 fails a check: refused, nothing staged -------------------
for variant in mismatch unbound repeated bad-sha elf32; do
    rel="$(make_release "b-$variant" "$variant")"
    sb="$(make_sandbox "b-$variant")"
    out="$(run "$sb" "$rel" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
    assert_rc "b-$variant: install.sh stops" 1 "$rc" "$out"
    case "$variant" in
        mismatch) assert_contains "b-$variant: says why" "pattern-status.txt names netsock64.so $(sha "$rel/SLSsteam.so"), not the downloaded $(sha "$rel/netsock64.so")" "$out" ;;
        unbound|repeated) assert_contains "b-$variant: says why" "must name the netsock64.so released with it with exactly one netsock64_sha256= line" "$out" ;;
        bad-sha) assert_contains "b-$variant: says why" "prebuilt netsock64.so sha256 $(sha "$rel/netsock64.so") does not match the published 0000" "$out" ;;
        elf32) assert_contains "b-$variant: says why" "prebuilt netsock64.so is not a 64-bit x86-64 shared object" "$out" ;;
    esac
    assert_contains "b-$variant: refuses instead of falling back" "refusing to stage an unverified prebuilt netsock64.so; nothing was staged" "$out"
    assert_absent "b-$variant: no SLSsteam.so.64" "$sb/moon64/SLSsteam.so.64"
    assert_absent "b-$variant: no netsock64.so" "$sb/moon64/netsock64.so"
    assert_absent "b-$variant: no state" "$sb/moon64/slsteam64.state"
    assert_absent "b-$variant: no rollback download" "$sb/home/.local/share/SLSsteam"
    assert_not_contains "b-$variant: stopped before stopping Steam" "Steam is not running" "$out"
done

# --- (c) no .sha256 for netsock64: the binding alone vouches for it ---------
rel="$(make_release c no-sha)"
sb="$(make_sandbox c)"
out="$(run "$sb" "$rel" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "c1: install succeeds" 0 "$rc" "$out"
assert_contains "c1: says so" "no file://$rel/netsock64.so.sha256 published; netsock64.so is only checked against the netsock64_sha256 in pattern-status.txt" "$out"
assert_same "c1: staged" "$rel/netsock64.so" "$sb/moon64/netsock64.so"
out="$(run "$sb" "$rel" bash "$sb/moon64/moon64" doctor 2>&1)"
assert_contains "c2: doctor repeats it" "netsock64.so present (prebuilt, downloaded from file://$rel/netsock64.so (no .sha256 published; checked against pattern-status.txt only))" "$out"

# --- (d) release without netsock64.so -----------------------------------------
rel="$(make_release d absent)"
sb="$(make_sandbox d1)"
out="$(run "$sb" "$rel" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "d1: without gcc the install still succeeds" 0 "$rc" "$out"
assert_contains "d1: says the release has none" "the release has no file://$rel/netsock64.so" "$out"
assert_contains "d1: says the cert patch is inactive" "the release has no netsock64.so and gcc is not installed to build it: the P2P cert patch will be inactive" "$out"
assert_contains "d1: degraded, not failed" "this is a degraded feature, not a failed install" "$out"
assert_contains "d1: summary" "netsock64.so: none (the P2P cert patch is inactive)" "$out"
assert_absent "d1: no netsock64.so" "$sb/moon64/netsock64.so"
assert_same "d1: SLSsteam.so still staged" "$rel/SLSsteam.so" "$sb/moon64/SLSsteam.so.64"

sb="$(make_sandbox d2)"
out="$(SANDBOX_PATH="$PATH" run "$sb" "$rel" bash "$REPO_ROOT/install.sh" --prebuilt 2>&1)"; rc=$?
assert_rc "d2: with gcc it is built from patches/netsock64" 0 "$rc" "$out"
assert_contains "d2: summary" "netsock64.so: built from $REPO_ROOT/patches/netsock64/steamclient_audit64.c" "$out"
assert_contains "d2: state records the build" "source=built" "$(cat "$sb/moon64/netsock64.state" 2>/dev/null)"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
