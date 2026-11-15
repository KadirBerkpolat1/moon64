#!/usr/bin/env bash
# Sandbox test for bin/wrapper.64.sh: verifies WINEDLLOVERRIDES and PROTON_*
# pass through untouched alongside the 64-bit LD_AUDIT / STEAM_FORCE_CLIENT setup.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        printf 'PASS [%s]\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL [%s]: expected %q, got %q\n' "$label" "$expected" "$actual" >&2
        FAIL=$((FAIL + 1))
    fi
}

pass() {
    printf 'PASS [%s]\n' "$1"
    PASS=$((PASS + 1))
}

fail() {
    printf 'FAIL [%s]: %s\n' "$1" "$2" >&2
    FAIL=$((FAIL + 1))
}

FAKE_HOME="$TMP_ROOT/home"
FAKE_MOON="$TMP_ROOT/moon64"
FAKE_BIN="$TMP_ROOT/bin"
STEAM_DIR="$FAKE_HOME/.local/share/Steam"
SLS_DIR="$FAKE_HOME/.local/share/SLSsteam"

mkdir -p "$FAKE_HOME" "$FAKE_MOON" "$FAKE_BIN" "$STEAM_DIR/steamrt64" "$SLS_DIR"

# Stub systemctl so host systemd user services are never queried/started.
cat > "$FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAKE_BIN/systemctl"

# Stub netsock64.so and SLSsteam.so (wrapper checks -f before adding to LD_AUDIT).
: > "$FAKE_MOON/netsock64.so"
: > "$SLS_DIR/SLSsteam.so"

# Fake steamrt64/steam and steam.sh; steam.sh records received env & args.
cat > "$STEAM_DIR/steamrt64/steam" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STEAM_DIR/steamrt64/steam"

DUMP_FILE="$TMP_ROOT/steam-env.dump"
cat > "$STEAM_DIR/steam.sh" <<SH
#!/usr/bin/env bash
{
    printf 'STEAM_FORCE_CLIENT=%s\n' "\${STEAM_FORCE_CLIENT-<UNSET>}"
    printf 'LD_AUDIT=%s\n' "\${LD_AUDIT-<UNSET>}"
    printf 'WINEDLLOVERRIDES=%s\n' "\${WINEDLLOVERRIDES-<UNSET>}"
    printf 'WINEDLLOVERRIDES_SET=%s\n' "\${WINEDLLOVERRIDES+SET}"
    printf 'PROTON_LOG=%s\n' "\${PROTON_LOG-<UNSET>}"
    printf 'PROTON_ENABLE_WAYLAND=%s\n' "\${PROTON_ENABLE_WAYLAND-<UNSET>}"
    printf 'PROTON_NO_ESYNC=%s\n' "\${PROTON_NO_ESYNC-<UNSET>}"
    printf 'PROTON_USE_WINED3D=%s\n' "\${PROTON_USE_WINED3D-<UNSET>}"
    printf 'PROTON_EXTRA_CUSTOM=%s\n' "\${PROTON_EXTRA_CUSTOM-<UNSET>}"
    printf 'ARGS=%s\n' "\$*"
} > "$DUMP_FILE"
SH
chmod +x "$STEAM_DIR/steam.sh"

# Case 1: WINEDLLOVERRIDES + multiple PROTON_* vars + foreign LD_AUDIT + stale own auditor
env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$FAKE_HOME" \
    MOON64_DIR="$FAKE_MOON" \
    LD_AUDIT="/old/SLSsteam.so:/foreign/auditor.so:/old/netsock64.so" \
    WINEDLLOVERRIDES="winmm=n,b;SteamFix64=n,b" \
    PROTON_LOG="1" \
    PROTON_ENABLE_WAYLAND="1" \
    PROTON_NO_ESYNC="1" \
    PROTON_USE_WINED3D="0" \
    PROTON_EXTRA_CUSTOM="keep me=1" \
    bash "$REPO_ROOT/bin/wrapper.64.sh" --foo "bar baz"

# shellcheck disable=SC1090
dump1="$(cat "$DUMP_FILE")"
val_of() {
    local key="$1"
    awk -F= -v k="$key" '$1==k{sub(/^[^=]*=/,""); print; exit}' <<<"$dump1"
}

assert_eq "case1 STEAM_FORCE_CLIENT" "steamrt64" "$(val_of STEAM_FORCE_CLIENT)"
assert_eq "case1 LD_AUDIT order + foreign kept + own stripped" \
    "$FAKE_MOON/netsock64.so:$SLS_DIR/SLSsteam.so:/foreign/auditor.so" \
    "$(val_of LD_AUDIT)"
