#!/usr/bin/env bash
# Sandbox test for the fail-closed x86_64 pattern-table gate in install.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Source install.sh only to load check_pattern_gate (no staging runs).
# shellcheck disable=SC1091
source "$REPO_ROOT/install.sh"

PASS=0
FAIL=0

run_gate_case() {
    local name="$1"
    local expect_rc="$2"
    local allow_override="$3"
    local content="$4"
    local expect_substr="${5:-}"
    local case_dir out rc

    case_dir="$TMP_ROOT/case-$PASS-$FAIL"
    mkdir -p "$case_dir"

    if [ "$content" != "__MISSING__" ]; then
        mkdir -p "$case_dir/res"
        printf '%s\n' "$content" > "$case_dir/res/pattern-status.txt"
    fi

    out="$(
        SLSM_ALLOW_INCOMPLETE_PATTERNS="$allow_override" \
            check_pattern_gate "$case_dir" 2>&1
    )"
    rc=$?

    if [ "$rc" -ne "$expect_rc" ]; then
        printf 'FAIL [%s]: expected rc=%s, got rc=%s\n%s\n' "$name" "$expect_rc" "$rc" "$out" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi

    if [ -n "$expect_substr" ]; then
        case "$out" in
            *"$expect_substr"*) ;;
            *)
                printf 'FAIL [%s]: output missing %q\n%s\n' "$name" "$expect_substr" "$out" >&2
                FAIL=$((FAIL + 1))
                return 1
                ;;
        esac
    fi

    printf 'PASS [%s] (rc=%s)\n' "$name" "$rc"
    PASS=$((PASS + 1))
    return 0
}

# 1. File missing -> refuse
run_gate_case "file missing" 1 0 "__MISSING__" "status file missing"

# 2. Arch missing / wrong -> refuse
run_gate_case "arch missing" 1 0 \
$'required=38\nresolved=38\npending=0\nrunipcframe_tail=ready' \
"arch must be x86_64"

run_gate_case "arch wrong (i386)" 1 0 \
$'arch=i386\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready' \
"arch must be x86_64"

# 3. Any key missing or non-numeric -> refuse
run_gate_case "required missing" 1 0 \
$'arch=x86_64\nresolved=38\npending=0\nrunipcframe_tail=ready' \
"required must be present"

run_gate_case "resolved missing" 1 0 \
$'arch=x86_64\nrequired=38\npending=0\nrunipcframe_tail=ready' \
"resolved must be present"

run_gate_case "pending missing" 1 0 \
$'arch=x86_64\nrequired=38\nresolved=38\nrunipcframe_tail=ready' \
"pending must be present"

run_gate_case "runipcframe_tail missing" 1 0 \
$'arch=x86_64\nrequired=38\nresolved=38\npending=0' \
"runipcframe_tail must be 'ready'"

run_gate_case "pending non-numeric" 1 0 \
$'arch=x86_64\nrequired=38\nresolved=38\npending=zero\nrunipcframe_tail=ready' \
"pending must be present and numeric"

# 4. resolved + pending != required -> refuse
run_gate_case "resolved+pending != required" 1 0 \
$'arch=x86_64\nrequired=38\nresolved=37\npending=0\nrunipcframe_tail=ready' \
"!= required"

# 5. pending != 0 -> refuse
run_gate_case "pending != 0" 1 0 \
$'arch=x86_64\nrequired=38\nresolved=21\npending=17\nrunipcframe_tail=ready' \
"pending is 17"

# 6. runipcframe_tail=complete -> refuse (must accept ONLY ready)
run_gate_case "runipcframe_tail=complete rejected" 1 0 \
$'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=complete' \
"runipcframe_tail must be 'ready'"

# 7. runipcframe_tail=ready & pending=0 & arch ok -> pass
run_gate_case "complete & ready -> pass" 0 0 \
$'# comment\narch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready' \
"pattern table complete"

# 8. SLSM_ALLOW_INCOMPLETE_PATTERNS=1 -> warn + pass (missing file & incomplete)
run_gate_case "override on missing file -> warn+pass" 0 1 \
"__MISSING__" \
"WARNING: BYPASSING"

run_gate_case "override on incomplete table -> warn+pass" 0 1 \
$'arch=x86_64\nrequired=38\nresolved=21\npending=17\nrunipcframe_tail=complete' \
"WARNING: BYPASSING"

# 9. End-to-end sandbox invocation of install.sh (aborts before make/staging)
e2e_home="$TMP_ROOT/e2e-home"
e2e_moon="$TMP_ROOT/e2e-moon"
e2e_src="$TMP_ROOT/e2e-src"
e2e_bin="$TMP_ROOT/e2e-bin"
mkdir -p "$e2e_home" "$e2e_moon" "$e2e_src/res" "$e2e_bin"
printf 'all:\n\t@echo SHOULD_NOT_RUN_MAKE; exit 99\n' > "$e2e_src/Makefile"
printf 'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=complete\n' > "$e2e_src/res/pattern-status.txt"

e2e_out="$(
    HOME="$e2e_home" MOON64_DIR="$e2e_moon" SLS64_SRC="$e2e_src" \
        bash "$REPO_ROOT/install.sh" 2>&1
)"
e2e_rc=$?
if [ "$e2e_rc" -eq 0 ]; then
    printf 'FAIL [e2e install.sh refuse]: expected non-zero exit, got 0\n%s\n' "$e2e_out" >&2
    FAIL=$((FAIL + 1))
else
    case "$e2e_out" in
        *SHOULD_NOT_RUN_MAKE*)
            printf 'FAIL [e2e install.sh refuse]: make ran past gate\n%s\n' "$e2e_out" >&2
            FAIL=$((FAIL + 1))
            ;;
        *"refusing to stage an incomplete build"*)
            printf 'PASS [e2e install.sh refuses before build] (rc=%s)\n' "$e2e_rc"
            PASS=$((PASS + 1))
            ;;
        *)
            printf 'FAIL [e2e install.sh refuse]: unexpected output\n%s\n' "$e2e_out" >&2
            FAIL=$((FAIL + 1))
            ;;
    esac
fi

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
