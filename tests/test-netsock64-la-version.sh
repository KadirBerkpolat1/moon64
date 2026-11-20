#!/usr/bin/env bash
# Regression test for netsock64 la_version negotiation (issue: hard-returning
# LAV_CURRENT aborts ld.so on glibc <= 2.34 when built on glibc >= 2.35).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/patches/netsock64/steamclient_audit64.c"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { printf 'PASS [%s]\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

# 1. Source-level check: no unconditional `return LAV_CURRENT;`, negotiation present.
if grep -Eq '^[[:space:]]*return[[:space:]]+LAV_CURRENT[[:space:]]*;' "$SRC"; then
    fail "source: no unconditional return LAV_CURRENT" "found unconditional 'return LAV_CURRENT;' in $SRC"
else
    pass "source: no unconditional return LAV_CURRENT"
fi

if grep -Fq 'version < LAV_CURRENT ? version : LAV_CURRENT' "$SRC"; then
    pass "source: negotiation expression present"
else
    fail "source: negotiation expression present" "missing negotiation clamp in $SRC"
fi

# 2. Compiler + LD_AUDIT host probe checks.
if command -v gcc >/dev/null 2>&1; then
    SO="$TMP_ROOT/netsock64.so"
    if gcc -O2 -Wall -Wextra -Wpedantic -shared -fPIC -o "$SO" "$SRC" -ldl; then
        pass "build: gcc -O2 -Wall -Wextra -Wpedantic -shared -fPIC"
    else
        fail "build: gcc -O2 -Wall -Wextra -Wpedantic -shared -fPIC" "compilation failed"
        SO=""
    fi

    if [ -n "$SO" ]; then
        PROBE_SRC="$TMP_ROOT/probe.c"
        PROBE_BIN="$TMP_ROOT/probe"
        cat > "$PROBE_SRC" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdio.h>

typedef unsigned int (*la_version_fn)(unsigned int);

