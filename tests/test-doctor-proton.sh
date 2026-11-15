#!/usr/bin/env bash
# Sandbox test for `moon64 doctor` Proton diagnostics and GLIBCXX error reporting.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*)
            printf 'PASS [%s]\n' "$label"
            PASS=$((PASS + 1))
            ;;
        *)
            printf 'FAIL [%s]: missing %q in:\n%s\n' "$label" "$substr" "$text" >&2
            FAIL=$((FAIL + 1))
            ;;
    esac
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" -eq "$actual" ]; then
        printf 'PASS [%s] (rc=%s)\n' "$label" "$actual"
        PASS=$((PASS + 1))
    else
        printf 'FAIL [%s]: expected rc=%s, got rc=%s\n' "$label" "$expected" "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

FAKE_HOME="$TMP_ROOT/home"
FAKE_MOON="$TMP_ROOT/moon64"
FAKE_CFG="$TMP_ROOT/config"
STEAM_DIR="$FAKE_HOME/.local/share/Steam"
SLS_DIR="$FAKE_HOME/.local/share/SLSsteam"
FIX_DIR="$FAKE_HOME/.local/share/Lumen/fix_installs"
GAMES_DIR="$TMP_ROOT/games"

mkdir -p \
    "$FAKE_HOME" "$FAKE_MOON" "$FAKE_CFG/environment.d" \
    "$STEAM_DIR/steamrt64" "$SLS_DIR" \
    "$FIX_DIR/526870" "$FIX_DIR/999001" "$FIX_DIR/999002" "$FIX_DIR/999003" \
    "$GAMES_DIR/Satisfactory" "$GAMES_DIR/EmptyFix" "$GAMES_DIR/MissingList"

# Minimal 64-bit shared library so elfbits + ldd -r succeed cleanly on host.
printf 'int moon64_test_sym(void) { return 42; }\n' > "$TMP_ROOT/stub.c"
gcc -shared -fPIC "$TMP_ROOT/stub.c" -o "$FAKE_MOON/SLSsteam.so.64"
: > "$FAKE_MOON/netsock64.so"
: > "$STEAM_DIR/steamrt64/steamclient.so"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STEAM_DIR/steamrt64/steam"
chmod +x "$STEAM_DIR/steamrt64/steam"

# environment.d entry
cat > "$FAKE_CFG/environment.d/proton.conf" <<'CONF'
# comment
WINEDLLOVERRIDES=winmm=n,b
PROTON_LOG=1
CONF

# Managed games:
# 526870 -> .slssteam_fix_dlls with 3 DLLs
printf '{"installPath":"%s/Satisfactory"}\n' "$GAMES_DIR" > "$FIX_DIR/526870/manifest.json"
printf 'SteamFix64.dll\nEpicFix64.dll\nwinmm.dll\n' > "$GAMES_DIR/Satisfactory/.slssteam_fix_dlls"

# 999001 -> .slssteam_fix_dlls present, empty (0 DLLs)
printf '{"installPath":"%s/EmptyFix"}\n' "$GAMES_DIR" > "$FIX_DIR/999001/manifest.json"
: > "$GAMES_DIR/EmptyFix/.slssteam_fix_dlls"

# 999002 -> .slssteam_fix_dlls missing (warn, non-blocking)
printf '{"installPath":"%s/MissingList"}\n' "$GAMES_DIR" > "$FIX_DIR/999002/manifest.json"

# 999003 -> installPath does not exist on disk (warn, non-blocking)
printf '{"installPath":"%s/NoSuchGame"}\n' "$GAMES_DIR" > "$FIX_DIR/999003/manifest.json"

doc_out="$(
    HOME="$FAKE_HOME" \
    XDG_CONFIG_HOME="$FAKE_CFG" \
    MOON64_DIR="$FAKE_MOON" \
    LUMEN_FIX_INSTALLS_DIR="$FIX_DIR" \
    WINEDLLOVERRIDES="SteamFix64=n,b" \
    PROTON_NO_FSYNC="1" \
    bash "$REPO_ROOT/bin/moon64" doctor 2>&1
)"
doc_rc=$?

assert_rc "doctor non-blocking despite missing .slssteam_fix_dlls" 0 "$doc_rc"
assert_contains "doctor prints proton section" "-- proton --" "$doc_out"
assert_contains "doctor reports env WINEDLLOVERRIDES" "env: WINEDLLOVERRIDES=SteamFix64=n,b" "$doc_out"
assert_contains "doctor reports env PROTON_*" "PROTON_NO_FSYNC=1" "$doc_out"
assert_contains "doctor reports environment.d WINEDLLOVERRIDES" "environment.d (proton.conf): WINEDLLOVERRIDES=winmm=n,b" "$doc_out"
assert_contains "doctor reports environment.d PROTON_LOG" "environment.d (proton.conf): PROTON_LOG=1" "$doc_out"
assert_contains "doctor reports present .slssteam_fix_dlls count" "app 526870 (Satisfactory): .slssteam_fix_dlls present (3 DLL(s))" "$doc_out"
assert_contains "doctor reports empty .slssteam_fix_dlls" "app 999001 (EmptyFix): .slssteam_fix_dlls present (0 DLLs" "$doc_out"
assert_contains "doctor warns on missing .slssteam_fix_dlls" "app 999002 (MissingList): .slssteam_fix_dlls missing" "$doc_out"
assert_contains "doctor warns on absent installPath" "app 999003: installPath absent on disk" "$doc_out"

# Test explicit GLIBCXX diagnostic when ldd reports missing GLIBCXX_3.4.32
FAKE_LDD_BIN="$TMP_ROOT/fake-ldd-bin"
mkdir -p "$FAKE_LDD_BIN"
cat > "$FAKE_LDD_BIN/ldd" <<'SH'
#!/usr/bin/env bash
printf '%s: /usr/lib/libstdc++.so.6: version `GLIBCXX_3.4.32'\'' not found (required by %s)\n' "$2" "$2"
printf '\tlibstdc++.so.6 => /usr/lib/libstdc++.so.6 (0x00007f0000000000)\n'
printf '\tlibc.so.6 => /usr/lib/libc.so.6 (0x00007f0000100000)\n'
SH
chmod +x "$FAKE_LDD_BIN/ldd"

glibcxx_out="$(
    PATH="$FAKE_LDD_BIN:$PATH" \
    HOME="$FAKE_HOME" \
    XDG_CONFIG_HOME="$FAKE_CFG" \
    MOON64_DIR="$FAKE_MOON" \
    LUMEN_FIX_INSTALLS_DIR="$FIX_DIR" \
    bash "$REPO_ROOT/bin/moon64" doctor 2>&1
)"
glibcxx_rc=$?

assert_rc "doctor fails when GLIBCXX_3.4.32 missing" 1 "$glibcxx_rc"
assert_contains "doctor emits explicit GLIBCXX message" "requires a newer libstdc++" "$glibcxx_out"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