assert_eq "case1 WINEDLLOVERRIDES preserved" "winmm=n,b;SteamFix64=n,b" "$(val_of WINEDLLOVERRIDES)"
assert_eq "case1 PROTON_LOG preserved" "1" "$(val_of PROTON_LOG)"
assert_eq "case1 PROTON_ENABLE_WAYLAND preserved" "1" "$(val_of PROTON_ENABLE_WAYLAND)"
assert_eq "case1 PROTON_NO_ESYNC preserved" "1" "$(val_of PROTON_NO_ESYNC)"
assert_eq "case1 PROTON_USE_WINED3D preserved" "0" "$(val_of PROTON_USE_WINED3D)"
assert_eq "case1 PROTON_EXTRA_CUSTOM preserved" "keep me=1" "$(val_of PROTON_EXTRA_CUSTOM)"
assert_eq "case1 args preserved" "--foo bar baz" "$(val_of ARGS)"

# Case 2: Unset WINEDLLOVERRIDES and PROTON_* stay unset
rm -f "$DUMP_FILE"
env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$FAKE_HOME" \
    MOON64_DIR="$FAKE_MOON" \
    bash "$REPO_ROOT/bin/wrapper.64.sh"

dump1="$(cat "$DUMP_FILE")"
assert_eq "case2 WINEDLLOVERRIDES stays unset" "<UNSET>" "$(val_of WINEDLLOVERRIDES)"
assert_eq "case2 WINEDLLOVERRIDES_SET empty" "" "$(val_of WINEDLLOVERRIDES_SET)"
assert_eq "case2 PROTON_LOG stays unset" "<UNSET>" "$(val_of PROTON_LOG)"

# Case 3: Explicitly empty WINEDLLOVERRIDES="" stays set and empty
rm -f "$DUMP_FILE"
env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$FAKE_HOME" \
    MOON64_DIR="$FAKE_MOON" \
    WINEDLLOVERRIDES="" \
    bash "$REPO_ROOT/bin/wrapper.64.sh"

dump1="$(cat "$DUMP_FILE")"
assert_eq "case3 WINEDLLOVERRIDES stays set when empty" "SET" "$(val_of WINEDLLOVERRIDES_SET)"
assert_eq "case3 WINEDLLOVERRIDES value stays empty" "" "$(val_of WINEDLLOVERRIDES)"

# Case 4: netsock64.state sha256 mismatch skips netsock64.so and logs plainly
rm -f "$DUMP_FILE"
printf 'source=prebuilt\nsha256=%064d\n' 0 > "$FAKE_MOON/netsock64.state"
err4="$(env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$FAKE_HOME" \
    MOON64_DIR="$FAKE_MOON" \
    bash "$REPO_ROOT/bin/wrapper.64.sh" 2>&1)"; rc4=$?
dump1="$(cat "$DUMP_FILE")"
assert_eq "case4 wrapper exits 0 when SLSsteam.so is valid" "0" "$rc4"
assert_eq "case4 LD_AUDIT skips mismatched netsock64.so" "$SLS_DIR/SLSsteam.so" "$(val_of LD_AUDIT)"
case "$err4" in
    *"P2P cert patch skipped"*) pass "case4 stderr explains cert patch skipped" ;;
    *) fail "case4 stderr explains cert patch skipped" "got: $err4" ;;
esac

# Case 5: SLSM_ALLOW_UNVERIFIED_NETSOCK=1 loads despite sha256 mismatch
rm -f "$DUMP_FILE"
err5="$(env -i \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    HOME="$FAKE_HOME" \
    MOON64_DIR="$FAKE_MOON" \
    SLSM_ALLOW_UNVERIFIED_NETSOCK=1 \
    bash "$REPO_ROOT/bin/wrapper.64.sh" 2>&1)"; rc5=$?
dump1="$(cat "$DUMP_FILE")"
assert_eq "case5 wrapper exits 0 with override" "0" "$rc5"
assert_eq "case5 LD_AUDIT includes netsock64.so with override" "$FAKE_MOON/netsock64.so:$SLS_DIR/SLSsteam.so" "$(val_of LD_AUDIT)"
case "$err5" in
    *"SLSM_ALLOW_UNVERIFIED_NETSOCK=1"*) pass "case5 stderr warns on override" ;;
    *) fail "case5 stderr warns on override" "got: $err5" ;;
esac

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