int main(int argc, char **argv) {
    if (argc < 2) {
        return 0;
    }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }
    la_version_fn fn = (la_version_fn)(uintptr_t)dlsym(h, "la_version");
    if (!fn) {
        fprintf(stderr, "dlsym(la_version) failed: %s\n", dlerror());
        dlclose(h);
        return 3;
    }

    unsigned int host_lav = LAV_CURRENT;
    unsigned int r_host = fn(host_lav);
    unsigned int r_v1 = fn(1);
    unsigned int r_high = fn(host_lav + 5);
    unsigned int r_zero = fn(0);

    printf("host_lav=%u r_host=%u r_v1=%u r_high=%u r_zero=%u\n",
           host_lav, r_host, r_v1, r_high, r_zero);

    int bad = 0;
    if (r_host == 0 || r_host > host_lav) bad = 1;
    if (r_v1 == 0 || r_v1 > 1) bad = 1;
    if (r_high == 0 || r_high > host_lav) bad = 1;
    if (r_zero != host_lav) bad = 1;

    dlclose(h);
    return bad ? 4 : 0;
}
EOF
        if gcc -O2 -Wall -Wextra -o "$PROBE_BIN" "$PROBE_SRC" -ldl; then
            probe_out="$(HOME="$TMP_ROOT/home" "$PROBE_BIN" "$SO" 2>&1)"
            probe_rc=$?
            if [ "$probe_rc" -eq 0 ]; then
                pass "probe: la_version returns <= offered version ($probe_out)"
            else
                fail "probe: la_version returns <= offered version" "rc=$probe_rc out=$probe_out"
            fi

            audit_out="$(HOME="$TMP_ROOT/home" LD_AUDIT="$SO" "$PROBE_BIN" 2>&1)"
            audit_rc=$?
            if [ "$audit_rc" -eq 0 ]; then
                pass "probe: LD_AUDIT load under host ld.so succeeds"
            else
                fail "probe: LD_AUDIT load under host ld.so succeeds" "rc=$audit_rc out=$audit_out"
            fi
        else
            fail "probe: compile host probe" "gcc failed"
        fi

        # Gate checks: a host that dlopens a library named steamclient.so, so
        # la_objopen sees the same object a Steam client or a game loading
        # ~/.steam/sdk64/steamclient.so would.  Copied as "steam" and as
        # non-Steam names, including ones that only start with "steam" (Proton's
        # steam.exe, steamwebhelper, the launcher script), to flip
        # is_steam_process().
        LOADER_SRC="$TMP_ROOT/loader.c"
        LOADER_BIN="$TMP_ROOT/loader"
        cat > "$LOADER_SRC" <<'EOF'
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) {
        return 1;
    }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) {
        fprintf(stderr, "dlopen failed: %s\n", dlerror());
        return 2;
    }
    dlclose(h);
    return 0;
}
EOF
        mkdir -p "$TMP_ROOT/fake"
        FAKE_CLIENT="$TMP_ROOT/fake/steamclient.so"
        printf 'int moon64_fake_steamclient = 1;\n' > "$TMP_ROOT/fake/steamclient.c"
        if gcc -O2 -Wall -Wextra -o "$LOADER_BIN" "$LOADER_SRC" -ldl \
            && gcc -shared -fPIC -o "$FAKE_CLIENT" "$TMP_ROOT/fake/steamclient.c"; then
            cp "$LOADER_BIN" "$TMP_ROOT/steam"
            OTHER_NAMES=(notsteam steam.exe steamwebhelper steam.sh)
            mkdir -p "$TMP_ROOT/other"
            for name in "${OTHER_NAMES[@]}"; do
                cp "$LOADER_BIN" "$TMP_ROOT/other/$name"
            done

            # A real $HOME exists; only .cache may be absent.  Provide every home
            # dir but leave .cache missing so the shim's own mkdir of .cache
            # (and .cache/moon64) is what creates the log path: a non-steam
            # process that slips past the gate would create it too.
            mkdir -p "$TMP_ROOT/home-steam"

            HOME="$TMP_ROOT/home-steam" LD_AUDIT="$SO" "$TMP_ROOT/steam" "$FAKE_CLIENT" >/dev/null 2>&1
            steam_rc=$?
            steam_log="$TMP_ROOT/home-steam/.cache/moon64/netsock.log"
            if [ "$steam_rc" -eq 0 ] && [ -f "$steam_log" ] && grep -Fq 'audit loaded, la_version ' "$steam_log"; then
                pass "probe: steam-named host writes audit loaded log line"
            else
                fail "probe: steam-named host writes audit loaded log line" "rc=$steam_rc, missing or empty log: $steam_log"
            fi
            if [ -f "$steam_log" ] && grep -Fq "steamclient.so opened: $FAKE_CLIENT" "$steam_log"; then
                pass "probe: steam-named host scans an opened steamclient.so"
            else
                fail "probe: steam-named host scans an opened steamclient.so" "no 'steamclient.so opened' line in $steam_log"
            fi

            for name in "${OTHER_NAMES[@]}"; do
                other_home="$TMP_ROOT/home-other-$name"
                mkdir -p "$other_home"
                HOME="$other_home" LD_AUDIT="$SO" "$TMP_ROOT/other/$name" "$FAKE_CLIENT" >/dev/null 2>&1
                other_rc=$?
                other_log="$other_home/.cache/moon64/netsock.log"
                check="probe: non-steam host '$name' opening steamclient.so leaves no log"
                if [ "$other_rc" -ne 0 ]; then
                    fail "$check" "loader rc=$other_rc, gate not exercised"
                elif [ -e "$other_log" ]; then
                    fail "$check" "unexpected log: $other_log"
                else
                    pass "$check"
                fi
            done
        else
            fail "probe: compile gate loader and fake steamclient.so" "gcc failed"
        fi
    fi
else
    printf 'SKIP [compiler checks]: gcc not installed\n'
fi

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
