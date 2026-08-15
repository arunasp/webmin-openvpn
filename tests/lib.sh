#!/bin/bash
# Assertions and dependency mocking for the tool suites.
#
# Vendored rather than sourced from anywhere else: the suite has to run inside
# a CI worker that mounts this repository and nothing else.
#
# The mocking exists because two of the dependencies cannot be exercised for
# real here. systemctl needs an init system, and the root check needs a uid
# the worker does not have. Faking those on PATH is what lets the same suite
# produce the same result as root in a sandbox and as uid 1000 in a worker.

TESTS_RUN=0
TESTS_FAILED=0
FAILED_NAMES=()

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '[PASS] %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    FAILED_NAMES+=("$1")
    printf '[FAIL] %s: %s\n' "$1" "$2"
}

assert_eq() {
    local name=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name" "expected '$expected', got '$actual'"
    fi
}

assert_exit() {
    local name=$1 expected=$2 actual=$3
    if [ "$expected" -eq "$actual" ]; then
        pass "$name (exit $expected)"
    else
        fail "$name" "expected exit $expected, got $actual"
    fi
}

assert_contains() {
    local name=$1 haystack=$2 needle=$3
    case "$haystack" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "output does not contain '$needle'" ;;
    esac
}

assert_not_contains() {
    local name=$1 haystack=$2 needle=$3
    case "$haystack" in
        *"$needle"*) fail "$name" "output unexpectedly contains '$needle'" ;;
        *) pass "$name" ;;
    esac
}

assert_file_contains() {
    local name=$1 file=$2 needle=$3
    if [ -f "$file" ] && grep -q -- "$needle" "$file"; then
        pass "$name"
    else
        fail "$name" "$file does not contain '$needle'"
    fi
}

assert_file_absent() {
    local name=$1 file=$2
    if [ -e "$file" ]; then
        fail "$name" "$file exists and should not"
    else
        pass "$name"
    fi
}

# mock_bin <dir> <name> <body> -- a fake binary that behaves like the real
# tool in one specific scenario. A fake that always succeeds tests nothing.
mock_bin() {
    local dir=$1 name=$2 body=$3
    mkdir -p "$dir"
    {
        printf '#!/bin/bash\n'
        printf '%s\n' "$body"
    } > "$dir/$name"
    chmod 755 "$dir/$name"
}

report() {
    printf '\n=== TEST REPORT ===\n'
    printf 'ran    %d\n' "$TESTS_RUN"
    printf 'failed %d\n' "$TESTS_FAILED"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf 'failing assertions:\n'
        printf '  %s\n' "${FAILED_NAMES[@]}"
        return 1
    fi
    printf 'all assertions passed\n'
}
