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
            mkdir -p "$TMP_ROOT/home/.local/share/moon64"
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
        cp "$PROBE_BIN" "$TMP_ROOT/steam"
        cp "$PROBE_BIN" "$TMP_ROOT/notsteam"
        mkdir -p "$TMP_ROOT/home-steam/.local/share/moon64" \
                 "$TMP_ROOT/home-other/.local/share/moon64"

        HOME="$TMP_ROOT/home-steam" LD_AUDIT="$SO" "$TMP_ROOT/steam" >/dev/null 2>&1
        steam_log="$TMP_ROOT/home-steam/.local/share/moon64/moon64-netsock.log"
        if [ -f "$steam_log" ] && grep -Fq 'audit loaded, la_version ' "$steam_log"; then
            pass "probe: steam-named host writes audit loaded log line"
        else
            fail "probe: steam-named host writes audit loaded log line" "missing or empty log: $steam_log"
        fi

        HOME="$TMP_ROOT/home-other" LD_AUDIT="$SO" "$TMP_ROOT/notsteam" >/dev/null 2>&1
        other_log="$TMP_ROOT/home-other/.local/share/moon64/moon64-netsock.log"
        if [ ! -e "$other_log" ]; then
            pass "probe: non-steam host does not write audit loaded log"
        else
            fail "probe: non-steam host does not write audit loaded log" "unexpected log: $other_log"
        fi
    fi
else
    printf 'SKIP [compiler checks]: gcc not installed\n'
fi

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
